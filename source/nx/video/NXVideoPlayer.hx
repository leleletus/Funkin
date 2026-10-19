package nx.video;

import flixel.FlxG;
import flixel.FlxSprite;
import flixel.graphics.FlxGraphic;
import flixel.graphics.frames.FlxAtlasFrames;
import flixel.util.FlxColor;
import funkin.audio.FunkinSound;
import funkin.play.PlayState;
import funkin.Paths;
import openfl.utils.Assets;
import openfl.media.Sound;
import lime.media.AudioBuffer;

/**
 * Modular Cutscene & Video abstraction for Nintendo Switch.
 * Streams converted in-engine sprite/atlas sheets 1 at a time to prevent RAM spikes (keeps GC heap ~35 MB).
 * Safely plays synchronized Vorbis audio and features watchdog timers against softlocks.
 * Completely decoupled from FlxSignal.dispatch to eliminate Null Object Reference crashes.
 */
class NXVideoPlayer
{
  static var currentSprite:Null<FlxSprite> = null;
  static var currentAudio:Null<FunkinSound> = null;
  static var isPlaying:Bool = false;
  /**
   * True while the pause menu is open over the cutscene: frames and audio stay frozen.
   */
  static var isPaused:Bool = false;

  static var currentVideoName:String = "";
  static var currentSheetIndex:Int = 0;
  static var totalSheets:Int = 0;
  static var animFps:Float = 24.0;
  static var onCompleteCallback:Null<Void->Void> = null;
  static var activeBitmapData:Null<openfl.display.BitmapData> = null;
  static var activeGraphic:Null<FlxGraphic> = null;
  static var isAdvancingSheet:Bool = false;

  // Sincronización A/V por reloj de audio (Frame-Sync)
  static var sheetStartGlobalFrame:Int = 0;
  static var currentSheetFrameCount:Int = 0;
  static var lastValidAudioSec:Float = 0.0;
  static var lastWallTimestamp:Float = 0.0;

  // Pre-decodificación asíncrona de hojas en hilo secundario
  #if sys
  static var prefetchMutex:Null<sys.thread.Mutex> = null;
  static var prefetchedSheetIndex:Int = -1;
  static var prefetchedImage:Null<lime.graphics.Image> = null;
  static var prefetchedXml:Null<String> = null;
  static var isPrefetching:Bool = false;
  /**
   * Bumped by stop() and playConverted() under prefetchMutex. A prefetch thread only publishes its sheet if the
   * generation it started with is still current; otherwise a skipped cutscene's sheet (~58 MiB) would stay pinned
   * and be shown inside the next cutscene (Ugh frames in Guns).
   */
  static var prefetchGen:Int = 0;
  #end

