package nx;

import flixel.FlxG;
#if switch
import nx.NXMain;
#end

/**
 * Deep engine logging system for Nintendo Switch.
 * Writes real-time execution traces, state transitions, audio metrics, and hardware events
 * directly to sdmc:/switch/Friday-Night-Funkin/logs/deep_engine_trace.log with immediate flush().
 */
class NXDeepTrace
{
  static var logFilePath:Null<String> = null;
  static var isInitialized:Bool = false;
  static var signalsHooked:Bool = false;

  /**
   * Generates a precise timestamp in HH:MM:SS.mmm format.
   */
  public static function getTimestamp():String
  {
    var now:Date = Date.now();
    var msFrac:Int = Math.floor((Sys.time() % 1.0) * 1000.0);
    if (msFrac < 0) msFrac = 0;
    var h:String = StringTools.lpad(Std.string(now.getHours()), "0", 2);
    var m:String = StringTools.lpad(Std.string(now.getMinutes()), "0", 2);
    var s:String = StringTools.lpad(Std.string(now.getSeconds()), "0", 2);
    var ms:String = StringTools.lpad(Std.string(msFrac), "0", 3);
    return '$h:$m:$s.$ms';
  }

  /**
   * Initializes deep engine logging and intercepts global traces.
   */
  public static function init():Void
  {
    #if !NX_DEV_TOOLS
    return;
    #end
    if (isInitialized) return;
    isInitialized = true;

    #if sys
    try
    {
      if (logFilePath == null)
      {
        #if switch
        logFilePath = NXMain.getSafeAppSubPath('logs/deep_engine_trace.log');
        #else
        logFilePath = 'logs/deep_engine_trace.log';
        #end
        var dir:String = haxe.io.Path.directory(logFilePath);
        if (!sys.FileSystem.exists(dir)) sys.FileSystem.createDirectory(dir);
      }

      writeEntry('INIT', '=======================================================');
      writeEntry('INIT', 'Friday Night Funkin NX Deep Engine Trace Initialized');
      writeEntry('INIT', 'Target: Nintendo Switch (Release) | Time: ' + Date.now().toString());
      writeEntry('INIT', '=======================================================');

      var oldTrace = haxe.Log.trace;
      haxe.Log.trace = function(v:Dynamic, ?infos:haxe.PosInfos) {
        oldTrace(v, infos);

        var strMsg:String = Std.string(v);
        var isImportant:Bool = false;
        if (strMsg.indexOf("ERROR") != -1 || strMsg.indexOf("Exception") != -1 || strMsg.indexOf("CRASH") != -1
            || strMsg.indexOf("[NXVideoPlayer]") != -1 || strMsg.indexOf("[AUTOTEST]") != -1 || strMsg.indexOf("[NXAudioRecovery]") != -1
            || strMsg.indexOf("[NXSleepWake]") != -1 || strMsg.indexOf("STAGE") != -1 || strMsg.indexOf("SONG") != -1
            || strMsg.indexOf("MEMORY") != -1 || strMsg.indexOf("LoadingState") != -1)
        {
          isImportant = true;
        }

        #if switch
        if (!isImportant && !funkin.Preferences.switchVerboseAudioLog) return;
        #end

        var origin:String = (infos != null) ? '${infos.className}:${infos.lineNumber}' : 'trace';
        writeEntry('TRACE', '[$origin] $v');
      };
    }
    catch (e:Dynamic) {}
    #end
  }

  /**
   * Hooks Flixel state switch signals once FlxG is available.
   */
  public static function initSignals():Void
  {
    #if !NX_DEV_TOOLS
    return;
    #end
    if (signalsHooked) return;
    signalsHooked = true;

    try
    {
      if (FlxG.signals != null)
      {
        FlxG.signals.preStateSwitch.add(function() {
          var nextStateName:String = "Unknown";
          @:privateAccess
          if (FlxG.game != null && FlxG.game._nextState != null)
          {
            nextStateName = Type.getClassName(Type.getClass(FlxG.game._nextState));
          }
          logStateTransition('PRE-SWITCH', nextStateName);
        });

        FlxG.signals.postStateSwitch.add(function() {
          var curStateName:String = (FlxG.state != null) ? Type.getClassName(Type.getClass(FlxG.state)) : "Unknown";
          logStateTransition('POST-SWITCH', curStateName);
        });
      }
    }
    catch (e:Dynamic)
    {
      writeEntry('ERROR', 'Failed to hook state signals: ' + e);
    }
  }

