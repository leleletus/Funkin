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
   */
  public static function playConverted(videoPath:String, onComplete:Void->Void):Bool
  {
    if (PlayState.instance == null) return false;

    try
    {
      var videoName:String = extractVideoName(videoPath);
      if (videoName == null || videoName.length == 0) return false;

      trace('[NXVideoPlayer] Verifying converted assets for: $videoName');

      var pngExists:Bool = false;
      var xmlExists:Bool = false;

      // 1. Check OpenFL / Lime Assets Library
      try
      {
        if (Assets.exists('videos:assets/videos/converted/$videoName.png', IMAGE) &&
            Assets.exists('videos:assets/videos/converted/$videoName.xml', TEXT))
        {
          pngExists = true;
          xmlExists = true;
        }
        else if (Assets.exists('assets/videos/converted/$videoName.png', IMAGE) &&
                 Assets.exists('assets/videos/converted/$videoName.xml', TEXT))
        {
          pngExists = true;
          xmlExists = true;
        }
        #if sys
        // 2. Check RomFS / SDMC direct filesystem
        else if (sys.FileSystem.exists('romfs:/assets/videos/converted/$videoName.png') &&
                 sys.FileSystem.exists('romfs:/assets/videos/converted/$videoName.xml'))
        {
          pngExists = true;
          xmlExists = true;
        }
        else if (sys.FileSystem.exists('assets/videos/converted/$videoName.png') &&
                 sys.FileSystem.exists('assets/videos/converted/$videoName.xml'))
        {
          pngExists = true;
          xmlExists = true;
        }
        #end
      }
      catch (e:Dynamic)
      {
        trace('[NXVideoPlayer] Asset existence check threw: ' + e);
        return false;
      }

      // If either .png or .xml does not exist, do NOT instantiate ANY graphics
      if (!pngExists || !xmlExists)
      {
        trace('[NXVideoPlayer] No converted atlas (.png/.xml) found for "$videoName". Safe skip to avoid SIGSEGV.');
        stop();
        return false;
      }

      // Load atlas frames safely
      var frames:FlxAtlasFrames = null;
      try
      {
        if (Assets.exists('videos:assets/videos/converted/$videoName.png', IMAGE) &&
            Assets.exists('videos:assets/videos/converted/$videoName.xml', TEXT))
        {
          frames = FlxAtlasFrames.fromSparrow(
            Assets.getBitmapData('videos:assets/videos/converted/$videoName.png'),
            Assets.getText('videos:assets/videos/converted/$videoName.xml')
          );
        }
        else if (Assets.exists('assets/videos/converted/$videoName.png', IMAGE) &&
                 Assets.exists('assets/videos/converted/$videoName.xml', TEXT))
        {
          frames = FlxAtlasFrames.fromSparrow(
            Assets.getBitmapData('assets/videos/converted/$videoName.png'),
            Assets.getText('assets/videos/converted/$videoName.xml')
          );
        }
        #if sys
        else if (sys.FileSystem.exists('romfs:/assets/videos/converted/$videoName.png') &&
                 sys.FileSystem.exists('romfs:/assets/videos/converted/$videoName.xml'))
        {
          frames = FlxAtlasFrames.fromSparrow(
            openfl.display.BitmapData.fromFile('romfs:/assets/videos/converted/$videoName.png'),
            sys.io.File.getContent('romfs:/assets/videos/converted/$videoName.xml')
          );
        }
        else if (sys.FileSystem.exists('assets/videos/converted/$videoName.png') &&
                 sys.FileSystem.exists('assets/videos/converted/$videoName.xml'))
        {
          frames = FlxAtlasFrames.fromSparrow(
            openfl.display.BitmapData.fromFile('assets/videos/converted/$videoName.png'),
            sys.io.File.getContent('assets/videos/converted/$videoName.xml')
          );
        }
        #end
      }
      catch (e:Dynamic)
      {
        trace('[NXVideoPlayer] Exception loading sparrow atlas: ' + e);
        stop();
        return false;
      }

      if (frames == null || frames.frames == null || frames.frames.length == 0)
      {
        trace('[NXVideoPlayer] Loaded atlas frames were null or empty for "$videoName". Aborting.');
        stop();
        return false;
      }

      // Check audio existence
      var hasAudio:Bool = false;
      var audioPath:String = 'videos/converted/$videoName.ogg';
      try
      {
        if (Assets.exists('videos:assets/videos/converted/$videoName.ogg', SOUND) ||
            Assets.exists('assets/videos/converted/$videoName.ogg', SOUND))
        {
          hasAudio = true;
        }
        #if sys
        else if (sys.FileSystem.exists('romfs:/assets/videos/converted/$videoName.ogg') ||
                 sys.FileSystem.exists('assets/videos/converted/$videoName.ogg'))
        {
          hasAudio = true;
        }
        #end
      }
      catch (e:Dynamic)
      {
        hasAudio = false;
      }

      trace('[NXVideoPlayer] Playing converted cutscene for: $videoName (Audio: $hasAudio)');
      isPlaying = true;

      PlayState.instance.isInCutscene = true;
      PlayState.instance.camHUD.visible = false;

      var cutsceneSpr:FlxSprite = new FlxSprite(0, 0);
      cutsceneSpr.frames = frames;
      cutsceneSpr.animation.addByPrefix('play', 'cutscene', 24, false);
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
          currentAudio = FunkinSound.load(Paths.file(audioPath), 1.0, false, true, false, false, finishCutscene, null, true);
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
      cutsceneSpr.animation.finishCallback = function(_)
      {
        if (!hasAudio) finishCutscene();
      };

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
        currentSprite.destroy();
        currentSprite = null;
      }

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