  static function prefetchNextSheet(nextIndex:Int):Void
  {
    #if sys
    if (nextIndex >= totalSheets || !isPlaying) return;

    if (prefetchMutex == null) prefetchMutex = new sys.thread.Mutex();

    prefetchMutex.acquire();
    if (isPrefetching || prefetchedSheetIndex == nextIndex)
    {
      prefetchMutex.release();
      return;
    }
    #if switch
    // Prefetch only with room for this sheet and the next one: on a tight heap the decode thread and the main thread
    // (uploading the current sheet) both need a sheet-sized block, and a failed large allocation aborts the game
    // (hxcpp "Memory Exhausted", console 2026-10-19 03:26, 2hot cutscene). Skipped, the next sheet is decoded on the
    // main thread at the switch instead (a short hitch, no crash).
    var sheetBytes:Float = (activeBitmapData != null) ? activeBitmapData.width * 4.0 * activeBitmapData.height : 0.0;
    if (sheetBytes > 0 && nx.NXPerformance.getLargestAllocatableMB() * 1048576.0 < 2.0 * sheetBytes + 16.0 * 1048576.0)
    {
      prefetchMutex.release();
      trace('[NXVideoPlayer] Prefetch of sheet $nextIndex skipped: no room for two sheets');
      return;
    }
    #end
    isPrefetching = true;
    var gen:Int = prefetchGen;
    prefetchMutex.release();

    var vidName:String = currentVideoName;
    var sheetsTotal:Int = totalSheets;

    trace('[NXVideoPlayer] Scheduling prefetch for sheet $nextIndex...');

    sys.thread.Thread.create(function() {
      // Thread-safety: Proteger todo el cuerpo en try/catch y jamás invocar OpenFL/OpenGL ni FlxG
      try
      {
        var pngPath:String = (sheetsTotal > 1) ? 'assets/videos/converted/${vidName}_$nextIndex.png' : 'assets/videos/converted/$vidName.png';
        var xmlPath:String = (sheetsTotal > 1) ? 'assets/videos/converted/${vidName}_$nextIndex.xml' : 'assets/videos/converted/$vidName.xml';

        var img:Null<lime.graphics.Image> = null;
        // Skip the whole decode if the cutscene was stopped or replaced meanwhile.
        if (isStalePrefetch(gen))
        {
          trace('[NXVideoPlayer] Prefetch DROPPED (stale) before decoding sheet $nextIndex of $vidName');
          return;
        }
        var romfsPng:String = 'romfs:/' + pngPath;
        if (sys.FileSystem.exists(romfsPng))
        {
          var bytes = sys.io.File.getBytes(romfsPng);
          if (bytes != null && bytes.length > 0)
          {
            img = lime.graphics.Image.fromBytes(bytes);
            bytes = null;
          }
        }
        else if (sys.FileSystem.exists(pngPath))
        {
          var bytes = sys.io.File.getBytes(pngPath);
          if (bytes != null && bytes.length > 0)
          {
            img = lime.graphics.Image.fromBytes(bytes);
            bytes = null;
          }
        }

        var xmlStr:Null<String> = null;
        var romfsXml:String = 'romfs:/' + xmlPath;
        if (sys.FileSystem.exists(romfsXml))
        {
          xmlStr = sys.io.File.getContent(romfsXml);
        }
        else if (sys.FileSystem.exists(xmlPath))
        {
          xmlStr = sys.io.File.getContent(xmlPath);
        }

        if (prefetchMutex != null)
        {
          prefetchMutex.acquire();
          if (gen != prefetchGen)
          {
            // Stopped or replaced while decoding: never publish it, and leave isPrefetching to the newer prefetch.
            if (img != null && img.buffer != null) img.buffer.data = null;
            img = null;
            prefetchMutex.release();
            trace('[NXVideoPlayer] Prefetch DROPPED (stale) sheet $nextIndex of $vidName');
            return;
          }
          if (img != null && xmlStr != null)
          {
            prefetchedImage = img;
            prefetchedXml = xmlStr;
            prefetchedSheetIndex = nextIndex;
            trace('[NXVideoPlayer] Prefetch READY for sheet $nextIndex (${img.width}x${img.height})');
          }
          else
          {
            trace('[NXVideoPlayer] Prefetch FAILED for sheet $nextIndex (img: ${img != null}, xml: ${xmlStr != null})');
          }
          isPrefetching = false;
          prefetchMutex.release();
        }
      }
      catch (e:Dynamic)
      {
        trace('[NXVideoPlayer] Prefetch EXCEPTION on sheet $nextIndex: $e');
        if (prefetchMutex != null)
        {
          prefetchMutex.acquire();
          if (gen == prefetchGen) isPrefetching = false;
          prefetchMutex.release();
        }
      }
    });
    #end
  }

  static function isStalePrefetch(gen:Int):Bool
  {
    #if sys
    if (prefetchMutex == null) return true;
    prefetchMutex.acquire();
    var stale:Bool = gen != prefetchGen;
    prefetchMutex.release();
    return stale;
    #else
    return true;
    #end
  }

  /**
   * Returns whether a cutscene is actively rendering or playing audio.
   */
  public static inline function isCutscenePlaying():Bool
  {
    return isPlaying;
  }

  /**
   * Sheet being shown and sheet count of the cutscene that is playing (tests check that it reached the last sheet).
   */
  public static inline function sheetIndex():Int
  {
    return currentSheetIndex;
  }

  public static inline function sheetCount():Int
  {
    return totalSheets;
  }

  /**
   * Checks if an adapted sprite sheet / atlas and audio exist for the given video file.
   * If available, plays it in PlayState with hardware rendering and synchronized audio.
   * If missing or on any failure, safely returns false without instantiating any graphics or sounds.
   *
   * @param videoPath The original video path (e.g. "assets/videos/videos/stressPicoCutscene.mkv" or "stressPicoCutscene")
   * @param onComplete Callback invoked when the cutscene finishes or is skipped.
   * @return `true` if a converted cutscene was found and started, `false` otherwise.
   */
  static function hasAsset(path:String, ?type:openfl.utils.AssetType):Bool
  {
    try
    {
      #if sys
      if (sys.FileSystem.exists('romfs:/' + path) || sys.FileSystem.exists(path)) return true;
      #end
      if (type != null)
      {
        if (Assets.exists('videos:' + path, type) || Assets.exists(path, type)) return true;
      }
      if (Assets.exists('videos:' + path) || Assets.exists(path)) return true;
    }
    catch (e:Dynamic) {}
    return false;
  }