  /**
   * Logs state transitions.
   */
  public static function logStateTransition(phase:String, stateName:String):Void
  {
    #if !NX_DEV_TOOLS
    return;
    #end
    writeEntry('STATE', '[$phase] State -> $stateName');
  }

  /**
   * Logs song loading parameters.
   */
  public static function logSongInit(songId:String, difficulty:String, variation:String, ?extra:String):Void
  {
    #if !NX_DEV_TOOLS
    return;
    #end
    var extraStr:String = (extra != null) ? ' | Info: $extra' : '';
    writeEntry('SONG', 'Loading: "$songId" [Diff: $difficulty, Variation: $variation]$extraStr');
  }

  /**
   * Logs physical button events.
   */
  public static function logButtonEvent(button:String, ?details:String):Void
  {
    #if !NX_DEV_TOOLS
    return;
    #end
    var detStr:String = (details != null && details.length > 0) ? ' -> $details' : '';
    writeEntry('INPUT', 'Button [$button]$detStr');
  }

  /**
   * Logs OpenAL and audio hardware metrics.
   */
  public static function logAudioMetrics(context:String):Void
  {
    #if !NX_DEV_TOOLS
    return;
    #end
    var alState:String = (FlxG.sound.music != null) ? NXAudioDiagnostics.getOpenALSourceState(FlxG.sound.music) : "Null";
    var activeChannels:Int = NXAudioDiagnostics.getActiveSoundsCount();
    var musicTime:Float = (FlxG.sound.music != null) ? FlxG.sound.music.time : -1.0;
    var musicLen:Float = (FlxG.sound.music != null) ? FlxG.sound.music.length : -1.0;
    var memMb:Float = #if switch Math.round(NXPerformance.getPhysicalMemoryUsed() * 10.0) / 10.0 #else Math.round((openfl.system.System.totalMemory / (1024 * 1024)) * 10.0) / 10.0 #end;
    var drift:Float = Math.round(NXAudioDiagnostics.getSyncDriftMs() * 10.0) / 10.0;

    writeEntry('AUDIO', '[$context] Time: ${Math.round(musicTime)}/${Math.round(musicLen)}ms | OpenAL: $alState | Channels: $activeChannels | Drift: ${drift}ms | RAM: ${memMb}MB');
    if (context == 'END_SONG')
    {
      // Record who ended the song: natural onComplete, end-of-song watchdog, cutscene or script.
      var stack:String = haxe.CallStack.toString(haxe.CallStack.callStack());
      var lines:Array<String> = [for (l in stack.split('\n')) if (StringTools.trim(l).length > 0) StringTools.trim(l)];
      writeEntry('AUDIO', '[END_SONG] Caller: ' + lines.slice(0, 8).join(' <- '));
    }
  }

