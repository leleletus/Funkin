package nx.video;

import flixel.FlxG;
import flixel.FlxSprite;
import flixel.graphics.frames.FlxAtlasFrames;
import flixel.util.FlxColor;
import funkin.audio.FunkinSound;
import funkin.play.PlayState;
import funkin.Paths;
import openfl.utils.Assets;

/**
 * Modular Cutscene & Video abstraction for Nintendo Switch.
 * Seamlessly plays converted 60fps in-engine sprite/atlas cutscenes with Vorbis audio,
 * or safely falls back to direct transition if no converted asset exists.
 * Armored against Null Pointer Exceptions (SIGSEGV) and missing assets.
 */
class NXVideoPlayer
{
  static var currentSprite:Null<FlxSprite> = null;
  static var currentAudio:Null<FunkinSound> = null;
  static var isPlaying:Bool = false;

  /**
   * Returns whether a cutscene is actively rendering or playing audio.
   */
  public static inline function isCutscenePlaying():Bool
  {
    return isPlaying;
  }

  /**
   * Checks if an adapted sprite sheet / atlas and audio exist for the given video file.
   * If available, plays it in PlayState with 60 FPS hardware rendering and synchronized audio.
   * If missing or on any failure, safely returns false without instantiating any graphics or sounds.
   *
   * @param videoPath The original video path (e.g. "assets/videos/videos/stressPicoCutscene.mkv" or "stressPicoCutscene")
   * @param onComplete Callback invoked when the cutscene finishes or is skipped.
   * @return `true` if a converted cutscene was found and started, `false` otherwise.
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
      if (sys.FileSystem.exists('romfs:/' + path)) return openfl.display.BitmapData.fromFile('romfs:/' + path);
      if (sys.FileSystem.exists(path)) return openfl.display.BitmapData.fromFile(path);
      #end
      if (Assets.exists('videos:' + path, IMAGE)) return Assets.getBitmapData('videos:' + path);
      if (Assets.exists(path, IMAGE)) return Assets.getBitmapData(path);
      if (Assets.exists('videos:' + path))
      {
        var bytes = Assets.getBytes('videos:' + path);
        if (bytes != null) return openfl.display.BitmapData.fromBytes(bytes);
      }
      if (Assets.exists(path))
      {
        var bytes = Assets.getBytes(path);
        if (bytes != null) return openfl.display.BitmapData.fromBytes(bytes);
      }
    }
    catch (e:Dynamic) {}
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

  public static function playConverted(videoPath:String, onComplete:Void->Void):Bool
  {
    if (PlayState.instance == null) return false;

    try
    {
      var videoName:String = extractVideoName(videoPath);
      if (videoName == null || videoName.length == 0) return false;

      trace('[NXVideoPlayer] Verifying converted assets for: $videoName');

      var isMultiSheet:Bool = false;
      var primaryPng:String = '';
      var primaryXml:String = '';

      if (hasAsset('assets/videos/converted/$videoName.png', IMAGE) &&
          hasAsset('assets/videos/converted/$videoName.xml', TEXT))
      {
        primaryPng = 'assets/videos/converted/$videoName.png';
        primaryXml = 'assets/videos/converted/$videoName.xml';
      }
      else if (hasAsset('assets/videos/converted/${videoName}_0.png', IMAGE) &&
               hasAsset('assets/videos/converted/${videoName}_0.xml', TEXT))
      {
        isMultiSheet = true;
        primaryPng = 'assets/videos/converted/${videoName}_0.png';
        primaryXml = 'assets/videos/converted/${videoName}_0.xml';
      }
      else
      {
        trace('[NXVideoPlayer] No converted atlas (.png/.xml) found for "$videoName". Safe skip to avoid SIGSEGV.');
        stop();
        return false;
      }

      var primaryBmd = getBitmap(primaryPng);
      var primaryXmlStr = getText(primaryXml);
      if (primaryBmd == null || primaryXmlStr == null)
      {
        trace('[NXVideoPlayer] Failed reading primary bitmap or xml for "$videoName". Aborting.');
        stop();
        return false;
      }

      var frames:FlxAtlasFrames = FlxAtlasFrames.fromSparrow(primaryBmd, primaryXmlStr);

      if (isMultiSheet)
      {
        var sheetIdx:Int = 1;
        while (true)
        {
          var nextPng = 'assets/videos/converted/${videoName}_$sheetIdx.png';
          var nextXml = 'assets/videos/converted/${videoName}_$sheetIdx.xml';
          if (hasAsset(nextPng, IMAGE) && hasAsset(nextXml, TEXT))
          {
            var nextBmd = getBitmap(nextPng);
            var nextXmlStr = getText(nextXml);
            if (nextBmd != null && nextXmlStr != null)
            {
              var subFrames = FlxAtlasFrames.fromSparrow(nextBmd, nextXmlStr);
              if (subFrames != null) frames.addAtlas(subFrames);
            }
            sheetIdx++;
          }
          else
          {
            break;
          }
        }
      }

      if (frames == null || frames.frames == null || frames.frames.length == 0)
      {
        trace('[NXVideoPlayer] Loaded atlas frames were null or empty for "$videoName". Aborting.');
        stop();
        return false;
      }

      var animFps:Int = 24;
      try
      {
        var parsedXml = Xml.parse(primaryXmlStr).firstElement();
        if (parsedXml != null && parsedXml.exists("fps"))
        {
          var parsed = Std.parseInt(parsedXml.get("fps"));
          if (parsed != null && parsed > 0) animFps = parsed;
        }
      }
      catch (e:Dynamic) {}

      // Check audio existence
      var hasAudio:Bool = hasAsset('assets/videos/converted/$videoName.ogg', SOUND);

      trace('[NXVideoPlayer] Playing converted cutscene for: $videoName (Audio: $hasAudio, FPS: $animFps, MultiSheet: $isMultiSheet)');
      isPlaying = true;

      PlayState.instance.isInCutscene = true;
      PlayState.instance.camHUD.visible = false;

      var cutsceneSpr:FlxSprite = new FlxSprite(0, 0);
      cutsceneSpr.frames = frames;
      cutsceneSpr.animation.addByPrefix('play', 'cutscene', animFps, false);
      cutsceneSpr.setGraphicSize(1280, 720);
      cutsceneSpr.updateHitbox();
      cutsceneSpr.screenCenter();
      cutsceneSpr.cameras = [PlayState.instance.camCutscene];
      cutsceneSpr.scrollFactor.set(0, 0);

      currentSprite = cutsceneSpr;
      PlayState.instance.add(cutsceneSpr);

      var finishCutscene:Void->Void = function()
      {
        if (!isPlaying) return;
        isPlaying = false;

        stop();

        if (onComplete != null) onComplete();
      };

      if (hasAudio)
      {
        try
        {
          var audioKey:String = Assets.exists('videos:assets/videos/converted/$videoName.ogg') ? 'videos:assets/videos/converted/$videoName.ogg' : 'assets/videos/converted/$videoName.ogg';
          #if sys
          if (sys.FileSystem.exists('romfs:/assets/videos/converted/$videoName.ogg'))
          {
            audioKey = 'romfs:/assets/videos/converted/$videoName.ogg';
          }
          #end
          currentAudio = FunkinSound.load(Paths.file(audioKey), 1.0, false, true, false, false, finishCutscene, null, true);
          if (currentAudio != null)
          {
            currentAudio.play();
          }
        }
        catch (e:Dynamic)
        {
          trace('[NXVideoPlayer] Warning: Failed to play audio for cutscene: ' + e);
        }
      }

      cutsceneSpr.animation.play('play');
      if (cutsceneSpr.animation.onFinish != null)
      {
        cutsceneSpr.animation.onFinish.add(function(_)
        {
          if (!hasAudio) finishCutscene();
        });
      }
      else
      {
        cutsceneSpr.animation.finishCallback = function(_)
        {
          if (!hasAudio) finishCutscene();
        };
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
   * Safely stops and frees all resources for the cutscene.
   */
  public static function stop():Void
  {
    isPlaying = false;
    try
    {
      if (currentAudio != null)
      {
        currentAudio.stop();
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

      #if switch
      funkin.FunkinMemory.purgeCache(true);
      cpp.vm.Gc.run(true);
      cpp.vm.Gc.compact();
      #end

      if (PlayState.instance != null)
      {
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