  static function getBitmap(path:String):Null<openfl.display.BitmapData>
  {
    try
    {
      #if sys
      var romfsPath:String = 'romfs:/' + path;
      if (sys.FileSystem.exists(romfsPath))
      {
        var bmd = openfl.display.BitmapData.fromFile(romfsPath);
        if (bmd != null && bmd.image != null && bmd.width > 0 && bmd.height > 0)
        {
          trace('[NXVideoPlayer] getBitmap loaded fromFile: $romfsPath');
          return bmd;
        }

        var bytes = sys.io.File.getBytes(romfsPath);
        if (bytes != null && bytes.length > 0)
        {
          var bmdFromBytes = openfl.display.BitmapData.fromBytes(bytes);
          bytes = null;
          if (bmdFromBytes != null && bmdFromBytes.image != null && bmdFromBytes.width > 0 && bmdFromBytes.height > 0)
          {
            trace('[NXVideoPlayer] getBitmap loaded fromBytes: $romfsPath');
            return bmdFromBytes;
          }
        }
      }
      if (sys.FileSystem.exists(path))
      {
        var bmd = openfl.display.BitmapData.fromFile(path);
        if (bmd != null && bmd.image != null && bmd.width > 0 && bmd.height > 0)
        {
          trace('[NXVideoPlayer] getBitmap loaded fromFile: $path');
          return bmd;
        }
      }
      #end

      if (Assets.exists('videos:' + path, IMAGE))
      {
        var bmd = Assets.getBitmapData('videos:' + path, false);
        #if openfl
        if (openfl.utils.Assets.cache != null) openfl.utils.Assets.cache.removeBitmapData('videos:' + path);
        #end
        #if lime
        if (lime.utils.Assets.cache != null) lime.utils.Assets.cache.image.remove('videos:' + path);
        #end
        if (bmd != null && bmd.image != null && bmd.width > 0 && bmd.height > 0)
        {
          trace('[NXVideoPlayer] getBitmap loaded Assets: videos:$path');
          return bmd;
        }
      }
      if (Assets.exists(path, IMAGE))
      {
        var bmd = Assets.getBitmapData(path, false);
        #if openfl
        if (openfl.utils.Assets.cache != null) openfl.utils.Assets.cache.removeBitmapData(path);
        #end
        #if lime
        if (lime.utils.Assets.cache != null) lime.utils.Assets.cache.image.remove(path);
        #end
        if (bmd != null && bmd.image != null && bmd.width > 0 && bmd.height > 0)
        {
          trace('[NXVideoPlayer] getBitmap loaded Assets: $path');
          return bmd;
        }
      }
      if (Assets.exists('videos:' + path))
      {
        var bytes = Assets.getBytes('videos:' + path);
        if (bytes != null && bytes.length > 0)
        {
          var bmd = openfl.display.BitmapData.fromBytes(bytes);
          bytes = null;
          if (bmd != null && bmd.image != null && bmd.width > 0 && bmd.height > 0)
          {
            trace('[NXVideoPlayer] getBitmap loaded Assets getBytes: videos:$path');
            return bmd;
          }
        }
      }
      if (Assets.exists(path))
      {
        var bytes = Assets.getBytes(path);
        if (bytes != null && bytes.length > 0)
        {
          var bmd = openfl.display.BitmapData.fromBytes(bytes);
          bytes = null;
          if (bmd != null && bmd.image != null && bmd.width > 0 && bmd.height > 0)
          {
            trace('[NXVideoPlayer] getBitmap loaded Assets getBytes: $path');
            return bmd;
          }
        }
      }
    }
    catch (e:Dynamic)
    {
      trace('[NXVideoPlayer] Error loading bitmap ($path): ' + e);
    }
    return null;
  }

  static function getText(path:String):Null<String>
  {
    try
    {
      #if sys
      if (sys.FileSystem.exists('romfs:/' + path)) return sys.io.File.getContent('romfs:/' + path);
      if (sys.FileSystem.exists(path)) return sys.io.File.getContent(path);
      #end
      if (Assets.exists('videos:' + path, TEXT)) return Assets.getText('videos:' + path);
      if (Assets.exists(path, TEXT)) return Assets.getText(path);
      if (Assets.exists('videos:' + path)) return Assets.getText('videos:' + path);
      if (Assets.exists(path)) return Assets.getText(path);
    }
    catch (e:Dynamic) {}
    return null;
  }

