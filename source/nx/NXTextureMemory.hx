package nx;

import flixel.FlxG;
import flixel.graphics.FlxGraphic;
import funkin.play.PlayState;

/**
 * Drops the CPU-side pixel copy of gameplay asset textures once they live on the GPU.
 *
 * On Switch every loaded texture otherwise exists twice in the same 3.2 GB unified memory pool:
 * the decoded lime `Image` (RGBA, width * height * 4 bytes) and the GPU texture uploaded by Mesa.
 * Flixel renders in DRAW_TILES mode through `beginShaderFill` + `drawQuads` / `drawTriangles`,
 * which OpenFL executes fully on the GPU, so gameplay never reads those CPU pixels.
 * OpenFL's `BitmapData.getTexture()` frees `image` after upload when `readable == false`.
 *
 * Only runs while a PlayState is active and only touches non-protected asset textures
 * (see `FunkinMemory.isProtectedGraphic`), so menus, fonts, UI, FlxBar, Polymod and
 * Freeplay atlases keep their CPU copies exactly like upstream.
 */
class NXTextureMemory
{
  static var initialized:Bool = false;

  /**
   * A/B switch for diagnostics (autotest scenarios containing NOTEXMEM disable this module).
   */
  public static var enabled:Bool = true;

  /** Diagnostic switches (autotest scenarios NOUPLOADREL / NOPOSTREL). */
  public static var releaseOnUpload:Bool = true;
  public static var releaseAfterCreate:Bool = true;
  static var lastPassStamp:Float = 0.0;

  /**
   * Interval between passes during gameplay. Textures created mid-song (props spawned by scripts,
   * game over sprites) are released once the renderer has uploaded them.
   */
  static final PASS_INTERVAL:Float = 1.0;

  static final EXCLUDED_PATTERNS:Array<String> = ["videos/", "stickers", "results", "freeplay", "charSelect", "menu"];

  public static function init():Void
  {
    if (initialized) return;
    initialized = true;
    FlxG.signals.preStateCreate.add(onPreStateCreate);
    FlxG.signals.postStateSwitch.add(onPostStateSwitch);
    FlxG.signals.postDraw.add(onPostDraw);
  }

  /**
   * Number of frames presented between destroying the previous state and building a PlayState.
   */
  static final FLUSH_FRAMES:Int = 2;

  static function onPreStateCreate(state:flixel.FlxState):Void
  {
    if (!enabled) return;
    // The previous state is destroyed and the new one is still empty: nothing alive uses gameplay atlases.
    var merged:Int = releaseMergedAtlases();
    var orphans:Int = releaseOrphanGeneratedGraphics();
    if (merged > 0 || orphans > 0) funkin.FunkinMemory.purgeStageCache(null);
    if (Std.isOfType(state, PlayState)) flushDeferredGpuFrees();
  }

  /**
   * Graphics built from runtime BitmapData get keys like "pixels123" and, with persist enabled, are never
   * cleared by FlxG.bitmap.clearCache(); FunkinMemory only purges asset keys by pattern, so hundreds of
   * them (60+ MB after a few weeks) accumulated across states. At preStateCreate nothing alive uses them.
   * @return Number of orphan generated graphics destroyed.
   */
  public static function releaseOrphanGeneratedGraphics():Int
  {
    var victims:Array<FlxGraphic> = [];
    var mb:Float = 0.0;
    @:privateAccess
    {
      if (FlxG.bitmap == null || FlxG.bitmap._cache == null) return 0;
      for (key => graphic in FlxG.bitmap._cache)
      {
        if (graphic == null || graphic.isDestroyed || graphic.useCount > 0) continue;
        if (key == null || key.indexOf("assets/") != -1) continue; // Asset textures are handled by FunkinMemory.
        if (funkin.FunkinMemory.isProtectedGraphic(key, graphic)) continue;
        victims.push(graphic);
      }
    }
    for (graphic in victims)
    {
      mb += (graphic.width * graphic.height * 4) / 1048576.0;
      FlxG.bitmap.remove(graphic);
      graphic.persist = false;
      graphic.destroy();
    }
    if (victims.length > 0)
    {
      NXDeepTrace.writeEntry('MEMORY', '[NXTextureMemory] Destroyed ${victims.length} orphan generated graphics (${Math.round(mb * 10) / 10} MB)');
    }
    return victims.length;
  }

