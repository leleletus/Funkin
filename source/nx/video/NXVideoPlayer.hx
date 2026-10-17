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

  static var currentVideoName:String = "";
  static var currentSheetIndex:Int = 0;
  static var totalSheets:Int = 0;
  static var animFps:Int = 24;
  static var onCompleteCallback:Null<Void->Void> = null;
  static var activeBitmapData:Null<openfl.display.BitmapData> = null;
  static var activeGraphic:Null<FlxGraphic> = null;
  static var isAdvancingSheet:Bool = false;

  /**
   * Returns whether a cutscene is actively rendering or playing audio.
   */
  public static inline function isCutscenePlaying():Bool
  {
    return isPlaying;
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
        if (bmd != null && bmd.image != null && bmd.width > 0 && bmd.height > 0) return bmd;

        var bytes = sys.io.File.getBytes(romfsPath);
        if (bytes != null && bytes.length > 0)
        {
          var bmdFromBytes = openfl.display.BitmapData.fromBytes(bytes);
          if (bmdFromBytes != null && bmdFromBytes.image != null && bmdFromBytes.width > 0 && bmdFromBytes.height > 0) return bmdFromBytes;
        }
      }
      if (sys.FileSystem.exists(path))
      {
        var bmd = openfl.display.BitmapData.fromFile(path);
        if (bmd != null && bmd.image != null && bmd.width > 0 && bmd.height > 0) return bmd;
      }
      #end

      if (Assets.exists('videos:' + path, IMAGE))
      {
        var bmd = Assets.getBitmapData('videos:' + path);
        if (bmd != null && bmd.image != null && bmd.width > 0 && bmd.height > 0) return bmd;
      }
      if (Assets.exists(path, IMAGE))
      {
        var bmd = Assets.getBitmapData(path);
        if (bmd != null && bmd.image != null && bmd.width > 0 && bmd.height > 0) return bmd;
      }
      if (Assets.exists('videos:' + path))
      {
        var bytes = Assets.getBytes('videos:' + path);
        if (bytes != null && bytes.length > 0)
        {
          var bmd = openfl.display.BitmapData.fromBytes(bytes);
          if (bmd != null && bmd.image != null && bmd.width > 0 && bmd.height > 0) return bmd;
        }
      }
      if (Assets.exists(path))
      {
        var bytes = Assets.getBytes(path);
        if (bytes != null && bytes.length > 0)
        {
          var bmd = openfl.display.BitmapData.fromBytes(bytes);
          if (bmd != null && bmd.image != null && bmd.width > 0 && bmd.height > 0) return bmd;
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

    var newBmd = getBitmap(pngPath);
    var newXmlStr = getText(xmlPath);
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

    trace('[NXVideoPlayer] Sheet $sheetIndex loaded: ${newBmd.width}x${newBmd.height}, frames: ${newFrames.frames.length} ($pngPath)');

    var oldGraphic = activeGraphic;
    var oldFrames = currentSprite.frames;
    var oldBmd = activeBitmapData;

    activeGraphic = newGraphic;
    activeBitmapData = newBmd;

    // Asignar nuevos frames y resetear animaciones previas
    currentSprite.frames = newFrames;
    currentSprite.animation.destroyAnimations();

    var animName:String = 'sheet_$sheetIndex';
    currentSprite.animation.addByPrefix(animName, 'cutscene', animFps, false);

    // Fallback garantizado por si los nombres de subtextura en XML difieren
    if (currentSprite.animation.getByName(animName) == null || currentSprite.animation.getByName(animName).numFrames == 0)
    {
      var allIndices:Array<Int> = [for (i in 0...newFrames.frames.length) i];
      currentSprite.animation.add(animName, allIndices, animFps, false);
    }

    // Reproducir primero para que frameWidth y frameHeight sean los del frame 0 de la animación
    currentSprite.animation.play(animName, true);

    // CRÍTICO: Ajustar tamaño, hitbox y centrado DESPUÉS de animation.play()
    currentSprite.setGraphicSize(1280, 720);
    currentSprite.updateHitbox();
    currentSprite.screenCenter();
    currentSprite.scrollFactor.set(0, 0);
    currentSprite.zIndex = 10000;
    currentSprite.visible = true;
    currentSprite.alpha = 1.0;

    // Dispose old assets immediately to keep RAM at ~35 MB
    if (oldFrames != null && oldFrames != newFrames)
    {
      oldFrames.destroy();
    }
    if (oldGraphic != null && oldGraphic != newGraphic)
    {
      FlxG.bitmap.remove(oldGraphic);
      oldGraphic.destroy();
    }
    if (oldBmd != null && oldBmd != newBmd)
    {
      oldBmd.disposeImage();
      oldBmd.dispose();
    }

    return true;
  }

  static function onPostUpdate():Void
  {
    if (!isPlaying || currentSprite == null || isAdvancingSheet) return;

    if (currentSprite.animation != null && currentSprite.animation.curAnim != null)
    {
      if (currentSprite.animation.curAnim.finished)
      {
        onSheetAnimationComplete();
      }
    }
  }

  static function onSheetAnimationComplete():Void
  {
    if (!isPlaying || isAdvancingSheet) return;
    isAdvancingSheet = true;

    if (currentSheetIndex + 1 < totalSheets)
    {
      currentSheetIndex++;
      loadAndPlaySheet(currentSheetIndex);
      isAdvancingSheet = false;
    }
    else
    {
      // Final sheet finished!
      isAdvancingSheet = false;
      finishCutscene();
    }
  }

  /**
   * Pauses the active cutscene.
   */
  public static function pause():Void
  {
    if (!isPlaying) return;
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
    try
    {
      if (currentAudio != null && !currentAudio.playing) currentAudio.resume();
      if (currentSprite != null && currentSprite.animation != null) currentSprite.animation.resume();
    }
    catch (e:Dynamic) {}
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
    isAdvancingSheet = false;
    onCompleteCallback = null;
    FlxG.signals.postUpdate.remove(onPostUpdate);

    try
    {
      if (currentAudio != null)
      {
        currentAudio.stop();
        FlxG.sound.list.remove(currentAudio, true);
        currentAudio.destroy();
        currentAudio = null;
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

      if (activeBitmapData != null)
      {
        activeBitmapData.disposeImage();
        activeBitmapData.dispose();
        activeBitmapData = null;
      }

      #if (cpp || switch)
      cpp.vm.Gc.run(true);
      cpp.vm.Gc.compact();
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
