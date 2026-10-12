package nx;

import flixel.FlxG;
import flixel.sound.FlxSound;
import funkin.Preferences;
import funkin.audio.FunkinSound;
#if lime
import lime.media.openal.AL;
#end

/**
 * Diagnostic and self-healing telemetry system for audio on Nintendo Switch.
 * Monitors OpenAL source state, audio-to-hardware sync drift, sound mixer channel count,
 * and recovers seamlessly from audio buffer exhaustion or stutters.
 */
class NXAudioDiagnostics
{
  static var logFilePath:Null<String> = null;
  static var lastTelemetryTime:Float = 0.0;
  static final TELEMETRY_INTERVAL:Float = 1.0; // 1 second interval for telemetry log

  public static var songStartHardwareTime:Float = -1.0;
  public static var songStartAudioTime:Float = 0.0;
  public static var frameDropsCount:Int = 0;
  public static var lastStallTime:Float = -1.0;
  public static var recoveryAttempts:Int = 0;

  public static var isPaused:Bool = false;
  public static var pauseStartHardwareTime:Float = -1.0;
  public static var totalPausedHardwareDuration:Float = 0.0;

  /**
   * Resets diagnostics when a new song starts.
   */
  public static function onSongStart(initialAudioTime:Float = 0.0):Void
  {
    songStartHardwareTime = Sys.time();
    songStartAudioTime = initialAudioTime;
    frameDropsCount = 0;
    recoveryAttempts = 0;
    isPaused = false;
    pauseStartHardwareTime = -1.0;
    totalPausedHardwareDuration = 0.0;
    lastTelemetryTime = Sys.time();
  }

  /**
   * Notifies diagnostics that the game has paused.
   */
  public static function onPause():Void
  {
    if (!isPaused)
    {
      isPaused = true;
      pauseStartHardwareTime = Sys.time();
    }
  }

  /**
   * Notifies diagnostics that the game has resumed.
   */
  public static function onResume():Void
  {
    if (isPaused)
    {
      if (pauseStartHardwareTime > 0)
      {
        totalPausedHardwareDuration += (Sys.time() - pauseStartHardwareTime);
      }
      isPaused = false;
      pauseStartHardwareTime = -1.0;
    }
  }

  /**
   * Queries the OpenAL source state of an FlxSound.
   */
  public static function getOpenALSourceState(sound:Null<FlxSound>):String
  {
    if (sound == null) return "Null";

    #if (cpp && !macro)
    try
    {
      @:privateAccess
      if (sound._channel != null)
      {
        var sc:Dynamic = sound._channel;
        var audioSrc:Dynamic = (sc.__audioSource != null) ? sc.__audioSource : sc.__source;
        if (audioSrc != null && audioSrc.__backend != null)
        {
          var handle:Dynamic = audioSrc.__backend.handle;
          if (handle != null)
          {
            var state:Int = AL.getSourcei(handle, AL.SOURCE_STATE);
            switch (state)
            {
              case 0x1011: return "Initial";
              case 0x1012: return "Playing";
              case 0x1013: return "Paused";
              case 0x1014: return "Stopped";
              default: return 'Unknown($state)';
            }
          }
        }
      }
    }
    catch (e:Dynamic) {}
    #end

    return sound.playing ? "Playing" : (@:privateAccess sound._paused ? "Paused" : "Stopped");
  }

  /**
   * Total number of sounds currently active in the Flixel mixer and OpenFL channels.
   */
  public static function getActiveSoundsCount():Int
  {
    var count:Int = FlxG.sound.list.length;
    if (FlxG.sound.music != null && FlxG.sound.music.playing) count++;
    return count;
  }