  static function loadSoundAsset(videoName:String):Null<openfl.media.Sound>
  {
    try
    {
      var romfsPath:String = 'romfs:/assets/videos/converted/$videoName.ogg';
      var relativePath:String = 'assets/videos/converted/$videoName.ogg';

      #if sys
      if (sys.FileSystem.exists(romfsPath))
      {
        var buffer = lime.media.AudioBuffer.fromFile(romfsPath);
        if (buffer != null)
        {
          var sound = openfl.media.Sound.fromAudioBuffer(buffer);
          if (sound != null) return sound;
        }
        var sound = openfl.media.Sound.fromFile(romfsPath);
        if (sound != null) return sound;
      }
      #end

      // Intento por Assets de OpenFL/Lime
      if (Assets.exists('videos:' + relativePath, SOUND))
      {
        var sound = Assets.getSound('videos:' + relativePath);
        if (sound != null) return sound;
      }
      if (Assets.exists(relativePath, SOUND))
      {
        var sound = Assets.getSound(relativePath);
        if (sound != null) return sound;
      }

      // Si fue empaquetado como BINARY (por project.hxp en Switch)
      var bytes:Null<openfl.utils.ByteArray> = null;
      if (Assets.exists('videos:' + relativePath))
      {
        bytes = Assets.getBytes('videos:' + relativePath);
      }
      else if (Assets.exists(relativePath))
      {
        bytes = Assets.getBytes(relativePath);
      }

      if (bytes != null)
      {
        var buffer = lime.media.AudioBuffer.fromBytes(bytes);
        if (buffer != null)
        {
          var sound = openfl.media.Sound.fromAudioBuffer(buffer);
          if (sound != null) return sound;
        }
      }

      #if sys
      if (sys.FileSystem.exists(relativePath))
      {
        var buffer = lime.media.AudioBuffer.fromFile(relativePath);
        if (buffer != null)
        {
          var sound = openfl.media.Sound.fromAudioBuffer(buffer);
          if (sound != null) return sound;
        }
      }
      #end
    }
    catch (e:Dynamic)
    {
      trace('[NXVideoPlayer] Error loading sound asset: ' + e);
    }
    return null;
  }

  static function countAvailableSheets(videoName:String):Int
  {
    if (hasAsset('assets/videos/converted/${videoName}_0.png', IMAGE) &&
        hasAsset('assets/videos/converted/${videoName}_0.xml', TEXT))
    {
      var count:Int = 0;
      while (count < 50)
      {
        if (hasAsset('assets/videos/converted/${videoName}_$count.png', IMAGE) &&
            hasAsset('assets/videos/converted/${videoName}_$count.xml', TEXT))
        {
          count++;
        }
        else
        {
          break;
        }
      }
      return count;
    }
    if (hasAsset('assets/videos/converted/$videoName.png', IMAGE) &&
        hasAsset('assets/videos/converted/$videoName.xml', TEXT))
    {
      return 1;
    }
    return 0;
  }