  /**
   * Logs a full memory snapshot: Haxe GC heap, native malloc heap, kernel-reported RAM,
   * FlxG.bitmap cache (count + decoded pixel MB), OpenFL asset cache, FlxAnimate atlas cache
   * and FunkinMemory tracked entries. Used at every state transition by NXAutoTest.
   * @param label Context label for the snapshot (e.g. `PRE-SWITCH lit-up`).
   * @param listSounds If true, also dumps every key in `openfl.Assets.cache.sound`.
   */
  public static function logMemorySnapshot(label:String, listSounds:Bool = false):Void
  {
    #if !NX_DEV_TOOLS
    return;
    #end
    try
    {
      var gcMb:Float = 0.0;
      var gcLargeMb:Float = 0.0;
      var gcReservedMb:Float = 0.0;
      #if cpp
      gcMb = cpp.vm.Gc.memInfo(0) / (1024.0 * 1024.0);
      gcReservedMb = cpp.vm.Gc.memInfo(1) / (1024.0 * 1024.0);
      gcLargeMb = cpp.vm.Gc.memInfo(3) / (1024.0 * 1024.0);
      #end
      var nativeMb:Float = #if switch NXPerformance.getNativeHeapUsed() #else 0.0 #end;
      var sysMb:Float = #if switch NXPerformance.getPhysicalMemoryUsed() #else 0.0 #end;

      var bitmapCount:Int = 0;
      var bitmapPixelMb:Float = 0.0;
      @:privateAccess
      if (FlxG.bitmap != null && FlxG.bitmap._cache != null)
      {
        for (graphic in FlxG.bitmap._cache)
        {
          if (graphic == null) continue;
          bitmapCount++;
          if (graphic.bitmap != null) bitmapPixelMb += (graphic.width * graphic.height * 4) / (1024.0 * 1024.0);
        }
      }

      var oflBitmaps:Int = 0;
      var oflSounds:Int = 0;
      var soundKeys:Array<String> = [];
      @:privateAccess
      if (openfl.utils.Assets.cache != null && Std.isOfType(openfl.utils.Assets.cache, openfl.utils.AssetCache))
      {
        var cache:openfl.utils.AssetCache = cast openfl.utils.Assets.cache;
        for (_ in cache.bitmapData.keys())
          oflBitmaps++;
        for (key in cache.sound.keys())
        {
          oflSounds++;
          soundKeys.push(key);
        }
      }

      var atlasCount:Int = 0;
      @:privateAccess
      if (animate.FlxAnimateFrames._cachedAtlases != null)
      {
        for (_ in animate.FlxAnimateFrames._cachedAtlases.keys())
          atlasCount++;
      }

      var fmCurTex:Int = 0;
      var fmPrevTex:Int = 0;
      var fmCurSnd:Int = 0;
      @:privateAccess
      {
        for (_ in funkin.FunkinMemory.currentCachedTextures.keys())
          fmCurTex++;
        for (_ in funkin.FunkinMemory.previousCachedTextures.keys())
          fmPrevTex++;
        for (_ in funkin.FunkinMemory.currentCachedSounds.keys())
          fmCurSnd++;
      }

      var r = function(v:Float):Float return Math.round(v * 10.0) / 10.0;
      writeEntry('MEMORY',
        '[$label] GC Heap: ${r(gcMb)} MB (Large: ${r(gcLargeMb)} MB, Reserved: ${r(gcReservedMb)} MB) | Native malloc: ${r(nativeMb)} MB | SYS RAM: ${r(sysMb)} MB'
        + ' | FlxG.bitmap: $bitmapCount (${r(bitmapPixelMb)} MB px) | Assets.cache: $oflBitmaps bmp / $oflSounds snd'
        + ' | FlxAnimate atlases: $atlasCount | FunkinMemory tex: $fmCurTex cur / $fmPrevTex prev, snd: $fmCurSnd'
        + ' | FlxG.sound.list: ${FlxG.sound != null ? FlxG.sound.list.length : -1}');

      if (listSounds && soundKeys.length > 0)
      {
        writeEntry('MEMORY', '[$label] Assets.cache.sound keys: ' + soundKeys.join(', '));
      }
    }
    catch (e:Dynamic)
    {
      writeEntry('ERROR', '[$label] Memory snapshot failed: $e');
    }
  }

  /**
   * Groups every graphic in FlxG.bitmap by its asset folder (count and decoded MB) to find what survives
   * a state change. Example group: "shared:images/resultScreen".
   */
  public static function logGraphicsByFolder(label:String):Void
  {
    #if !NX_DEV_TOOLS
    return;
    #end
    try
    {
      var groups:Map<String, {n:Int, mb:Float}> = new Map();
      @:privateAccess
      for (key => g in FlxG.bitmap._cache)
      {
        if (g == null) continue;
        var lib:String = (key.indexOf(":") != -1) ? key.substr(0, key.indexOf(":")) : "";
        var path:String = (key.indexOf("images/") != -1) ? key.substr(key.indexOf("images/")) : key;
        var parts:Array<String> = path.split("/");
        var folder:String = (parts.length > 2) ? parts[0] + "/" + parts[1] : (parts.length > 1 ? parts[0] : "(generated)");
        if (key.indexOf("assets/") == -1) folder = "(generated)";
        var id:String = (lib != "" ? lib + ":" : "") + folder;
        var e = groups.get(id);
        if (e == null) e = {n: 0, mb: 0.0};
        e.n++;
        e.mb += (g.width * g.height * 4) / 1048576.0;
        groups.set(id, e);
      }
      var list = [for (k => v in groups) {k: k, n: v.n, mb: v.mb}];
      list.sort((a, b) -> (b.mb > a.mb) ? 1 : ((b.mb < a.mb) ? -1 : 0));
      writeEntry('MEMORY', '[$label] Graphics by folder: ' + [for (e in list) '${e.k}=${e.n}/${Math.round(e.mb * 10) / 10}MB'].join(' | '));
      var generated:Array<String> = [];
      @:privateAccess
      for (key => g in FlxG.bitmap._cache)
        if (g != null && key.indexOf("assets/") == -1 && generated.length < 12) generated.push('$key(uses=${g.useCount},persist=${g.persist})');
      writeEntry('MEMORY', '[$label] Generated graphics sample: ' + generated.join(', '));
    }
    catch (e:Dynamic) {}
  }