  /**
   * Measures clock drift between hardware monotonic time and OpenAL music playback time (in ms).
   * Compensates for any paused durations to accurately measure audio synchronization.
   */
  public static function getSyncDriftMs():Float
  {
    if (songStartHardwareTime < 0 || FlxG.sound.music == null || !FlxG.sound.music.playing) return 0.0;

    var currentPauseOffset:Float = totalPausedHardwareDuration;
    if (isPaused && pauseStartHardwareTime > 0)
    {
      currentPauseOffset += (Sys.time() - pauseStartHardwareTime);
    }

    var activeHardwareElapsedSec:Float = (Sys.time() - songStartHardwareTime) - currentPauseOffset;
    if (activeHardwareElapsedSec < 0) activeHardwareElapsedSec = 0;
    var expectedElapsedMs:Float = activeHardwareElapsedSec * 1000.0;
    var actualElapsedMs:Float = FlxG.sound.music.time - songStartAudioTime;
    return actualElapsedMs - expectedElapsedMs;
  }

  /**
   * Called per frame to track frame drops and record telemetry if enabled.
   */
  public static function update(elapsed:Float):Void
  {
    if (elapsed > 0.034)
    {
      frameDropsCount++;
    }

    var now:Float = Sys.time();
    if (now - lastTelemetryTime >= TELEMETRY_INTERVAL)
    {
      lastTelemetryTime = now;
      if (Preferences.switchVerboseAudioLog)
      {
        logTelemetry();
      }
    }
  }

  static function logTelemetry():Void
  {
    var musicState:String = getOpenALSourceState(FlxG.sound.music);
    var activeSounds:Int = getActiveSoundsCount();
    var drift:Float = Math.round(getSyncDriftMs() * 10.0) / 10.0;
    var musicTime:Float = (FlxG.sound.music != null) ? FlxG.sound.music.time : -1.0;
    var memMb:Float = #if switch Math.round(NXPerformance.getPhysicalMemoryUsed() * 10.0) / 10.0 #else Math.round((openfl.system.System.totalMemory / (1024 * 1024)) * 10.0) / 10.0 #end;

    var logLine:String = '[AUDIO-TELEM] Time: ${Math.round(musicTime)}ms | State: $musicState | Channels: $activeSounds | Drift: ${drift}ms | Drops: $frameDropsCount | RAM: ${memMb}MB';

    trace(logLine);

    #if switch
    writeToTelemetryFile(logLine);
    #end
  }

  static function writeToTelemetryFile(line:String):Void
  {
    try
    {
      if (logFilePath == null)
      {
        logFilePath = NXMain.getSafeAppSubPath('logs/audio_telemetry.log');
        var dir:String = haxe.io.Path.directory(logFilePath);
        if (!sys.FileSystem.exists(dir)) sys.FileSystem.createDirectory(dir);
      }
      var entry:String = Date.now().toString() + ' ' + line + '\n';
      var f = sys.io.File.append(logFilePath);
      f.writeString(entry);
      f.close();
    }
    catch (e:Dynamic) {}
  }

