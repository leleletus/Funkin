package nx;

#if (switch && lime && !macro)
import lime.graphics.Image;
import lime.graphics.WebGLRenderContext;
import openfl.display3D.textures.TextureBase;
#end

/**
 * Banded texture uploads for Switch (INC-49).
 *
 * OpenFL uploads a BitmapData with a single glTexImage2D of the whole image (TextureBase.hx:428). Mesa's nvc0 driver
 * copies every upload through a staging buffer the size of the uploaded box, memalign'ed from the same newlib heap as
 * everything else (nvc0_miptree_transfer_map -> nouveau_bo_new) and freed at the next fence update. Mesa's 64 MiB
 * upload throttle limits uploads in flight but never splits one, so an 8192x4096 sheet needs a second contiguous
 * 128 MiB + 4 KiB block while its texture and its CPU copy already exist.
 *
 * The storage is already there when this runs: BitmapData.getTexture creates a RectangleTexture whose constructor
 * calls texImage2D(TEXTURE_2D, 0, internalFormat, width, height, 0, format, UNSIGNED_BYTE, null)
 * (RectangleTexture.hx:37, 114-121), and Mesa's st_TexImage is itself st_TexSubImage over the full box. So images of
 * 16 MiB or more go up as glTexSubImage2D row bands of about 8 MiB that point straight into the image buffer (no copy,
 * no pixel-store changes). Mesa stages each band on its own and its throttle recycles them (at most ~64 MiB in
 * flight), so no block larger than one band is needed. Same bytes, formats and texture: same pixels.
 *
 * Everything else (under 16 MiB, 8-bit alpha images, size or format mismatches, a texture without storage) takes
 * OpenFL's exact call. Wired into TextureBase.__uploadFromImage by nx.macro.NXLibraryPatches (Switch only).
 */
class NXTextureUpload
{
  /**
   * Smaller uploads keep OpenFL's single call: their staging fits ordinary heap holes.
   */
  static inline final MIN_BANDED_BYTES:Int = 16 * 1024 * 1024;

  /**
   * Staging per band: Mesa allocates exactly rows * width * 4 per call. Below the throttle's 12.8 MiB slot, so each
   * band gets its own slot and the throttle recycles them one by one.
   */
  static inline final BAND_BYTES:Int = 8 * 1024 * 1024;

  static inline final MAX_SIDE:Int = 16384;

  /**
   * Test builds can turn banding off at runtime (nx_devtools.cfg banded_upload=false, autotest token NOBANDUPLOAD)
   * for A/B runs with the same NRO; public builds always band.
   */
  public static var enabled:Bool = true;

  /**
   * Uploads of 16 MiB or more done in bands / with OpenFL's single call / sent back to it by a GL error on band 0.
   */
  public static var banded(default, null):Int = 0;

  public static var fullLarge(default, null):Int = 0;
  public static var fallbacks(default, null):Int = 0;

  /**
   * GL_OUT_OF_MEMORY read around texture uploads (texture storage or upload staging that did not fit). Mesa keeps only
   * the first error until it is read, so a recurring error elsewhere in the frame hides it from a once-per-frame check;
   * test builds read it around every upload, public builds only around banded ones.
   */
  public static var outOfMemory(default, null):Int = 0;

  /**
   * GL errors read right after an upload (band 0 in every build; every upload in test builds). UPLOAD_PARITY checks it:
   * those reads clear Mesa's error flag, so a later glGetError would no longer see them.
   */
  public static var uploadErrors(default, null):Int = 0;

  static inline final GL_OUT_OF_MEMORY:Int = 0x0505;

  #if (switch && lime && !macro)
  static inline function noteError(code:Int):Int
  {
    if (code == GL_OUT_OF_MEMORY) outOfMemory++;
    return code;
  }

  static inline function noteUploadError(code:Int):Int
  {
    if (code != 0) uploadErrors++;
    return noteError(code);
  }

  /**
   * lime's inline GL wrappers keep the last pixel source in a static BytePointer (WebGL2RenderContext.__tempPointer)
   * until the next pointer-taking GL call, so the image just uploaded stays reachable and a collection right after the
   * upload cannot free it (NXTextureMemory drops and collects exactly that copy). Main thread only, like every GL call.
   */
  public static inline function releaseUploadSource():Void
  {
    @:privateAccess lime.graphics.WebGL2RenderContext.__tempPointer.set();
  }

