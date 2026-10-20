package nx;

import haxe.io.Bytes;
import lime.app.Future;
import lime.app.Promise;
import lime.media.AudioBuffer;
import openfl.media.Sound;

#if (switch && cpp)
@:cppFileCode('#include <switch.h>')
#end
/**
 * Freeplay song previews on Switch, in place of FlxPartialSound's native path (FunkinSound.loadPartial).
 *
 * FlxPartialSound reads the whole OGG, cleans it byte by byte and decodes the requested part
 * (AudioBuffer.fromBytes, 20% of the song) on the main thread: 100-600 ms in one frame on the console every time
 * the selection stops on a song. Here the file is read in two ranges, cleaned with a plain loop and decoded on a
 * lime worker thread moved to core 2 (the main thread is on core 0, the audio thread on core 1). Only the latest
 * request completes; a stale one is dropped. The last few previews stay cached.
 */
class NXPreviewAudio
{
  /**
   * Bytes at the start of the file that hold the Vorbis headers (same size as FlxPartialSound).
   */
  static inline final INTRO_BYTES:Int = 16 * 400;

  static inline final CACHE_SIZE:Int = 3;

  static var generation:Int = 0;
  static var cache:Array<{key:String, sound:Sound}> = [];

  public static function load(path:String, start:Float, end:Float):Null<Promise<Sound>>
  {
    var promise:Promise<Sound> = new Promise<Sound>();
    var key:String = path + '.partial-' + start + '-' + end;
    for (entry in cache)
    {
      if (entry.key == key)
      {
        promise.complete(entry.sound);
        return promise;
      }
    }
    var filePath:Null<String> = openfl.utils.Assets.getPath(path);
    if (filePath == null || !sys.FileSystem.exists(filePath))
    {
      trace('[NXPreviewAudio] No file for $path (resolved to $filePath)');
      return null;
    }

    var gen:Int = ++generation;
    var startedAt:Float = haxe.Timer.stamp();
    trace('[NXPreviewAudio] Loading $filePath (${Math.round(start * 100)}-${Math.round(end * 100)}%)');
    var work = new Future<Null<AudioBuffer>>(function() {
      moveToCore2();
      if (gen != generation) return null;
      var bytes:Null<Bytes> = readRanges(filePath, start, end);
      if (bytes == null || gen != generation) return null;
      return AudioBuffer.fromBytes(bytes);
    }, true);
    work.onComplete(function(buffer:Null<AudioBuffer>) {
      if (buffer == null || gen != generation)
      {
        if (gen == generation) trace('[NXPreviewAudio] Could not decode $filePath');
        promise.error('superseded');
        return;
      }
      var sound:Sound = Sound.fromAudioBuffer(buffer);
      cache.push({key: key, sound: sound});
      if (cache.length > CACHE_SIZE) cache.shift();
      trace('[NXPreviewAudio] $path ready in ${Math.round((haxe.Timer.stamp() - startedAt) * 1000)} ms (decoded off the main thread)');
      promise.complete(sound);
    });
    work.onError(function(e:Dynamic) {
      trace('[NXPreviewAudio] Error loading $filePath: $e');
      promise.error(e);
    });
    return promise;
  }

  /**
   * The Vorbis headers plus the requested part of the file, both cut to whole Ogg pages, as one Ogg stream.
   */
  static function readRanges(filePath:String, start:Float, end:Float):Null<Bytes>
  {
    var input:Null<sys.io.FileInput> = null;
    try
    {
      var size:Int = sys.FileSystem.stat(filePath).size;
      input = sys.io.File.read(filePath, true);
      var intro:Bytes = input.read(Std.int(Math.min(INTRO_BYTES, size)));
      var from:Int = Std.int(start * size);
      var to:Int = Std.int(Math.min(end * size, size));
      if (to <= from) return null;
      input.seek(from, SeekBegin);
      var body:Bytes = input.read(to - from);
      input.close();
      input = null;
      var cleanIntro:Null<Bytes> = cleanOgg(intro);
      var cleanBody:Null<Bytes> = cleanOgg(body);
      if (cleanIntro == null || cleanBody == null) return null;
      var out:Bytes = Bytes.alloc(cleanIntro.length + cleanBody.length);
      out.blit(0, cleanIntro, 0, cleanIntro.length);
      out.blit(cleanIntro.length, cleanBody, 0, cleanBody.length);
      return out;
    }
    catch (e:Dynamic)
    {
      if (input != null) input.close();
      return null;
    }
  }

  /**
   * Same result as FlxPartialSound.cleanOggBytes: from the first "OggS" page (marked as the start of the stream)
   * up to the start of the last one, plus one zero byte. A plain byte scan instead of building strings.
   */
  static function cleanOgg(data:Bytes):Null<Bytes>
  {
    var first:Int = -1;
    var last:Int = -1;
    var i:Int = 0;
    var limit:Int = data.length - 3;
    while (i < limit)
    {
      if (data.get(i) == 'O'.code && data.get(i + 1) == 'g'.code && data.get(i + 2) == 'g'.code && data.get(i + 3) == 'S'.code)
      {
        if (first < 0)
        {
          first = i;
          if (i + 5 < data.length) data.set(i + 5, 2);
        }
        last = i;
        i += 4;
      }
      else
      {
        i++;
      }
    }
    if (first < 0 || last <= first) return null;
    var length:Int = last - first;
    var output:Bytes = Bytes.alloc(length + 1);
    output.blit(0, data, first, length);
    return output;
  }

  static function moveToCore2():Void
  {
    #if (switch && cpp)
    untyped __cpp__('svcSetThreadCoreMask(CUR_THREAD_HANDLE, 2, 1u << 2)');
    #end
  }
}
