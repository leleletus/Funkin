package nx;

/**
 * Test builds: saves the next rendered frame as a PNG (the exact 1280x720 picture the game draws, without window
 * borders or scaling), in Citron and on the console. Used for the store screenshots (autotest SCREENSHOTS).
 *
 * The frame is read with glReadPixels from a listener that runs after OpenFL has drawn the stage and before the
 * buffers are swapped.
 */
class NXScreenshot
{
  static var pending:Null<{file:String, done:Bool->Void}> = null;
  static var hooked:Bool = false;

  /**
   * Saves the next frame to `file` (absolute path, the folder is created), then calls `done` with the result.
   */
  public static function capture(file:String, done:Bool->Void):Void
  {
    #if NX_DEV_TOOLS
    pending = {file: file, done: done};
    if (!hooked)
    {
      hooked = true;
      // Lower priority than OpenFL's own render listener: runs once the frame is drawn.
      lime.app.Application.current.window.onRender.add(onRender, false, -1000);
    }
    #else
    done(false);
    #end
  }

  #if NX_DEV_TOOLS
  static function onRender(_:lime.graphics.RenderContext):Void
  {
    if (pending == null) return;
    var job = pending;
    pending = null;
    var ok:Bool = false;
    try
    {
      var window = lime.app.Application.current.window;
      var w:Int = Std.int(window.width * window.scale);
      var h:Int = Std.int(window.height * window.scale);
      var raw:haxe.io.Bytes = haxe.io.Bytes.alloc(w * h * 4);
      lime.graphics.opengl.GL.readPixels(0, 0, w, h, lime.graphics.opengl.GL.RGBA, lime.graphics.opengl.GL.UNSIGNED_BYTE, raw);
      // OpenGL rows go bottom-up; PNG rows top-down. The alpha of the back buffer is not meaningful.
      var flipped:haxe.io.Bytes = haxe.io.Bytes.alloc(w * h * 4);
      var row:Int = w * 4;
      for (y in 0...h)
        flipped.blit((h - 1 - y) * row, raw, y * row, row);
      for (i in 0...w * h)
        flipped.set(i * 4 + 3, 0xFF);
      var image = new lime.graphics.Image(new lime.graphics.ImageBuffer(lime.utils.UInt8Array.fromBytes(flipped), w, h), 0, 0, w, h);
      var png:haxe.io.Bytes = image.encode(PNG);
      var dir:String = haxe.io.Path.directory(job.file);
      if (dir.length > 0 && !sys.FileSystem.exists(dir)) sys.FileSystem.createDirectory(dir);
      sys.io.File.saveBytes(job.file, png);
      NXDeepTrace.writeEntry('SCREENSHOT', 'Saved ${w}x${h} frame to ${job.file} (${Math.round(png.length / 1024)} KB)');
      ok = true;
    }
    catch (e:Dynamic)
    {
      NXDeepTrace.writeEntry('SCREENSHOT', 'Capture to ${job.file} failed: $e');
    }
    job.done(ok);
  }
  #end
}
