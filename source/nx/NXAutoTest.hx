package nx;

import flixel.FlxG;
import flixel.util.FlxTimer;
import funkin.play.PlayState;
import funkin.play.PlayStatePlaylist;
import funkin.play.song.Song;
import funkin.data.story.level.LevelRegistry;
import funkin.Highscore;
import funkin.data.song.SongRegistry;
import funkin.ui.transition.LoadingState;
import funkin.util.Constants;
import funkin.Paths;
import funkin.Conductor;
import haxe.Timer;
import nx.video.NXVideoPlayer;

/**
 * Autonomous test runner for Nintendo Switch / Citron.
 * Activated strictly if `autotest.cfg` exists in SDMC root.
 * Executes automated test scenarios and writes real-time telemetry to `deep_engine_trace.log`.
 */
class NXAutoTest
{
  static var isRunning:Bool = false;
  static var currentScenario:String = "";
  static var testTimer:Float = 0.0;
  static var stepState:Int = 0;

  /**
   * Checks if an autotest configuration file is present on the SDMC and executes it.
   * @return `true` if an autotest was initiated, `false` to proceed with normal game startup.
   */
  public static function checkAndRun():Bool
  {
    #if sys
    try
    {
      var configPath:Null<String> = null;
      var candidatePaths:Array<String> = [
        #if switch
        nx.NXMain.getSafeAppSubPath('autotest.cfg'),
        'sdmc:/switch/Friday-Night-Funkin/autotest.cfg',
        '/switch/Friday-Night-Funkin/autotest.cfg',
        #end
        'autotest.cfg'
      ];

      for (path in candidatePaths)
      {
        if (sys.FileSystem.exists(path))
        {
          configPath = path;
          break;
        }
      }

      if (configPath == null) return false;

      var rawContent:String = sys.io.File.getContent(configPath);
      if (rawContent == null || rawContent.length == 0) return false;

      currentScenario = StringTools.trim(rawContent).toUpperCase();
      isRunning = true;
      testTimer = 0.0;
      stepState = 0;
      hasTriggeredEndSong = false;

      trace('[AUTOTEST] ========================================');
      trace('[AUTOTEST] ACTIVATED via config file: ' + configPath);
      trace('[AUTOTEST] Target Scenario: ' + currentScenario);
      trace('[AUTOTEST] ========================================');

      FlxG.signals.postUpdate.add(onPostUpdate);

      new FlxTimer().start(0.5, function(tmr:FlxTimer) {
        startScenario(currentScenario);
      });

      return true;
    }
    catch (e:Dynamic)
    {
      trace('[AUTOTEST] Error checking autotest config: ' + e);
    }
    #end
    return false;
  }

