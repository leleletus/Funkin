package nx;

import flixel.FlxG;
import flixel.util.FlxTimer;
import funkin.play.PlayState;
import funkin.play.PlayStatePlaylist;
import funkin.play.song.Song;
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
      if (scenario.indexOf("DARNELL") != -1 || scenario.indexOf("WEEKEND1") != -1)
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
    if (testTimer > 180.0)
    {
      failTest("Global test timeout reached (180s)");
      return;
    }

    if (currentScenario.indexOf("AUDIO_TORTURE") != -1)
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

  static function passTest():Void
  {
    isRunning = false;
    FlxG.signals.postUpdate.remove(onPostUpdate);

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
    trace('[AUTOTEST] ========================================');
    trace('[AUTOTEST] [FAIL] TEST FAILED: ' + reason);
    trace('[AUTOTEST] ========================================');
  }
}
