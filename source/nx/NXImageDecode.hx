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
 *
 * Residual risk (lime-nx, outside this repo): Bytes::Set boxes the buffer length while holding lime's static
 * Bytes mutex, which allocates GC memory under that lock. Decodes are serialised here (hxcpp waits on a Mutex in
 * a GC-free zone), so two image decodes can no longer meet inside it; an image decode against a concurrent audio
 * decode still can. The real fix is reading the length before the lock in the lime fork.
 */
class NXImageDecode
{
  static inline final MIN_PRESIZE_BYTES:Int = 64 * 1024;
  static inline final MAX_SIDE:Int = 16384;
  // The largest shipped image is 8192x8192 (week2 halloween_bg, 256 MiB); anything bigger is a bad header.
  static inline final MAX_PRESIZE_BYTES:Int = 256 * 1024 * 1024;
  static inline final LARGE_BYTES:Int = 64 * 1024 * 1024;
  static inline final BREADCRUMB_BYTES:Int = 16 * 1024 * 1024;

  /**
   * Decodes that used one block / took the stock path / still copied (should stay 0) / failed after presizing.
   */
  public static var singleCopy(default, null):Int = 0;

  public static var stock(default, null):Int = 0;
  public static var missed(default, null):Int = 0;
  public static var failed(default, null):Int = 0;

  /**
   * Test builds can turn the single-copy path off at runtime (nx_devtools.cfg single_copy_decode=false) for A/B runs
   * with the same NRO; public builds always use it.
   */
  public static var enabled:Bool = true;

  #if (switch && lime_cffi && !macro)
  static var decodeMutex:sys.thread.Mutex = new sys.thread.Mutex();

  @:access(lime._internal.backend.native.NativeCFFI)
  public static function loadFile(path:String):ImageBuffer
  {
    decodeMutex.acquire();
    try
    {
      var result:ImageBuffer = decodeFileLocked(path);
      decodeMutex.release();
      return result;
    }
    catch (e:Dynamic)
    {
      decodeMutex.release();
      throw e;
    }
  }

  @:access(lime._internal.backend.native.NativeCFFI)
  public static function loadBytes(bytes:Bytes):ImageBuffer
  {
    decodeMutex.acquire();
    try
    {
      var result:ImageBuffer = decodeBytesLocked(bytes);
      decodeMutex.release();
      return result;
    }
    catch (e:Dynamic)
    {
      decodeMutex.release();
      throw e;
    }
  }

  @:access(lime._internal.backend.native.NativeCFFI)
  static function decodeFileLocked(path:String):ImageBuffer
  {
    var header:Null<ImageBuffer> = enabled ? NativeCFFI.lime_png_decode_file(path, false, emptyBuffer()) : null;
    var presized:Null<ImageBuffer> = presize(header, path);
    if (presized == null)
    {
      stock++;
      return NativeCFFI.lime_image_load_file(path, emptyBuffer());
    }
    var before = presized.data.buffer.getData();
    var result:ImageBuffer = NativeCFFI.lime_image_load_file(path, presized);
    track(result, before, path, presized);
    return result;
  }

  @:access(lime._internal.backend.native.NativeCFFI)
  static function decodeBytesLocked(bytes:Bytes):ImageBuffer
  {
    var header:Null<ImageBuffer> = enabled ? NativeCFFI.lime_png_decode_bytes(bytes, false, emptyBuffer()) : null;
    var presized:Null<ImageBuffer> = presize(header, 'bytes');
    if (presized == null)
    {
      stock++;
      return NativeCFFI.lime_image_load_bytes(bytes, emptyBuffer());
    }
    var before = presized.data.buffer.getData();
    var result:ImageBuffer = NativeCFFI.lime_image_load_bytes(bytes, presized);
    track(result, before, 'bytes', presized);
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
  static function presize(header:Null<ImageBuffer>, what:String):Null<ImageBuffer>
  {
    if (header == null) return null;
    var w:Int = header.width;
    var h:Int = header.height;
    if (w <= 0 || h <= 0 || w > MAX_SIDE || h > MAX_SIDE) return null;
    var size:Int = w * h * 4;
    if (size < MIN_PRESIZE_BYTES || size > MAX_PRESIZE_BYTES) return null;

    if (size >= LARGE_BYTES && size + 64 * 1024 > NXPerformance.getLargestAllocatableMB() * 1024 * 1024)
    {
      // Free parked/dead large blocks before asking for one contiguous block of this size. If it still does not fit, the
      // presized buffer is still the better bet: lime's stock decode needs this block plus a second one of the same size,
      // and hxcpp retries a failed large allocation after its own forced compacting collection.
      cpp.vm.Gc.run(true);
      #if NX_DEV_TOOLS
      if (size + 64 * 1024 > NXPerformance.getLargestAllocatableMB() * 1024 * 1024)
      {
        NXDeepTrace.writeEntry('MEMORY', '[NXImageDecode] no ${Math.round(size / 1048576)} MiB block for $what (${w}x${h}) even after a full GC; allocating it anyway');
      }
      #end
    }
    #if NX_DEV_TOOLS
    // Written before the allocation (the log flushes immediately), so an allocation trap still names the image.
    if (size >= BREADCRUMB_BYTES) NXDeepTrace.writeEntry('MEMORY', '[IMG] presize $what ${w}x${h} ${Math.round(size / 1048576)} MiB');
    #end
    return new ImageBuffer(new UInt8Array(Bytes.alloc(size)), w, h);
  }

  static function track(result:Null<ImageBuffer>, before:Dynamic, what:String, presized:ImageBuffer):Void
  {
    if (result == null)
    {
      failed++;
      #if NX_DEV_TOOLS
      NXDeepTrace.writeEntry('MEMORY', '[NXImageDecode] presized decode failed: $what (${presized.width}x${presized.height})');
      #end
      return;
    }
    // Bytes::Value rewrites the Haxe Bytes object in place, so compare the underlying data, not the object.
    if (result.data != null && result.data.buffer != null && result.data.buffer.getData() == before)
    {
      singleCopy++;
    }
    else
    {
      missed++;
      #if NX_DEV_TOOLS
      NXDeepTrace.writeEntry('MEMORY', '[NXImageDecode] decode still copied: $what (${result.width}x${result.height})');
      #end
    }
  }
  #end

  public static function describe():String
  {
    #if nx_legacy_image_decode
    return 'macro off (stock lime decode)';
    #else
    return '${enabled ? "single-copy" : "legacy (off)"}: one block $singleCopy, stock $stock, missed $missed, failed $failed';
    #end
  }
}