  @:access(openfl.display3D.textures.TextureBase)
  public static function upload(texture:TextureBase, gl:WebGLRenderContext, internalFormat:Int, format:Int, image:Image):Void
  {
    var data = image.data;
    var width:Int = image.buffer.width;
    var height:Int = image.buffer.height;
    var stride:Int = width * 4;

    if (!enabled
      || data == null
      || image.buffer.bitsPerPixel != 32 // 8-bit images use OpenFL's ALPHA branch (TextureBase.hx:393-397)
      || format != TextureBase.__textureFormat
      || internalFormat != TextureBase.__textureInternalFormat
      || width <= 0
      || height <= 0
      || width > MAX_SIDE
      || height > MAX_SIDE
      || stride * height < MIN_BANDED_BYTES
      || data.byteLength < stride * height
      // texSubImage2D can only fill storage of exactly this size and format; texImage2D (re)defines it.
      || texture.__width != width
      || texture.__height != height
      || texture.__internalFormat != internalFormat
      || texture.__format != format)
    {
      fullUpload(gl, internalFormat, format, image, false);
      return;
    }

    var rows:Int = Std.int(BAND_BYTES / stride); // 256 rows at 8192 px; at least 128 since width <= 16384
    if (rows < 1) rows = 1;

    #if NX_DEV_TOOLS
    var start:Float = haxe.Timer.stamp();
    var heapBefore:String = NXPerformance.describeHeap();
    #end

    // Clear errors left by earlier calls so the check after band 0 only sees band 0 (Mesa keeps a single error flag;
    // nothing on native reads glGetError). GL_OUT_OF_MEMORY here usually means this texture's texImage2D(null) failed.
    var staleError:Int = noteError(gl.getError());
    if (staleError != gl.NO_ERROR)
    {
      var drained:Int = 0;
      while (drained < 8 && noteError(gl.getError()) != gl.NO_ERROR)
        drained++;
    }

    var y:Int = 0;
    while (y < height)
    {
      var n:Int = (height - y < rows) ? height - y : rows;
      // srcOffset is a byte offset that lime adds to data.byteOffset (BytePointer.set, BytePointer.hx:42), so Mesa reads
      // rows y..y+n-1 straight from the image buffer (DataPointer.fromBytesPointer = &bytes[0] + offset). Do NOT add
      // data.byteOffset again and do NOT wrap data in new UInt8Array(view): that clones the whole buffer.
      gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, y, width, n, format, gl.UNSIGNED_BYTE, data, y * stride);
      if (y == 0 && noteUploadError(gl.getError()) != gl.NO_ERROR)
      {
        // No storage of this size and format (its texImage2D(null) ran out of memory, or it was redefined):
        // OpenFL's call defines it again and uploads, exactly as without this patch.
        fallbacks++;
        fullUpload(gl, internalFormat, format, image, true);
        return;
      }
      y += n;
    }
    releaseUploadSource();
    banded++;

    #if NX_DEV_TOOLS
    NXDeepTrace.writeEntry('MEMORY', '[UPLOAD] banded ${width}x${height} (${mib(stride * height)} MiB, ${Math.ceil(height / rows)} bands of $rows rows)'
      + ' in ${elapsedMs(start)} ms, glError ${hex(noteUploadError(gl.getError()))}, before upload ${hex(staleError)} | before: $heapBefore | after: ${NXPerformance.describeHeap()}');
    #end
  }

  /**
   * OpenFL's exact call (TextureBase.hx:428).
   */
  static function fullUpload(gl:WebGLRenderContext, internalFormat:Int, format:Int, image:Image, fallback:Bool):Void
  {
    var large:Bool = (image.buffer.width : Float) * image.buffer.height * 4 >= MIN_BANDED_BYTES;
    #if NX_DEV_TOOLS
    var start:Float = haxe.Timer.stamp();
    var heapBefore:Null<String> = large ? NXPerformance.describeHeap() : null;
    var staleError:Int = fallback ? 0 : noteError(gl.getError());
    #end
    gl.texImage2D(gl.TEXTURE_2D, 0, internalFormat, image.buffer.width, image.buffer.height, 0, format, gl.UNSIGNED_BYTE, image.data);
    releaseUploadSource();
    #if NX_DEV_TOOLS
    var error:Int = noteUploadError(gl.getError());
    if (!large && (error == GL_OUT_OF_MEMORY || staleError == GL_OUT_OF_MEMORY))
    {
      NXDeepTrace.writeEntry('MEMORY', '[UPLOAD] GL_OUT_OF_MEMORY around the ${image.buffer.width}x${image.buffer.height} upload (before ${hex(staleError)}, after ${hex(error)}): ${NXPerformance.describeHeap()}');
    }
    #end
    if (!large) return;
    fullLarge++;
    #if NX_DEV_TOOLS
    var why:String = fallback ? 'GL error on band 0' : (enabled ? 'not bandable' : 'banded_upload=false');
    NXDeepTrace.writeEntry('MEMORY', '[UPLOAD] full ${image.buffer.width}x${image.buffer.height} (${mib((image.buffer.width : Float) * image.buffer.height * 4)} MiB, $why)'
      + ' in ${elapsedMs(start)} ms, glError ${hex(error)}, before upload ${hex(staleError)} | before: $heapBefore | after: ${NXPerformance.describeHeap()}');
    #end
  }

  #if NX_DEV_TOOLS
  static inline function mib(bytes:Float):Float
    return Math.round(bytes / 104857.6) / 10;

  static inline function elapsedMs(start:Float):Int
    return Math.round((haxe.Timer.stamp() - start) * 1000);

  static inline function hex(code:Int):String
    return code == 0 ? '0' : '0x' + StringTools.hex(code, 4);
  #end
  #end

  public static function describe():String
  {
    #if nx_legacy_texture_upload
    return 'macro off (stock OpenFL upload, no error reads)';
    #else
    return '${enabled ? "banded" : "single call (off)"}: banded $banded, single call >=16 MiB $fullLarge, fallbacks $fallbacks, GL out of memory $outOfMemory';
    #end
  }
}
