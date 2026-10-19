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

  /**
   * INC-49 heap ratchet. The post-switch pass used to upload every texture in hash order while all their CPU copies
   * were still allocated, so the GPU buffers (~275-285 MB per Spaghetti) could not reuse that space and took new
   * memory at the top of the heap, and Gc.run(false) then parked the dropped copies.
   * true: largest texture first; before a texture whose GPU buffer fits no free chunk, a full collection frees the
   * copies dropped since the previous one, so the buffer lands where those copies were; collections here free
   * (Gc.run(true)) instead of parking. false: Build 25 behaviour (test builds: nx_devtools.cfg ordered_release,
   * autotest token NOORDEREDREL).
   */
  public static var orderedRelease:Bool = true;

  static var lastPassStamp:Float = 0.0;

  /** Smaller textures never trigger a collection before their upload: their GPU buffers always find a hole. */
  static inline final SPLIT_MIN_BYTES:Float = 4.0 * 1048576.0;

  /** Upper bound of extra collections in one post-switch pass (each one is a full mark, ~15-45 ms on hardware). */
  static inline final MAX_SPLIT_COLLECTS:Int = 12;

  /** releaseAfterUpload: the dropped copy of a sheet this big is freed at once instead of waiting for a GC. */
  static inline final EAGER_FREE_BYTES:Float = 32.0 * 1048576.0;

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
    var deadKeys:Array<String> = [];
    var mb:Float = 0.0;
    @:privateAccess
    {
      if (FlxG.bitmap == null || FlxG.bitmap._cache == null) return 0;
      for (key => graphic in FlxG.bitmap._cache)
      {
        if (graphic == null || graphic.isDestroyed)
        {
          // Destroyed without leaving the cache: flixel-animate's BakedFramesVector.setNull destroys its baked filter and
          // mask graphics ("pixels#", persist) but never removes them, so ~414 dead entries piled up per LE SSERAFIM run.
          deadKeys.push(key);
          continue;
        }
        if (graphic.useCount > 0) continue;
        if (key == null || key.indexOf("assets/") != -1) continue; // Asset textures are handled by FunkinMemory.
        if (funkin.FunkinMemory.isProtectedGraphic(key, graphic)) continue;
        victims.push(graphic);
      }
      for (key in deadKeys)
        FlxG.bitmap._cache.remove(key);
    }
    for (graphic in victims)
    {
      mb += (graphic.width * graphic.height * 4) / 1048576.0;
      FlxG.bitmap.remove(graphic);
      graphic.persist = false;
      graphic.destroy();
    }
    #if NX_DEV_TOOLS
    if (victims.length > 0 || deadKeys.length > 0)
    {
      NXDeepTrace.writeEntry('MEMORY', '[NXTextureMemory] Destroyed ${victims.length} orphan generated graphics (${Math.round(mb * 10) / 10} MB), dropped ${deadKeys.length} dead cache entries');
    }
    #end
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
    // The heap figures only feed the test-build log: mallinfo and the heap probe walk every free chunk under malloc's lock.
    #if NX_DEV_TOOLS
    var before:Float = NXPerformance.getNativeHeapUsed();
    #end

    // The previous state is unreachable at preStateCreate. Menus (Freeplay, Character Select) are not
    // destroyed through PlayState.destroy(), so nothing collects their decoded images before the new
    // song loads (~650 MB retained after Freeplay with Pico -> 2Hot, which ran out of memory).
    #if cpp
    #if switch
    NXTextureUpload.releaseUploadSource();
    #end
    cpp.vm.Gc.run(true);
    cpp.vm.Gc.compact();
    #end
    #if NX_DEV_TOOLS
    var afterGc:Float = NXPerformance.getNativeHeapUsed();
    #end
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
    #if NX_DEV_TOOLS
    var after:Float = NXPerformance.getNativeHeapUsed();
    NXDeepTrace.writeEntry('MEMORY', '[NXTextureMemory] Before PlayState.create: native malloc ${Math.round(before * 10) / 10} MB'
      + ' -> ${Math.round(afterGc * 10) / 10} MB after full GC -> ${Math.round(after * 10) / 10} MB after presenting $FLUSH_FRAMES frames'
      + ' | ${NXPerformance.describeHeap()}');
    #end
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
      var bytes:Float = bmp.width * bmp.height * 4.0;
      uploadAndDropCpuCopy(bmp, context);
      // A big sheet cached while the song is built (picoExplosionDeath 168 MiB, bfHoldingGF-DEAD 128 MiB): free the
      // dropped copy now so the next decodes of this create can reuse its space (INC-49).
      if (orderedRelease && bmp.image == null && bytes >= EAGER_FREE_BYTES) collect();
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

    var candidates:Array<FlxGraphic> = [];
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
        candidates.push(graphic);
      }
    }
    if (candidates.length == 0) return 0.0;

    var ordered:Bool = allowUpload && orderedRelease;
    if (ordered) candidates.sort(largestFirst);

    var releasedMb:Float = 0.0;
    var count:Int = 0;
    var releasedKeys:Array<String> = [];
    var collects:Int = 0;
    var droppedSinceCollect:Float = 0.0;

    for (graphic in candidates)
    {
      var bmp = graphic.bitmap;
      if (bmp == null || bmp.image == null) continue;
      var bytes:Float = bmp.width * bmp.height * 4.0;
      // Free the copies dropped so far when this texture's GPU buffer would otherwise extend the heap. The first time it
      // also frees the large garbage left by create.
      if (ordered && bytes >= SPLIT_MIN_BYTES && collects < MAX_SPLIT_COLLECTS && (collects == 0 || droppedSinceCollect > 0)
        && NXPerformance.getLargestFreeChunkBytes() < bufferObjectBytes(bmp.width, bmp.height))
      {
        collect();
        collects++;
        droppedSinceCollect = 0.0;
      }

      try
      {
        uploadAndDropCpuCopy(bmp, context);
        if (bmp.image == null)
        {
          releasedMb += bytes / 1048576.0;
          droppedSinceCollect += bytes;
          count++;
          #if NX_DEV_TOOLS
          if (label != null) releasedKeys.push(graphic.key);
          #end
        }
      }
      catch (e:Dynamic)
      {
        NXDeepTrace.logWarning('[NXTextureMemory] Failed to release CPU copy of ${graphic.key}: $e');
      }
    }

    if (count > 0)
    {
      // Gc.run(true) frees the dropped copies in this sweep; Gc.run(false) costs the same full mark but parks them in
      // the large-object recycle list until some later collection.
      if (orderedRelease) collect();
      else
      {
        #if cpp
        cpp.vm.Gc.run(false);
        #end
      }
      #if NX_DEV_TOOLS
      if (label != null)
      {
        var how:String = ordered ? ', largest first, $collects extra collections' : '';
        NXDeepTrace.writeEntry('MEMORY', '[NXTextureMemory] [$label] Released CPU pixel copies of $count textures (${Math.round(releasedMb * 10) / 10} MB$how): ' + releasedKeys.join(', '));
      }
      #end
    }
    return releasedMb;
  }

  static function largestFirst(a:FlxGraphic, b:FlxGraphic):Int
  {
    var sa:Float = a.bitmap.width * 1.0 * a.bitmap.height;
    var sb:Float = b.bitmap.width * 1.0 * b.bitmap.height;
    if (sa != sb) return (sb > sa) ? 1 : -1;
    return (a.key < b.key) ? -1 : ((a.key > b.key) ? 1 : 0);
  }

  /**
   * Bytes malloc must find in one piece for the GPU texture of a w x h BGRA bitmap: nouveau_bo_new memaligns the tiled
   * level (pitch aligned to 64 bytes, rows to the block height) to 4 KiB, and newlib's memalign asks malloc for
   * size + 4096 + 32. Rounded up: an overestimate only costs one more collection.
   */
  static function bufferObjectBytes(w:Int, h:Int):Float
  {
    var pitch:Float = Math.ceil(w * 4.0 / 64.0) * 64.0;
    var rows:Float = Math.ceil(h / 128.0) * 128.0;
    return pitch * rows + 2 * 4096.0 + 64.0;
  }

  /**
   * Full collection that frees dead large blocks at once (never parks them).
   */
  static function collect():Void
  {
    #if cpp
    #if switch
    // lime keeps the last uploaded image reachable through a static pointer until the next GL call that takes one.
    NXTextureUpload.releaseUploadSource();
    #end
    cpp.vm.Gc.run(true);
    #end
  }

  public static function describe():String
  {
    return orderedRelease ? 'largest first' : 'hash order (off)';
  }

  /**
   * Test builds: FlxG.bitmap grouped by key pattern (numbers and hex ids as #), largest groups first, with how many are
   * still used / persistent / protected / asset keys. Shows what keeps growing between songs (INC-49: ~416 graphics,
   * ~63 MB more after each LE SSERAFIM run, none of them orphans for releaseOrphanGeneratedGraphics).
   */
  #if NX_DEV_TOOLS
  static final KEY_NUMBERS:EReg = ~/[0-9a-fA-F]{6,}|[0-9]+/g;
  #end

  public static function describeCache(top:Int = 8):String
  {
    #if NX_DEV_TOOLS
    var groups:Map<String, Array<Float>> = [];
    @:privateAccess
    {
      if (FlxG.bitmap == null || FlxG.bitmap._cache == null) return 'no cache';
      for (key => graphic in FlxG.bitmap._cache)
      {
        if (graphic == null) continue;
        var k:String = (key == null) ? 'null' : key;
        var parts:Array<String> = k.split('/');
        var tail:String = (parts.length > 1) ? parts[parts.length - 2] + '/' + parts[parts.length - 1] : k;
        var pattern:String = KEY_NUMBERS.replace(tail, '#');
        if (pattern.length > 48) pattern = pattern.substr(0, 48);
        var g:Null<Array<Float>> = groups.get(pattern);
        if (g == null)
        {
          g = [0, 0, 0, 0, 0, 0, 0, 0];
          groups.set(pattern, g);
        }
        var mb:Float = graphic.width * graphic.height * 4 / 1048576.0;
        g[0]++;
        g[1] += mb;
        if (graphic.useCount > 0) g[2]++;
        if (graphic.persist) g[3]++;
        if (funkin.FunkinMemory.isProtectedGraphic(key, graphic)) g[4]++;
        if (k.indexOf('assets/') != -1) g[5]++;
        // width/height survive destroy(): only graphics that still own a bitmap hold real memory.
        if (graphic.isDestroyed) g[6]++;
        else if (graphic.bitmap != null) g[7] += mb;
      }
    }
    var names:Array<String> = [for (name in groups.keys()) name];
    names.sort(function(a, b) {
      var ma:Float = groups.get(a)[1];
      var mb:Float = groups.get(b)[1];
      return (ma == mb) ? 0 : ((mb > ma) ? 1 : -1);
    });
    var out:Array<String> = [];
    for (i in 0...(names.length < top ? names.length : top))
    {
      var g:Array<Float> = groups.get(names[i]);
      out.push('${names[i]} x${Std.int(g[0])} ${Math.round(g[1] * 10) / 10} MB, live ${Math.round(g[7] * 10) / 10} MB (used ${Std.int(g[2])}, persist ${Std.int(g[3])}, protected ${Std.int(g[4])}, asset ${Std.int(g[5])}, destroyed ${Std.int(g[6])})');
    }
    return '${names.length} key patterns; ' + out.join('; ');
    #else
    return '';
    #end
  }

}