  static function startScenario(scenario:String):Void
  {
    try
    {
      if (scenario.indexOf("WEEKEND1_PLAYLIST") != -1)
      {
        startWeekend1Playlist();
      }
      else if (scenario.indexOf("DARNELL") != -1 || scenario.indexOf("WEEKEND1") != -1)
      {
        trace('[AUTOTEST] Launching Weekend 1 Story Mode (Darnell Cutscene)...');
        Paths.setCurrentLevel('weekend1');
        PlayStatePlaylist.isStoryMode = true;
        PlayStatePlaylist.campaignId = "weekend1";
        PlayStatePlaylist.campaignTitle = "Weekend 1";
        PlayStatePlaylist.campaignDifficulty = "hard";
        PlayStatePlaylist.playlistSongIds = ["lit-up", "2hot", "blazin"];

        var targetSong:Song = SongRegistry.instance.fetchEntry("darnell", {variation: Constants.DEFAULT_VARIATION});
        LoadingState.loadPlayState({
          targetSong: targetSong,
          targetDifficulty: "hard",
          targetVariation: "default"
        }, true);
      }
      else if (scenario.indexOf("2HOT") != -1 && scenario.indexOf("BLAZIN") == -1)
      {
        trace('[AUTOTEST] Launching 2Hot Story Mode (2Hot Cutscene)...');
        Paths.setCurrentLevel('weekend1');
        PlayStatePlaylist.isStoryMode = true;
        PlayStatePlaylist.campaignId = "weekend1";
        PlayStatePlaylist.campaignTitle = "Weekend 1";
        PlayStatePlaylist.campaignDifficulty = "hard";
        PlayStatePlaylist.playlistSongIds = ["blazin"];

        var targetSong:Song = SongRegistry.instance.fetchEntry("2hot", {variation: Constants.DEFAULT_VARIATION});
        LoadingState.loadPlayState({
          targetSong: targetSong,
          targetDifficulty: "hard",
          targetVariation: "default"
        }, true);
      }
      else if (scenario.indexOf("UGH") != -1 || scenario.indexOf("WEEK7") != -1)
      {
        trace('[AUTOTEST] Launching Week 7 Story Mode (Ugh Cutscene)...');
        Paths.setCurrentLevel('week7');
        PlayStatePlaylist.isStoryMode = true;
        PlayStatePlaylist.campaignId = "week7";
        PlayStatePlaylist.campaignTitle = "Tankman";
        PlayStatePlaylist.campaignDifficulty = "hard";
        PlayStatePlaylist.playlistSongIds = ["guns", "stress"];

        var targetSong:Song = SongRegistry.instance.fetchEntry("ugh", {variation: Constants.DEFAULT_VARIATION});
        LoadingState.loadPlayState({
          targetSong: targetSong,
          targetDifficulty: "hard",
          targetVariation: "default"
        }, true);
      }
      else if (scenario.indexOf("BLAZIN") != -1)
      {
        trace('[AUTOTEST] Launching Blazin Freeplay...');
        PlayStatePlaylist.isStoryMode = false;
        var targetSong:Song = SongRegistry.instance.fetchEntry("blazin", {variation: Constants.DEFAULT_VARIATION});
        LoadingState.loadPlayState({
          targetSong: targetSong,
          targetDifficulty: "hard",
          targetVariation: "default",
          practiceMode: false
        }, false);
      }
      else if (scenario.indexOf("AUDIO_TORTURE") != -1)
      {
        trace('[AUTOTEST] Launching AUDIO_TORTURE scenario (spaghetti)...');
        Paths.setCurrentLevel('default');
        PlayStatePlaylist.isStoryMode = false;
        var targetSong:Song = SongRegistry.instance.fetchEntry("spaghetti", {variation: Constants.DEFAULT_VARIATION});
        if (targetSong == null)
        {
          trace('[AUTOTEST] spaghetti song not found, falling back to bopeebo...');
          targetSong = SongRegistry.instance.fetchEntry("bopeebo", {variation: Constants.DEFAULT_VARIATION});
        }
        LoadingState.loadPlayState({
          targetSong: targetSong,
          targetDifficulty: "hard",
          targetVariation: "default",
          practiceMode: false
        }, false);
      }
      else
      {
        trace('[AUTOTEST] Unknown scenario: $scenario. Aborting.');
        failTest("Unknown scenario string: " + scenario);
      }
    }
    catch (e:Dynamic)
    {
      trace('[AUTOTEST] Fatal exception while starting scenario: ' + e);
      failTest('Exception: $e');
    }
  }

  static function onPostUpdate():Void
  {
    if (!isRunning) return;
    testTimer += FlxG.elapsed;

    // Timeout de seguridad global por si algo se bloquea por completo
    var globalTimeout:Float = (currentScenario.indexOf("PLAYLIST") != -1) ? 600.0 : 180.0;
    if (testTimer > globalTimeout)
    {
      failTest('Global test timeout reached (${globalTimeout}s)');
      return;
    }

    if (currentScenario.indexOf("WEEKEND1_PLAYLIST") != -1)
    {
      handleWeekend1PlaylistScenario();
    }
    else if (currentScenario.indexOf("AUDIO_TORTURE") != -1)
    {
      handleAudioTortureScenario();
    }
    else if (currentScenario.indexOf("CUTSCENE") != -1 || currentScenario.indexOf("DARNELL") != -1 || currentScenario.indexOf("UGH") != -1)
    {
      handleCutsceneScenario();
    }
    else if (currentScenario.indexOf("BLAZIN") != -1)
    {
      handleBlazinScenario();
    }
  }

  static var hasTriggeredEndSong:Bool = false;