  public static function playConverted(videoPath:String, onComplete:Void->Void):Bool
  {
    if (PlayState.instance == null) return false;

    try
    {
      var videoName:String = extractVideoName(videoPath);
      if (videoName == null || videoName.length == 0) return false;

      totalSheets = countAvailableSheets(videoName);
      if (totalSheets <= 0)
      {
        trace('[NXVideoPlayer] No converted atlas (.png/.xml) found for "$videoName". Safe skip to avoid SIGSEGV.');
        stop();
        return false;
      }

      currentVideoName = videoName;
      currentSheetIndex = 0;
      onCompleteCallback = onComplete;
      isAdvancingSheet = false;

      // Determine initial XML to read authoring FPS
      var initialXmlPath = (totalSheets > 1) ? 'assets/videos/converted/${videoName}_0.xml' : 'assets/videos/converted/$videoName.xml';
      var initialXmlStr = getText(initialXmlPath);
      animFps = 24;
      if (initialXmlStr != null)
      {
        try
        {
          var parsedXml = Xml.parse(initialXmlStr).firstElement();
          if (parsedXml != null && parsedXml.exists("fps"))
          {
            var parsed = Std.parseInt(parsedXml.get("fps"));
            if (parsed != null && parsed > 0) animFps = parsed;
          }
        }
        catch (e:Dynamic) {}
      }

      // Load sound
      var sound = loadSoundAsset(videoName);
      trace('[NXVideoPlayer] Starting streaming cutscene for: $videoName (Sheets: $totalSheets, FPS: $animFps, Audio: ${sound != null})');

      isPlaying = true;
      PlayState.instance.isInCutscene = true;
      PlayState.instance.camHUD.visible = false;

      // Configurar cámara camCutscene con fondo negro puro y máxima visibilidad
      if (PlayState.instance.camCutscene != null)
      {
        PlayState.instance.camCutscene.visible = true;
        PlayState.instance.camCutscene.alpha = 1.0;
        PlayState.instance.camCutscene.bgColor = 0xFF000000;
        PlayState.instance.camCutscene.scroll.set(0, 0);
        PlayState.instance.camCutscene.zoom = 1.0;
      }

      var cutsceneSpr:FlxSprite = new FlxSprite(0, 0);
      cutsceneSpr.cameras = [PlayState.instance.camCutscene];
      cutsceneSpr.scrollFactor.set(0, 0);
      cutsceneSpr.zIndex = 10000;
      cutsceneSpr.visible = true;
      cutsceneSpr.alpha = 1.0;

      currentSprite = cutsceneSpr;
      PlayState.instance.add(cutsceneSpr);
      PlayState.instance.refresh();

      // Desacoplado 100% de FlxSignal: Usamos exclusivamente postUpdate
      FlxG.signals.postUpdate.add(onPostUpdate);

      sheetStartGlobalFrame = 0;
      currentSheetFrameCount = 0;
      lastValidAudioSec = 0.0;
      lastWallTimestamp = haxe.Timer.stamp();

      #if sys
      // A new cutscene never inherits another cutscene's prefetched sheet.
      if (prefetchMutex == null) prefetchMutex = new sys.thread.Mutex();
      prefetchMutex.acquire();
      prefetchGen++;
      prefetchedImage = null;
      prefetchedXml = null;
      prefetchedSheetIndex = -1;
      isPrefetching = false;
      prefetchMutex.release();
      #end

      // Start sheet 0
      if (!loadAndPlaySheet(0))
      {
        trace('[NXVideoPlayer] Failed to load initial sheet for "$videoName". Aborting.');
        stop();
        return false;
      }

      if (sound != null)
      {
        try
        {
          currentAudio = FunkinSound.load(sound, 1.0, false, false, false, false, function() {
            trace('[NXVideoPlayer] Audio reached end.');
          }, null, true);

          if (currentAudio != null)
          {
            FlxG.sound.list.add(currentAudio);
            currentAudio.play();
          }
        }
        catch (e:Dynamic)
        {
          trace('[NXVideoPlayer] Warning: Failed to play audio for cutscene: ' + e);
        }
      }

      return true;
    }
    catch (e:Dynamic)
    {
      trace('[NXVideoPlayer] Fatal exception in playConverted: ' + e);
      stop();
      return false;
    }
  }

