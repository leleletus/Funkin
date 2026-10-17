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
    writeEntry('STATE', '[$phase] State -> $stateName');
  }

  /**
   * Logs song loading parameters.
   */
  public static function logSongInit(songId:String, difficulty:String, variation:String, ?extra:String):Void
  {
    var extraStr:String = (extra != null) ? ' | Info: $extra' : '';
    writeEntry('SONG', 'Loading: "$songId" [Diff: $difficulty, Variation: $variation]$extraStr');
  }

  /**
   * Logs physical button events.
   */
  public static function logButtonEvent(button:String, ?details:String):Void
  {
    var detStr:String = (details != null && details.length > 0) ? ' -> $details' : '';
    writeEntry('INPUT', 'Button [$button]$detStr');
  }

  /**
   * Logs OpenAL and audio hardware metrics.
   */
  public static function logAudioMetrics(context:String):Void
  {
    var alState:String = (FlxG.sound.music != null) ? NXAudioDiagnostics.getOpenALSourceState(FlxG.sound.music) : "Null";
    var activeChannels:Int = NXAudioDiagnostics.getActiveSoundsCount();
    var musicTime:Float = (FlxG.sound.music != null) ? FlxG.sound.music.time : -1.0;
    var musicLen:Float = (FlxG.sound.music != null) ? FlxG.sound.music.length : -1.0;
    var memMb:Float = #if switch Math.round(NXPerformance.getPhysicalMemoryUsed() * 10.0) / 10.0 #else Math.round((openfl.system.System.totalMemory / (1024 * 1024)) * 10.0) / 10.0 #end;
    var drift:Float = Math.round(NXAudioDiagnostics.getSyncDriftMs() * 10.0) / 10.0;

    writeEntry('AUDIO', '[$context] Time: ${Math.round(musicTime)}/${Math.round(musicLen)}ms | OpenAL: $alState | Channels: $activeChannels | Drift: ${drift}ms | RAM: ${memMb}MB');
  }

  /**
   * Logs warnings.
   */
  public static function logWarning(message:String):Void
  {
    writeEntry('WARN', message);
  }

  /**
   * Logs critical errors and exceptions.
   */
  public static function logError(error:String, ?stack:String):Void
  {
    var stackStr:String = (stack != null && stack.length > 0) ? '\nStack:\n$stack' : '';
    writeEntry('ERROR', error + stackStr);
  }

  /**
   * Core writer with immediate flush() to SD card.
   */
  public static function writeEntry(tag:String, message:String):Void
  {
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