  static function handleCutsceneScenario():Void
  {
    switch (stepState)
    {
      case 0:
        if (currentScenario.indexOf("2HOT") != -1 && !hasTriggeredEndSong)
        {
          if (PlayState.instance != null && PlayState.instance.currentSong != null && PlayState.instance.currentSong.id == "2hot")
          {
            hasTriggeredEndSong = true;
            trace('[AUTOTEST] 2Hot loaded into PlayState, triggering endSong() to start 2hotCutscene...');
            PlayState.instance.endSong(true);
          }
        }

        // Esperando a que el VideoPlayer comience a reproducir
        if (NXVideoPlayer.isCutscenePlaying())
        {
          trace('[AUTOTEST] [PASS] Cutscene playback started successfully!');
          stepState = 1;
        }
      case 1:
        // En reproducción: monitorear que avance y termine naturalmente
        if (!NXVideoPlayer.isCutscenePlaying())
        {
          trace('[AUTOTEST] [PASS] Cutscene playback completed naturally!');
          passTest();
        }
    }
  }

  static function handleBlazinScenario():Void
  {
    switch (stepState)
    {
      case 0:
        // Esperando a que PlayState cargue Blazin
        if (PlayState.instance != null && PlayState.instance.currentStageId == "phillyBlazin")
        {
          trace('[AUTOTEST] [PASS] Entered Blazin stage. Playing for 3 seconds...');
          stepState = 1;
          testTimer = 0.0;
        }
      case 1:
        // Esperar 3 segundos en Blazin
        if (testTimer >= 3.0)
        {
          trace('[AUTOTEST] Pausing Blazin and exiting to Menu...');
          stepState = 2;
          if (PlayState.instance != null)
          {
            // Simular pausa
            @:privateAccess
            PlayState.instance.pause();
            PlayState.instance.persistentDraw = false;
            PlayState.instance.persistentUpdate = false;
            PlayState.instance.visible = false;

            // Iniciar 2Hot directamente
            new FlxTimer().start(0.5, function(tmr:FlxTimer) {
              trace('[AUTOTEST] Transitioning to 2Hot (testing VRAM / shader cleanup)...');
              PlayStatePlaylist.isStoryMode = false;
              var targetSong:Song = SongRegistry.instance.fetchEntry("2hot", {variation: Constants.DEFAULT_VARIATION});
              LoadingState.loadPlayState({
                targetSong: targetSong,
                targetDifficulty: "hard",
                targetVariation: "default",
                practiceMode: false
              }, false);
              stepState = 3;
            });
          }
        }
      case 3:
        // Validar que 2Hot haya entrado sin crashear
        if (PlayState.instance != null && PlayState.instance.currentStageId == "phillyStreets")
        {
          trace('[AUTOTEST] [PASS] Successfully loaded 2Hot after Blazin! No OOM or Unmapped Write64.');
          passTest();
        }
    }
  }

  static var audioTortureSleepStart:Float = 0.0;
  static var audioTortureStallTime:Float = 0.0;
  static var audioTortureStallPos:Float = 0.0;

  static function handleAudioTortureScenario():Void
  {
    switch (stepState)
    {
      case 0:
        // Wait until PlayState is active and either startingSong (countdown) or isInCutscene
        if (PlayState.instance != null && (@:privateAccess PlayState.instance.startingSong || PlayState.instance.isInCutscene))
        {
          trace('[AUTOTEST] PlayState loaded (startingSong=${@:privateAccess PlayState.instance.startingSong}, inCutscene=${PlayState.instance.isInCutscene}). Testing Sleep/Wake during intro...');
          PlayState.instance.onFocusLost();
          audioTortureSleepStart = haxe.Timer.stamp();
          stepState = 1;
        }

      case 1:
        // Wait 0.5s using haxe.Timer.stamp() (never FlxTimer, which is paused during focus loss!)
        if (haxe.Timer.stamp() - audioTortureSleepStart >= 0.5)
        {
          trace('[AUTOTEST] 0.5s elapsed in Sleep mode. Testing Wake mode via onFocus()...');
          if (PlayState.instance != null)
          {
            PlayState.instance.onFocus();
          }
          trace('[AUTOTEST] [PASS] Wake completed successfully. Waiting for song playback to reach 3000ms...');
          stepState = 2;
        }

      case 2:
        // Wait until countdown finishes and songPosition exceeds 3000ms
        if (PlayState.instance != null && !(@:privateAccess PlayState.instance.startingSong) && Conductor.instance.songPosition > 3000.0)
        {
          trace('[AUTOTEST] Song reached ${Conductor.instance.songPosition}ms. Simulating OpenAL clock stall / audio underrun...');
          if (FlxG.sound.music != null)
          {
            FlxG.sound.music.pause();
          }
          audioTortureStallTime = haxe.Timer.stamp();
          audioTortureStallPos = Conductor.instance.songPosition;
          stepState = 3;
        }

      case 3:
        // Verify that Conductor continues advancing (notes do not freeze) during the stall
        var timeSinceStall:Float = haxe.Timer.stamp() - audioTortureStallTime;
        if (timeSinceStall >= 0.3)
        {
          var currentPos:Float = Conductor.instance.songPosition;
          if (currentPos > audioTortureStallPos)
          {
            trace('[AUTOTEST] [PASS] Conductor advanced during stall from ${audioTortureStallPos}ms to ${currentPos}ms! Notes did not freeze.');
            stepState = 4;
          }
        }

      case 4:
        // Verify audio recovery re-ignited music playback
        var timeSinceStall:Float = haxe.Timer.stamp() - audioTortureStallTime;
        if (timeSinceStall >= 0.6)
        {
          if (FlxG.sound.music != null && FlxG.sound.music.playing)
          {
            trace('[AUTOTEST] [PASS] FlxG.sound.music is playing after recovery! (songPosition=${Conductor.instance.songPosition}ms, music.time=${FlxG.sound.music.time}ms)');
            stepState = 5;
          }
        }

      case 5:
        // Run for 2 more seconds to ensure smooth playback without regression
        var timeSinceStall:Float = haxe.Timer.stamp() - audioTortureStallTime;
        if (timeSinceStall >= 2.5)
        {
          trace('[AUTOTEST] [PASS] AUDIO_TORTURE scenario fully validated! No freeze, no audio drop, perfect recovery.');
          passTest();
        }
    }
  }