  static function loadAndPlaySheet(sheetIndex:Int):Bool
  {
    if (!isPlaying || currentSprite == null) return false;

    var pngPath:String = (totalSheets > 1) ? 'assets/videos/converted/${currentVideoName}_$sheetIndex.png' : 'assets/videos/converted/$currentVideoName.png';
    var xmlPath:String = (totalSheets > 1) ? 'assets/videos/converted/${currentVideoName}_$sheetIndex.xml' : 'assets/videos/converted/$currentVideoName.xml';

    var newBmd:Null<openfl.display.BitmapData> = null;
    var newXmlStr:Null<String> = null;
    var fromPrefetch:Bool = false;

    #if sys
    if (prefetchMutex == null) prefetchMutex = new sys.thread.Mutex();
    prefetchMutex.acquire();
    if (prefetchedSheetIndex == sheetIndex && prefetchedImage != null && prefetchedXml != null)
    {
      try
      {
        // EXCLUSIVAMENTE en el hilo principal: conversión Image -> BitmapData
        newBmd = openfl.display.BitmapData.fromImage(prefetchedImage);
        newXmlStr = prefetchedXml;
        fromPrefetch = true;
      }
      catch (e:Dynamic)
      {
        newBmd = null;
        newXmlStr = null;
      }
      prefetchedImage = null;
      prefetchedXml = null;
      prefetchedSheetIndex = -1;
    }
    prefetchMutex.release();
    #end

    if (newBmd == null || newXmlStr == null)
    {
      newBmd = getBitmap(pngPath);
      newXmlStr = getText(xmlPath);
    }

    if (newBmd == null || newXmlStr == null)
    {
      trace('[NXVideoPlayer] Missing sheet assets at index $sheetIndex ($pngPath / $xmlPath)');
      finishCutscene();
      return false;
    }

    // Wrap in FlxGraphic with persist = false to prevent bitmap leaks
    var newGraphic = FlxGraphic.fromBitmapData(newBmd, false, pngPath, false);
    newGraphic.persist = false;
    newGraphic.destroyOnNoUse = false;

    var newFrames = FlxAtlasFrames.fromSparrow(newGraphic, newXmlStr);
    if (newFrames == null || newFrames.frames == null || newFrames.frames.length == 0)
    {
      trace('[NXVideoPlayer] Invalid atlas frames at index $sheetIndex');
      finishCutscene();
      return false;
    }

    currentSheetFrameCount = newFrames.frames.length;
    trace('[NXVideoPlayer] Sheet $sheetIndex loaded (source: ${fromPrefetch ? "PREFETCH" : "FALLBACK"}): ${newBmd.width}x${newBmd.height}, frames: $currentSheetFrameCount ($pngPath)');

    var oldGraphic = activeGraphic;
    var oldFrames = currentSprite.frames;
    var oldBmd = activeBitmapData;

    activeGraphic = newGraphic;
    activeBitmapData = newBmd;

    // Asignar nuevos frames y resetear animaciones previas
    currentSprite.frames = newFrames;
    currentSprite.animation.destroyAnimations();

    var animName:String = 'sheet_$sheetIndex';
    // FPS = 0 obligatorio
    currentSprite.animation.addByPrefix(animName, 'cutscene', 0, false);

    // Fallback garantizado por si los nombres de subtextura en XML difieren
    if (currentSprite.animation.getByName(animName) == null || currentSprite.animation.getByName(animName).numFrames == 0)
    {
      var allIndices:Array<Int> = [for (i in 0...newFrames.frames.length) i];
      currentSprite.animation.add(animName, allIndices, 0, false);
    }

    // Iniciar animación con 0 FPS y pausar
    currentSprite.animation.play(animName, true);
    if (currentSprite.animation.curAnim != null)
    {
      currentSprite.animation.curAnim.paused = true;
      currentSprite.animation.curAnim.curFrame = 0;
    }

    // Ajustar tamaño, hitbox, centrado y marcar dirty = true
    currentSprite.setGraphicSize(1280, 720);
    currentSprite.updateHitbox();
    currentSprite.screenCenter();
    currentSprite.scrollFactor.set(0, 0);
    currentSprite.zIndex = 10000;
    currentSprite.visible = true;
    currentSprite.alpha = 1.0;
    currentSprite.dirty = true;

    // 1. OBLIGATORIO: Destruye por completo los buffers de la hoja anterior ANTES de destruir el graphic
    if (oldBmd != null && oldBmd != newBmd)
    {
      if (oldGraphic != null)
      {
        oldGraphic.bitmap = null;
      }
      if (oldBmd.image != null)
      {
        if (oldBmd.image.buffer != null)
        {
          if (oldBmd.image.buffer.data != null)
          {
            oldBmd.image.buffer.data.buffer = null;
          }
          oldBmd.image.buffer.data = null;
        }
        oldBmd.image.data = null;
        oldBmd.image.buffer = null;
      }
      oldBmd.disposeImage();
      oldBmd.dispose();
      oldBmd = null;
    }
    if (oldFrames != null && oldFrames != newFrames)
    {
      oldFrames.destroy();
      oldFrames = null;
    }
    if (oldGraphic != null && oldGraphic != newGraphic)
    {
      FlxG.bitmap.remove(oldGraphic);
      oldGraphic.destroy();
      oldGraphic = null;
    }

    #if (openfl && !macro)
    if (openfl.utils.Assets.cache != null)
    {
      openfl.utils.Assets.cache.clear("assets/videos/converted/");
      openfl.utils.Assets.cache.clear("videos:assets/videos/converted/");
    }
    #end
    #if (lime && !macro)
    if (lime.utils.Assets.cache != null)
    {
      lime.utils.Assets.cache.clear("assets/videos/converted/");
      lime.utils.Assets.cache.clear("videos:assets/videos/converted/");
    }
    #end

    #if (cpp || switch)
    cpp.vm.Gc.run(true);
    trace('[NXVideoPlayer] Memory after sheet $sheetIndex cleanup: GC Heap: ${Math.round(cpp.vm.Gc.memInfo(0) / (1024*1024))} MB (large: ${Math.round(cpp.vm.Gc.memInfo(3) / (1024*1024))} MB)');
    #end

    // 2. DESPUÉS: Lanzar prefetch de la siguiente hoja en segundo plano (máximo 2 hojas en RAM)
    if (sheetIndex + 1 < totalSheets)
    {
      prefetchNextSheet(sheetIndex + 1);
    }

    return true;
  }

