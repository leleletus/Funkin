package nx;

#if (switch && lime_cffi && !macro)
import haxe.io.Bytes;
import lime._internal.backend.native.NativeCFFI;
import lime.graphics.ImageBuffer;
import lime.utils.UInt8Array;
#end

/**
 * Single-copy image decode for Switch (INC-49).
 *
 * lime calls lime_image_load_file/bytes with an empty buffer, so the native PNG decoder mallocs the pixels and
 * ImageBuffer::Value then copies them into a second, GC-owned block of the same size (lime Bytes.cpp:143 and
 * :280-285). An 8192x4096 sheet therefore needs two contiguous 128 MiB blocks at the same time, and on a
 * fragmented heap the second one fails (INC-49, gfTankmen.png; INC-32, spraycanAtlas).
 *
 * Here the header is read first (lime's own PNG decoder with decodeData=false), and lime receives an ImageBuffer
 * that already owns a GC buffer of exactly width*height*4 bytes: Bytes::Set adopts it, Bytes::Resize is a no-op,
 * libpng writes the rows straight into it and Bytes::Value skips the copy. Same pixels, one block.
 *
 * lime.graphics.Image.__fromFile/__fromBytes are redirected here by nx.macro.NXLibraryPatches (Switch only).
 * Anything that is not a plain PNG of at least 64 KiB (JPEG, tiny images, odd sizes) takes the stock call.
 */
class NXImageDecode
{
  static inline final MIN_PRESIZE_BYTES:Int = 64 * 1024;
  static inline final MAX_SIDE:Int = 16384;

  /**
   * Decodes that used one block / the stock path / that still copied (should stay 0).
   */
  public static var singleCopy(default, null):Int = 0;

  public static var stock(default, null):Int = 0;
  public static var missed(default, null):Int = 0;

  /**
   * Test builds can turn the single-copy path off at runtime (nx_devtools.cfg single_copy_decode=false) for A/B runs
   * with the same NRO; public builds always use it.
   */
  public static var enabled:Bool = true;

  #if (switch && lime_cffi && !macro)
  @:access(lime._internal.backend.native.NativeCFFI)
  public static function loadFile(path:String):ImageBuffer
  {
    var header:Null<ImageBuffer> = enabled ? NativeCFFI.lime_png_decode_file(path, false, emptyBuffer()) : null;
    var presized:Null<ImageBuffer> = presize(header);
    if (presized == null)
    {
      stock++;
      return NativeCFFI.lime_image_load_file(path, emptyBuffer());
    }
    var before = presized.data.buffer.getData();
    var result:ImageBuffer = NativeCFFI.lime_image_load_file(path, presized);
    track(result, before, path);
    return result;
  }

  @:access(lime._internal.backend.native.NativeCFFI)
  public static function loadBytes(bytes:Bytes):ImageBuffer
  {
    var header:Null<ImageBuffer> = enabled ? NativeCFFI.lime_png_decode_bytes(bytes, false, emptyBuffer()) : null;
    var presized:Null<ImageBuffer> = presize(header);
    if (presized == null)
    {
      stock++;
      return NativeCFFI.lime_image_load_bytes(bytes, emptyBuffer());
    }
    var before = presized.data.buffer.getData();
    var result:ImageBuffer = NativeCFFI.lime_image_load_bytes(bytes, presized);
    track(result, before, 'bytes');
    return result;
  }

  static inline function emptyBuffer():ImageBuffer
  {
    return new ImageBuffer(new UInt8Array(Bytes.alloc(0)));
  }

  /**
   * An ImageBuffer whose data is exactly what PNG::Decode will Resize to (width * height * 4, 32 bpp RGBA),
   * or null when the stock path must be used.
   */
  static function presize(header:Null<ImageBuffer>):Null<ImageBuffer>
  {
    if (header == null) return null;
    var w:Int = header.width;
    var h:Int = header.height;
    if (w <= 0 || h <= 0 || w > MAX_SIDE || h > MAX_SIDE) return null;
    var size:Int = w * h * 4;
    if (size < MIN_PRESIZE_BYTES) return null;
    return new ImageBuffer(new UInt8Array(Bytes.alloc(size)), w, h);
  }

  static function track(result:Null<ImageBuffer>, before:Dynamic, what:String):Void
  {
    if (result == null) return;
    // Bytes::Value rewrites the Haxe Bytes object in place, so compare the underlying data, not the object.
    if (result.data != null && result.data.buffer != null && result.data.buffer.getData() == before)
    {
      singleCopy++;
    }
    else
    {
      missed++;
      NXDeepTrace.writeEntry('MEMORY', '[NXImageDecode] decode still copied: $what (${result.width}x${result.height})');
    }
  }
  #end

  public static function describe():String
  {
    return '${enabled ? "single-copy" : "legacy (off)"}: one block $singleCopy, stock $stock, missed $missed';
  }
}