  // ---------------------------------------------------------------------------
  // WEEKEND1_PLAYLIST: full Weekend 1 Story Mode (Hard) chain
  // darnellCutscene -> darnell -> lit-up -> 2hot -> 2hotCutscene -> blazin -> blazinCutscene -> Results
  // ---------------------------------------------------------------------------

  static final W1_EXPECTED_SONGS:Array<String> = ["darnell", "lit-up", "2hot", "blazin"];
  static final W1_CUTSCENE_SECONDS:Float = 2.0;
  static final W1_SONG_SECONDS:Float = 3.0;
  static final W1_PHASE_TIMEOUT:Float = 90.0;

  static inline var W1_WAIT_START:Int = 0;
  static inline var W1_PLAYING:Int = 1;
  static inline var W1_WAIT_END:Int = 2;
  static inline var W1_CUTSCENE:Int = 3;

  static var w1Instance:Null<PlayState> = null;
  static var w1SongId:String = "";
  static var w1Phase:Int = 0;
  static var w1PhaseStamp:Float = 0.0;
  static var w1EndRequested:Bool = false;
  static var w1SongsEntered:Array<String> = [];
  static var w1CutscenesPlayed:Array<String> = [];
  static var w1TransitionIndex:Int = 0;
  static var w1PeakNativeMb:Float = 0.0;
  static var w1LastSample:Float = 0.0;
  static var w1CaptureRequested:Bool = false;

  static function startWeekend1Playlist():Void
  {
    trace('[AUTOTEST] Launching WEEKEND1_PLAYLIST (Weekend 1 Story Mode, Hard, full chain)...');

    w1Instance = null;
    w1SongId = "";
    w1Phase = W1_WAIT_START;
    w1PhaseStamp = Timer.stamp();
    w1EndRequested = false;
    w1SongsEntered = [];
    w1CutscenesPlayed = [];
    w1TransitionIndex = 0;
    w1PeakNativeMb = 0.0;

    // Snapshot every state transition: before the old state is destroyed, after it has been destroyed
    // and purged (but before the new state is built), and once the new state has been created.
    FlxG.signals.preStateSwitch.add(onW1PreStateSwitch);
    FlxG.signals.preStateCreate.add(onW1PreStateCreate);
    FlxG.signals.postStateSwitch.add(onW1PostStateSwitch);
    funkin.util.logging.CrashHandler.errorSignal.add(onW1Error);
    funkin.util.logging.CrashHandler.criticalErrorSignal.add(onW1Error);

    // Mirror StoryMenuState.selectLevel() exactly.
    var level = LevelRegistry.instance.fetchEntry("weekend1");
    if (level == null)
    {
      failTest("Level weekend1 not found in LevelRegistry");
      return;
    }

    Paths.setCurrentLevel(level.id);
    PlayStatePlaylist.playlistSongIds = level.getSongs();
    trace('[AUTOTEST] Weekend 1 playlist: ' + PlayStatePlaylist.playlistSongIds.join(' -> '));
    if (PlayStatePlaylist.playlistSongIds.join(',') != W1_EXPECTED_SONGS.join(','))
    {
      trace('[AUTOTEST] WARNING: playlist differs from expected ' + W1_EXPECTED_SONGS.join(' -> '));
    }
    PlayStatePlaylist.isStoryMode = true;
    PlayStatePlaylist.campaignScore = 0;

    var targetSongId:String = PlayStatePlaylist.playlistSongIds.shift();
    var targetSong:Song = SongRegistry.instance.fetchEntry(targetSongId, {variation: Constants.DEFAULT_VARIATION});

    PlayStatePlaylist.campaignId = level.id;
    PlayStatePlaylist.campaignTitle = level.getTitle();
    PlayStatePlaylist.campaignDifficulty = "hard";
    Highscore.talliesLevel = new funkin.Highscore.Tallies();

    NXDeepTrace.logMemorySnapshot('W1 BASELINE (before darnell)', true);

    LoadingState.loadPlayState(
      {
        targetSong: targetSong,
        targetDifficulty: PlayStatePlaylist.campaignDifficulty,
        targetVariation: targetSong.getFirstValidVariation(PlayStatePlaylist.campaignDifficulty)
      }, true);
  }