  /**
   * Watchdog: inspects whether instrumental music stopped anomalously and forces auto-recovery.
   */
  public static function checkWatchdog(targetSongPosition:Float, isGamePaused:Bool, isInCutscene:Bool, vocals:Null<funkin.audio.VoicesGroup> = null):Void
  {
    if (isGamePaused || isInCutscene || FlxG.sound.music == null) return;

    var musicLen:Float = (FlxG.sound.music != null) ? FlxG.sound.music.length : 0.0;
    if (musicLen > 0 && targetSongPosition >= (musicLen - 250)) return;

    var state:String = getOpenALSourceState(FlxG.sound.music);
    var enginePlaying:Bool = FlxG.sound.music.playing;
    var musicStalled:Bool = (!enginePlaying || state == "Stopped") && targetSongPosition > 500;

    if (musicStalled)
    {
      var now:Float = Sys.time();
      if (lastStallTime < 0 || (now - lastStallTime) > 1.0)
      {
        // Reset recovery attempts if playback was stable for more than 10 seconds
        if (lastStallTime > 0 && (now - lastStallTime) > 10.0)
        {
          recoveryAttempts = 0;
        }

        lastStallTime = now;
        recoveryAttempts++;

        #if switch
        nx.NXDeepTrace.writeEntry('AUDIO', '[AUDIO-WATCHDOG] OpenAL Stall Detected at ${Math.round(targetSongPosition)}ms (State: $state, EnginePlaying: $enginePlaying). Recovery attempt #$recoveryAttempts...');
        #end

        trace('[AUDIO-WATCHDOG] Anomaly detected: Music stalled at ${targetSongPosition}ms (State: $state). Auto-recovering (attempt #$recoveryAttempts)...');

        try
        {
          #if (cpp && !macro)
          // Drain any sticky OpenAL error codes so context can accept new commands
          while (AL.getError() != AL.NO_ERROR) {}
          #end

          // Prune dead channels to prevent SoundMixer channel exhaustion
          @:privateAccess
          if (openfl.media.SoundMixer.__soundChannels != null)
          {
            var channels = openfl.media.SoundMixer.__soundChannels;
            var i = channels.length - 1;
            while (i >= 0)
            {
              var ch = channels[i];
              if (ch == null || !ch.__isValid #if lime || ch.__audioSource == null #end || ch.__sound == null)
              {
                channels.splice(i, 1);
              }
              i--;
            }
          }

          // Hardware-level OpenAL recovery
          var hardwareRecovered:Bool = false;
          @:privateAccess
          if (FlxG.sound.music._channel != null)
          {
            var sc:Dynamic = FlxG.sound.music._channel;
            var audioSrc:Dynamic = (sc.__audioSource != null) ? sc.__audioSource : sc.__source;
            if (audioSrc != null && audioSrc.__backend != null)
            {
              var backend:Dynamic = audioSrc.__backend;
              if (backend.handle != null)
              {
                if (backend.stream)
                {
                  backend.refillBuffers();
                }
                AL.sourcePlay(backend.handle);
                var curAlState:Int = AL.getSourcei(backend.handle, AL.SOURCE_STATE);
                if (curAlState == 0x1012) hardwareRecovered = true;
              }
            }
          }

          if (!hardwareRecovered)
          {
            FlxG.sound.music.pause();
            FlxG.sound.music.time = targetSongPosition;
            FlxG.sound.music.play();
          }

          if (vocals != null)
          {
            vocals.pause();
            vocals.time = targetSongPosition;
            vocals.play();
          }

          #if switch
          var postState:String = getOpenALSourceState(FlxG.sound.music);
          nx.NXDeepTrace.writeEntry('AUDIO', '[AUDIO-WATCHDOG] Stall recovery complete. Resulting OpenAL state: $postState');
          #end
        }
        catch (e:Dynamic)
        {
          #if switch
          nx.NXDeepTrace.logError('[AUDIO-WATCHDOG] Recovery attempt failed: ' + e);
          #end
          trace('[AUDIO-WATCHDOG] Recovery attempt failed: $e');
        }
      }
    }
  }

  static function generateStallDump(songPosition:Float, alState:String):Void
  {
    var stack = haxe.CallStack.toString(haxe.CallStack.callStack());
    var memMb:Float = Math.round((openfl.system.System.totalMemory / (1024 * 1024)) * 10.0) / 10.0;
    var dump:String = '=== OPENAL STALL EMERGENCY DUMP ===\n'
      + 'Timestamp: ' + Date.now().toString() + '\n'
      + 'SongPosition: ' + songPosition + ' ms\n'
      + 'OpenAL State: ' + alState + '\n'
      + 'Active Sounds: ' + getActiveSoundsCount() + '\n'
      + 'Frame Drops: ' + frameDropsCount + '\n'
      + 'Memory: ' + memMb + ' MB\n'
      + 'Recovery Count: ' + recoveryAttempts + '\n'
      + 'Stack:\n' + stack + '\n'
      + '====================================\n';

    trace(dump);

    #if switch
    try
    {
      var dumpPath = NXMain.getSafeAppSubPath('logs/stall_dump_${Math.round(Sys.time())}.log');
      var dir = haxe.io.Path.directory(dumpPath);
      if (!sys.FileSystem.exists(dir)) sys.FileSystem.createDirectory(dir);
      sys.io.File.saveContent(dumpPath, dump);
    }
    catch (e:Dynamic) {}
    #end
  }
}
