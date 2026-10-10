package nx.video;

import flixel.FlxG;
import flixel.FlxSprite;
import flixel.util.FlxColor;
import funkin.audio.FunkinSound;
import funkin.play.PlayState;
import funkin.Paths;
import openfl.utils.Assets;

/**
 * Modular Cutscene & Video abstraction for Nintendo Switch.
 * Seamlessly plays converted 60fps in-engine sprite/atlas cutscenes with Vorbis audio,
 * or safely falls back to direct transition if no converted asset exists.
 */
class NXVideoPlayer
{
  static var currentSprite:Null<FlxSprite> = null;
  static var currentAudio:Null<FunkinSound> = null;
  static var isPlaying:Bool = false;

  /**
   * Checks if an adapted sprite sheet / atlas and audio exist for the given video file.
   * If available, plays it in PlayState with 60 FPS hardware rendering and synchronized audio.
   *
   * @param videoPath The original video path (e.g. "assets/videos/videos/stressPicoCutscene.mkv" or "stressPicoCutscene")
   * @param onComplete Callback invoked when the cutscene finishes or is skipped.
   * @return `true` if a converted cutscene was found and started, `false` otherwise.
   */
  public static function playConverted(videoPath:String, onComplete:Void->Void):Bool
  {
    if (PlayState.instance == null) return false;

    var videoName:String = extractVideoName(videoPath);
    trace('[NXVideoPlayer] Checking converted cutscene for: $videoName');

    var sparrowPngPath:String = 'videos/converted/$videoName.png';
    var sparrowXmlPath:String = 'videos/converted/$videoName.xml';
    var audioPath:String = 'videos/converted/$videoName.ogg';

    var hasSparrow:Bool = Assets.exists(Paths.file(sparrowPngPath)) && Assets.exists(Paths.file(sparrowXmlPath));
    var hasAudio:Bool = Assets.exists(Paths.file(audioPath));

    if (!hasSparrow)
    {
      sparrowPngPath = 'assets/videos/converted/$videoName.png';
      sparrowXmlPath = 'assets/videos/converted/$videoName.xml';
      audioPath = 'assets/videos/converted/$videoName.ogg';
      hasSparrow = Assets.exists(sparrowPngPath) && Assets.exists(sparrowXmlPath);
      hasAudio = Assets.exists(audioPath);
    }

    if (!hasSparrow)
    {
      trace('[NXVideoPlayer] No converted sprite/atlas found for "$videoName". Safe skip.');
      return false;
    }

    trace('[NXVideoPlayer] Playing converted cutscene for: $videoName');
    isPlaying = true;

    PlayState.instance.isInCutscene = true;
    PlayState.instance.camHUD.visible = false;

    var cutsceneSpr:FlxSprite = new FlxSprite(0, 0);
    cutsceneSpr.frames = Paths.getSparrowAtlas('converted/$videoName', 'videos');
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

      if (currentAudio != null)
      {
        currentAudio.stop();
        currentAudio.destroy();
        currentAudio = null;
      }

      if (currentSprite != null)
      {
        PlayState.instance.remove(currentSprite);
        currentSprite.destroy();
        currentSprite = null;
      }

      PlayState.instance.camHUD.visible = true;
      PlayState.instance.isInCutscene = false;

      if (onComplete != null) onComplete();
    };

    if (hasAudio)
    {
      currentAudio = FunkinSound.load(Paths.file(audioPath), 1.0, false, true, false, false, finishCutscene, null, true);
      if (currentAudio != null)
      {
        currentAudio.play();
      }
    }

    cutsceneSpr.animation.play('play');
    cutsceneSpr.animation.finishCallback = function(_)
    {
      if (!hasAudio) finishCutscene();
    };

    return true;
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