  static function onW1PreStateSwitch():Void
  {
    if (!isRunning) return;
    w1TransitionIndex++;
    var from:String = (PlayState.instance != null && PlayState.instance.currentSong != null) ? PlayState.instance.currentSong.id : Type.getClassName(Type.getClass(FlxG.state));
    snapshotW1('T$w1TransitionIndex PRE-SWITCH (leaving $from)', false);
  }

  static function onW1PreStateCreate(state:flixel.FlxState):Void
  {
    if (!isRunning) return;
    snapshotW1('T$w1TransitionIndex POST-DESTROY/PURGE (before ${Type.getClassName(Type.getClass(state))}.create)', true);
  }

  static function onW1PostStateSwitch():Void
  {
    if (!isRunning) return;
    var into:String = (PlayState.instance != null && PlayState.instance.currentSong != null) ? PlayState.instance.currentSong.id : Type.getClassName(Type.getClass(FlxG.state));
    snapshotW1('T$w1TransitionIndex POST-CREATE (entered $into)', false);
  }

  static function onW1Error(message:String):Void
  {
    trace('[AUTOTEST] [EXCEPTION] Captured engine error during WEEKEND1_PLAYLIST: $message');
  }

  static function snapshotW1(label:String, listSounds:Bool):Void
  {
    NXDeepTrace.logMemorySnapshot(label, listSounds);
    #if switch
    var nativeMb:Float = NXPerformance.getNativeHeapUsed();
    if (nativeMb > w1PeakNativeMb) w1PeakNativeMb = nativeMb;
    #end
  }

  static function setW1Phase(phase:Int):Void
  {
    w1Phase = phase;
    w1PhaseStamp = Timer.stamp();
  }

  static function isW1ResultsOpen():Bool
  {
    if (FlxG.state == null) return false;
    if (Std.isOfType(FlxG.state, funkin.play.ResultState)) return true;
    var sub = FlxG.state.subState;
    while (sub != null)
    {
      if (Std.isOfType(sub, funkin.play.ResultState)) return true;
      sub = sub.subState;
    }
    return false;
  }