  /**
   * MultiSparrowCharacter.buildSpritesheet() (upstream V-Slice) appends every extra sheet of a character
   * to the FlxAtlasFrames collection CACHED in its primary texture (`addAtlas`), which increments the use
   * count of each extra sheet forever. Those sheets (e.g. bfHoldingGF-DEAD.png, 128 MB in Week 7) then
   * survive every purge, even in the menus. Destroying the merged collections releases those counts; the
   * next character load rebuilds them exactly as before.
   * @return Number of merged collections released.
   */
  public static function releaseMergedAtlases():Int
  {
    var released:Int = 0;
    var names:Array<String> = [];
    @:privateAccess
    {
      if (FlxG.bitmap == null || FlxG.bitmap._cache == null) return 0;
      for (key => graphic in FlxG.bitmap._cache)
      {
        if (graphic == null || graphic.isDestroyed || graphic.frameCollections == null) continue;
        var atlases:Array<Dynamic> = graphic.frameCollections.get(flixel.graphics.frames.FlxFramesCollection.FlxFrameCollectionType.ATLAS);
        if (atlases == null) continue;
        for (collection in atlases.copy())
        {
          if (!Std.isOfType(collection, flixel.graphics.frames.FlxAtlasFrames)) continue;
          var atlas:flixel.graphics.frames.FlxAtlasFrames = cast collection;
          if (atlas.usedGraphics == null || atlas.usedGraphics.length == 0) continue;
          for (g in atlas.usedGraphics)
            if (g != null) names.push(g.key);
          atlases.remove(collection);
          atlas.destroy(); // decrementUseCount() on every appended sheet
          released++;
        }
      }
    }
    if (released > 0)
    {
      NXDeepTrace.writeEntry('MEMORY', '[NXTextureMemory] Released $released merged character atlases (sheets: ${names.join(", ")})');
    }
    return released;
  }

  /**
   * Mesa/nouveau on Horizon only returns the memory of deleted textures to the heap once a frame is
   * presented (glFinish is not enough). `FlxGame.switchState()` destroys the old state and builds the
   * new one inside the same frame, so without a present the previous stage (~500-700 MB on Weekend 1)
   * and the incoming one coexist at the loading peak, which ran 2Hot out of memory after Lit Up.
   * Presenting here (old state already destroyed and purged, new one still empty) releases it first.
   */
  public static function flushDeferredGpuFrees():Void
  {
    var before:Float = NXPerformance.getNativeHeapUsed();

    // The previous state is unreachable at preStateCreate. Menus (Freeplay, Character Select) are not
    // destroyed through PlayState.destroy(), so nothing collects their decoded images before the new
    // song loads (~650 MB retained after Freeplay with Pico -> 2Hot, which ran out of memory).
    #if cpp
    cpp.vm.Gc.run(true);
    cpp.vm.Gc.compact();
    #end
    var afterGc:Float = NXPerformance.getNativeHeapUsed();
    try
    {
      for (i in 0...FLUSH_FRAMES)
      {
        @:privateAccess FlxG.stage.__renderAfterEvent();
      }
    }
    catch (e:Dynamic)
    {
      NXDeepTrace.logWarning('[NXTextureMemory] Frame flush failed: $e');
      return;
    }
    var after:Float = NXPerformance.getNativeHeapUsed();
    NXDeepTrace.writeEntry('MEMORY', '[NXTextureMemory] Before PlayState.create: native malloc ${Math.round(before * 10) / 10} MB'
      + ' -> ${Math.round(afterGc * 10) / 10} MB after full GC -> ${Math.round(after * 10) / 10} MB after presenting $FLUSH_FRAMES frames'
      + ' | largest free block ${Math.round(NXPerformance.getLargestAllocatableMB())} MB');
  }

  static function onPostStateSwitch():Void
  {
    if (!enabled) return;
    // Upload the freshly built stage / characters / note style now (we are still in the loading frame)
    // and drop their CPU copies before the first gameplay frame.
    if (PlayState.instance != null && releaseAfterCreate) releaseCpuCopies(true, 'enter ${PlayState.instance.currentSong?.id}');
  }

  static function onPostDraw():Void
  {
    if (!enabled) return;
    if (PlayState.instance == null || !releaseAfterCreate) return;
    var now:Float = haxe.Timer.stamp();
    if (now - lastPassStamp < PASS_INTERVAL) return;
    lastPassStamp = now;
    // Mid-song: never force an upload (avoids hitches), only release textures the renderer already uploaded.
    releaseCpuCopies(false, null);
  }

