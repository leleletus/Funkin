package funkin;

import flixel.graphics.FlxGraphic;
import flixel.FlxG;
import funkin.play.notes.notestyle.NoteStyle;
import openfl.utils.AssetType;
import openfl.Assets;
import openfl.system.System;
import openfl.media.Sound;
import lime.app.Future;
import lime.app.Promise;

/**
 * Handles caching of textures and sounds for the game.
 * TODO: Remove this once Eric finishes the memory system.
 */
@:nullSafety(Off)
class FunkinMemory
{
  static var permanentCachedTextures:Map<String, FlxGraphic> = [];
  static var currentCachedTextures:Map<String, FlxGraphic> = [];
  static var previousCachedTextures:Map<String, FlxGraphic> = [];

  // waow
  static var permanentCachedSounds:Map<String, Sound> = [];
  static var currentCachedSounds:Map<String, Sound> = [];
  static var previousCachedSounds:Map<String, Sound> = [];

  static var purgeFilter:Array<String> = [
    "/week",
    "/characters",
    "/charSelect",
    "/results",
    "phillyStreets/",
    "phillyBlazin/",
    "phillyTrain",
    "spraycan",
    "Spraypaint",
    "SpraycanPile",
    "wked1_cutscene"
  ];

  static final STAGE_PURGE_PATTERNS:Array<String> = [
    "philly", "erect", "spraycan", "Spraypaint", "CanImpact", "wked1_cutscene",
    "weekend1", "tank", "mountains", "cityruins", "smokeLeft", "smokeRight", "bricksGround",
    "school", "weeb", "petals", "limo", "fastCar", "mall", "santa", "evilTree",
    "evilSnowman", "spooky", "halloween", "bgTrees", "sserafim", "truck", "counter-stretch",
    "burger-cutscene", "front-stool", "back-tables", "back-stools"
  ];