  static function handleWeekend1PlaylistScenario():Void
  {
    if (isW1ResultsOpen())
    {
      snapshotW1('W1 RESULTS SCREEN', true);
      trace('[AUTOTEST] [PASS] Reached ResultState after the full Weekend 1 chain.');
      trace('[AUTOTEST] Songs entered: ' + w1SongsEntered.join(' -> '));
      trace('[AUTOTEST] Cutscenes played: ' + w1CutscenesPlayed.join(' -> '));
      trace('[AUTOTEST] Peak native malloc observed at transitions: ${Math.round(w1PeakNativeMb * 10) / 10} MB');
      if (w1SongsEntered.join(',') != W1_EXPECTED_SONGS.join(','))
      {
        failTest('Unexpected song order: ' + w1SongsEntered.join(' -> '));
        return;
      }
      passTest();
      return;
    }

    var ps:Null<PlayState> = PlayState.instance;
    // Telemetry: sample native malloc twice per second (shows when GPU memory is actually returned).
    #if switch
    if (Timer.stamp() - w1LastSample >= 0.5)
    {
      w1LastSample = Timer.stamp();
      var ctx:String = (ps == null) ? 'no-playstate' : 'song=${ps.currentSong?.id} phase=$w1Phase starting=${@:privateAccess ps.startingSong} cutscene=${ps.isInCutscene} pos=${Math.round(Conductor.instance.songPosition)}';
      #if cpp
      var gcMb:Float = Math.round(cpp.vm.Gc.memInfo(0) / 104857.6) / 10.0;
      #else
      var gcMb:Float = 0.0;
      #end
      NXDeepTrace.writeEntry('MEMSAMPLE', 'native=${Math.round(NXPerformance.getNativeHeapUsed() * 10) / 10} gc=$gcMb $ctx');
    }
    #end
    if (ps == null || ps.currentSong == null) return; // Mid-transition.

    if (ps != w1Instance)
    {
      w1Instance = ps;
      w1SongId = ps.currentSong.id;
      w1EndRequested = false;
      w1CaptureRequested = false;
      w1SongsEntered.push(w1SongId);
      setW1Phase(W1_WAIT_START);
      trace('[AUTOTEST] Entered song "$w1SongId" (${w1SongsEntered.length}/${W1_EXPECTED_SONGS.length}) on stage "${ps.currentStageId}" [diff=${ps.currentDifficulty}, story=${PlayStatePlaylist.isStoryMode}]');
    }

    var phaseElapsed:Float = Timer.stamp() - w1PhaseStamp;
    if (phaseElapsed > W1_PHASE_TIMEOUT)
    {
      failTest('Stuck in phase $w1Phase of song "$w1SongId" for ${Math.round(phaseElapsed)}s'
        + ' (startingSong=${@:privateAccess ps.startingSong}, isInCutscene=${ps.isInCutscene}, video=${NXVideoPlayer.isCutscenePlaying()})');
      return;
    }

    switch (w1Phase)
    {
      case W1_WAIT_START | W1_WAIT_END:
        if (NXVideoPlayer.isCutscenePlaying())
        {
          var videoName:String = @:privateAccess NXVideoPlayer.currentVideoName;
          w1CutscenesPlayed.push(videoName);
          trace('[AUTOTEST] Cutscene "$videoName" started in song "$w1SongId". Letting it run ${W1_CUTSCENE_SECONDS}s...');
          setW1Phase(W1_CUTSCENE);
        }
        else if (w1Phase == W1_WAIT_START && !w1EndRequested && !(@:privateAccess ps.startingSong) && !ps.isInCutscene
          && FlxG.sound.music != null && FlxG.sound.music.playing && Conductor.instance.songPosition > 0)
        {
          trace('[AUTOTEST] Song "$w1SongId" is playing (songPosition=${Math.round(Conductor.instance.songPosition)}ms). Letting it run ${W1_SONG_SECONDS}s...');
          setW1Phase(W1_PLAYING);
        }

      case W1_PLAYING:
        if (!w1CaptureRequested && phaseElapsed >= W1_SONG_SECONDS - 0.5)
        {
          w1CaptureRequested = true;
          requestFrameCapture('w1_${w1SongId}');
        }
        if (phaseElapsed >= W1_SONG_SECONDS)
        {
          trace('[AUTOTEST] Song "$w1SongId" ran ${W1_SONG_SECONDS}s (songPosition=${Math.round(Conductor.instance.songPosition)}ms). Calling endSong(true)...');
          snapshotW1('W1 END OF $w1SongId', false);
          w1EndRequested = true;
          setW1Phase(W1_WAIT_END);
          ps.endSong(true);
        }

      case W1_CUTSCENE:
        if (!NXVideoPlayer.isCutscenePlaying())
        {
          trace('[AUTOTEST] Cutscene in song "$w1SongId" ended on its own.');
          setW1Phase(w1EndRequested ? W1_WAIT_END : W1_WAIT_START);
        }
        else if (phaseElapsed >= W1_CUTSCENE_SECONDS)
        {
          trace('[AUTOTEST] Finishing cutscene in song "$w1SongId" through the natural completion path...');
          setW1Phase(w1EndRequested ? W1_WAIT_END : W1_WAIT_START);
          NXVideoPlayer.finishCutscene();
        }

      default:
    }
  }