  static function onPostUpdate():Void
  {
    if (!isPlaying || isPaused || currentSprite == null || isAdvancingSheet) return;
    if (restartPending)
    {
      updateRestart();
      return;
    }

    var elapsedSec:Float = 0.0;
    if (currentAudio != null && currentAudio.playing)
    {
      elapsedSec = currentAudio.time / 1000.0;
      lastValidAudioSec = elapsedSec;
      lastWallTimestamp = haxe.Timer.stamp();
    }
    else
    {
      // Fallback cuando el audio termina antes que la última hoja
      if (currentAudio != null && !currentAudio.playing && lastValidAudioSec > 1.0)
      {
        if (currentSheetIndex >= totalSheets - 1)
        {
          trace('[NXVideoPlayer] Audio completed on final sheet. Concluding cutscene cleanly.');
          finishCutscene();
          return;
        }
      }
      elapsedSec = lastValidAudioSec + (haxe.Timer.stamp() - lastWallTimestamp);
    }

    var targetGlobalFrame:Int = Std.int(Math.floor(elapsedSec * animFps));

    // Bucle while obligatorio para avance/salto de hojas sin desincronización
    while (isPlaying && targetGlobalFrame >= (sheetStartGlobalFrame + currentSheetFrameCount))
    {
      if (currentSheetIndex + 1 < totalSheets)
      {
        var prevSheetFrameCount:Int = currentSheetFrameCount;
        sheetStartGlobalFrame += prevSheetFrameCount;
        currentSheetIndex++;
        isAdvancingSheet = true;
        var loaded:Bool = loadAndPlaySheet(currentSheetIndex);
        isAdvancingSheet = false;
        if (!loaded)
        {
          return;
        }
      }
      else
      {
        finishCutscene();
        return;
      }
    }

    if (!isPlaying || currentSprite == null) return;

    // Posicionar inmediatamente el localFrame de la hoja actual en este mismo tick
    var localFrame:Int = targetGlobalFrame - sheetStartGlobalFrame;
    if (localFrame < 0) localFrame = 0;
    if (localFrame >= currentSheetFrameCount) localFrame = currentSheetFrameCount - 1;

    if (currentSprite.animation != null && currentSprite.animation.curAnim != null)
    {
      currentSprite.animation.curAnim.curFrame = localFrame;
      currentSprite.dirty = true;
    }
  }

  /**
   * Pauses the active cutscene.
   */
  public static function pause():Void
  {
    if (!isPlaying) return;
    isPaused = true;
    try
    {
      if (currentAudio != null && currentAudio.playing) currentAudio.pause();
      if (currentSprite != null && currentSprite.animation != null) currentSprite.animation.pause();
    }
    catch (e:Dynamic) {}
  }

  /**
   * Resumes the active cutscene.
   */
  public static function resume():Void
  {
    if (!isPlaying) return;
    isPaused = false;
    // The wall-clock fallback must not count the time spent in the pause menu.
    lastWallTimestamp = haxe.Timer.stamp();
    try
    {
      if (currentAudio != null && !currentAudio.playing) currentAudio.resume();
      if (currentSprite != null && currentSprite.animation != null) currentSprite.animation.resume();
    }
    catch (e:Dynamic) {}
  }

  /**
   * True while "Restart Cutscene" waits for sheet 0 to come back from the prefetch thread.
   */
  static var restartPending:Bool = false;

  /**
   * Plays the active cutscene again from the beginning ("Restart Cutscene" in the pause menu) and resumes
   * it, like upstream's restartVideo(). Never blocks the main thread: on sheet 0 it only rewinds the audio;
   * on a later sheet, sheet 0 is decoded by the prefetch thread and playback restarts once it is ready.
   */
  public static function restart():Bool
  {
    if (!isPlaying) return false;
    isPaused = false;
    if (currentSheetIndex == 0)
    {
      restartFromBeginning();
      trace('[NXVideoPlayer] Restart: rewound sheet 0 of $currentVideoName');
      return true;
    }
    try
    {
      if (currentAudio != null) currentAudio.pause();
    }
    catch (e:Dynamic) {}
    restartPending = true;
    trace('[NXVideoPlayer] Restart: waiting for sheet 0 of $currentVideoName from the prefetch thread');
    return true;
  }

  static function restartFromBeginning():Void
  {
    sheetStartGlobalFrame = 0;
    lastValidAudioSec = 0.0;
    lastWallTimestamp = haxe.Timer.stamp();
    try
    {
      if (currentSprite != null && currentSprite.animation != null && currentSprite.animation.curAnim != null)
      {
        currentSprite.animation.resume();
        currentSprite.animation.curAnim.curFrame = 0;
      }
      if (currentAudio != null) currentAudio.play(true, 0);
    }
    catch (e:Dynamic) {}
  }

  /**
   * Restart in progress: schedule sheet 0 and switch to it as soon as the prefetch thread has it.
   */
  static function updateRestart():Void
  {
    #if sys
    if (prefetchMutex == null) prefetchMutex = new sys.thread.Mutex();
    prefetchMutex.acquire();
    var ready:Bool = prefetchedSheetIndex == 0 && prefetchedImage != null && prefetchedXml != null;
    var busy:Bool = isPrefetching;
    prefetchMutex.release();
    if (!ready)
    {
      if (!busy) prefetchNextSheet(0);
      return;
    }
    #end
    currentSheetIndex = 0;
    sheetStartGlobalFrame = 0;
    isAdvancingSheet = true;
    var loaded:Bool = loadAndPlaySheet(0);
    isAdvancingSheet = false;
    restartPending = false;
    if (loaded) restartFromBeginning();
    trace('[NXVideoPlayer] Restart: sheet 0 back (${loaded ? "playing from the start" : "load failed"})');
  }