  /**
   * Caches textures that are always required.
   */
  public static inline function initialCache():Void
  {
    var allImages:Array<String> = Assets.list();

    for (file in allImages)
    {
      if (!(file.endsWith(".png") #if FEATURE_COMPRESSED_TEXTURES || file.endsWith(".astc") #end)
        || file.contains("chart-editor")
        || !file.contains("ui/"))
      {
        continue;
      }

      file = file.replace(" ", ""); // Handle stray spaces.

      if (file.contains("shared") || Assets.exists('shared:$file', AssetType.IMAGE))
      {
        file = 'shared:$file';
      }
      permanentCacheTexture(file);
    }

    permanentCacheTexture(Paths.image("healthBar"));
    permanentCacheTexture(Paths.image("menuDesat"));
    permanentCacheTexture(Paths.image("notes", "shared"));
    permanentCacheTexture(Paths.image("noteSplashes", "shared"));
    permanentCacheTexture(Paths.image("noteStrumline", "shared"));
    permanentCacheTexture(Paths.image("NOTE_hold_assets"));
    // dude
    permanentCacheTexture(Paths.image("fonts/bold", null));
    permanentCacheTexture(Paths.image("fonts/default", null));
    permanentCacheTexture(Paths.image("fonts/freeplay-clear", null));

    var allSounds:Array<String> = Assets.list(AssetType.SOUND);

    for (file in allSounds)
    {
      if (!file.endsWith(".ogg") || !file.contains("countdown/")) continue;

      file = file.replace(" ", "");

      if (file.contains("shared") || Assets.exists('shared:$file', AssetType.SOUND))
      {
        file = 'shared:$file';
      }

      permanentCacheSound(file);
    }

    permanentCacheSound(Paths.sound("cancelMenu"));
    permanentCacheSound(Paths.sound("confirmMenu"));
    permanentCacheSound(Paths.sound("screenshot"));
    permanentCacheSound(Paths.sound("scrollMenu"));
    permanentCacheSound(Paths.sound("soundtray/Voldown"));
    permanentCacheSound(Paths.sound("soundtray/VolMAX"));
    permanentCacheSound(Paths.sound("soundtray/Volup"));
    permanentCacheSound(Paths.music("freakyMenu/freakyMenu"));
    permanentCacheSound(Paths.music("offsetsLoop/offsetsLoop"));
    permanentCacheSound(Paths.music("offsetsLoop/drumsLoop"));
    permanentCacheSound(Paths.sound("missnote1", "shared"));
    permanentCacheSound(Paths.sound("missnote2", "shared"));
    permanentCacheSound(Paths.sound("missnote3", "shared"));
  }

  /**
   * Evaluates whether a graphic belongs to essential UI, fonts, Polymod scripts,
   * FlxBar elements, or permanent assets and must NEVER be destroyed.
   */
  public static function isProtectedGraphic(key:String, obj:Null<FlxGraphic>):Bool
  {
    if (key == null) return true;
    if (permanentCachedTextures.exists(key)) return true;

    // Resguardar fuentes
    if (key.contains("fonts")) return true;

    // Resguardar elementos de UI e iconos
    if (key.contains("healthBar") || key.contains("icons") || key.contains("ui/") || key.contains("flixel/")) return true;

    // Resguardar graficos internos generados por FlxBar
    if (key.contains("FlxBar") || key.contains("flxBar")) return true;

    // Resguardar scripts de Polymod, backing cards y elementos de Freeplay
    if (key.contains("scripts/") || key.contains("backcards/") || key.contains("sortedLetters")) return true;

    return false;
  }

  /**
   * Selectively purges graphics associated with a specific stage (or all previous stages and temporary props)
   * while safeguarding UI (healthBar, icons, fonts, ui/), FlxBar, and Polymod scripts.
   * Runs Gc.run(true) and Gc.compact() to consolidate unified memory on Switch.
   * @param stageId Optional stage ID to purge. If null, purges all previous stages, cutscenes, and temporary characters.
   */
  public static function purgeStageCache(?stageId:String):Void
  {
    @:privateAccess
    if (FlxG.bitmap._cache == null) return;

    var keysToPurge:Array<String> = [];

    @:privateAccess
    for (key in FlxG.bitmap._cache.keys())
    {
      var obj:Null<FlxGraphic> = FlxG.bitmap.get(key);
      if (obj == null || isProtectedGraphic(key, obj)) continue;

      var shouldPurge:Bool = false;

      // Coincidencia por escenario específico
      if (stageId != null && stageId.length > 0 && key.toLowerCase().contains(stageId.toLowerCase()))
      {
        shouldPurge = true;
      }

      // Prefijos y patrones de escenarios pesados y props temporales
      if (!shouldPurge)
      {
        if (key.contains("stage") && !key.contains("StageProp") && !key.contains("Stage"))
        {
          shouldPurge = true;
        }
        else
        {
          for (pattern in STAGE_PURGE_PATTERNS)
          {
            if (key.contains(pattern))
            {
              shouldPurge = true;
              break;
            }
          }
        }
      }

      // Si stageId es null (salida completa de gameplay/semana), purgar también personajes temporales
      if (!shouldPurge && stageId == null)
      {
        if (key.contains("characters/") || key.contains("charSelect/"))
        {
          shouldPurge = true;
        }
      }

      if (shouldPurge)
      {
        keysToPurge.push(key);
      }
    }

    for (key in keysToPurge)
    {
      var graphic:Null<FlxGraphic> = FlxG.bitmap.get(key);
      if (graphic != null && !graphic.isDestroyed)
      {
        if (graphic.useCount > 0) continue;

        FlxG.bitmap.remove(graphic);
        graphic.persist = false;
        graphic.destroy();
      }
      currentCachedTextures.remove(key);
      previousCachedTextures.remove(key);
      openfl.Assets.cache.removeBitmapData(key);
    }

    #if (cpp || neko || hl)
    cpp.vm.Gc.run(true);
    cpp.vm.Gc.compact();
    #end
  }

  /**
   * Clears unused texture and sound caches safely.
   */
  public static inline function purgeCache(callGarbageCollector:Bool = false):Void
  {
    preparePurgeTextureCache();
    purgeTextureCache();
    preparePurgeSoundCache();
    purgeSoundCache();
    #if (cpp || neko || hl)
    if (callGarbageCollector) cpp.vm.Gc.run(false);
    #end
  }

  /**
   * Safe stub that avoids destructive cache clearing.
   */
  public static inline function purgeVRAMAggressive():Void
  {
    purgeCache(false);
  }

  ///// TEXTURES /////

  /**
   * Determine whether the texture with the given key is cached.
   * @param key The key of the texture to check.
   * @return Whether the texture is cached.
   */
  public static function isTextureCached(key:String):Bool
  {
    return FlxG.bitmap.get(key) != null;
  }

  /**
   * Ensures a texture with the given key is cached.
   * @param key The key of the texture to cache.
   */
  public static function cacheTexture(key:String):Void
  {
    if (currentCachedTextures.exists(key)) return;

    if (previousCachedTextures.exists(key))
    {
      // Move the texture from the previous cache to the current cache.
      var graphic:Null<FlxGraphic> = previousCachedTextures.get(key);
      previousCachedTextures.remove(key);
      if (graphic != null) currentCachedTextures.set(key, graphic);
      return;
    }

    var graphic:Null<FlxGraphic> = FlxGraphic.fromAssetKey(key, false, null, true);
    if (graphic == null)
    {
      FlxG.log.warn('Failed to cache graphic: $key');
      return;
    }

    log('Cached asset $key');
    graphic.persist = true;
    currentCachedTextures.set(key, graphic);
    forceRender(graphic);
  }

  /**
   * Permanently caches a texture with the given key.
   * @param key The key of the texture to cache.
   */
  static function permanentCacheTexture(key:String):Void
  {
    if (permanentCachedTextures.exists(key)) return;

    var graphic:Null<FlxGraphic> = FlxGraphic.fromAssetKey(key, false, null, true);
    if (graphic == null)
    {
      FlxG.log.warn('Failed to cache graphic: $key');
      return;
    }

    log('Cached graphic $key');
    graphic.persist = true;
    permanentCachedTextures.set(key, graphic);
    forceRender(graphic);
    currentCachedTextures = permanentCachedTextures.copy();
  }

  /**
   * Forces the GPU to load and upload a FlxGraphic.
   */
  private static function forceRender(graphic:FlxGraphic):Void
  {
    if (graphic == null) return;

    var bmp:Null<FlxGraphic> = FlxG.bitmap.get(graphic.key);
    if (bmp != null && bmp.bitmap != null) var _:Int = bmp.bitmap.width; // Trigger

    // Draws sprite and actually caches it.
    var sprite = new flixel.FlxSprite();
    sprite.loadGraphic(graphic);
    sprite.draw(); // Draw sprite and load it into game's memory.
    graphic.bitmap?.getTexture(FlxG.stage.context3D); // Just in case that didn't work...
    sprite.destroy();
  }

  /**
   * Checks, if graphic with given path cached in memory.
   */
  public static inline function isGraphicCached(path:String):Bool
    return permanentCachedTextures.exists(path) || currentCachedTextures.exists(path) || previousCachedTextures.exists(path);

  public static function getCachedGraphic(path:String):Null<FlxGraphic>
  {
    if (permanentCachedTextures.exists(path)) return permanentCachedTextures.get(path);
    if (currentCachedTextures.exists(path)) return currentCachedTextures.get(path);
    if (previousCachedTextures.exists(path)) return previousCachedTextures.get(path); // just in case

    return null;
  }

  /**
   * Prepares the cache for purging unused textures.
   */
  public inline static function preparePurgeTextureCache():Void
  {
    previousCachedTextures = currentCachedTextures.copy();

    for (graphicKey in previousCachedTextures.keys())
    {
      if (permanentCachedTextures.exists(graphicKey))
      {
        previousCachedTextures.remove(graphicKey);
      }
    }

    currentCachedTextures = permanentCachedTextures.copy();
  }

  /**
   * Purges unused textures from the cache.
   */
  public static function purgeTextureCache():Void
  {
    for (graphicKey in previousCachedTextures.keys())
    {
      if (permanentCachedTextures.exists(graphicKey))
      {
        previousCachedTextures.remove(graphicKey);
        continue;
      }

      var graphic:Null<FlxGraphic> = previousCachedTextures.get(graphicKey);
      if (graphic != null)
      {
        if (isProtectedGraphic(graphicKey, graphic))
        {
          previousCachedTextures.remove(graphicKey);
          continue;
        }

        FlxG.bitmap.remove(graphic);
        graphic.persist = false;
        graphic.destroy();
        previousCachedTextures.remove(graphicKey);
        Assets.cache.clear(graphicKey);
      }
    }
    @:privateAccess
    if (FlxG.bitmap._cache == null)
    {
      @:privateAccess
      FlxG.bitmap._cache = new Map();
    }

    @:privateAccess
    {
      var keysToCheck:Array<String> = [];
      for (key in FlxG.bitmap._cache.keys())
      {
        keysToCheck.push(key);
      }

      for (key in keysToCheck)
      {
        var obj:Null<FlxGraphic> = FlxG.bitmap.get(key);
        if (obj == null || obj.isDestroyed || isProtectedGraphic(key, obj) || key.contains("stickers"))
        {
          continue;
        }

        if (obj.useCount > 0)
        {
          continue;
        }

        for (purgeEntry in purgeFilter)
        {
          if (key.contains(purgeEntry))
          {
            FlxG.bitmap.removeKey(key);
            obj.persist = false;
            obj.destroy();
            break;
          }
        }
      }
    }
  }

  ///// NOTE STYLE //////

  public static function cacheNoteStyle(style:NoteStyle):Void
  {
    // TODO: Texture paths should fall back to the default values.
    cacheTexture(Paths.image(style.getNoteAssetPath() ?? "note"));
    cacheTexture(style.getHoldNoteAssetPath() ?? "noteHold");
    cacheTexture(Paths.image(style.getStrumlineAssetPath() ?? "strumline"));
    cacheTexture(Paths.image(style.getSplashAssetPath() ?? "noteSplash"));

    cacheTexture(Paths.image(style.getHoldCoverDirectionAssetPath(LEFT) ?? "LEFT"));
    cacheTexture(Paths.image(style.getHoldCoverDirectionAssetPath(RIGHT) ?? "RIGHT"));
    cacheTexture(Paths.image(style.getHoldCoverDirectionAssetPath(UP) ?? "UP"));
    cacheTexture(Paths.image(style.getHoldCoverDirectionAssetPath(DOWN) ?? "DOWN"));

    // cacheTexture(Paths.image(style.buildCountdownSpritePath(THREE) ?? "THREE"));
    cacheTexture(Paths.image(style.buildCountdownSpritePath(TWO) ?? "TWO"));
    cacheTexture(Paths.image(style.buildCountdownSpritePath(ONE) ?? "ONE"));
    cacheTexture(Paths.image(style.buildCountdownSpritePath(GO) ?? "GO"));

    cacheSound(style.getCountdownSoundPath(THREE) ?? "THREE");
    cacheSound(style.getCountdownSoundPath(TWO) ?? "TWO");
    cacheSound(style.getCountdownSoundPath(ONE) ?? "ONE");
    cacheSound(style.getCountdownSoundPath(GO) ?? "GO");

    cacheTexture(Paths.image(style.buildJudgementSpritePath("sick") ?? 'sick'));
    cacheTexture(Paths.image(style.buildJudgementSpritePath("good") ?? 'good'));
    cacheTexture(Paths.image(style.buildJudgementSpritePath("bad") ?? 'bad'));
    cacheTexture(Paths.image(style.buildJudgementSpritePath("shit") ?? 'shit'));

    cacheTexture(Paths.image(style.buildComboNumSpritePath(0) ?? '0'));
    cacheTexture(Paths.image(style.buildComboNumSpritePath(1) ?? '1'));
    cacheTexture(Paths.image(style.buildComboNumSpritePath(2) ?? '2'));
    cacheTexture(Paths.image(style.buildComboNumSpritePath(3) ?? '3'));
    cacheTexture(Paths.image(style.buildComboNumSpritePath(4) ?? '4'));
    cacheTexture(Paths.image(style.buildComboNumSpritePath(5) ?? '5'));
    cacheTexture(Paths.image(style.buildComboNumSpritePath(6) ?? '6'));
    cacheTexture(Paths.image(style.buildComboNumSpritePath(7) ?? '7'));
    cacheTexture(Paths.image(style.buildComboNumSpritePath(8) ?? '8'));
    cacheTexture(Paths.image(style.buildComboNumSpritePath(9) ?? '9'));
  }

  ///// SOUND //////

  public static function cacheSound(key:String):Void
  {
    if (currentCachedSounds.exists(key)) return;

    if (previousCachedSounds.exists(key))
    {
      // Move the texture from the previous cache to the current cache.
      var sound:Null<Sound> = previousCachedSounds.get(key);
      previousCachedSounds.remove(key);
      if (sound != null) currentCachedSounds.set(key, sound);
      return;
    }

    var sound:Null<Sound> = Assets.getSound(key, true);
    if (sound == null) return;
    else
      currentCachedSounds.set(key, sound);
  }

  public static function permanentCacheSound(key:String):Void
  {
    if (permanentCachedSounds.exists(key)) return;

    var sound:Null<Sound> = Assets.getSound(key, true);
    if (sound == null) return;
    else
      permanentCachedSounds.set(key, sound);

    if (sound != null) currentCachedSounds.set(key, sound);
  }

  public static function preparePurgeSoundCache():Void
  {
    previousCachedSounds = currentCachedSounds.copy();

    for (key in previousCachedSounds.keys())
    {
      if (permanentCachedSounds.exists(key))
      {
        previousCachedSounds.remove(key);
      }
    }

    currentCachedSounds = permanentCachedSounds.copy();
  }

  /**
   * Purges unused sounds from the cache.
   */
  public static inline function purgeSoundCache():Void
  {
    for (key in previousCachedSounds.keys())
    {
      if (permanentCachedSounds.exists(key))
      {
        previousCachedSounds.remove(key);
        continue;
      }

      var sound:Null<Sound> = previousCachedSounds.get(key);
      if (sound != null)
      {
        Assets.cache.removeSound(key);
        previousCachedSounds.remove(key);
      }
    }
    Assets.cache.clear("songs");
    Assets.cache.clear("music");
    // Felt lazy.
    var key = Paths.music("freakyMenu/freakyMenu");
    var sound:Null<Sound> = Assets.getSound(key, true);
    if (sound != null)
    {
      permanentCachedSounds.set(key, sound);
      currentCachedSounds.set(key, sound);
    }
  }

  ///// MISC /////

  public static inline function clearFreeplay():Void
  {
    var keysToRemove:Array<String> = [];

    @:privateAccess
    for (key in FlxG.bitmap._cache.keys())
    {
      if (!key.contains("freeplay")) continue;
      if (permanentCachedTextures.exists(key) || key.contains("fonts")) continue;

      keysToRemove.push(key);
    }

    @:privateAccess
    for (key in keysToRemove)
    {
      log('Cleaning asset $key');
      var obj:Null<FlxGraphic> = FlxG.bitmap.get(key);
      if (obj != null)
      {
        obj.destroy();
      }
      FlxG.bitmap.removeKey(key);
      if (currentCachedTextures.exists(key)) currentCachedTextures.remove(key);
      Assets.cache.clear(key);
    }

    preparePurgeSoundCache();
    purgeSoundCache();
  }

  public static inline function clearStickers():Void
  {
    var keysToRemove:Array<String> = [];

    @:privateAccess
    for (key in FlxG.bitmap._cache.keys())
    {
      if (!key.contains("stickers")) continue;
      if (permanentCachedTextures.exists(key) || key.contains("fonts")) continue;

      keysToRemove.push(key);
    }

    @:privateAccess
    for (key in keysToRemove)
    {
      log('Cleaning asset $key');
      var obj:Null<FlxGraphic> = FlxG.bitmap.get(key);
      if (obj != null)
      {
        obj.destroy();
      }
      FlxG.bitmap.removeKey(key);
      if (currentCachedTextures.exists(key)) currentCachedTextures.remove(key);
      Assets.cache.clear(key);
    }
  }

  static function log(message:String):Void
  {
    trace(' MEMORY '.bg_bright_lilac().bold() + ' ${message}');
  }
}