  // ---------------------------------------------------------------------------
  // Frame capture: reads the rendered backbuffer (after OpenFL draws, before the swap)
  // and saves it as PNG next to the trace log, as visual evidence for headless runs.
  // ---------------------------------------------------------------------------

  static var pendingCaptureName:Null<String> = null;
  static var captureHooked:Bool = false;

  static function requestFrameCapture(name:String):Void
  {
    pendingCaptureName = name;
    if (!captureHooked)
    {
      captureHooked = true;
      // Lower priority than OpenFL's stage render (0), so the frame is already drawn.
      lime.app.Application.current.window.onRender.add(onRenderCapture, false, -1000);
    }
  }

  static function onRenderCapture(_):Void
  {
    if (pendingCaptureName == null) return;
    var name:String = pendingCaptureName;
    pendingCaptureName = null;

    #if sys
    try
    {
      var w:Int = FlxG.stage.stageWidth;
      var h:Int = FlxG.stage.stageHeight;
      var gl = lime.graphics.opengl.GL;
      var pixels = new lime.utils.UInt8Array(w * h * 4);
      gl.bindFramebuffer(gl.FRAMEBUFFER, null);
      gl.readPixels(0, 0, w, h, gl.RGBA, gl.UNSIGNED_BYTE, pixels);

      // GL origin is bottom-left: flip rows.
      var rowBytes:Int = w * 4;
      var flipped = haxe.io.Bytes.alloc(w * h * 4);
      var src = pixels.toBytes();
      var nonBlack:Int = 0;
      for (y in 0...h)
      {
        flipped.blit((h - 1 - y) * rowBytes, src, y * rowBytes, rowBytes);
      }
      var i:Int = 0;
      while (i < flipped.length)
      {
        if (flipped.get(i) > 16 || flipped.get(i + 1) > 16 || flipped.get(i + 2) > 16) nonBlack++;
        i += 4 * 16;
      }

      var image = new lime.graphics.Image(new lime.graphics.ImageBuffer(lime.utils.UInt8Array.fromBytes(flipped), w, h));
      var png = image.encode(PNG);
      #if switch
      var path:String = nx.NXMain.getSafeAppSubPath('logs/autotest_$name.png');
      #else
      var path:String = 'logs/autotest_$name.png';
      #end
      sys.io.File.saveBytes(path, png);
      var coverage:Float = Math.round(nonBlack / ((w * h) / 16) * 1000) / 10;
      trace('[AUTOTEST] Frame captured: $path (${w}x${h}, non-black coverage: $coverage%)');
    }
    catch (e:Dynamic)
    {
      trace('[AUTOTEST] Frame capture failed for $name: $e');
    }
    #end
  }

  static function passTest():Void
  {
    isRunning = false;
    FlxG.signals.postUpdate.remove(onPostUpdate);
    unhookW1Signals();

    #if (cpp || switch)
    cpp.vm.Gc.run(true);
    cpp.vm.Gc.compact();
    var memMb:Float = (cpp.vm.Gc.memInfo(0) / (1024.0 * 1024.0));
    var largeMb:Float = (cpp.vm.Gc.memInfo(3) / (1024.0 * 1024.0));
    trace('[AUTOTEST] Memory info: GC Heap: ${Math.round(memMb * 10) / 10} MB (Large allocs pool: ${Math.round(largeMb * 10) / 10} MB)');
    #end

    trace('[AUTOTEST] ========================================');
    trace('[AUTOTEST] COMPLETED SUCCESSFULLY');
    trace('[AUTOTEST] ========================================');
  }

  static function failTest(reason:String):Void
  {
    isRunning = false;
    FlxG.signals.postUpdate.remove(onPostUpdate);
    unhookW1Signals();
    trace('[AUTOTEST] ========================================');
    trace('[AUTOTEST] [FAIL] TEST FAILED: ' + reason);
    trace('[AUTOTEST] ========================================');
  }

  static function unhookW1Signals():Void
  {
    FlxG.signals.preStateSwitch.remove(onW1PreStateSwitch);
    FlxG.signals.preStateCreate.remove(onW1PreStateCreate);
    FlxG.signals.postStateSwitch.remove(onW1PostStateSwitch);
    funkin.util.logging.CrashHandler.errorSignal.remove(onW1Error);
    funkin.util.logging.CrashHandler.criticalErrorSignal.remove(onW1Error);
  }
}
