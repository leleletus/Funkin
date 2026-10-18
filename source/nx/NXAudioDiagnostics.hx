package nx;

import flixel.FlxG;
import flixel.sound.FlxSound;
import funkin.Preferences;
import funkin.audio.FunkinSound;
#if lime
import lime.media.openal.AL;
import lime.media.openal.ALC;
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

  // ---------------------------------------------------------------------------
  // Horizon suspension (HOME / Sleep) and OpenAL device recovery
  // ---------------------------------------------------------------------------

  static var lastFrameWallTime:Float = -1.0;
  static var stallRebuildCount:Int = 0;
  static var lastStallRebuildTime:Float = -1.0;

  /**
   * Called every frame (NXPerformance.update). On real hardware HOME/Sleep freezes the process at once
   * and the focus-lost event only arrives after the player comes back (seen 35 s late in hardware
   * logs), so the game never paused and the audio device was left broken (endless stall loop with no
   * sound). A wall-clock gap between two frames is the reliable signal that the process was suspended.
   */
  // ---------------------------------------------------------------------------
  // Mixer liveness (OpenAL device clock)
  // ---------------------------------------------------------------------------

  // ---------------------------------------------------------------------------
  // Black box: last audio events, dumped to the log the moment the mixer stops
  // ---------------------------------------------------------------------------

  static final BLACKBOX_SIZE:Int = 96;
  static var blackBox:Array<String> = [];
  static var blackBoxStart:Float = -1.0;

  /**
   * Records an event in an in-memory ring buffer (no disk I/O). Called for every FunkinSound start,
   * pause, resume, seek, completion and destroy, plus gamepad input and state changes.
   */
  public static function record(event:String, ?sound:FlxSound, value:Float = 0.0):Void
  {
    var now:Float = Sys.time();
    if (blackBoxStart < 0) blackBoxStart = now;
    var label:String = '';
    if (sound != null)
    {
      var lbl:Null<String> = Std.isOfType(sound, FunkinSound) ? @:privateAccess (cast sound : FunkinSound)._label : null;
      label = (sound == FlxG.sound.music ? 'MUSIC ' : '') + (lbl != null && lbl != 'unknown' ? lbl.substr(lbl.lastIndexOf('/') + 1) : 'snd') + ' t=${Math.round(value)} len=${Math.round(sound.length)}';
    }
    else if (value != 0.0) label = Std.string(Math.round(value));
    blackBox.push('${nx.NXDeepTrace.getTimestamp()} $event $label');
    if (blackBox.length > BLACKBOX_SIZE) blackBox.shift();
  }

  public static function dumpBlackBox(reason:String):Void
  {
    nx.NXDeepTrace.writeEntry('AUDIO', '[BLACKBOX] $reason. Last ${blackBox.length} audio events:\n    ' + blackBox.join('\n    '));
  }

  static var mixerLastWall:Float = -1.0;
  static var mixerLastClock:Float = -1.0;
  static var mixerStalled:Bool = false;
  static var mixerStallStart:Float = 0.0;
  static var mixerLastSummary:Float = 0.0;
  static var mixerMinRatio:Float = 99.0;

  /**
   * Every 0.5 s compares the OpenAL device clock with wall time. The device clock only advances while
   * the mixer (SDL audio thread) renders audio, so a ratio near 0 means the whole audio stack stopped,
   * not just one sound. Logs the exact moment it stops/recovers and a summary every 10 s.
   */
  public static function monitorMixer():Void
  {
    var wall:Float = Sys.time();
    if (mixerLastWall >= 0 && wall - mixerLastWall < 0.1) return;
    var clock:Float = NXAudioNative.deviceClockMs();
    if (clock < 0)
    {
      mixerLastWall = wall;
      return;
    }
    if (mixerLastWall >= 0 && mixerLastClock >= 0)
    {
      var dWall:Float = (wall - mixerLastWall) * 1000.0;
      var dClock:Float = clock - mixerLastClock;
      var ratio:Float = (dWall > 0) ? dClock / dWall : 1.0;
      if (ratio < mixerMinRatio) mixerMinRatio = ratio;
      if (!mixerStalled && ratio < 0.3)
      {
        mixerStalled = true;
        mixerStallStart = wall;
        nx.NXDeepTrace.writeEntry('AUDIO', '[MIXER] STOPPED: device clock +${Math.round(dClock)}ms in ${Math.round(dWall)}ms (sdl ${NXAudioNative.sdlAudioStatus()}). ${describeAudioState()}');
        dumpBlackBox('Mixer stopped at device clock ${Math.round(clock)}ms');
      }
      else if (mixerStalled && ratio > 0.7)
      {
        mixerStalled = false;
        nx.NXDeepTrace.writeEntry('AUDIO', '[MIXER] RUNNING again after ${Math.round((wall - mixerStallStart) * 10) / 10}s (sdl ${NXAudioNative.sdlAudioStatus()})');
      }
      if (wall - mixerLastSummary >= 10.0)
      {
        mixerLastSummary = wall;
        nx.NXDeepTrace.writeEntry('AUDIO', '[MIXER] ${mixerStalled ? "STOPPED" : "ok"} clock ${Math.round(clock)}ms, min ratio last 10s ${Math.round(mixerMinRatio * 100) / 100}, sdl ${NXAudioNative.sdlAudioStatus()}');
        mixerMinRatio = 99.0;
      }
    }
    mixerLastWall = wall;
    mixerLastClock = clock;
  }

  public static function isMixerStalled():Bool
    return mixerStalled;

  static var lastFrameState:Null<flixel.FlxState> = null;
  static var stateSwitchSeen:Bool = false;
  static var stateSignalsHooked:Bool = false;

  public static function checkSystemSuspension():Void
  {
    monitorMixer();
    if (!stateSignalsHooked && FlxG.signals != null)
    {
      stateSignalsHooked = true;
      FlxG.signals.preStateSwitch.add(() -> {
        stateSwitchSeen = true;
        record('state-switch');
      });
    }

    var now:Float = Sys.time();
    var gap:Float = (lastFrameWallTime < 0) ? 0.0 : now - lastFrameWallTime;
    lastFrameWallTime = now;

    // Loading a state blocks a single frame for seconds: that is not a suspension.
    var switched:Bool = stateSwitchSeen || FlxG.state != lastFrameState;
    stateSwitchSeen = false;
    lastFrameState = FlxG.state;
    if (gap < 3.0 || switched) return; // Real HOME/Sleep suspensions last seconds; loading hitches stay below this.

    nx.NXDeepTrace.writeEntry('AUDIO', '[NXSuspend] Process was suspended for ${Math.round(gap * 10) / 10}s (HOME/Sleep). ${describeAudioState()}');
    cycleAudioDevice('resume after ${Math.round(gap * 10) / 10}s suspension');

    // Behave like a console game: come back paused while a song is playing, the player resumes when ready.
    // During cutscenes and the countdown PlayState handles focus itself (and needs a matching onFocus).
    var ps = funkin.play.PlayState.instance;
    if (ps != null && ps.subState == null && !@:privateAccess ps._requestSubStateReset && !ps.isInCutscene
      && !@:privateAccess ps.startingSong && FlxG.sound.music != null && FlxG.sound.music.playing)
    {
      @:privateAccess ps.pause(funkin.play.PauseSubState.PauseMode.Standard, true);
    }
  }

  /**
   * Pauses and resumes the OpenAL device (alcDevicePauseSOFT / alcDeviceResumeSOFT) and reprocesses the
   * context. lime-nx disables AudioManager.suspend/resume on Switch, so nothing did this after a resume.
   */
  public static function cycleAudioDevice(reason:String):Void
  {
    #if (lime && cpp)
    try
    {
      var context = ALC.getCurrentContext();
      if (context == null)
      {
        nx.NXDeepTrace.writeEntry('AUDIO', '[NXSuspend] cycleAudioDevice($reason): no current ALC context');
        return;
      }
      var device = ALC.getContextsDevice(context);
      if (device == null)
      {
        nx.NXDeepTrace.writeEntry('AUDIO', '[NXSuspend] cycleAudioDevice($reason): no ALC device');
        return;
      }
      ALC.pauseDevice(device);
      ALC.resumeDevice(device);
      ALC.processContext(context);
      while (AL.getError() != AL.NO_ERROR) {}
      nx.NXDeepTrace.writeEntry('AUDIO', '[NXSuspend] OpenAL device cycled ($reason). ${describeAudioState()}');
    }
    catch (e:Dynamic)
    {
      nx.NXDeepTrace.logError('[NXSuspend] cycleAudioDevice($reason) failed: $e');
    }
    #end
  }

  /**
   * Called by PlayState each time its stall recovery rebuilds the instrumental. Logs the full audio
   * state (for hardware diagnosis) and escalates to an OpenAL device cycle when rebuilds keep failing.
   */
  public static function onStallRebuild(songPosition:Float):Void
  {
    var now:Float = Sys.time();
    if (lastStallRebuildTime < 0 || now - lastStallRebuildTime > 5.0) stallRebuildCount = 0;
    lastStallRebuildTime = now;
    stallRebuildCount++;
    nx.NXDeepTrace.writeEntry('AUDIO', '[NXAudioRecovery] Rebuild #$stallRebuildCount at ${Math.round(songPosition)}ms. ${describeAudioState()}');
    if (stallRebuildCount >= 2)
    {
      cycleAudioDevice('stall rebuild #$stallRebuildCount did not restore the clock');
    }
  }

  /**
   * One-line snapshot of the audio stack: music source state/offset, AL error, ALC connection,
   * live FlxG.sound.list entries and OpenFL SoundMixer channels.
   */
  public static function describeAudioState():String
  {
    var parts:Array<String> = [];
    try
    {
      var music = FlxG.sound.music;
      if (music == null) parts.push('music=null');
      else
      {
        var handle:Dynamic = null;
        @:privateAccess
        {
          var sc:Dynamic = music._channel;
          if (sc != null)
          {
            var src:Dynamic = (sc.__audioSource != null) ? sc.__audioSource : sc.__source;
            if (src != null && src.__backend != null) handle = src.__backend.handle;
          }
        }
        parts.push('music=${music.playing ? "playing" : "stopped"} time=${Math.round(music.time)}/${Math.round(music.length)} source=${handle == null ? "NONE" : getOpenALSourceState(music)}');
      }
      #if (lime && cpp)
      parts.push('alError=${AL.getError()}');
      var context = ALC.getCurrentContext();
      var device = (context != null) ? ALC.getContextsDevice(context) : null;
      if (device != null)
      {
        var connected = ALC.getIntegerv(device, 0x313, 1); // ALC_CONNECTED
        parts.push('alcConnected=${connected != null && connected.length > 0 ? Std.string(connected[0]) : "?"} alcError=${ALC.getError(device)}');
        parts.push('deviceClock=${Math.round(NXAudioNative.deviceClockMs())}ms mixer=${mixerStalled ? "STOPPED" : "running"} sdl=${NXAudioNative.sdlAudioStatus()}');
      }
      else
        parts.push('alcDevice=null');
      @:privateAccess parts.push('mixerChannels=${openfl.media.SoundMixer.__soundChannels != null ? openfl.media.SoundMixer.__soundChannels.length : -1}');
      #end
      var names:Array<String> = [];
      FlxG.sound.list.forEach(function(snd:FlxSound) {
        if (snd != null && names.length < 16) names.push('${snd.playing ? "P" : "-"}${Math.round(snd.length / 1000)}s');
      });
      parts.push('soundList=${FlxG.sound.list.length}[${names.join(",")}]');
    }
    catch (e:Dynamic)
    {
      parts.push('describe failed: $e');
    }
    return parts.join(' | ');
  }

  /**
   * Margin before the real end of the instrumental under which an onComplete is considered premature.
   */
  static final PREMATURE_COMPLETION_MARGIN_MS:Float = 1500.0;

  static var pendingRebuildMusicTime:Float = -1.0;

  /**
   * Last Conductor position observed while the instrumental's OpenAL source was really PLAYING.
   * At the natural end of a song OpenAL reports the source as STOPPED with a 0 ms offset for one frame
   * before lime dispatches onComplete, so the live Conductor value cannot be trusted at that moment.
   */
  static var lastPlayingSongPosition:Float = -1.0;
  static var trackedPlayState:Null<funkin.play.PlayState> = null;

  /**
   * Called every frame from PlayState.update (through checkWatchdog) to remember the last valid position.
   */
  static function trackPlayingPosition(songPosition:Float):Void
  {
    var ps = funkin.play.PlayState.instance;
    if (ps != trackedPlayState)
    {
      trackedPlayState = ps;
      lastPlayingSongPosition = -1.0;
    }
    var music = FlxG.sound.music;
    if (music != null && music.playing && songPosition > 0 && getOpenALSourceState(music) == "Playing")
    {
      lastPlayingSongPosition = songPosition;
    }
  }

  /**
   * lime-nx's NativeAudioSource.checkPlay() reports ANY OpenAL state other than PLAYING as "finished":
   * if Horizon stops or pauses the source (Sleep, audio renderer reset, buffer underrun) the instrumental
   * dispatches onComplete and PlayState ends the song in the middle (seen at 7-9 s of a 120 s song).
   * Called from the music onComplete handler: returns true when the completion is premature, in which
   * case the song must NOT end and the instrumental and vocals are rebuilt at the current position.
   */
  public static function interceptPrematureSongCompletion():Bool
  {
    var music = FlxG.sound.music;
    if (music == null || music.length <= 0) return false;

    var ps = funkin.play.PlayState.instance;
    var songPosition:Float = (lastPlayingSongPosition >= 0) ? lastPlayingSongPosition : funkin.Conductor.instance.songPosition;
    var musicTime:Float = songPosition - funkin.Conductor.instance.combinedOffset;

    // Genuine end: the instrumental was within the last 1.5 s, or every note of the chart was already played.
    if (musicTime >= music.length - PREMATURE_COMPLETION_MARGIN_MS) return false;
    var lastNote:Float = (ps != null) ? @:privateAccess ps.lastChartNoteTime : 0.0;
    if (lastNote > 0 && songPosition >= lastNote) return false;

    nx.NXDeepTrace.writeEntry('AUDIO', '[NXAudioRecovery] Premature onComplete at ${Math.round(musicTime)}/${Math.round(music.length)}ms'
      + ' (OpenAL source left PLAYING outside the engine). Rebuilding instead of ending the song.');

    // FlxSound.stopped() runs cleanup() (channel = null, time = 0) right after this callback returns,
    // so the rebuild happens at the start of the next frame.
    if (pendingRebuildMusicTime < 0) FlxG.signals.preUpdate.addOnce(rebuildAfterPrematureCompletion);
    pendingRebuildMusicTime = musicTime;
    return true;
  }

  static function rebuildAfterPrematureCompletion():Void
  {
    var musicTime:Float = pendingRebuildMusicTime;
    pendingRebuildMusicTime = -1.0;

    var ps = funkin.play.PlayState.instance;
    var music = FlxG.sound.music;
    if (ps == null || music == null || musicTime < 0) return;

    try
    {
      // Keep the pause menu (HOME / Sleep) paused: PlayState resumes the music itself on Resume.
      var paused:Bool = (ps.subState != null || @:privateAccess ps._requestSubStateReset);

      music.play(true, musicTime);
      if (paused) music.pause();

      if (ps.vocals != null)
      {
        @:privateAccess
        {
          var playerOffset:Float = ps.vocals.playerVoicesOffset;
          var opponentOffset:Float = ps.vocals.opponentVoicesOffset;
          ps.vocals.playerVoices?.forEachAlive(function(v:FunkinSound) {
            v.play(true, Math.max(0, musicTime - playerOffset));
            if (paused) v.pause();
          });
          ps.vocals.opponentVoices?.forEachAlive(function(v:FunkinSound) {
            v.play(true, Math.max(0, musicTime - opponentOffset));
            if (paused) v.pause();
          });
        }
      }

      recoveryAttempts++;
      nx.NXDeepTrace.writeEntry('AUDIO', '[NXAudioRecovery] Instrumental and vocals rebuilt at ${Math.round(musicTime)}ms'
        + ' (paused: $paused, OpenAL: ${getOpenALSourceState(music)})');
    }
    catch (e:Dynamic)
    {
      nx.NXDeepTrace.logError('[NXAudioRecovery] Rebuild after premature onComplete failed: $e');
    }
  }

  /**
   * Watchdog: inspects whether instrumental music stopped anomalously and forces auto-recovery.
   */
  public static function checkWatchdog(targetSongPosition:Float, isGamePaused:Bool, isInCutscene:Bool, vocals:Null<funkin.audio.VoicesGroup> = null):Void
  {
    trackPlayingPosition(targetSongPosition);
    if (isGamePaused || isInCutscene || FlxG.sound.music == null) return;

    // A pause requested outside of PlayState.update (HOME / Sleep focus loss) is only applied by
    // FlxState.tryUpdate() after the next update() call. In that frame subState is still null but the
    // music was paused on purpose: "recovering" it here would keep the song playing under the pause menu.
    var ps = funkin.play.PlayState.instance;
    if (ps != null && (@:privateAccess ps._requestSubStateReset || @:privateAccess ps.musicPausedBySubState)) return;

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
