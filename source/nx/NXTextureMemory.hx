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
    if (!Std.isOfType(state, PlayState)) return;
    flushDeferredGpuFrees();
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
    NXDeepTrace.writeEntry('MEMORY', '[NXTextureMemory] Presented $FLUSH_FRAMES frames before PlayState.create: native malloc ${Math.round(before * 10) / 10} -> ${Math.round(after * 10) / 10} MB');
  }

  static function onPostStateSwitch():Void
  {
    // Upload the freshly built stage / characters / note style now (we are still in the loading frame)
    // and drop their CPU copies before the first gameplay frame.
    if (PlayState.instance != null) releaseCpuCopies(true, 'enter ${PlayState.instance.currentSong?.id}');
  }

  static function onPostDraw():Void
  {
    if (PlayState.instance == null) return;
    var now:Float = haxe.Timer.stamp();
    if (now - lastPassStamp < PASS_INTERVAL) return;
    lastPassStamp = now;
    // Mid-song: never force an upload (avoids hitches), only release textures the renderer already uploaded.
    releaseCpuCopies(false, null);
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
          bmp.disposeImage(); // readable = false
          bmp.getTexture(context); // Uploads if needed, then frees `image` because the bitmap is no longer readable.
          if (bmp.image == null)
          {
            releasedMb += mb;
            count++;
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
        NXDeepTrace.writeEntry('MEMORY', '[NXTextureMemory] [$label] Released CPU pixel copies of $count textures (${Math.round(releasedMb * 10) / 10} MB)');
      }
    }
    return releasedMb;
  }
}