  /**
   * Logs the largest graphics in FlxG.bitmap (decoded size, CPU copy present, use count, protection).
   */
  public static function logTopGraphics(label:String, count:Int = 20):Void
  {
    #if !NX_DEV_TOOLS
    return;
    #end
    try
    {
      var list:Array<{key:String, mb:Float, cpu:Bool, uses:Int, prot:Bool}> = [];
      @:privateAccess
      for (key => g in FlxG.bitmap._cache)
      {
        if (g == null || g.bitmap == null) continue;
        list.push(
          {
            key: key,
            mb: (g.width * g.height * 4) / (1024.0 * 1024.0),
            cpu: g.bitmap.image != null,
            uses: g.useCount,
            prot: funkin.FunkinMemory.isProtectedGraphic(key, g)
          });
      }
      list.sort((a, b) -> (b.mb > a.mb) ? 1 : ((b.mb < a.mb) ? -1 : 0));
      var lines:Array<String> = [];
      for (i in 0...Std.int(Math.min(count, list.length)))
      {
        var e = list[i];
        lines.push('${Math.round(e.mb * 10) / 10}MB${e.cpu ? "+cpu" : ""}${e.prot ? " [protected]" : ""} uses=${e.uses} ${e.key}');
      }
      writeEntry('MEMORY', '[$label] Top graphics: ' + lines.join(' || '));

      // OpenFL asset cache (FlxAnimate spritemaps are loaded here, outside FlxG.bitmap).
      var ofl:Array<String> = [];
      @:privateAccess
      if (Std.isOfType(openfl.utils.Assets.cache, openfl.utils.AssetCache))
      {
        var cache:openfl.utils.AssetCache = cast openfl.utils.Assets.cache;
        for (key => bmp in cache.bitmapData)
        {
          if (bmp == null) continue;
          ofl.push('${Math.round(bmp.width * bmp.height * 4 / 104857.6) / 10}MB${bmp.image != null ? "+cpu" : ""} ${key}');
        }
      }
      writeEntry('MEMORY', '[$label] OpenFL Assets.cache bitmaps: ' + ofl.join(' || '));

      // FlxAnimate atlas cache: every spritemap of every cached atlas.
      var atl:Array<String> = [];
      @:privateAccess
      for (key => frames in animate.FlxAnimateFrames._cachedAtlases)
      {
        if (frames == null || frames.parent == null) continue;
        var total:Float = 0.0;
        var n:Int = 0;
        var spritemaps:Array<flixel.graphics.FlxGraphic> = cast(frames.parent, animate.FlxAnimateFrames.FlxAnimateSpritemapCollection).spritemaps;
        for (sm in spritemaps)
        {
          if (sm == null || sm.isDestroyed) continue;
          total += sm.width * sm.height * 4 / 1048576.0;
          n++;
        }
        atl.push('${Math.round(total * 10) / 10}MB/${n}sm uses=${frames.parent.useCount} ${key}');
      }
      writeEntry('MEMORY', '[$label] FlxAnimate cached atlases: ' + atl.join(' || '));
    }
    catch (e:Dynamic) {}
  }

  /**
   * Logs warnings.
   */
  public static function logWarning(message:String):Void
  {
    #if !NX_DEV_TOOLS
    return;
    #end
    writeEntry('WARN', message);
  }

  /**
   * Logs critical errors and exceptions.
   */
  public static function logError(error:String, ?stack:String):Void
  {
    #if !NX_DEV_TOOLS
    return;
    #end
    var stackStr:String = (stack != null && stack.length > 0) ? '\nStack:\n$stack' : '';
    writeEntry('ERROR', error + stackStr);
  }

  /**
   * Core writer with immediate flush() to SD card.
   */
  public static function writeEntry(tag:String, message:String):Void
  {
    #if !NX_DEV_TOOLS
    return;
    #end
    #if sys
    try
    {
      if (logFilePath == null)
      {
        #if switch
        logFilePath = NXMain.getSafeAppSubPath('logs/deep_engine_trace.log');
        #else
        logFilePath = 'logs/deep_engine_trace.log';
        #end
        var dir:String = haxe.io.Path.directory(logFilePath);
        if (!sys.FileSystem.exists(dir)) sys.FileSystem.createDirectory(dir);
      }

      var line:String = '[${getTimestamp()}] [$tag] $message\n';
      var f = sys.io.File.append(logFilePath);
      f.writeString(line);
      f.flush();
      f.close();
    }
    catch (e:Dynamic) {}
    #end
  }
}
