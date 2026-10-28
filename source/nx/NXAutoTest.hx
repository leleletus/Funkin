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
  /**
   * True while an automated test is running (botplay is forced on).
   */
  public static function isActive():Bool
  {
    return isRunning;
  }

  /**
   * True when the run was started on the console with L+R (shows progress on screen).
   */
  public static var startedOnConsole(default, null):Bool = false;

  /**
   * Starts a scenario while the game is running (L+R held 3 s on the console, see NXPerformance).
   * @return false if another automated run is already active or test tools are compiled out.
   */
  public static function startRuntime(scenario:String):Bool
  {
    if (isRunning || !NXDevTools.autotestsAllowed()) return false;
    currentScenario = scenario.toUpperCase();
    isRunning = true;
    startedOnConsole = true;
    testTimer = 0.0;
    stepState = 0;
    hasTriggeredEndSong = false;
    trace('[AUTOTEST] ========================================');
    trace('[AUTOTEST] ACTIVATED on the console (button combo): ' + currentScenario);
    trace('[AUTOTEST] ========================================');
    NXDevOverlay.show('AUTO $currentScenario: starting...');
    FlxG.signals.postUpdate.add(onPostUpdate);
    new FlxTimer().start(0.5, function(tmr:FlxTimer) {
      startScenario(currentScenario);
    });
    return true;
  }

  public static function checkAndRun():Bool
  {
    NXDevTools.init();
    if (!NXDevTools.autotestsAllowed()) return false;
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
      // "ONCE:<SCENARIO>" runs the scenario a single time (used on real hardware): the file is deleted
      // right away so the next boot starts the game normally.
      if (StringTools.startsWith(currentScenario, "ONCE:"))
      {
        currentScenario = currentScenario.substr(5);
        try
        {
          sys.FileSystem.deleteFile(configPath);
        }
        catch (e:Dynamic) {}
      }
      if (currentScenario.indexOf("NOTEXMEM") != -1) NXTextureMemory.enabled = false;
      if (currentScenario.indexOf("NOUPLOADREL") != -1) NXTextureMemory.releaseOnUpload = false;
      if (currentScenario.indexOf("NOPOSTREL") != -1) NXTextureMemory.releaseAfterCreate = false;
      if (currentScenario.indexOf("NOORDEREDREL") != -1) NXTextureMemory.orderedRelease = false;
      if (currentScenario.indexOf("NOBANDUPLOAD") != -1) NXTextureUpload.enabled = false;
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
      if (scenario.indexOf("HAPTICS") != -1)
      {
        startHapticsProbe();
      }
      else if (scenario.indexOf("CREDITS") != -1)
      {
        startCreditsCheck();
      }
      else if (scenario.indexOf("SCREENSHOTS") != -1)
      {
        startScreenshots();
      }
      else if (scenario.indexOf("PLAYTHROUGH") != -1)
      {
        NXRegressionSuite.startPlaythrough();
      }
      else if (scenario.indexOf("CUTSCENE_SKIP") != -1)
      {
        NXRegressionSuite.startCutsceneSkip();
      }
      else if (scenario.indexOf("INC49_REPRO") != -1)
      {
        NXRegressionSuite.startInc49Repro();
      }
      else if (scenario.indexOf("DECODE_PARITY") != -1)
      {
        runDecodeParity();
      }
      else if (scenario.indexOf("UPLOAD_PARITY") != -1)
      {
        runUploadParity();
      }
      else if (scenario.indexOf("AUDIO_DRIVER_STALL") != -1)
      {
        NXRegressionSuite.startAudioDriverStall(scenario.indexOf("LEGACY") != -1);
      }
      else if (scenario.indexOf("AUDIO_STARVE") != -1)
      {
        NXRegressionSuite.startAudioStarve();
      }
      else if (scenario.indexOf("MEMORY_BUDGET") != -1)
      {
        NXRegressionSuite.startMemoryBudget(scenario.indexOf("_X3") != -1 ? 3 : 2);
      }
      else if (scenario.indexOf("SOAK") != -1)
      {
        NXRegressionSuite.startSoak();
      }
      else if (scenario.indexOf("REGRESSION") != -1)
      {
        var fromIdx:Int = scenario.indexOf("REGRESSION_FROM_");
        NXRegressionSuite.start(fromIdx != -1 ? Std.parseInt(scenario.substr(fromIdx + "REGRESSION_FROM_".length)) : 1);
      }
      else if (scenario.indexOf("WEEKEND1_PLAYLIST") != -1 || scenario.indexOf("WEEKEND1_FULL") != -1)
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
    var globalTimeout:Float = (currentScenario.indexOf("SCREENSHOTS") != -1) ? 900.0 : (currentScenario.indexOf("MEMORY_BUDGET") != -1) ? 7200.0 : (currentScenario.indexOf("PLAYTHROUGH") != -1 || currentScenario.indexOf("INC49_REPRO") != -1) ? 4500.0 : (currentScenario.indexOf("CUTSCENE_SKIP") != -1) ? 600.0 : (currentScenario.indexOf("SOAK") != -1) ? 2700.0 : (currentScenario.indexOf("WEEKEND1_FULL") != -1) ? 1500.0 : ((currentScenario.indexOf("PLAYLIST") != -1
      || currentScenario.indexOf("REGRESSION") != -1) ? 900.0 : 180.0);
    if (testTimer > globalTimeout)
    {
      failTest('Global test timeout reached (${globalTimeout}s)');
      return;
    }

    if (currentScenario.indexOf("REGRESSION") != -1 || currentScenario.indexOf("SOAK") != -1 || currentScenario.indexOf("AUDIO_STARVE") != -1
      || currentScenario.indexOf("AUDIO_DRIVER_STALL") != -1 || currentScenario.indexOf("PLAYTHROUGH") != -1 || currentScenario.indexOf("CUTSCENE_SKIP") != -1
      || currentScenario.indexOf("INC49_REPRO") != -1 || currentScenario.indexOf("MEMORY_BUDGET") != -1)
    {
      NXRegressionSuite.update();
    }
    else if (currentScenario.indexOf("WEEKEND1_PLAYLIST") != -1 || currentScenario.indexOf("WEEKEND1_FULL") != -1)
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
  // WEEKEND1_PLAYLIST cuts every cutscene at 2s and every song at 3s (fast transition check).
  // WEEKEND1_FULL lets cutscenes and songs (botplay) run to their natural end, like a real playthrough.
  // ---------------------------------------------------------------------------

  static final W1_EXPECTED_SONGS:Array<String> = ["darnell", "lit-up", "2hot", "blazin"];
  static final W1_CUTSCENE_SECONDS:Float = 2.0;
  static final W1_SONG_SECONDS:Float = 3.0;
  static final W1_PHASE_TIMEOUT:Float = 90.0;
  static final W1_FULL_PHASE_TIMEOUT:Float = 400.0;
  static var w1Full:Bool = false;

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
    trace('[AUTOTEST] Launching $currentScenario (Weekend 1 Story Mode, Hard, full chain)...');

    w1Instance = null;
    w1SongId = "";
    w1Phase = W1_WAIT_START;
    w1PhaseStamp = Timer.stamp();
    w1EndRequested = false;
    w1SongsEntered = [];
    w1CutscenesPlayed = [];
    w1TransitionIndex = 0;
    w1PeakNativeMb = 0.0;
    w1Full = currentScenario.indexOf("WEEKEND1_FULL") != -1;

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
    if (Timer.stamp() - w1LastSample >= (w1Full ? 2.0 : 0.5))
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
    if (phaseElapsed > (w1Full ? W1_FULL_PHASE_TIMEOUT : W1_PHASE_TIMEOUT))
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
        if (w1Full)
        {
          // Natural playthrough: the song ends by itself and may start an ending cutscene.
          if (NXVideoPlayer.isCutscenePlaying())
          {
            var videoName:String = @:privateAccess NXVideoPlayer.currentVideoName;
            w1CutscenesPlayed.push(videoName);
            w1EndRequested = true;
            snapshotW1('W1 END OF $w1SongId (natural)', false);
            trace('[AUTOTEST] Song "$w1SongId" ended naturally, ending cutscene "$videoName" started.');
            setW1Phase(W1_CUTSCENE);
          }
        }
        else if (phaseElapsed >= W1_SONG_SECONDS)
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
        else if (!w1Full && phaseElapsed >= W1_CUTSCENE_SECONDS)
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
  public static var lastCaptureName:String = "";
  public static var lastCaptureCoverage:Float = -1.0;
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
      lastCaptureName = name;
      lastCaptureCoverage = coverage;
      trace('[AUTOTEST] Frame captured: $path (${w}x${h}, non-black coverage: $coverage%)');
    }
    catch (e:Dynamic)
    {
      trace('[AUTOTEST] Frame capture failed for $name: $e');
    }
    #end
  }

  /**
   * HAPTICS: drives HapticUtil exactly like the game does (one-shot and pattern) and checks that the
   * native HD Rumble path found a controller, sent every pulse and stopped the motors on time.
   */
  static function startHapticsProbe():Void
  {
    trace('[AUTOTEST] Haptics probe: ' + NXHaptics.describeStatus());
    funkin.util.HapticUtil.vibrate(0, 0.01, 0.5);
    new FlxTimer().start(0.5, function(_) {
      trace('[AUTOTEST] Haptics after one-shot: ' + NXHaptics.describeStatus());
      funkin.util.HapticUtil.vibrate(0.1, 0.5, 0.5);
      new FlxTimer().start(1.0, function(_) {
        var status:String = NXHaptics.describeStatus();
        trace('[AUTOTEST] Haptics after pattern: ' + status);
        if (NXHaptics.lastResult != 0) failTest('Vibration not sent: ' + status);
        else if (NXHaptics.sentCount < 6) failTest('Expected at least 6 pulses, got ' + NXHaptics.sentCount);
        else if (NXHaptics.isActive()) failTest('Motors still running after the pattern ended');
        else passTest();
      });
    });
  }

  /**
   * DECODE_PARITY: decodes every shipped PNG variant (and the 128 MiB / 91 MiB sheets that crashed, plus a video
   * sheet from bytes) with lime's stock call and with nx.NXImageDecode, and requires identical pixels and that the
   * new path really used a single block (INC-49).
   */
  @:access(lime._internal.backend.native.NativeCFFI)
  static function runDecodeParity():Void
  {
    #if (switch && lime_cffi)
    var files:Array<String> = [
      'assets/week6/images/pixelNoteHoldCover.png', 'assets/images/charSelect/barThing/spritemap1.png',
      'assets/week6/images/weeb/pixelUI/dialogueBox-evilNew.png', 'assets/week1/lol.png',
      'assets/shared/images/resultScreen/rankText/rankTextPERFECT.png', 'assets/week6/images/weeb/pixelUI/dialogueBox-evil.png',
      'assets/images/freeplay/ref.png', 'assets/images/icons/icon-face.png', 'assets/week1/opensauceforever.png',
      'assets/week6/images/weeb/petals.png', 'assets/shared/images/characters/gfTankmen.png',
      'assets/weekend1/images/spraycanAtlas/spritemap1.png', 'assets/videos/converted/2hotCutscene_0.png',
      'assets/shared/images/characters/pico/explosion-death/spritemap1.png', 'assets/shared/images/characters/BOYFRIEND.png'
    ];
    // Files of 128 MiB or more are only compared through the file path, to keep the bytes runs small.
    var hugeOnlyFile:Array<String> = ['gfTankmen', 'explosion-death', 'BOYFRIEND'];
    var failures:Array<String> = [];
    var checked:Int = 0;
    inline function empty() return new lime.graphics.ImageBuffer(new lime.utils.UInt8Array(haxe.io.Bytes.alloc(0)));
    function compare(label:String, a:lime.graphics.ImageBuffer, b:lime.graphics.ImageBuffer):Void
    {
      checked++;
      if (a == null || b == null)
      {
        failures.push('$label: null result (stock ${a != null}, nx ${b != null})');
        return;
      }
      if (a.width != b.width || a.height != b.height || a.bitsPerPixel != b.bitsPerPixel)
      {
        failures.push('$label: size ${a.width}x${a.height}/${a.bitsPerPixel} vs ${b.width}x${b.height}/${b.bitsPerPixel}');
        return;
      }
      var ab:haxe.io.Bytes = a.data.buffer;
      var bb:haxe.io.Bytes = b.data.buffer;
      if (a.data.byteLength != b.data.byteLength || ab.compare(bb) != 0) failures.push('$label: pixels differ (${a.data.byteLength} vs ${b.data.byteLength} bytes)');
      else trace('[AUTOTEST] DECODE_PARITY ok: $label ${a.width}x${a.height}');
    }
    // Every image of 64 KiB or more must take the single-copy path (smaller ones take the stock call by design).
    function requireSingleCopy(label:String, decoded:Null<lime.graphics.ImageBuffer>, usedSingleCopy:Bool):Void
    {
      if (decoded == null) return;
      if (decoded.width * 4.0 * decoded.height >= 64 * 1024 && !usedSingleCopy)
        failures.push('$label: took the stock two-block decode (${decoded.width}x${decoded.height})');
    }
    for (file in files)
    {
      var path:String = 'romfs:/' + file;
      var stockFile:lime.graphics.ImageBuffer = lime._internal.backend.native.NativeCFFI.lime_image_load_file(path, empty());
      var singleBefore:Int = NXImageDecode.singleCopy;
      var nxFile:lime.graphics.ImageBuffer = NXImageDecode.loadFile(path);
      requireSingleCopy('file ' + file, stockFile, NXImageDecode.singleCopy > singleBefore);
      compare('file ' + file, stockFile, nxFile);
      stockFile = null;
      nxFile = null;
      cpp.vm.Gc.run(true);
      var huge:Bool = false;
      for (name in hugeOnlyFile)
        if (file.indexOf(name) != -1) huge = true;
      if (huge) continue;
      var bytes = sys.io.File.getBytes(path);
      var stockBytes:lime.graphics.ImageBuffer = lime._internal.backend.native.NativeCFFI.lime_image_load_bytes(bytes, empty());
      var singleBeforeBytes:Int = NXImageDecode.singleCopy;
      var nxBytes:lime.graphics.ImageBuffer = NXImageDecode.loadBytes(bytes);
      requireSingleCopy('bytes ' + file, stockBytes, NXImageDecode.singleCopy > singleBeforeBytes);
      compare('bytes ' + file, stockBytes, nxBytes);
      stockBytes = null;
      nxBytes = null;
      bytes = null;
      cpp.vm.Gc.run(true);
    }
    // The real entry points the game uses must reach NXImageDecode (the macro patched lime.graphics.Image).
    var before:Int = NXImageDecode.singleCopy;
    var viaFile = lime.graphics.Image.fromFile('romfs:/assets/week1/opensauceforever.png');
    var viaBytes = lime.graphics.Image.fromBytes(sys.io.File.getBytes('romfs:/assets/week1/opensauceforever.png'));
    if (viaFile == null || viaBytes == null || NXImageDecode.singleCopy - before != 2)
      failures.push('lime.graphics.Image.fromFile/fromBytes did not go through NXImageDecode (single-copy delta ${NXImageDecode.singleCopy - before})');
    else trace('[AUTOTEST] DECODE_PARITY ok: lime Image.fromFile/fromBytes use the single-copy path');
    viaFile = null;
    viaBytes = null;

    var stats:String = NXImageDecode.describe();
    trace('[AUTOTEST] DECODE_PARITY: $checked comparisons, ${failures.length} failures, $stats');
    if (failures.length > 0) failTest('DECODE_PARITY: ' + failures.join(' | '));
    else if (NXImageDecode.missed > 0) failTest('DECODE_PARITY: pixels match but ${NXImageDecode.missed} decodes still copied ($stats)');
    else passTest();
    #else
    failTest('DECODE_PARITY needs the Switch build');
    #end
  }

  /**
   * UPLOAD_PARITY: uploads shipped sheets with nx.NXTextureUpload's row bands (through BitmapData.getTexture, the
   * game's path) and with OpenFL's single glTexImage2D (banding off), reads both textures back from the GPU in 64-row
   * slices and requires them to be identical and equal to the uploaded image (INC-49).
   */
  @:access(openfl.display.BitmapData)
  @:access(openfl.display3D.Context3D)
  @:access(openfl.display3D._internal.Context3DState)
  @:access(openfl.display3D.textures.TextureBase)
  static function runUploadParity():Void
  {
    #if (switch && lime_cffi)
    var context:openfl.display3D.Context3D = FlxG.stage.context3D;
    if (context == null)
    {
      failTest('UPLOAD_PARITY: no Context3D');
      return;
    }
    var gl = context.gl;
    // Largest first, while the heap is still in one piece.
    var files:Array<String> = [
      'assets/shared/images/characters/pico/explosion-death/spritemap1.png', // 8181x4687, 146 MiB (the largest since 0.8.3): odd stride
      'assets/shared/images/characters/BOYFRIEND.png', // 8192x4096, 128 MiB: whole bands
      'assets/shared/images/characters/gfTankmen.png', // 8192x4096 (INC-49)
      'assets/shared/images/characters/pico/death/spritemap1.png', // 4094x2897, 45 MiB
      'assets/week2/images/halloween_bg/spritemap1.png', // 3924x2256, 34 MiB: the Week 2 background since 0.8.3
      'assets/videos/converted/ughCutscene_0.png', // 3840x3960 video sheet
      'assets/weekend1/images/bgConcept.png', // 4200x2600 RGB PNG without alpha
      'assets/shared/images/characters/pico/playable-animations/spritemap1.png', // 4093x1335: odd width, partial last band
      'assets/weekend1/images/fightPico.png', // 2048x2048: exactly 16 MiB, the smallest banded size
      'assets/shared/images/characters/pico-holding-nene/picoAndNene-DEAD/spritemap1.png' // 2048x2008, 15.7 MiB: OpenFL's single call
    ];
    var sliceRows:Int = 64;
    var wasEnabled:Bool = NXTextureUpload.enabled;
    // OpenFL uploads BGRA bytes when the driver has a BGRA extension; readPixels(RGBA) returns R and B swapped.
    var swapRB:Bool = openfl.display3D.textures.TextureBase.__textureFormat != gl.RGBA;
    var failures:Array<String> = [];
    var inconclusive:Array<String> = [];
    var bandedImages:Int = 0;
    inline function hex(code:Int):String return '0x' + StringTools.hex(code, 4);
    for (file in files)
    {
      var started:Float = haxe.Timer.stamp();
      var bitmap:openfl.display.BitmapData = openfl.display.BitmapData.fromFile('romfs:/' + file);
      if (bitmap == null || bitmap.image == null)
      {
        failures.push('$file: could not load');
        continue;
      }
      var image:lime.graphics.Image = bitmap.image;
      var width:Int = image.buffer.width;
      var height:Int = image.buffer.height;
      var stride:Int = width * 4;
      var label:String = '$file ${width}x${height}';
      var bandable:Bool = stride * height >= 16 * 1024 * 1024;
      if (bandable) bandedImages++;
      // getTexture must upload this exact image (no premultiply clone), so both arms send the same bytes.
      if (!image.premultiplied && image.transparent) failures.push('$label: not premultiplied, getTexture would upload a clone');
      for (i in 0...16)
        if (gl.getError() == gl.NO_ERROR) break;

      NXTextureUpload.enabled = true;
      var oom0:Int = NXTextureUpload.outOfMemory;
      var banded0:Int = NXTextureUpload.banded;
      // Test builds read the GL error right after every upload (clearing Mesa's flag): count those reads too.
      var uploadErrors0:Int = NXTextureUpload.uploadErrors;
      var texA:openfl.display3D.textures.TextureBase = bitmap.getTexture(context);
      var errA:Int = gl.getError();
      if (errA == gl.NO_ERROR && NXTextureUpload.uploadErrors != uploadErrors0) errA = -1;
      var uploadErrorsA:Int = NXTextureUpload.uploadErrors;
      var bandedDelta:Int = NXTextureUpload.banded - banded0;

      var full0:Int = NXTextureUpload.fullLarge;
      var texB:openfl.display3D.textures.RectangleTexture = context.createRectangleTexture(width, height, openfl.display3D.Context3DTextureFormat.BGRA,
        false);
      NXTextureUpload.enabled = false;
      texB.__uploadFromImage(image);
      NXTextureUpload.enabled = true;
      var errB:Int = gl.getError();
      if (errB == gl.NO_ERROR && NXTextureUpload.uploadErrors != uploadErrorsA) errB = -1;
      var fullDelta:Int = NXTextureUpload.fullLarge - full0;
      var uploaded:Float = haxe.Timer.stamp();

      var sliceA = new lime.utils.UInt8Array(haxe.io.Bytes.alloc(stride * sliceRows));
      var sliceB = new lime.utils.UInt8Array(haxe.io.Bytes.alloc(stride * sliceRows));
      var previous = context.__contextState.__currentGLFramebuffer;
      var fbA = texA.__getGLFramebuffer(false, 0, 0);
      context.__bindGLFramebuffer(fbA);
      var statusA:Int = gl.checkFramebufferStatus(gl.FRAMEBUFFER);
      var fbB = texB.__getGLFramebuffer(false, 0, 0);
      context.__bindGLFramebuffer(fbB);
      var statusB:Int = gl.checkFramebufferStatus(gl.FRAMEBUFFER);
      var abDiff:Int = 0;
      var aSrcDiff:Int = 0;
      var bSrcDiff:Int = 0;
      var firstAB:String = '';
      var firstSrc:String = '';
      var readError:Int = 0;
      if (statusA == gl.FRAMEBUFFER_COMPLETE && statusB == gl.FRAMEBUFFER_COMPLETE)
      {
        var src:haxe.io.Bytes = image.data.buffer;
        var srcOffset:Int = image.data.byteOffset;
        var a:haxe.io.Bytes = sliceA.buffer;
        var b:haxe.io.Bytes = sliceB.buffer;
        var y:Int = 0;
        while (y < height)
        {
          var n:Int = (height - y < sliceRows) ? height - y : sliceRows;
          context.__bindGLFramebuffer(fbA);
          gl.readPixels(0, y, width, n, gl.RGBA, gl.UNSIGNED_BYTE, sliceA);
          context.__bindGLFramebuffer(fbB);
          gl.readPixels(0, y, width, n, gl.RGBA, gl.UNSIGNED_BYTE, sliceB);
          var base:Int = srcOffset + y * stride;
          var end:Int = n * stride;
          var p:Int = 0;
          while (p < end)
          {
            var wa:Int = a.getInt32(p);
            var wb:Int = b.getInt32(p);
            var ws:Int = src.getInt32(base + p);
            if (swapRB) ws = (ws & 0xFF00FF00) | ((ws & 0xFF) << 16) | ((ws >>> 16) & 0xFF);
            if (wa != wb)
            {
              if (abDiff == 0) firstAB = 'at (${Std.int((p % stride) / 4)},${y + Std.int(p / stride)}) banded ${StringTools.hex(wa, 8)} single ${StringTools.hex(wb, 8)}';
              abDiff++;
            }
            if (wa != ws)
            {
              if (aSrcDiff == 0) firstSrc = 'at (${Std.int((p % stride) / 4)},${y + Std.int(p / stride)}) read ${StringTools.hex(wa, 8)} image ${StringTools.hex(ws, 8)}';
              aSrcDiff++;
            }
            if (wb != ws) bSrcDiff++;
            p += 4;
          }
          y += n;
        }
        readError = gl.getError();
      }
      context.__bindGLFramebuffer(previous);
      var ms:Int = Math.round((haxe.Timer.stamp() - started) * 1000);
      var uploadMs:Int = Math.round((uploaded - started) * 1000);

      if (bandable && bandedDelta != 1) failures.push('$label: getTexture did not band (banded +$bandedDelta, fallbacks ${NXTextureUpload.fallbacks})');
      if (!bandable && bandedDelta != 0) failures.push('$label: banded below 16 MiB');
      if (bandable && fullDelta != 1) failures.push('$label: banded_upload off did not take OpenFL\'s call (single call +$fullDelta)');
      // -1: an error that NXTextureUpload read (and cleared) right after the upload.
      if (errA != gl.NO_ERROR || errB != gl.NO_ERROR) failures.push('$label: GL error after upload (banded ${hex(errA)}, single ${hex(errB)})');
      if (NXTextureUpload.outOfMemory != oom0) failures.push('$label: GL_OUT_OF_MEMORY during the uploads (${NXTextureUpload.outOfMemory - oom0})');
      if (statusA != gl.FRAMEBUFFER_COMPLETE || statusB != gl.FRAMEBUFFER_COMPLETE || readError != gl.NO_ERROR)
      {
        inconclusive.push('$label: no readback (framebuffer ${hex(statusA)}/${hex(statusB)}, readPixels ${hex(readError)})');
      }
      else if (abDiff > 0 && bSrcDiff == 0)
      {
        failures.push('$label: banded upload differs from OpenFL\'s in $abDiff pixels, first $firstAB');
      }
      else if (abDiff > 0 || aSrcDiff > 0)
      {
        // OpenFL's own upload does not read back as the image either: the readback is not reliable here.
        inconclusive.push('$label: readback differs from the image (banded $aSrcDiff px, single $bSrcDiff px, banded vs single $abDiff px), first $firstSrc');
      }
      else
      {
        trace('[AUTOTEST] UPLOAD_PARITY ok: $label ${bandable ? "banded" : "single call"}, identical to OpenFL\'s upload and to the image (uploads $uploadMs ms, total $ms ms)');
      }

      texB.dispose();
      bitmap.dispose(); // also disposes texA (BitmapData.dispose -> __texture.dispose)
      texA = null;
      texB = null;
      bitmap = null;
      image = null;
      sliceA = null;
      sliceB = null;
      cpp.vm.Gc.run(true);
    }
    NXTextureUpload.enabled = wasEnabled;

    var stats:String = NXTextureUpload.describe();
    trace('[AUTOTEST] UPLOAD_PARITY: ${files.length} images ($bandedImages bandable), ${failures.length} failures, ${inconclusive.length} inconclusive, $stats');
    if (failures.length > 0) failTest('UPLOAD_PARITY: ' + failures.join(' | '));
    else if (inconclusive.length > 0) failTest('UPLOAD_PARITY inconclusive: ' + inconclusive.join(' | '));
    else passTest();
    #else
    failTest('UPLOAD_PARITY needs the Switch build');
    #end
  }

  /**
   * SCREENSHOTS: store screenshots, saved by NXScreenshot to logs/screens/ (1280x720 PNG): the title screen, Spaghetti,
   * the Weekend 1 video cutscene and Blazin' with its rain. Songs run in botplay; the score line is hidden for the
   * captured frame only.
   */
  static var screenshotRestore:Null<Void->Void> = null;

  static function startScreenshots():Void
  {
    NXDevTools.setBotplay(true);
    // Clean pictures: no FPS/RAM counter, no performance HUD, no test overlay. Restored at the end.
    var debugDisplay = funkin.Preferences.debugDisplay;
    var perfHud:Bool = funkin.Preferences.switchShowPerfHud;
    funkin.Preferences.debugDisplay = funkin.ui.debug.FunkinDebugDisplay.DebugDisplayMode.Off;
    funkin.Preferences.switchShowPerfHud = false;
    NXDevOverlay.hide();
    screenshotRestore = function() {
      funkin.Preferences.debugDisplay = debugDisplay;
      funkin.Preferences.switchShowPerfHud = perfHud;
    };
    screenshotStep(0);
  }

  static function screenshotStep(step:Int):Void
  {
    var next = () -> screenshotStep(step + 1);
    switch (step)
    {
      case 0:
        FlxG.switchState(() -> new funkin.ui.title.TitleState());
        haxe.Timer.delay(() -> shoot('1-title', false, next), 22000);
      case 1:
        PlayStatePlaylist.isStoryMode = false;
        LoadingState.loadPlayState({
          targetSong: SongRegistry.instance.fetchEntry("spaghetti", {variation: Constants.DEFAULT_VARIATION}),
          targetDifficulty: "hard",
          targetVariation: "default"
        }, false);
        whenSongAt(28.0, () -> shoot('2-spaghetti', true, next));
      case 2:
        Paths.setCurrentLevel('weekend1');
        PlayStatePlaylist.isStoryMode = true;
        PlayStatePlaylist.campaignId = "weekend1";
        PlayStatePlaylist.campaignTitle = "Weekend 1";
        PlayStatePlaylist.campaignDifficulty = "hard";
        PlayStatePlaylist.playlistSongIds = ["lit-up", "2hot", "blazin"];
        LoadingState.loadPlayState({
          targetSong: SongRegistry.instance.fetchEntry("darnell", {variation: Constants.DEFAULT_VARIATION}),
          targetDifficulty: "hard",
          targetVariation: "default"
        }, true);
        whenCutscenePlaying(() -> haxe.Timer.delay(() -> shoot('3-weekend1-cutscene', false, next), 16000));
      case 3:
        nx.video.NXVideoPlayer.stop();
        PlayStatePlaylist.isStoryMode = false;
        LoadingState.loadPlayState({
          targetSong: SongRegistry.instance.fetchEntry("blazin", {variation: Constants.DEFAULT_VARIATION}),
          targetDifficulty: "hard",
          targetVariation: "default"
        }, false);
        whenSongAt(48.0, () -> shoot('4-blazin', true, next));
      default:
        if (screenshotRestore != null) screenshotRestore();
        passTest();
    }
  }

  /** Calls `then` once a song is running and its position has reached `seconds` (polled with haxe.Timer). */
  static function whenSongAt(seconds:Float, then:Void->Void):Void
  {
    var ps = PlayState.instance;
    @:privateAccess var ready:Bool = ps != null && ps.subState == null && !ps.startingSong && !ps.isInCutscene
      && funkin.Conductor.instance.songPosition >= seconds * 1000;
    if (ready) then();
    else haxe.Timer.delay(() -> whenSongAt(seconds, then), 500);
  }

  static function whenCutscenePlaying(then:Void->Void):Void
  {
    if (nx.video.NXVideoPlayer.isCutscenePlaying()) then();
    else haxe.Timer.delay(() -> whenCutscenePlaying(then), 250);
  }

  /** Captures the next frame; with `hideScore`, the score line ("BOTPLAY ACTIVE") is hidden for that frame. */
  static function shoot(name:String, hideScore:Bool, then:Void->Void):Void
  {
    @:privateAccess var score = PlayState.instance != null ? PlayState.instance.scoreText : null;
    var wasVisible:Bool = score != null && score.visible;
    if (hideScore && score != null) score.visible = false;
    NXDevOverlay.hide();
    // Two frames so the hidden score is really out of the drawn picture.
    haxe.Timer.delay(() -> NXScreenshot.capture(nx.NXAssetRoot.ROOT + 'logs/screens/$name.png', function(ok:Bool) {
      if (hideScore && score != null) score.visible = wasVisible;
      trace('[AUTOTEST] [SCREENSHOTS] $name: ${ok ? "saved" : "FAILED"}');
      then();
    }), 50);
  }

  /**
   * CREDITS: opens the credits and, after a few seconds, checks that their data loaded and that the scrolling lines
   * are drawn with real glyphs (a missing font leaves every line empty and the screen black, INC-65).
   */
  static function startCreditsCheck():Void
  {
    FlxG.switchState(() -> new funkin.ui.credits.CreditsState());
    // haxe.Timer, not FlxTimer: state switches clear flixel's timers.
    haxe.Timer.delay(function() {
      var data = funkin.ui.credits.CreditsDataHandler.CREDITS_DATA;
      var entries:Int = data == null ? -1 : data.entries.length;
      var lines:Int = 0;
      var drawn:Int = 0;
      FlxG.state.forEachOfType(flixel.text.FlxText, function(text:flixel.text.FlxText) {
        lines++;
        if (text.text.length > 0 && text.textField.textWidth > 0) drawn++;
      }, true);
      trace('[AUTOTEST] [CREDITS] entries $entries, text lines $lines, drawn with glyphs $drawn, font ${@:privateAccess funkin.ui.credits.CreditsState.CREDITS_FONT}');
      if (entries <= 0) failTest('credits data did not load');
      else if (drawn == 0) failTest('credits text has no glyphs (font missing)');
      else passTest();
    }, 8000);
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
    if (startedOnConsole) NXDevOverlay.show('AUTO $currentScenario: COMPLETED OK (${Math.round(testTimer / 60)} min)', 30.0);
    startedOnConsole = false;
  }

  static function failTest(reason:String):Void
  {
    isRunning = false;
    FlxG.signals.postUpdate.remove(onPostUpdate);
    unhookW1Signals();
    trace('[AUTOTEST] ========================================');
    trace('[AUTOTEST] [FAIL] TEST FAILED: ' + reason);
    trace('[AUTOTEST] ========================================');
    if (startedOnConsole) NXDevOverlay.show('AUTO $currentScenario: FAILED - $reason', 60.0);
    startedOnConsole = false;
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