  /**
   * Finishes the cutscene naturally when animation completes, calling onComplete.
   */
  public static function finishCutscene():Void
  {
    if (!isPlaying) return;
    isPlaying = false;
    isAdvancingSheet = false;

    var cb = onCompleteCallback;
    onCompleteCallback = null;

    stop();

    if (cb != null)
    {
      cb();
    }
  }

  /**
   * Safely stops and frees all resources for the cutscene.
   */
  public static function stop():Void
  {
    isPlaying = false;
    isPaused = false;
    restartPending = false;
    isAdvancingSheet = false;
    onCompleteCallback = null;
    FlxG.signals.postUpdate.remove(onPostUpdate);

    #if sys
    if (prefetchMutex != null)
    {
      prefetchMutex.acquire();
      if (prefetchedImage != null)
      {
        if (prefetchedImage.buffer != null)
        {
          if (prefetchedImage.buffer.data != null)
          {
            prefetchedImage.buffer.data.buffer = null;
          }
          prefetchedImage.buffer.data = null;
        }
        prefetchedImage.data = null;
        prefetchedImage.buffer = null;
      }
      prefetchedImage = null;
      prefetchedXml = null;
      prefetchedSheetIndex = -1;
      isPrefetching = false;
      prefetchGen++;
      prefetchMutex.release();
    }
    #end

    sheetStartGlobalFrame = 0;
    currentSheetFrameCount = 0;
    lastValidAudioSec = 0.0;
    lastWallTimestamp = 0.0;

    try
    {
      if (currentAudio != null)
      {
        currentAudio.stop();
        FlxG.sound.list.remove(currentAudio, true);
        currentAudio.destroy();
        currentAudio = null;
      }

      if (activeGraphic != null)
      {
        activeGraphic.bitmap = null;
      }

      if (activeBitmapData != null)
      {
        if (activeBitmapData.image != null)
        {
          if (activeBitmapData.image.buffer != null)
          {
            if (activeBitmapData.image.buffer.data != null)
            {
              activeBitmapData.image.buffer.data.buffer = null;
            }
            activeBitmapData.image.buffer.data = null;
          }
          activeBitmapData.image.data = null;
          activeBitmapData.image.buffer = null;
        }
        activeBitmapData.disposeImage();
        activeBitmapData.dispose();
        activeBitmapData = null;
      }

      if (currentSprite != null)
      {
        if (PlayState.instance != null) PlayState.instance.remove(currentSprite);
        if (currentSprite.frames != null)
        {
          currentSprite.frames.destroy();
        }
        currentSprite.destroy();
        currentSprite = null;
      }

      if (activeGraphic != null)
      {
        FlxG.bitmap.remove(activeGraphic);
        activeGraphic.destroy();
        activeGraphic = null;
      }

      #if (openfl && !macro)
      if (openfl.utils.Assets.cache != null)
      {
        openfl.utils.Assets.cache.clear("assets/videos/converted/");
        openfl.utils.Assets.cache.clear("videos:assets/videos/converted/");
      }
      #end
      #if (lime && !macro)
      if (lime.utils.Assets.cache != null)
      {
        lime.utils.Assets.cache.clear("assets/videos/converted/");
        lime.utils.Assets.cache.clear("videos:assets/videos/converted/");
      }
      #end

      #if (cpp || switch)
      cpp.vm.Gc.run(true);
      cpp.vm.Gc.compact();
      trace('[NXVideoPlayer] Stop completed. Final GC Heap: ${Math.round(cpp.vm.Gc.memInfo(0) / (1024*1024))} MB (large: ${Math.round(cpp.vm.Gc.memInfo(3) / (1024*1024))} MB)');
      #end

      if (PlayState.instance != null)
      {
        if (PlayState.instance.camCutscene != null)
        {
          PlayState.instance.camCutscene.bgColor = 0x00000000;
        }
        PlayState.instance.camHUD.visible = true;
        PlayState.instance.isInCutscene = false;
      }
    }
    catch (e:Dynamic)
    {
      trace('[NXVideoPlayer] Error during stop(): ' + e);
    }
  }

  /**
   * Extracts clean file basename without directories or file extensions.
   */
  public static function extractVideoName(path:String):String
  {
    if (path == null) return "";
    var p = new haxe.io.Path(path);
    return p.file;
  }
}