  /**
   * Uploads a texture and frees its CPU copy without OpenFL's premultiply clone: getTexture() clones the
   * whole image (one more width*height*4 block, 64 MB for a 4096x4096 atlas) when it is not premultiplied.
   * Premultiplying in place first halves the large contiguous allocations while a song loads, which is
   * what fails first on a fragmented heap after long sessions.
   */
  static function uploadAndDropCpuCopy(bmp:openfl.display.BitmapData, context:openfl.display3D.Context3D):Void
  {
    if (bmp.image != null && bmp.transparent && !bmp.image.premultiplied) bmp.image.premultiplied = true;
    bmp.disposeImage(); // readable = false
    bmp.getTexture(context); // Uploads if needed, then frees `image` because the bitmap is no longer readable.
  }

  /**
   * Drops the CPU copy of a texture right after FunkinMemory uploaded it, so textures cached while a
   * song is being built (characters, note styles, script props) do not accumulate decoded copies
   * until the end of PlayState.create() (lower loading peak).
   */
  /**
   * @return true if the texture was uploaded here (caller must not upload it again).
   */
  public static function releaseAfterUpload(graphic:FlxGraphic):Bool
  {
    if (!enabled || !releaseOnUpload || graphic == null || PlayState.instance == null && !Std.isOfType(FlxG.state, PlayState)) return false;
    if (!isEligible(graphic.key, graphic)) return false;
    var bmp = graphic.bitmap;
    if (bmp == null || bmp.image == null) return false;
    var context = (FlxG.stage != null) ? FlxG.stage.context3D : null;
    if (context == null) return false;
    try
    {
      uploadAndDropCpuCopy(bmp, context);
      return true;
    }
    catch (e:Dynamic)
    {
      NXDeepTrace.logWarning('[NXTextureMemory] releaseAfterUpload failed for ${graphic.key}: $e');
    }
    return false;
  }

  static function isEligible(key:String, graphic:FlxGraphic):Bool
  {
    if (key == null || graphic == null || graphic.isDestroyed || graphic.bitmap == null) return false;
    if (key.indexOf("assets/") == -1) return false; // Generated graphics (FlxText, makeGraphic, FlxBar...) need their pixels.
    if (!(StringTools.endsWith(key, ".png") || StringTools.endsWith(key, ".astc"))) return false;
    for (pattern in EXCLUDED_PATTERNS)
      if (key.indexOf(pattern) != -1) return false;
    if (funkin.FunkinMemory.isProtectedGraphic(key, graphic)) return false;
    return true;
  }

  /**
   * @param allowUpload If true, textures not yet on the GPU are uploaded first. If false they are skipped.
   * @param label If not null, logs the amount of memory released.
   * @return Released CPU memory in MB.
   */
  public static function releaseCpuCopies(allowUpload:Bool, ?label:String):Float
  {
    var context = (FlxG.stage != null) ? FlxG.stage.context3D : null;
    if (context == null) return 0.0;

    var releasedMb:Float = 0.0;
    var count:Int = 0;
    var releasedKeys:Array<String> = [];

    @:privateAccess
    {
      if (FlxG.bitmap == null || FlxG.bitmap._cache == null) return 0.0;
      for (key in FlxG.bitmap._cache.keys())
      {
        var graphic:Null<FlxGraphic> = FlxG.bitmap._cache.get(key);
        if (!isEligible(key, graphic)) continue;

        var bmp = graphic.bitmap;
        if (bmp.image == null) continue; // Already GPU-only.
        if (!allowUpload && (bmp.__texture == null || bmp.__textureVersion < bmp.image.version)) continue;

        try
        {
          var mb:Float = (bmp.width * bmp.height * 4) / (1024.0 * 1024.0);
          uploadAndDropCpuCopy(bmp, context);
          if (bmp.image == null)
          {
            releasedMb += mb;
            count++;
            if (label != null) releasedKeys.push(key);
          }
        }
        catch (e:Dynamic)
        {
          NXDeepTrace.logWarning('[NXTextureMemory] Failed to release CPU copy of $key: $e');
        }
      }
    }

    if (count > 0)
    {
      #if cpp
      cpp.vm.Gc.run(false);
      #end
      if (label != null)
      {
        NXDeepTrace.writeEntry('MEMORY', '[NXTextureMemory] [$label] Released CPU pixel copies of $count textures (${Math.round(releasedMb * 10) / 10} MB): ' + releasedKeys.join(', '));
      }
    }
    return releasedMb;
  }
}
