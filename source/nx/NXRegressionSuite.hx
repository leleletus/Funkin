package nx;

import flixel.FlxG;
import flixel.FlxState;
import funkin.Conductor;
import funkin.Paths;
import funkin.data.song.SongRegistry;
import funkin.data.story.level.LevelRegistry;
import funkin.play.PauseSubState;
import funkin.play.PlayState;
import funkin.play.PlayStatePlaylist;
import funkin.play.ResultState;
import funkin.play.song.Song;
import funkin.ui.freeplay.FreeplayState;
import funkin.ui.story.StoryMenuState;
import funkin.ui.transition.LoadingState;
import funkin.util.Constants;
import haxe.Timer;
import nx.video.NXVideoPlayer;
#if lime
import lime.media.openal.AL;
#end

typedef RegressionStep =
{
  var name:String;
  var covers:String;
  var timeout:Float;
  var enter:Void->Void;
  var poll:Void->Null<Bool>; // true = pass, false = fail (see failReason), null = keep waiting
}

/**
 * Synthetic regression suite for every incident documented in docs/SWITCH_PORT_TRACKER.md.
 * Reproduces the real player flows (Story Mode exits, Weekend 1, Character Select -> Freeplay -> 2Hot,
 * results -> replay) and the hardware events that used to break the audio-driven gameplay:
 * HOME button, Sleep (power button), OpenAL stalls behind the engine's back, GPU frame hitches
 * and pause/resume spam. Each step reports PASS/FAIL with the incident it covers.
 *
 * Scenario name: REGRESSION_SUITE (see NXAutoTest).
 */
class NXRegressionSuite
{
  static var steps:Array<RegressionStep> = [];
  static var index:Int = -1;
  static var stepStart:Float = 0.0;
  static var results:Array<String> = [];
  static var failReason:String = "";
  static var running:Bool = false;

  // Per-step scratch values.
  static var mark:Float = 0.0;
  static var phase:Int = 0;
  static var counter:Int = 0;
  static var seenInstance:Null<PlayState> = null;

  // Audio baseline captured while the game is healthy.
  static var baselineOffset:Float = 0.0;
  static var baselineVoiceDrift:Array<Float> = [];
  static var hasBaseline:Bool = false;

  /**
   * @param firstStep 1-based step to start from (REGRESSION_FROM_<n>); steps from 8 on are self-contained.
   */
  public static function start(firstStep:Int = 1):Void
  {
    captureSongFrames = true;
    steps = buildSteps();
    results = [];
    index = Std.int(Math.max(0, firstStep - 1)) - 1;
    for (i in 0...(index + 1))
      results.push('SKIP  ${i + 1}. ${steps[i].name} (not requested)');
    running = true;
    trace('[AUTOTEST] REGRESSION_SUITE: ${steps.length} steps');
    NXDeepTrace.logMemorySnapshot('REG BASELINE', false);
    nextStep();
  }

  /**
   * SOAK: two uninterrupted rounds of Week 7, Weekend 1 and LE SSERAFIM in Story Mode, plus re-entering
   * Weekend 1 after leaving it mid-week. Detects memory that is never released (native floor growing
   * between rounds) and black stages when re-entering a week.
   */
  public static function startSoak():Void
  {
    captureSongFrames = true;
    steps = [];
    memoryFloors = new Map<String, Float>();
    for (round in 1...3)
    {
      for (week in ["week7", "weekend1", "sserafim"])
      {
        steps.push(
          {
            name: 'Round $round: Story Mode $week complete (all songs and cutscenes, Results)',
            covers: "INC-08, INC-11, INC-22, INC-32",
            timeout: 300,
            enter: () -> launchStory(week),
            poll: () -> playStoryWeek(week, round)
          });
        steps.push(
          {
            name: 'Round $round: memory floor in Story menu after $week',
            covers: "Leak check",
            timeout: 20,
            enter: () -> {},
            poll: () -> memoryCheckpoint('R$round-$week', round)
          });
      }
      steps.push(
        {
          name: 'Round $round: Weekend 1 re-entry (exit mid-week from Lit Up, enter again)',
          covers: "INC-22, INC-11, INC-18",
          timeout: 200,
          enter: () -> launchStory("weekend1"),
          poll: () -> reenterWeekAfterMidExit("weekend1", "lit-up", round)
        });
      steps.push(
        {
          name: 'Round $round: memory floor after Weekend 1 re-entry',
          covers: "Leak check",
          timeout: 20,
          enter: () -> {},
          poll: () -> memoryCheckpoint('R$round-reentry', round)
        });
    }
    steps.push(
      {
        name: "Round 2 vs Round 1: no memory growth at the end of the round",
        covers: "GC / purge leaks",
        timeout: 5,
        enter: () -> {},
        poll: () -> compareRounds(150.0, "reentry")
      });
    results = [];
    index = -1;
    running = true;
    trace('[AUTOTEST] SOAK: ${steps.length} steps');
    NXDeepTrace.logMemorySnapshot('SOAK BASELINE', false);
    nextStep();
  }

  /**
   * MEMORY_BUDGET: every Story week twice in a row without restarting (cutscenes 2 s, songs 3 s, dialogues skipped).
   * For each week it logs a [BUDGET] line with the large-block peak and the largest single request while the week ran,
   * plus the heap state afterwards: the heaviest week sets the memory the game must always keep available, and the
   * second round shows whether a long session still finds its large blocks (INC-49, INC-42).
   */
  public static function startMemoryBudget(rounds:Int = 2):Void
  {
    captureSongFrames = false;
    skipConversations = true;
    // The console heap (Citron gives ~98 MB more), so the budget and the second round mean the same as on hardware.
    NXDeepTrace.writeEntry('MEMORY', '[BUDGET] ${NXPerformance.capHeap(INC49_HEAP_CAP_MB)}');
    steps = [
      {
        name: "Console heap ceiling applied",
        covers: "Setup",
        timeout: 5,
        enter: () -> {},
        poll: () -> {
          var mb:Float = NXPerformance.getHeapTotalMB();
          if (mb > INC49_HEAP_CAP_MB + 1)
          {
            failReason = 'heap is ${Math.round(mb)} MB, the budget needs the console ceiling (${INC49_HEAP_CAP_MB} MB)';
            return false;
          }
          return true;
        }
      }
    ];
    memoryFloors = new Map<String, Float>();
    var weeks:Array<String> = ["tutorial", "week1", "week2", "week3", "week4", "week5", "week6", "week7", "weekend1", "sserafim"];
    for (round in 1...(rounds + 1))
    {
      for (week in weeks)
      {
        steps.push(
          {
            name: 'Round $round: Story Mode $week complete',
            covers: "Memory budget",
            timeout: 400,
            enter: () -> {
              NXLargeHeap.describe(true); // new peak window for this week
              launchStory(week);
            },
            poll: () -> glChecked(() -> playStoryWeek(week, round))
          });
        steps.push(
          {
            name: 'Round $round: memory budget of $week',
            covers: "Memory budget",
            timeout: 30,
            enter: () -> {},
            poll: () -> budgetCheckpoint(week, round)
          });
      }
    }
    steps.push(
      {
        name: "Each round vs the previous one: no memory growth at the end of the round",
        covers: "GC / purge leaks",
        timeout: 5,
        enter: () -> {},
        poll: () -> compareRounds(150.0, "sserafim", rounds)
      });
    results = [];
    index = -1;
    running = true;
    drainGlErrors();
    pendingGlOom = false;
    uploadOomBaseline = NXTextureUpload.outOfMemory;
    trace('[AUTOTEST] MEMORY_BUDGET: ${steps.length} steps');
    NXDeepTrace.writeEntry('MEMORY', '[BUDGET] start: ${NXPerformance.describeHeap()}');
    nextStep();
  }

  static function budgetCheckpoint(week:String, round:Int):Null<Bool>
  {
    if (!Std.isOfType(FlxG.state, StoryMenuState) || now() - mark < 3.0) return null;
    // The week window first (peak and largest request since the week started), then the state left behind.
    NXDeepTrace.writeEntry('MEMORY', '[BUDGET] R$round $week: ${NXLargeHeap.describe(false)} | after: ${NXPerformance.describeHeap()}');
    return memoryCheckpoint('R$round-$week', round);
  }

  /**
   * AUDIO_STARVE: reproduces on purpose the hardware failure where the whole audio stack stops
   * (INC-43). Holds the SDL audio device lock from the main thread so the audio thread misses its
   * deadline (as a long hitch does on the console) and checks that the mixer and the song recover.
   */
  public static function startAudioStarve():Void
  {
    steps = [
      {
        name: "Spaghetti (Freeplay, Hard) playing",
        covers: "Setup",
        timeout: 120,
        enter: () -> {
          PlayStatePlaylist.isStoryMode = false;
          var song:Song = SongRegistry.instance.fetchEntry("spaghetti", {variation: Constants.DEFAULT_VARIATION});
          LoadingState.loadPlayState({targetSong: song, targetDifficulty: "hard", targetVariation: "default"}, true);
        },
        poll: () -> waitSongPlaying("spaghetti", 3.0)
      },
      {
        name: "Audio baseline",
        covers: "INC-43",
        timeout: 20,
        enter: () -> resetHealthSampler(),
        poll: () -> captureBaselineWhenHealthy()
      }
    ];
    for (ms in [300, 1000])
    {
      steps.push(
        {
          name: 'SDL audio thread starved for ${ms}ms: mixer and song recover',
          covers: "INC-43",
          timeout: 15,
          enter: () -> {
            var id:Int = NXAudioNative.starveAudioThread(ms);
            trace('[AUTOTEST] Starved SDL audio device $id for ${ms}ms (clock ${Math.round(NXAudioNative.deviceClockMs())}ms)');
            resetHealthSampler();
          },
          poll: () -> {
            if (now() - stepStart < 2.0) return null;
            if (NXAudioDiagnostics.isMixerStalled())
            {
              failReason = 'OpenAL mixer stopped (device clock frozen, sdl ${NXAudioNative.sdlAudioStatus()})';
              return null;
            }
            if (pollAudioHealthy()) return true;
            failReason = lastHealthIssue;
            return null;
          }
        });
    }
    results = [];
    index = -1;
    running = true;
    trace('[AUTOTEST] AUDIO_STARVE: ${steps.length} steps');
    nextStep();
  }

  /**
   * AUDIO_DRIVER_STALL[_LEGACY]: A/B test of the SDL Switch audio driver (INC-43). Makes the SDL audio
   * thread sleep right after queuing a buffer, as a descheduled thread does on the console.
   * Legacy (original SDL PlayDevice): the mixer must die for good, reproducing the hardware bug.
   * Fixed driver (NXAudioDriver): the mixer and the song must recover after every delay.
   */
  public static function startAudioDriverStall(legacy:Bool):Void
  {
    steps = [
      {
        name: "Spaghetti (Freeplay, Hard) playing",
        covers: "Setup",
        timeout: 120,
        enter: () -> {
          PlayStatePlaylist.isStoryMode = false;
          var song:Song = SongRegistry.instance.fetchEntry("spaghetti", {variation: Constants.DEFAULT_VARIATION});
          LoadingState.loadPlayState({targetSong: song, targetDifficulty: "hard", targetVariation: "default"}, true);
        },
        poll: () -> waitSongPlaying("spaghetti", 3.0)
      },
      {
        name: "Audio baseline (replacement driver active)",
        covers: "INC-43",
        timeout: 20,
        enter: () -> resetHealthSampler(),
        poll: () -> {
          if (!NXAudioDriver.isActive())
          {
            failReason = 'SDL is not using NXAudioDriver (${NXAudioDriver.stats()})';
            return null;
          }
          return captureBaselineWhenHealthy();
        }
      }
    ];
    if (legacy)
    {
      steps.push(
        {
          name: "Original SDL driver + 80 ms audio thread delay: mixer dies for good (INC-43 reproduced)",
          covers: "INC-43",
          timeout: 15,
          enter: () -> {
            NXAudioDriver.setLegacyMode(true);
            NXAudioDriver.injectThreadDelay(80);
            trace('[AUTOTEST] Legacy driver, injected 80ms delay. ${NXAudioDriver.stats()}');
          },
          poll: () -> {
            if (now() - stepStart < 5.0) return null;
            trace('[AUTOTEST] After 5s: mixer ${NXAudioDiagnostics.isMixerStalled() ? "STOPPED" : "running"}, ${NXAudioDriver.stats()}');
            if (NXAudioDiagnostics.isMixerStalled()) return true;
            failReason = 'the original driver survived the delay (${NXAudioDriver.stats()})';
            return false;
          }
        });
    }
    else
    {
      for (ms in [80, 250, 1200])
      {
        steps.push(
          {
            name: 'Fixed driver + ${ms} ms audio thread delay: mixer and song recover',
            covers: "INC-43",
            timeout: 15,
            enter: () -> {
              NXAudioDriver.injectThreadDelay(ms);
              trace('[AUTOTEST] Injected ${ms}ms delay. ${NXAudioDriver.stats()}');
              resetHealthSampler();
            },
            poll: () -> {
              if (now() - stepStart < 2.5) return null;
              if (NXAudioDiagnostics.isMixerStalled())
              {
                failReason = 'OpenAL mixer stopped (${NXAudioDriver.stats()})';
                return null;
              }
              if (pollAudioHealthy())
              {
                trace('[AUTOTEST] Recovered. ${NXAudioDriver.stats()}');
                return true;
              }
              failReason = lastHealthIssue;
              return null;
            }
          });
      }
    }
    results = [];
    index = -1;
    running = true;
    trace('[AUTOTEST] AUDIO_DRIVER_STALL${legacy ? "_LEGACY" : ""}: ${steps.length} steps');
    nextStep();
  }

  /**
   * Songs and cutscenes run to their natural end (PLAYTHROUGH) instead of 2-3 s each.
   */
  static var fullLength:Bool = false;

  /**
   * MEMORY_BUDGET only: dialogues (Week 6) are skipped after 2 s instead of waiting for button presses.
   */
  static var skipConversations:Bool = false;

  static var conversationMark:Float = -1.0;

  /**
   * PLAYTHROUGH (L+R held 3 s on a test build, or autotest.cfg): a real session played to the end with
   * botplay: Story Mode Weekend 1, Week 7 and LE SSERAFIM, then Freeplay with Pico (2Hot) and with
   * Boyfriend (Spaghetti). Logs memory and heap state after each part, to reproduce long-session crashes.
   */
  public static function startPlaythrough():Void
  {
    captureSongFrames = true;
    fullLength = true;
    steps = [];
    for (week in ["weekend1", "week7", "sserafim"])
    {
      steps.push(
        {
          name: 'Story Mode $week played to the end',
          covers: "Playthrough",
          timeout: 1800,
          enter: () -> launchStory(week),
          poll: () -> playStoryWeek(week, 1)
        });
      steps.push(
        {
          name: 'Memory after $week',
          covers: "Memory",
          timeout: 20,
          enter: () -> {},
          poll: () -> logCheckpoint('after $week')
        });
    }
    steps.push(
      {
        name: "Freeplay -> Character Select -> Pico",
        covers: "Playthrough",
        timeout: 120,
        enter: () -> {},
        poll: () -> menusToCharSelectToFreeplay()
      });
    steps.push(
      {
        name: "Freeplay (Pico): 2Hot played to the end",
        covers: "Playthrough",
        timeout: 600,
        enter: () -> {},
        poll: () -> freeplayPlaySong("2hot")
      });
    steps.push(
      {
        name: "Memory after 2Hot (Pico)",
        covers: "Memory",
        timeout: 20,
        enter: () -> {},
        poll: () -> logCheckpoint('after 2hot')
      });
    steps.push(
      {
        name: "Character Select -> Boyfriend",
        covers: "Playthrough",
        timeout: 120,
        enter: () -> {},
        poll: () -> freeplayCharSelect("bf")
      });
    steps.push(
      {
        name: "Freeplay (Boyfriend): Spaghetti played to the end",
        covers: "Playthrough",
        timeout: 600,
        enter: () -> {},
        poll: () -> freeplayPlaySong("spaghetti")
      });
    steps.push(
      {
        name: "Memory at the end",
        covers: "Memory",
        timeout: 20,
        enter: () -> {},
        poll: () -> logCheckpoint('end')
      });
    results = [];
    index = -1;
    running = true;
    trace('[AUTOTEST] PLAYTHROUGH: ${steps.length} steps');
    NXDeepTrace.logMemorySnapshot('PLAYTHROUGH BASELINE', false);
    NXDeepTrace.writeEntry('MEMORY', '[HEAP] start: ${NXPerformance.describeHeap()}');
    nextStep();
  }

  /**
   * CUTSCENE_SKIP: every kind of cutscene handled exactly like upstream, with real SDL button presses:
   * - Video cutscenes (Weekend 1, Week 7): A does nothing; + opens the pause menu, "Restart Cutscene" plays it
   *   again from the start, "Skip Cutscene" skips it.
   * - "Restart Cutscene" on a later sheet of Ugh: sheet 0 comes back from the prefetch thread, and again with every
   *   prefetch declined (loaded on the main thread).
   * - Spaghetti's in-engine cutscene: the first A shows "Skip [ A ]", the second A skips it.
   * - Week 6 dialogue: A completes the line, A again shows the next one; + opens "Skip Dialogue".
   */
  public static function startCutsceneSkip():Void
  {
    captureSongFrames = true;
    fullLength = false;
    steps = [];
    for (entry in [["weekend1", "darnell"], ["week7", "ugh"]])
    {
      var week:String = entry[0];
      var song:String = entry[1];
      steps.push(
        {
          name: 'Story Mode $week: video cutscene (A ignored, + -> Restart Cutscene -> Skip Cutscene)',
          covers: "Cutscene skip",
          timeout: 150,
          enter: () -> launchStory(week),
          poll: () -> videoCutscenePauseMenu(song)
        });
      steps.push(
        {
          name: 'Pause -> exit to the Story menu',
          covers: "Setup",
          timeout: 40,
          enter: () -> {},
          poll: () -> pauseAndQuitToMenu(StoryMenuState)
        });
    }
    steps.push(
      {
        name: "Story Mode week7: Restart Cutscene on a later sheet, from the prefetch thread and with no room for a prefetch",
        covers: "Cutscene skip",
        timeout: 150,
        enter: () -> launchStory("week7"),
        poll: () -> videoRestartLaterSheet("ugh")
      });
    steps.push(
      {
        name: 'Pause -> exit to the Story menu',
        covers: "Setup",
        timeout: 40,
        enter: () -> {
          NXVideoPlayer.testDeclinePrefetch = false;
        },
        poll: () -> pauseAndQuitToMenu(StoryMenuState)
      });
    steps.push(
      {
        name: "Story Mode Week 6: dialogue (A completes / advances, + -> Skip Dialogue)",
        covers: "Cutscene skip",
        timeout: 150,
        enter: () -> launchStory("week6"),
        poll: () -> dialogueWithButtons()
      });
    steps.push(
      {
        name: 'Pause -> exit to the Story menu',
        covers: "Setup",
        timeout: 40,
        enter: () -> {},
        poll: () -> pauseAndQuitToMenu(StoryMenuState)
      });
    steps.push(
      {
        name: "Story Mode LE SSERAFIM: Spaghetti cutscene shows \"Skip [ A ]\" and A skips it",
        covers: "Cutscene skip",
        timeout: 120,
        enter: () -> launchStory("sserafim"),
        poll: () -> skipSpaghettiCutsceneWithA()
      });
    results = [];
    index = -1;
    running = true;
    trace('[AUTOTEST] CUTSCENE_SKIP: ${steps.length} steps');
    nextStep();
  }

  /**
   * Moves the pause menu cursor onto `text` with the D-pad and presses A. Returns true once A was pressed.
   */
  static function choosePauseEntry(text:String):Null<Bool>
  {
    var pause = findPauseSubState();
    if (pause == null) return null;
    if (now() - mark < 0.4) return null;
    var entries:Array<Dynamic> = @:privateAccess pause.currentMenuEntries;
    var target:Int = -1;
    for (i in 0...entries.length)
      if (entries[i].text == text) target = i;
    if (target < 0)
    {
      failReason = 'pause menu has no "$text" entry (${[for (e in entries) e.text].join(", ")})';
      return false;
    }
    var current:Int = @:privateAccess pause.currentEntry;
    mark = now();
    if (current != target)
    {
      NXInputInject.tap(current < target ? NXInputInject.SWITCH_DPAD_DOWN : NXInputInject.SWITCH_DPAD_UP);
      return null;
    }
    trace('[AUTOTEST] Pause menu: A on "$text"');
    NXInputInject.tap(NXInputInject.SWITCH_A);
    return true;
  }

  static var videoSheetAtPause:Int = -1;

  static function videoCutscenePauseMenu(songId:String):Null<Bool>
  {
    switch (phase)
    {
      case 0:
        if (songIs(songId) && NXVideoPlayer.isCutscenePlaying())
        {
          phase = 1;
          mark = now();
        }
        failReason = 'waiting for the $songId video cutscene (${describeState()})';
      case 1:
        // Upstream: A does nothing during a video cutscene.
        if (now() - mark >= 2.0)
        {
          if (!NXInputInject.tap(NXInputInject.SWITCH_A))
          {
            failReason = 'no controller connected';
            return false;
          }
          phase = 2;
          mark = now();
        }
      case 2:
        if (now() - mark >= 1.0)
        {
          if (!NXVideoPlayer.isCutscenePlaying() || findPauseSubState() != null)
          {
            failReason = 'A changed the video cutscene (upstream ignores A there)';
            return false;
          }
          trace('[AUTOTEST] A ignored during the $songId video, as upstream. Pressing +');
          NXInputInject.tap(NXInputInject.SWITCH_PLUS);
          phase = 3;
          mark = now();
        }
      case 3:
        var pause = findPauseSubState();
        if (pause != null && now() - mark >= 1.5)
        {
          var mode:String = Std.string(@:privateAccess pause.currentMode);
          var audioTime:Float = @:privateAccess NXVideoPlayer.currentAudio?.time ?? -1;
          videoSheetAtPause = Math.round(audioTime);
          trace('[AUTOTEST] Pause menu open (mode $mode), video audio at ${Math.round(audioTime)}ms');
          if (mode != "Cutscene")
          {
            failReason = 'pause menu opened in mode $mode instead of Cutscene';
            return false;
          }
          phase = 4;
          mark = now();
        }
        else if (pause == null && now() - mark > 2.0)
        {
          failReason = '+ did not open the pause menu during the video';
          return false;
        }
      case 4:
        // Frozen while paused.
        if (now() - mark >= 1.0)
        {
          var audioTime:Float = @:privateAccess NXVideoPlayer.currentAudio?.time ?? -1;
          if (Math.abs(audioTime - videoSheetAtPause) > 50 || !@:privateAccess NXVideoPlayer.isPaused)
          {
            failReason = 'the video kept running behind the pause menu (${videoSheetAtPause}ms -> ${Math.round(audioTime)}ms)';
            return false;
          }
          phase = 5;
          mark = now();
        }
      case 5:
        var chosen = choosePauseEntry("Restart Cutscene");
        if (chosen == false) return false;
        if (chosen == true)
        {
          phase = 6;
          mark = now();
        }
      case 6:
        if (now() - mark >= 1.5)
        {
          var audioTime:Float = @:privateAccess NXVideoPlayer.currentAudio?.time ?? -1;
          trace('[AUTOTEST] After Restart Cutscene: playing=${NXVideoPlayer.isCutscenePlaying()} audio=${Math.round(audioTime)}ms pause=${findPauseSubState() != null}');
          if (!NXVideoPlayer.isCutscenePlaying() || findPauseSubState() != null || audioTime < 0 || audioTime > 2500)
          {
            failReason = 'Restart Cutscene did not restart the video from the beginning (audio ${Math.round(audioTime)}ms)';
            return false;
          }
          NXInputInject.tap(NXInputInject.SWITCH_PLUS);
          phase = 7;
          mark = now();
        }
      case 7:
        if (findPauseSubState() != null && now() - mark >= 1.0)
        {
          phase = 8;
          mark = now();
        }
      case 8:
        var chosen = choosePauseEntry("Skip Cutscene");
        if (chosen == false) return false;
        if (chosen == true)
        {
          phase = 9;
          mark = now();
        }
      case 9:
        if (songPlaying())
        {
          trace('[AUTOTEST] Skip Cutscene: $songId playing ${Math.round((now() - mark) * 10) / 10}s later');
          return true;
        }
        if (now() - mark > 15.0)
        {
          failReason = 'Skip Cutscene did not start $songId (${describeState()})';
          return false;
        }
    }
    return null;
  }

  static var restartLoadsBefore:Int = 0;

  /**
   * "Restart Cutscene" pressed on a later sheet, twice. First sheet 0 comes back from the prefetch thread; then,
   * with every prefetch declined (as on a tight heap), it must be loaded on the main thread instead of leaving the
   * video frozen behind a closed pause menu (latent in Build 29). Ends with "Skip Cutscene".
   */
  static function videoRestartLaterSheet(songId:String):Null<Bool>
  {
    var result:Null<Bool> = videoRestartLaterSheetPoll(songId);
    if (result != null) NXVideoPlayer.testDeclinePrefetch = false;
    return result;
  }

  static function videoRestartLaterSheetPoll(songId:String):Null<Bool>
  {
    switch (phase)
    {
      case 0:
        if (songIs(songId) && NXVideoPlayer.isCutscenePlaying()) phase = 1;
        failReason = 'waiting for the $songId video cutscene (${describeState()})';
      case 1, 6:
        if (NXVideoPlayer.isCutscenePlaying() && NXVideoPlayer.sheetCount() < 2)
        {
          failReason = 'the $songId video has a single sheet; this step needs a later one';
          return false;
        }
        failReason = 'the $songId video never reached a later sheet (sheet ${NXVideoPlayer.sheetIndex()} of ${NXVideoPlayer.sheetCount()})';
        if (NXVideoPlayer.isCutscenePlaying() && NXVideoPlayer.sheetIndex() >= 1)
        {
          if (phase == 6)
          {
            NXVideoPlayer.testDeclinePrefetch = true;
            restartLoadsBefore = NXVideoPlayer.restartMainThreadLoads;
          }
          trace('[AUTOTEST] $songId video on sheet ${NXVideoPlayer.sheetIndex()} of ${NXVideoPlayer.sheetCount()}'
            + (phase == 6 ? ', every prefetch declined from now on' : '') + '. Pressing +');
          NXInputInject.tap(NXInputInject.SWITCH_PLUS);
          phase++;
          mark = now();
        }
      case 2, 7, 11:
        var pause = findPauseSubState();
        if (pause != null && now() - mark >= 1.0)
        {
          phase++;
          mark = now();
        }
        else if (pause == null && now() - mark > 2.0)
        {
          failReason = '+ did not open the pause menu during the video';
          return false;
        }
      case 3, 8:
        var chosen = choosePauseEntry("Restart Cutscene");
        if (chosen == false) return false;
        if (chosen == true)
        {
          phase++;
          mark = now();
        }
      case 4, 9:
        var audioTime:Float = @:privateAccess NXVideoPlayer.currentAudio?.time ?? -1;
        var pending:Bool = @:privateAccess NXVideoPlayer.restartPending;
        var back:Bool = NXVideoPlayer.isCutscenePlaying() && findPauseSubState() == null && NXVideoPlayer.sheetIndex() == 0 && !pending
          && audioTime >= 0 && audioTime <= 2500;
        if (back)
        {
          var direct:Int = NXVideoPlayer.restartMainThreadLoads - restartLoadsBefore;
          trace('[AUTOTEST] Restart Cutscene: sheet 0 playing again ${Math.round((now() - mark) * 10) / 10}s later, audio ${Math.round(audioTime)}ms'
            + (phase == 9 ? ', loaded on the main thread $direct time(s)' : ' (from the prefetch thread)'));
          if (phase == 4)
          {
            phase = 6;
            mark = now();
          }
          else
          {
            if (direct < 1)
            {
              failReason = 'with every prefetch declined, sheet 0 came back without the main-thread load';
              return false;
            }
            NXVideoPlayer.testDeclinePrefetch = false;
            phase = 10;
            mark = now();
          }
        }
        else if (now() - mark > 10.0)
        {
          failReason = 'Restart Cutscene on a later sheet left the video stuck (sheet ${NXVideoPlayer.sheetIndex()}, audio ${Math.round(audioTime)}ms, '
            + 'restart pending $pending, prefetch declined ${NXVideoPlayer.testDeclinePrefetch})';
          return false;
        }
      case 10:
        // Same settle time as the first video step before + reopens the pause menu.
        if (now() - mark >= 1.5)
        {
          NXInputInject.tap(NXInputInject.SWITCH_PLUS);
          phase = 11;
          mark = now();
        }
      case 12:
        var chosen = choosePauseEntry("Skip Cutscene");
        if (chosen == false) return false;
        if (chosen == true)
        {
          phase = 13;
          mark = now();
        }
      case 13:
        if (songPlaying())
        {
          trace('[AUTOTEST] Skip Cutscene: $songId playing ${Math.round((now() - mark) * 10) / 10}s later');
          return true;
        }
        if (now() - mark > 15.0)
        {
          failReason = 'Skip Cutscene did not start $songId (${describeState()})';
          return false;
        }
    }
    return null;
  }

  static var dialogueLineSeen:String = "";

  static function dialogueWithButtons():Null<Bool>
  {
    var ps = PlayState.instance;
    var conv = (ps != null) ? ps.currentConversation : null;
    switch (phase)
    {
      case 0:
        if (conv != null && Std.string(@:privateAccess conv.state) == "Speaking")
        {
          phase = 1;
          mark = now();
        }
        failReason = 'waiting for the Week 6 dialogue (${describeState()})';
      case 1:
        if (now() - mark >= 2.0)
        {
          dialogueLineSeen = '${@:privateAccess conv.currentDialogueEntry}:${@:privateAccess conv.currentDialogueLine}';
          NXInputInject.tap(NXInputInject.SWITCH_A);
          trace('[AUTOTEST] Dialogue: A at entry $dialogueLineSeen (state ${@:privateAccess conv.state})');
          phase = 2;
          mark = now();
        }
      case 2:
        if (now() - mark >= 0.8)
        {
          NXInputInject.tap(NXInputInject.SWITCH_A);
          phase = 3;
          mark = now();
        }
      case 3:
        if (now() - mark >= 1.0)
        {
          var nowAt:String = '${@:privateAccess conv.currentDialogueEntry}:${@:privateAccess conv.currentDialogueLine}';
          trace('[AUTOTEST] Dialogue: after two A presses entry $dialogueLineSeen -> $nowAt (state ${@:privateAccess conv.state})');
          if (nowAt == dialogueLineSeen)
          {
            failReason = 'A did not advance the dialogue (still at $nowAt)';
            return false;
          }
          NXInputInject.tap(NXInputInject.SWITCH_PLUS);
          phase = 4;
          mark = now();
        }
      case 4:
        var pause = findPauseSubState();
        if (pause != null && now() - mark >= 1.0)
        {
          var mode:String = Std.string(@:privateAccess pause.currentMode);
          if (mode != "Conversation")
          {
            failReason = 'pause menu opened in mode $mode instead of Conversation';
            return false;
          }
          phase = 5;
          mark = now();
        }
        else if (pause == null && now() - mark > 2.0)
        {
          failReason = '+ did not open the pause menu during the dialogue';
          return false;
        }
      case 5:
        var chosen = choosePauseEntry("Skip Dialogue");
        if (chosen == false) return false;
        if (chosen == true)
        {
          phase = 6;
          mark = now();
        }
      case 6:
        if (songPlaying()) return true;
        if (now() - mark > 15.0)
        {
          failReason = 'Skip Dialogue did not start the song (${describeState()})';
          return false;
        }
    }
    return null;
  }

  /**
   * INC49_REPRO: replays the console session that crashed in INC-49 (Build 22, log 12:04-12:18): Story LE SSERAFIM
   * three times picked from the Story menu (cutscene watched in runs 1-2, skipped with A in run 3; Results held
   * so that END_SONG -> next state takes ~8.4 / 4.2 / 75.4 s like the console; four HOME/Sleep suspensions of
   * 7.6/8/16/19.2 s at music 144.2/148.9/158.8/161.6 s in run 3), then Story Week 7, whose Ugh PlayState.create
   * decodes gfTankmen.png (128 MiB). The console heap (~3110 MB) is applied here, so Citron replays the same ceiling.
   */
  public static function startInc49Repro():Void
  {
    fullLength = true;
    captureSongFrames = false;
    NXDeepTrace.writeEntry('MEMORY', '[HEAP] INC49_REPRO ${NXPerformance.capHeap(INC49_HEAP_CAP_MB)}');
    steps = [
      {
        name: "Console heap ceiling applied",
        covers: "Setup",
        timeout: 5,
        enter: () -> {},
        poll: () -> {
          var mb:Float = NXPerformance.getHeapTotalMB();
          if (mb > INC49_HEAP_CAP_MB + 1)
          {
            failReason = 'heap is ${Math.round(mb)} MB, the replay needs the console ceiling (${INC49_HEAP_CAP_MB} MB)';
            return false;
          }
          return true;
        }
      }
    ];
    var holds:Array<Float> = [6.2, 2.0, 73.2];
    for (run in 1...4)
    {
      steps.push(
        {
          name: 'Story Mode LE SSERAFIM run $run${run == 3 ? " (cutscene skipped, 4 suspensions)" : ""}',
          covers: "INC-49 replay",
          timeout: 900,
          enter: () -> {
            suspendIndex = 0;
            skipTaps = 0;
            cutsceneSeenAt = -1.0;
            introSongStarted = false;
            launchStoryLikePlayer("sserafim");
          },
          poll: () -> glChecked(() -> (run == 3) ? playSpaghettiWithSuspends(holds[2]) : playStoryWeek("sserafim", run, holds[run - 1]))
        });
      steps.push(
        {
          name: 'Memory after LE SSERAFIM run $run',
          covers: "Memory",
          timeout: 20,
          enter: () -> {},
          poll: () -> glChecked(() -> logCheckpoint('after spaghetti $run'))
        });
    }
    steps.push(
      {
        name: "Story Mode Week 7: Ugh loads (INC-49 crash site), its cutscene plays to the end, the song plays with no GL out-of-memory",
        covers: "INC-49",
        timeout: 600,
        enter: () -> {
          drainGlErrors();
          videoSeen = false;
          videoSheetMax = -1;
          videoSheetCount = 0;
          launchStoryLikePlayer("week7");
        },
        poll: () -> glChecked(() -> waitSongPlaying("ugh", 10.0, true, true))
      });
    steps.push(
      {
        name: "Memory with Ugh playing",
        covers: "Memory",
        timeout: 20,
        enter: () -> {},
        poll: () -> glChecked(() -> logCheckpoint('ugh playing'))
      });
    steps.push(
      {
        name: "Pause -> exit Week 7 to the Story menu",
        covers: "Setup",
        timeout: 40,
        enter: () -> {},
        poll: () -> glChecked(() -> pauseAndQuitToMenu(StoryMenuState))
      });
    steps.push(
      {
        name: "Story Mode Week 2: Spookeez loads (halloween_bg, a 256 MiB image before 0.8.3, now an Animate atlas) and plays with no GL out-of-memory",
        covers: "INC-49",
        timeout: 300,
        enter: () -> {
          drainGlErrors();
          launchStoryLikePlayer("week2");
        },
        poll: () -> glChecked(() -> waitSongPlaying("spookeez", 10.0, true))
      });
    steps.push(
      {
        name: "Memory with Spookeez playing",
        covers: "Memory",
        timeout: 20,
        enter: () -> {},
        poll: () -> glChecked(() -> logCheckpoint('spookeez playing'))
      });
    results = [];
    index = -1;
    running = true;
    // One baseline for the whole replay: a GL_OUT_OF_MEMORY in any step after this point fails it.
    drainGlErrors();
    pendingGlOom = false;
    uploadOomBaseline = NXTextureUpload.outOfMemory;
    trace('[AUTOTEST] INC49_REPRO: ${steps.length} steps');
    NXDeepTrace.writeEntry('MEMORY', '[HEAP] INC49_REPRO start: ${NXPerformance.describeHeap()} | decode ${NXImageDecode.describe()} | release ${NXTextureMemory.describe()} | upload ${NXTextureUpload.describe()}');
    nextStep();
  }

  static inline final INC49_HEAP_CAP_MB:Int = 3110;
  static inline final GL_OUT_OF_MEMORY:Int = 0x0505;

  /**
   * GL errors are sticky: read and log them before a step so only the step's own errors count.
   */
  static var seenGlErrors:Array<Int> = [];

  /**
   * NXTextureUpload.outOfMemory when the replay started: any increase fails it, whichever step it happens in.
   */
  static var uploadOomBaseline:Int = 0;

  /**
   * A GL_OUT_OF_MEMORY read between steps (drainGlErrors): the next glChecked poll fails.
   */
  static var pendingGlOom:Bool = false;

  static var videoSeen:Bool = false;
  static var videoSheetMax:Int = -1;
  static var videoSheetCount:Int = 0;

  static function drainGlErrors():Void
  {
    seenGlErrors = [];
    for (i in 0...16)
    {
      var err:Int = lime.graphics.opengl.GL.getError();
      if (err == 0) break;
      if (err == GL_OUT_OF_MEMORY) pendingGlOom = true;
      trace('[AUTOTEST] GL error before step: 0x${StringTools.hex(err)}');
    }
  }

  /**
   * Wraps a poll so it fails on GL_OUT_OF_MEMORY: a texture or GPU buffer that cannot be allocated does not crash,
   * it just draws nothing, so a memory problem would otherwise pass unnoticed.
   */
  static function glChecked(poll:Void->Null<Bool>):Null<Bool>
  {
    var err:Int = lime.graphics.opengl.GL.getError();
    if (err == GL_OUT_OF_MEMORY) pendingGlOom = true;
    // Uploads read the error themselves (a recurring error elsewhere in the frame would hide it from this poll).
    var uploadOom:Int = NXTextureUpload.outOfMemory - uploadOomBaseline;
    if (pendingGlOom || uploadOom > 0)
    {
      var where:String = uploadOom > 0 ? ' ($uploadOom during texture uploads)' : '';
      NXDeepTrace.writeEntry('MEMORY', '[HEAP] GL_OUT_OF_MEMORY in ${currentSongId()}$where: ${NXPerformance.describeHeap()}');
      failReason = 'GL_OUT_OF_MEMORY while loading/playing ${currentSongId()} (a texture or GPU buffer did not fit)';
      return false;
    }
    if (err != 0 && seenGlErrors.indexOf(err) == -1)
    {
      // Not a memory error (e.g. a recurring GL_INVALID_ENUM): log it once per step.
      seenGlErrors.push(err);
      trace('[AUTOTEST] GL error 0x${StringTools.hex(err)} in ${currentSongId()} (logged once)');
    }
    return poll();
  }
  // Music positions of the four suspensions in the console log ([PAUSE] lines 552/758/1064/1169).
  static final SUSPEND_AT_MUSIC_MS:Array<Float> = [144219, 148886, 158847, 161586];
  static final SUSPEND_SECONDS:Array<Float> = [7.6, 8.0, 16.0, 19.2];
  static var suspendIndex:Int = 0;
  static var skipTaps:Int = 0;
  static var cutsceneSeenAt:Float = -1.0;
  static var skipGameTime:Float = 0.0;
  static var introSongStarted:Bool = false;
  static var pauseSeenAt:Float = -1.0;

  /**
   * Third Spaghetti of INC49_REPRO: skip the cutscene like the console (A ~3.9 s in, A again once the prompt is
   * fully shown), suspend four times at the logged music positions, resume ~1 s after each pause menu opens, then
   * finish the week through the normal driver.
   */
  static function playSpaghettiWithSuspends(resultsHold:Float):Null<Bool>
  {
    var ps = PlayState.instance;
    var pause = findPauseSubState();
    if (pause != null)
    {
      if (pauseSeenAt < 0) pauseSeenAt = now();
      if (now() - pauseSeenAt > 1.0)
      {
        trace('[AUTOTEST] Resuming after suspension ${suspendIndex}');
        @:privateAccess PauseSubState.resume(pause);
        pauseSeenAt = -1.0;
      }
      failReason = 'pause menu after a suspension';
      return null;
    }
    pauseSeenAt = -1.0;
    if (ps != null && songIs("spaghetti"))
    {
      // Only the intro cutscene is skipped: Spaghetti also has an ending cutscene ("See you") the console watched.
      if (songPlaying()) introSongStarted = true;
      if (ps.isInCutscene && !introSongStarted)
      {
        if (cutsceneSeenAt < 0) cutsceneSeenAt = now();
        if (skipTaps == 0 && now() - cutsceneSeenAt >= 3.9)
        {
          if (!NXInputInject.tap(NXInputInject.SWITCH_A))
          {
            failReason = 'no controller connected to skip the cutscene';
            return false;
          }
          skipTaps = 1;
          skipGameTime = 0.0;
          trace('[AUTOTEST] Cutscene skip: first A');
        }
        else if (skipTaps >= 1)
        {
          skipGameTime += FlxG.elapsed;
          var prompt = findSkipText();
          var promptShown:Bool = prompt != null && prompt.alpha >= 0.999;
          // Second A once the prompt tween (0.5 s) has finished; retry every 2 s of game time if the cutscene goes on.
          // canSkipCutscene turns true 0.5 s after the first A (FlxTimer), when the prompt tween also ends.
          if ((skipTaps == 1 && promptShown && skipGameTime >= 0.65) || (skipTaps == 1 && skipGameTime >= 1.0)
            || (skipTaps >= 2 && skipGameTime >= 2.0))
          {
            if (skipTaps >= 4)
            {
              failReason = 'the Spaghetti cutscene did not end after ${skipTaps} A presses';
              return false;
            }
            NXInputInject.tap(NXInputInject.SWITCH_A);
            skipTaps++;
            skipGameTime = 0.0;
            trace('[AUTOTEST] Cutscene skip: A #$skipTaps');
          }
        }
      }
      var music = FlxG.sound.music;
      if (songPlaying() && music != null && suspendIndex < SUSPEND_AT_MUSIC_MS.length && music.time >= SUSPEND_AT_MUSIC_MS[suspendIndex])
      {
        var seconds:Float = SUSPEND_SECONDS[suspendIndex];
        trace('[AUTOTEST] Suspension ${suspendIndex + 1}: ${seconds}s at music ${Math.round(music.time)}ms');
        suspendIndex++;
        simulateFocusLoss(true);
        Sys.sleep(seconds);
        simulateFocusGain(true);
        return null;
      }
    }
    return playStoryWeek("sserafim", 3, resultsHold);
  }

  /**
   * Picks a level in the open Story menu like a player (cursor moved to it, difficulty Hard, selectLevel), so the
   * menu's own transition runs. Falls back to launching it directly when the menu is not open or the level is locked.
   */
  static function launchStoryLikePlayer(levelId:String):Void
  {
    @:privateAccess StoryMenuState.rememberedLevelId = levelId;
    @:privateAccess StoryMenuState.rememberedDifficulty = "hard";
    if (Std.isOfType(FlxG.state, StoryMenuState) && FlxG.state.subState == null)
    {
      var menu:StoryMenuState = cast FlxG.state;
      var levels:Array<String> = @:privateAccess menu.levelList;
      var target:Int = levels.indexOf(levelId);
      var current:Int = levels.indexOf(@:privateAccess menu.currentLevelId);
      var level = LevelRegistry.instance.fetchEntry(levelId);
      if (target >= 0 && current >= 0 && level != null && level.isUnlocked())
      {
        @:privateAccess menu.changeLevel(target - current);
        @:privateAccess menu.currentDifficultyId = "hard";
        trace('[AUTOTEST] Story menu: selecting $levelId (Hard) like a player');
        @:privateAccess menu.selectLevel();
        return;
      }
    }
    trace('[AUTOTEST] Story menu not usable for $levelId, launching it directly');
    launchStory(levelId);
  }

  /**
   * Logs memory and heap state (PLAYTHROUGH checkpoints never fail, they leave evidence in the log).
   */
  static function logCheckpoint(label:String):Null<Bool>
  {
    if (now() - mark < 2.0) return null;
    NXDeepTrace.logMemorySnapshot('PLAYTHROUGH $label', false);
    NXDeepTrace.writeEntry('MEMORY', '[HEAP] $label: ${NXPerformance.describeHeap()} | decode ${NXImageDecode.describe()} | release ${NXTextureMemory.describe()} | upload ${NXTextureUpload.describe()}');
    NXDeepTrace.writeEntry('MEMORY', '[CACHE] $label: ${NXTextureMemory.describeCache()}');
    return true;
  }

  static function findSkipText():Null<flixel.text.FlxText>
  {
    var ps = PlayState.instance;
    if (ps == null || ps.currentStage == null) return null;
    var found:Null<flixel.text.FlxText> = null;
    ps.currentStage.forEach(function(obj) {
      if (found == null && Std.isOfType(obj, flixel.text.FlxText))
      {
        var t:flixel.text.FlxText = cast obj;
        if (t.text != null && StringTools.startsWith(t.text, 'Skip')) found = t;
      }
    }, true);
    return found;
  }

  static function skipSpaghettiCutsceneWithA():Null<Bool>
  {
    var ps = PlayState.instance;
    switch (phase)
    {
      case 0:
        if (songIs("spaghetti") && ps.isInCutscene && findSkipText() != null)
        {
          phase = 1;
          mark = now();
        }
        failReason = 'waiting for the Spaghetti cutscene (${describeState()})';
      case 1:
        if (now() - mark >= 3.0)
        {
          if (!NXInputInject.tap(NXInputInject.SWITCH_A))
          {
            failReason = 'no gamepad connected to press A';
            return false;
          }
          trace('[AUTOTEST] First A in the Spaghetti cutscene');
          phase = 2;
          mark = now();
        }
      case 2:
        if (now() - mark >= 1.2)
        {
          var t = findSkipText();
          var cam = (t != null && t.cameras != null && t.cameras.length > 0) ? t.cameras[0] : null;
          var shown:Bool = t != null && t.visible && t.alpha > 0.9 && cam != null && cam.visible && cam.alpha > 0.9;
          trace('[AUTOTEST] Skip prompt: text="${t?.text}" alpha=${t?.alpha} visible=${t?.visible} camera visible=${cam?.visible}');
          if (!shown)
          {
            failReason = 'the skip prompt is not visible (text=${t?.text} alpha=${t?.alpha} camera visible=${cam?.visible})';
            return false;
          }
          if (t.text.indexOf('A') == -1)
          {
            failReason = 'the skip prompt does not name the A button: "${t.text}"';
            return false;
          }
          @:privateAccess NXAutoTest.requestFrameCapture('cutscene_skip_prompt');
          NXInputInject.tap(NXInputInject.SWITCH_A);
          trace('[AUTOTEST] Second A in the Spaghetti cutscene');
          phase = 3;
          mark = now();
        }
      case 3:
        if (songPlaying()) return true;
        if (now() - mark > 15.0)
        {
          failReason = 'the second A did not skip the Spaghetti cutscene (${describeState()})';
          return false;
        }
        failReason = 'waiting for Spaghetti to start after the skip';
    }
    return null;
  }

  /**
   * From Freeplay: plays `songId` (hard) with the current character to the end, accepts Results and waits
   * to be back in Freeplay.
   */
  static function freeplayPlaySong(songId:String):Null<Bool>
  {
    switch (phase)
    {
      case 0:
        var freeplay = findFreeplay();
        if (freeplay == null || @:privateAccess freeplay.grpCapsules.countLiving() == 0)
        {
          failReason = 'waiting for Freeplay (${describeSubStates()})';
          return null;
        }
        if (now() - mark < 2.0) return null;
        var target = null;
        @:privateAccess for (cap in freeplay.grpCapsules.members)
        {
          if (cap != null && cap.alive && cap.freeplayData != null && cap.freeplayData.data.id == songId) target = cap;
        }
        if (target == null)
        {
          trace('[AUTOTEST] WARN: $songId not listed in Freeplay, launching it directly.');
          PlayStatePlaylist.isStoryMode = false;
          var song:Song = SongRegistry.instance.fetchEntry(songId, {variation: Constants.DEFAULT_VARIATION});
          LoadingState.loadPlayState({targetSong: song, targetDifficulty: "hard", targetVariation: song.getFirstValidVariation("hard")}, true);
        }
        else
        {
          @:privateAccess freeplay.currentDifficulty = "hard";
          @:privateAccess freeplay.capsuleOnConfirmDefault(target);
        }
        phase = 1;
        mark = now();
      case 1:
        if (songIs(songId) && songPlaying())
        {
          trace('[AUTOTEST] Freeplay: $songId playing');
          phase = 2;
          mark = now();
        }
        failReason = 'waiting for $songId to play (${describeState()})';
      case 2:
        var results = findResults();
        if (results != null)
        {
          if (now() - mark > 1.5)
          {
            tapAccept();
            mark = now();
          }
          failReason = 'Results open, accepting';
          return null;
        }
        var freeplay = findFreeplay();
        var inSong:Bool = Std.isOfType(FlxG.state, PlayState);
        if (freeplay != null && !inSong && now() - mark > 3.0) return true;
        if (inSong) failReason = 'playing $songId to the end (${Math.round(Conductor.instance.songPosition / 1000)}s)';
    }
    return null;
  }

  /**
   * From Freeplay: R3 to Character Select, cursor onto `charId`, A, back in Freeplay with that character.
   */
  static function freeplayCharSelect(charId:String):Null<Bool>
  {
    var stateName:String = Type.getClassName(Type.getClass(FlxG.state));
    switch (phase)
    {
      case 0:
        var freeplay = findFreeplay();
        if (freeplay != null && @:privateAccess freeplay.grpCapsules.countLiving() > 0 && now() - mark > 3.0)
        {
          trace('[AUTOTEST] Freeplay: opening Character Select (R3)');
          @:privateAccess freeplay.tryOpenCharSelect();
          phase = 1;
          mark = now();
        }
      case 1:
        if (stateName == "funkin.ui.charSelect.CharSelectSubState" && now() - mark > 4.0)
        {
          var charSelect:funkin.ui.charSelect.CharSelectSubState = cast FlxG.state;
          var charIndex:Int = -1;
          @:privateAccess for (pos => id in charSelect.availableChars)
            if (id == charId) charIndex = pos;
          if (charIndex < 0)
          {
            failReason = '$charId is not available in Character Select';
            return false;
          }
          @:privateAccess charSelect.cursorX = (charIndex % 3) - 1;
          @:privateAccess charSelect.cursorY = Std.int(charIndex / 3) - 1;
          trace('[AUTOTEST] Character Select: cursor moved to $charId (grid $charIndex)');
          phase = 2;
          mark = now();
        }
      case 2:
        if (now() - mark > 1.0)
        {
          tapAccept();
          trace('[AUTOTEST] Character Select: pressing Accept on $charId');
          phase = 3;
          mark = now();
        }
      case 3:
        var freeplay = findFreeplay();
        if (freeplay != null && @:privateAccess freeplay.grpCapsules.countLiving() > 0 && now() - mark > 3.0)
        {
          var current:String = @:privateAccess freeplay.currentCharacterId;
          if (current != charId)
          {
            failReason = 'Freeplay opened with "$current" instead of $charId';
            return false;
          }
          return true;
        }
    }
    failReason = 'phase $phase, ${describeSubStates()}';
    return null;
  }

  static var peakNativeMb:Float = 0.0;

  public static function update():Void
  {
    if (!running || index < 0 || index >= steps.length) return;
    #if switch
    // Record every new native memory peak, so a crash log shows how high memory went before it.
    var native:Float = NXPerformance.getNativeHeapUsed();
    if (native > peakNativeMb + 50.0)
    {
      peakNativeMb = native;
      NXDeepTrace.writeEntry('MEMORY', '[PEAK] native ${Math.round(native)} MB, largest free block ${Math.round(NXPerformance.getLargestAllocatableMB())} MB at step ${index + 1} (${describeState()})');
    }
    #end
    var step = steps[index];
    var elapsed:Float = now() - stepStart;

    var result:Null<Bool> = null;
    try
    {
      result = step.poll();
    }
    catch (e:Dynamic)
    {
      failReason = 'Exception in poll: $e';
      result = false;
    }

    if (result == null && elapsed > step.timeout)
    {
      failReason = 'Timeout after ${Math.round(elapsed)}s. ' + failReason;
      result = false;
    }

    if (result == true)
    {
      var line:String = 'PASS  ${index + 1}. ${step.name} [${step.covers}] (${Math.round(elapsed * 10) / 10}s)';
      results.push(line);
      trace('[AUTOTEST] [STEP ${index + 1}/${steps.length}] [PASS] ${step.name} [${step.covers}] in ${Math.round(elapsed * 10) / 10}s');
      NXDeepTrace.logMemorySnapshot('REG after step ${index + 1}', false);
      nextStep();
    }
    else if (result == false)
    {
      results.push('FAIL  ${index + 1}. ${step.name} [${step.covers}] -> $failReason');
      trace('[AUTOTEST] [STEP ${index + 1}/${steps.length}] [FAIL] ${step.name} [${step.covers}]: $failReason');
      finish(false);
    }
  }

  static function nextStep():Void
  {
    index++;
    if (index >= steps.length)
    {
      finish(true);
      return;
    }
    var step = steps[index];
    stepStart = now();
    mark = now();
    phase = 0;
    counter = 0;
    failReason = "";
    trace('[AUTOTEST] [STEP ${index + 1}/${steps.length}] ${step.name} [${step.covers}]');
    if (NXAutoTest.startedOnConsole) NXDevOverlay.show('AUTO [${index + 1}/${steps.length}] ${step.name}');
    try
    {
      step.enter();
    }
    catch (e:Dynamic)
    {
      results.push('FAIL  ${index + 1}. ${step.name} -> Exception in enter: $e');
      trace('[AUTOTEST] [STEP ${index + 1}/${steps.length}] [FAIL] ${step.name}: Exception in enter: $e');
      finish(false);
    }
  }

  static function finish(success:Bool):Void
  {
    running = false;
    NXVideoPlayer.testDeclinePrefetch = false;
    trace('[AUTOTEST] ===== REGRESSION_SUITE SUMMARY =====');
    for (line in results)
      trace('[AUTOTEST] $line');
    for (i in results.length...steps.length)
      trace('[AUTOTEST] SKIP  ${i + 1}. ${steps[i].name} [${steps[i].covers}]');
    if (success) @:privateAccess NXAutoTest.passTest();
    else
      @:privateAccess NXAutoTest.failTest('REGRESSION_SUITE step ${index + 1} failed: $failReason');
  }

  // ---------------------------------------------------------------------------
  // Steps
  // ---------------------------------------------------------------------------

  static function buildSteps():Array<RegressionStep>
  {
    return [
      {
        name: "Story Mode Week 1 starts (Bopeebo, Hard)",
        covers: "Preview 3 Story Mode",
        timeout: 90,
        enter: () -> launchStory("week1"),
        poll: () -> waitSongPlaying("bopeebo", 3.0)
      },
      {
        name: "Pause -> Exit to menu from Week 1",
        covers: "INC-11, INC-18",
        timeout: 40,
        enter: () -> {},
        poll: () -> pauseAndQuitToMenu(StoryMenuState)
      },
      {
        name: "Story Mode Weekend 1: darnellCutscene + Darnell",
        covers: "INC-13, INC-23, INC-25, INC-26",
        timeout: 120,
        enter: () -> launchStory("weekend1"),
        poll: () -> playCutsceneThenSong("darnell", "darnellCutscene")
      },
      {
        name: "Weekend 1: Darnell -> Lit Up transition",
        covers: "INC-32",
        timeout: 90,
        enter: () -> endCurrentSong(),
        poll: () -> waitSongPlaying("lit-up", 3.0)
      },
      {
        name: "Weekend 1: Lit Up -> 2Hot transition (hardware crash point)",
        covers: "INC-32, INC-33",
        timeout: 90,
        enter: () -> endCurrentSong(),
        poll: () -> waitSongPlaying("2hot", 3.0)
      },
      {
        name: "Pause -> Exit to menu from 2Hot (heaviest stage)",
        covers: "INC-08, INC-11, INC-18",
        timeout: 40,
        enter: () -> {},
        poll: () -> pauseAndQuitToMenu(StoryMenuState)
      },
      {
        name: "Story menu after leaving Weekend 1: memory back to baseline",
        covers: "INC-08, INC-11",
        timeout: 10,
        enter: () -> {},
        poll: () -> checkMenuMemory(1100.0)
      },
      {
        name: "Story menu -> Main menu -> Freeplay -> Character Select (R3) -> Pico -> Freeplay",
        covers: "INC-14, INC-19, INC-21",
        timeout: 90,
        enter: () -> {},
        poll: () -> menusToCharSelectToFreeplay()
      },
      {
        name: "Freeplay (Pico) -> 2Hot, Sleep/Wake during countdown",
        covers: "INC-27, Build 15 Sleep/Wake",
        timeout: 90,
        enter: () -> {},
        poll: () -> freeplayTo2HotWithCountdownSleep()
      },
      {
        name: "2Hot gameplay healthy (audio baseline)",
        covers: "INC-04, INC-16",
        timeout: 20,
        enter: () -> resetHealthSampler(),
        poll: () -> captureBaselineWhenHealthy()
      },
      {
        name: "HOME button mid-song (focus lost 2s, Resume)",
        covers: "INC-31, Build 15 Sleep/Wake",
        timeout: 25,
        enter: () -> {},
        poll: () -> suspendAndResume(false, false, 2.0)
      },
      {
        name: "Sleep mid-song with OpenAL sources stopped by the system (3s)",
        covers: "INC-31, Build 16 onComplete",
        timeout: 30,
        enter: () -> {},
        poll: () -> suspendAndResume(true, true, 3.0)
      },
      {
        name: "OpenAL clock stall mid-song (source paused behind the engine)",
        covers: "INC-31 3-tier recovery",
        timeout: 20,
        enter: () -> {},
        poll: () -> openALStall()
      },
      {
        name: "GPU overload: 10 frame hitches of 120-450 ms",
        covers: "INC-16, INC-31",
        timeout: 30,
        enter: () -> {},
        poll: () -> frameHitches(10)
      },
      {
        name: "Pause/Resume spam x5",
        covers: "INC-16, INC-04",
        timeout: 40,
        enter: () -> {},
        poll: () -> pauseResumeSpam(5)
      },
      {
        name: "OpenAL stopped 2.5s before the end: song still completes and reaches Results",
        covers: "INC-09",
        timeout: 40,
        enter: () -> {},
        poll: () -> endOfSongWatchdog()
      },
      {
        name: "Results -> Freeplay -> 2Hot replay: stage visible, no black screen",
        covers: "INC-22, INC-27",
        timeout: 90,
        enter: () -> {},
        poll: () -> replay2HotStageVisible()
      },
    ];
  }

  // ---------------------------------------------------------------------------
  // Step implementations
  // ---------------------------------------------------------------------------

  static function launchStory(levelId:String):Void
  {
    var level = LevelRegistry.instance.fetchEntry(levelId);
    if (level == null) throw 'Level $levelId not found';
    Paths.setCurrentLevel(level.id);
    PlayStatePlaylist.playlistSongIds = level.getSongs();
    PlayStatePlaylist.isStoryMode = true;
    PlayStatePlaylist.campaignScore = 0;
    var targetSongId:String = PlayStatePlaylist.playlistSongIds.shift();
    var targetSong:Song = SongRegistry.instance.fetchEntry(targetSongId, {variation: Constants.DEFAULT_VARIATION});
    PlayStatePlaylist.campaignId = level.id;
    PlayStatePlaylist.campaignTitle = level.getTitle();
    PlayStatePlaylist.campaignDifficulty = "hard";
    funkin.Highscore.talliesLevel = new funkin.Highscore.Tallies();
    LoadingState.loadPlayState(
      {
        targetSong: targetSong,
        targetDifficulty: "hard",
        targetVariation: targetSong.getFirstValidVariation("hard")
      }, true);
  }

  static function waitSongPlaying(songId:String, seconds:Float, letCutscenePlay:Bool = false, requireCutscene:Bool = false):Null<Bool>
  {
    if (!songIs(songId))
    {
      failReason = 'waiting for song "$songId" (current: ${currentSongId()})';
      return null;
    }
    if (NXVideoPlayer.isCutscenePlaying())
    {
      if (letCutscenePlay)
      {
        // The console watched it: its sheet decodes and the prefetch thread run after the character decodes.
        videoSeen = true;
        if (NXVideoPlayer.sheetIndex() > videoSheetMax) videoSheetMax = NXVideoPlayer.sheetIndex();
        videoSheetCount = NXVideoPlayer.sheetCount();
        failReason = 'cutscene playing in $songId';
        mark = now();
        return null;
      }
      // Finish any starting cutscene through the natural completion path.
      if (now() - mark > 2.0)
      {
        NXVideoPlayer.finishCutscene();
        return null;
      }
    }
    if (!songPlaying())
    {
      mark = now();
      failReason = 'song "$songId" loaded but not playing (${describeState()})';
      return null;
    }
    if (phase == 0)
    {
      phase = 1;
      mark = now();
    }
    if (now() - mark < seconds) return null;
    if (requireCutscene && (!videoSeen || videoSheetMax < videoSheetCount - 1))
    {
      // A cutscene that never started, or ended early on a missing or undecodable sheet, lets the song start anyway.
      failReason = videoSeen ? 'the $songId cutscene stopped at sheet ${videoSheetMax + 1} of $videoSheetCount' : 'the $songId cutscene never played';
      return false;
    }
    return true;
  }

  static function playCutsceneThenSong(songId:String, videoName:String):Null<Bool>
  {
    if (!songIs(songId)) return null;
    switch (phase)
    {
      case 0:
        if (NXVideoPlayer.isCutscenePlaying())
        {
          var playing:String = @:privateAccess NXVideoPlayer.currentVideoName;
          if (playing != videoName)
          {
            failReason = 'expected cutscene $videoName, got $playing';
            return false;
          }
          phase = 1;
          mark = now();
        }
      case 1:
        if (now() - mark >= 2.0)
        {
          NXVideoPlayer.finishCutscene();
          phase = 2;
        }
      case 2:
        if (songPlaying())
        {
          phase = 3;
          mark = now();
        }
      case 3:
        if (now() - mark >= 3.0) return true;
    }
    failReason = 'phase $phase (${describeState()})';
    return null;
  }

  static function endCurrentSong():Void
  {
    phase = 0;
    if (PlayState.instance != null) PlayState.instance.endSong(true);
  }

  static function pauseAndQuitToMenu(target:Class<FlxState>):Null<Bool>
  {
    switch (phase)
    {
      case 0:
        if (PlayState.instance == null || !songPlaying())
        {
          failReason = 'no song playing to pause (${describeState()})';
          return null;
        }
        @:privateAccess PlayState.instance.pause();
        phase = 1;
        mark = now();
      case 1:
        var pause = findPauseSubState();
        if (pause != null && now() - mark > 0.5)
        {
          @:privateAccess PauseSubState.quitToMenu(pause);
          phase = 2;
          mark = now();
        }
        else if (pause == null && now() - mark > 3.0)
        {
          failReason = 'pause menu did not open';
          return false;
        }
      case 2:
        if (Std.isOfType(FlxG.state, target) && now() - mark > 3.0) return true;
    }
    return null;
  }

  static function checkMenuMemory(maxNativeMb:Float):Null<Bool>
  {
    if (now() - mark < 2.0) return null;
    var native:Float = NXPerformance.getNativeHeapUsed();
    trace('[AUTOTEST] Native malloc in ${Type.getClassName(Type.getClass(FlxG.state))}: ${Math.round(native * 10) / 10} MB (limit $maxNativeMb MB)');
    if (native > maxNativeMb)
    {
      failReason = 'native malloc ${Math.round(native)} MB > $maxNativeMb MB after leaving gameplay (stage not purged)';
      return false;
    }
    return true;
  }

  /**
   * Same path a player takes: B in the Story menu, Freeplay in the main menu, R3 in Freeplay to open
   * Character Select, then confirm Pico back into Freeplay.
   */
  static function menusToCharSelectToFreeplay():Null<Bool>
  {
    var stateName:String = Type.getClassName(Type.getClass(FlxG.state));
    switch (phase)
    {
      case 0:
        if (Std.isOfType(FlxG.state, StoryMenuState))
        {
          @:privateAccess (cast FlxG.state : StoryMenuState).goBack();
        }
        else
        {
          FlxG.switchState(() -> new funkin.ui.mainmenu.MainMenuState());
        }
        phase = 1;
        mark = now();
      case 1:
        if (Std.isOfType(FlxG.state, funkin.ui.mainmenu.MainMenuState) && FlxG.state.subState == null && now() - mark > 2.0)
        {
          var item = null;
          @:privateAccess for (m in (cast FlxG.state : funkin.ui.mainmenu.MainMenuState).menuItems.members)
            if (m != null && m.name == "freeplay") item = m;
          if (item == null)
          {
            failReason = 'freeplay item not found in main menu';
            return false;
          }
          trace('[AUTOTEST] Main menu: selecting Freeplay');
          item.callback();
          phase = 2;
          mark = now();
        }
      case 2:
        var freeplay = findFreeplay();
        if (freeplay != null && @:privateAccess freeplay.grpCapsules.countLiving() > 0 && now() - mark > 3.0)
        {
          trace('[AUTOTEST] Freeplay: opening Character Select (R3)');
          @:privateAccess freeplay.tryOpenCharSelect();
          phase = 3;
          mark = now();
        }
      case 3:
        if (stateName == "funkin.ui.charSelect.CharSelectSubState" && now() - mark > 4.0)
        {
          var charSelect:funkin.ui.charSelect.CharSelectSubState = cast FlxG.state;
          var picoIndex:Int = -1;
          @:privateAccess for (pos => id in charSelect.availableChars)
            if (id == "pico") picoIndex = pos;
          if (picoIndex < 0)
          {
            failReason = 'Pico is not available in Character Select';
            return false;
          }
          // Move the cursor onto Pico like the D-pad does (grid index = (x + 1) + (y + 1) * 3).
          @:privateAccess charSelect.cursorX = (picoIndex % 3) - 1;
          @:privateAccess charSelect.cursorY = Std.int(picoIndex / 3) - 1;
          trace('[AUTOTEST] Character Select: cursor moved to Pico (grid $picoIndex)');
          phase = 4;
          mark = now();
        }
      case 4:
        if (now() - mark > 1.0)
        {
          var curChar:String = @:privateAccess (cast FlxG.state : funkin.ui.charSelect.CharSelectSubState).curChar;
          if (curChar != "pico")
          {
            failReason = 'cursor on Pico but curChar = $curChar';
            return false;
          }
          trace('[AUTOTEST] Character Select: pressing Accept on Pico');
          tapAccept();
          phase = 5;
          mark = now();
        }
      case 5:
        var freeplay = findFreeplay();
        if (freeplay != null && @:privateAccess freeplay.grpCapsules.countLiving() > 0 && now() - mark > 3.0)
        {
          var charId:String = @:privateAccess freeplay.currentCharacterId;
          if (charId != "pico")
          {
            failReason = 'Freeplay opened with character "$charId" instead of Pico';
            return false;
          }
          trace('[AUTOTEST] Freeplay is now using Pico.');
          return true;
        }
        if (now() - mark > 20.0 && counter == 0)
        {
          counter = 1;
          @:privateAccess NXAutoTest.requestFrameCapture('reg_freeplay_stuck');
        }
    }
    failReason = 'phase $phase, ${describeSubStates()}';
    return null;
  }

  static function freeplayTo2HotWithCountdownSleep():Null<Bool>
  {
    switch (phase)
    {
      case 0:
        var freeplay = findFreeplay();
        if (freeplay == null)
        {
          failReason = 'Freeplay not open';
          return null;
        }
        var target = null;
        @:privateAccess for (cap in freeplay.grpCapsules.members)
        {
          if (cap != null && cap.alive && cap.freeplayData != null && cap.freeplayData.data.id == "2hot") target = cap;
        }
        if (target == null)
        {
          trace('[AUTOTEST] WARN: 2hot capsule not listed in Freeplay for Pico, launching it directly from Freeplay.');
          PlayStatePlaylist.isStoryMode = false;
          var song:Song = SongRegistry.instance.fetchEntry("2hot", {variation: Constants.DEFAULT_VARIATION});
          LoadingState.loadPlayState({targetSong: song, targetDifficulty: "hard", targetVariation: "default"}, true);
        }
        else
        {
          @:privateAccess freeplay.currentDifficulty = "hard";
          @:privateAccess freeplay.capsuleOnConfirmDefault(target);
        }
        phase = 1;
        mark = now();
      case 1:
        // Sleep as soon as the countdown is running.
        if (songIs("2hot") && @:privateAccess PlayState.instance.startingSong && @:privateAccess PlayState.instance.isInCountdown)
        {
          trace('[AUTOTEST] Countdown running in 2Hot: simulating Sleep for 2s...');
          simulateFocusLoss(true);
          Sys.sleep(2.0);
          simulateFocusGain(true);
          phase = 2;
          mark = now();
        }
        else if (songIs("2hot") && songPlaying())
        {
          trace('[AUTOTEST] WARN: countdown already finished before the Sleep could be injected.');
          phase = 2;
          mark = now();
        }
      case 2:
        // Countdown must resume by itself (no pause menu during countdown) and the song must start.
        var pause = findPauseSubState();
        if (pause != null)
        {
          failReason = 'pause menu opened during countdown';
          return false;
        }
        if (songPlaying() && Conductor.instance.songPosition > 1000) return true;
    }
    failReason = 'phase $phase (${describeState()})';
    return null;
  }

  static function captureBaselineWhenHealthy():Null<Bool>
  {
    if (!songPlaying()) return null;
    var music = FlxG.sound.music;
    baselineOffset = Conductor.instance.songPosition - music.time;
    baselineVoiceDrift = [for (v in voices()) v.time - music.time];
    hasBaseline = true;
    if (pollAudioHealthy())
    {
      trace('[AUTOTEST] Audio baseline: songPosition - music.time = ${Math.round(baselineOffset)}ms, voice drifts = ${[for (d in baselineVoiceDrift) Math.round(d)]}');
      @:privateAccess NXAutoTest.requestFrameCapture('reg_2hot_baseline');
      return true;
    }
    failReason = lastHealthIssue;
    return null;
  }

  /**
   * HOME (sleep = false) or Sleep (sleep = true) while a song is playing:
   * focus lost -> the game opens the pause menu -> process suspended for `seconds`
   * -> focus regained -> player presses Resume -> audio must recover in sync.
   */
  static function suspendAndResume(sleep:Bool, stopSourcesBySystem:Bool, seconds:Float):Null<Bool>
  {
    switch (phase)
    {
      case 0:
        if (!songPlaying() || now() - stepStart < 2.0) return null;
        trace('[AUTOTEST] Simulating ${sleep ? "Sleep" : "HOME"} at songPosition=${Math.round(Conductor.instance.songPosition)}ms');
        simulateFocusLoss(sleep);
        phase = 1;
        mark = now();
      case 1:
        // Process suspended: block the main thread like Horizon does.
        if (stopSourcesBySystem) stopSourcesBehindEngine();
        Sys.sleep(seconds);
        simulateFocusGain(sleep);
        phase = 2;
        mark = now();
      case 2:
        var pause = findPauseSubState();
        if (pause == null)
        {
          if (now() - mark > 2.0)
          {
            failReason = 'pause menu was not opened by the focus loss';
            return false;
          }
          return null;
        }
        if (now() - mark > 1.0)
        {
          trace('[AUTOTEST] Pressing Resume...');
          @:privateAccess PauseSubState.resume(pause);
          phase = 3;
          mark = now();
          resetHealthSampler();
        }
      case 3:
        if (pollAudioHealthy())
        {
          trace('[AUTOTEST] Audio recovered ${Math.round((now() - mark) * 10) / 10}s after Resume.');
          return true;
        }
        failReason = lastHealthIssue;
    }
    return null;
  }

  static function openALStall():Null<Bool>
  {
    switch (phase)
    {
      case 0:
        if (!songPlaying() || now() - stepStart < 2.0) return null;
        var handle = sourceHandle(FlxG.sound.music);
        if (handle == null)
        {
          failReason = 'no OpenAL handle for music';
          return false;
        }
        mark = now();
        counter = Std.int(Conductor.instance.songPosition);
        #if lime
        AL.sourcePause(handle);
        #end
        trace('[AUTOTEST] OpenAL music source paused behind the engine at songPosition=$counter ms');
        phase = 1;
      case 1:
        // Notes must keep moving while the clock is frozen.
        if (now() - mark >= 0.4)
        {
          if (Conductor.instance.songPosition <= counter + 100)
          {
            failReason = 'Conductor froze during the stall (${Math.round(Conductor.instance.songPosition)}ms)';
            return false;
          }
          phase = 2;
          resetHealthSampler();
        }
      case 2:
        if (pollAudioHealthy())
        {
          trace('[AUTOTEST] Recovered from OpenAL stall in ${Math.round((now() - mark) * 10) / 10}s.');
          return true;
        }
        failReason = lastHealthIssue;
    }
    return null;
  }

  static function frameHitches(total:Int):Null<Bool>
  {
    if (counter < total)
    {
      if (!songPlaying()) return null;
      if (now() - mark >= 0.7)
      {
        var ms:Int = FlxG.random.int(120, 450);
        Sys.sleep(ms / 1000.0);
        counter++;
        mark = now();
        if (counter == total)
        {
          trace('[AUTOTEST] Injected $total frame hitches.');
          resetHealthSampler();
        }
      }
      return null;
    }
    if (pollAudioHealthy()) return true;
    failReason = lastHealthIssue;
    return null;
  }

  static function pauseResumeSpam(total:Int):Null<Bool>
  {
    if (counter < total)
    {
      switch (phase)
      {
        case 0:
          if (!songPlaying() || now() - mark < 0.8) return null;
          @:privateAccess PlayState.instance.pause();
          phase = 1;
          mark = now();
        case 1:
          var pause = findPauseSubState();
          if (pause != null && now() - mark >= 0.3)
          {
            @:privateAccess PauseSubState.resume(pause);
            counter++;
            phase = 0;
            mark = now();
            if (counter == total) resetHealthSampler();
          }
          else if (pause == null && now() - mark > 3.0)
          {
            failReason = 'pause menu did not open on iteration ${counter + 1}';
            return false;
          }
      }
      return null;
    }
    if (pollAudioHealthy()) return true;
    failReason = lastHealthIssue;
    return null;
  }

  static function endOfSongWatchdog():Null<Bool>
  {
    var ps = PlayState.instance;
    switch (phase)
    {
      case 0:
        if (!songPlaying()) return null;
        ps.isPracticeMode = true; // Skipped notes must not kill the player.
        var target:Float = FlxG.sound.music.length - 6000;
        trace('[AUTOTEST] Seeking to ${Math.round(target)}ms (song length ${Math.round(FlxG.sound.music.length)}ms)');
        FlxG.sound.music.time = target;
        if (ps.vocals != null) ps.vocals.time = target;
        phase = 1;
      case 1:
        if (FlxG.sound.music != null && FlxG.sound.music.playing && FlxG.sound.music.time >= FlxG.sound.music.length - 2500)
        {
          trace('[AUTOTEST] Stopping music/vocal sources behind the engine at ${Math.round(FlxG.sound.music.time)}ms (no onComplete)');
          stopSourcesBehindEngine();
          phase = 2;
          mark = now();
        }
      case 2:
        if (findResults() != null) return true;
        failReason = 'Results not reached after audio stopped (${describeState()})';
    }
    return null;
  }

  static function replay2HotStageVisible():Null<Bool>
  {
    // Leave the Results screen with the Accept button, like the player.
    if (phase == 0 && findResults() != null)
    {
      if (now() - mark > 1.5)
      {
        tapAccept();
        mark = now();
      }
      failReason = 'waiting for Results to accept input';
      return null;
    }
    switch (phase)
    {
      case 0:
        var freeplay = findFreeplay();
        if (freeplay == null || now() - mark < 3.0) return null;
        var target = null;
        @:privateAccess for (cap in freeplay.grpCapsules.members)
          if (cap != null && cap.alive && cap.freeplayData != null && cap.freeplayData.data.id == "2hot") target = cap;
        if (target == null)
        {
          var song:Song = SongRegistry.instance.fetchEntry("2hot", {variation: Constants.DEFAULT_VARIATION});
          LoadingState.loadPlayState({targetSong: song, targetDifficulty: "hard", targetVariation: "default"}, true);
        }
        else
        {
          @:privateAccess freeplay.currentDifficulty = "hard";
          @:privateAccess freeplay.capsuleOnConfirmDefault(target);
        }
        phase = 1;
        mark = now();
      case 1:
        if (songIs("2hot") && songPlaying() && Conductor.instance.songPosition > 2000)
        {
          var ps = PlayState.instance;
          var stage = ps.currentStage;
          if (stage == null || !stage.visible || !stage.alive || !stage.exists)
          {
            failReason = 'stage not visible after replay (stage=${stage != null}, visible=${stage?.visible}, alive=${stage?.alive})';
            return false;
          }
          if (!ps.camGame.visible || ps.camGame.alpha < 0.99)
          {
            failReason = 'camGame hidden after replay (visible=${ps.camGame.visible}, alpha=${ps.camGame.alpha})';
            return false;
          }
          @:privateAccess NXAutoTest.requestFrameCapture('reg_2hot_replay');
          return true;
        }
        failReason = describeState();
    }
    return null;
  }


  // ---------------------------------------------------------------------------
  // SOAK steps
  // ---------------------------------------------------------------------------

  static var memoryFloors:Map<String, Float> = new Map<String, Float>();
  static var weekInstance:Null<PlayState> = null;
  static var weekSongs:Array<String> = [];
  static var songPhase:Int = 0;
  static var songMark:Float = 0.0;
  static var cutsceneMark:Float = -1.0;
  static var pendingVisualCheck:String = "";
  static var songVisualRequested:Bool = false;
  static var visualRetries:Int = 0;
  static var resultsOpenedAt:Float = -1.0;

  /**
   * Whether driveStorySong captures a frame of each song (visual check). INC49_REPRO turns it off: the console
   * session it replays did not read back the framebuffer.
   */
  static var captureSongFrames:Bool = true;

  static function resetWeekTracking():Void
  {
    weekInstance = null;
    weekSongs = [];
    songPhase = 0;
    cutsceneMark = -1.0;
    pendingVisualCheck = "";
    resultsOpenedAt = -1.0;
  }

  /**
   * Plays a whole Story Mode week: every cutscene runs 2 s, every song 3 s, then Results are accepted.
   * Each song is checked for a visible stage (stage alive/visible, camGame visible, real frame not black).
   */
  static function playStoryWeek(levelId:String, round:Int, resultsHold:Float = 0.0):Null<Bool>
  {
    if (phase == 0)
    {
      resetWeekTracking();
      phase = 1;
    }

    var visual:Null<Bool> = checkPendingVisual();
    if (visual == false) return false;

    var results = findResults();
    if (results != null)
    {
      if (resultsOpenedAt < 0) resultsOpenedAt = now();
      if (now() - resultsOpenedAt >= resultsHold && now() - mark > 1.5)
      {
        tapAccept();
        mark = now();
      }
      failReason = 'Results open, accepting';
      return null;
    }
    resultsOpenedAt = -1.0;

    if (Std.isOfType(FlxG.state, StoryMenuState) && weekSongs.length > 0)
    {
      var expected = LevelRegistry.instance.fetchEntry(levelId)?.getSongs() ?? [];
      if (weekSongs.join(',') != expected.join(','))
      {
        failReason = 'songs played ${weekSongs.join(" -> ")} but week has ${expected.join(" -> ")}';
        return false;
      }
      return (now() - mark > 1.0) ? true : null;
    }

    return driveStorySong(round);
  }

  /**
   * Shared per-song driver: cutscenes 2 s, song 3 s with a visual check, then endSong(true).
   * Returns null while running (never passes by itself).
   */
  static function driveStorySong(round:Int, ?stopAtSong:String):Null<Bool>
  {
    var ps = PlayState.instance;
    if (ps == null || ps.currentSong == null) return null;

    if (ps != weekInstance)
    {
      weekInstance = ps;
      weekSongs.push(ps.currentSong.id);
      songPhase = 0;
      songVisualRequested = false;
      cutsceneMark = -1.0;
      trace('[AUTOTEST] Entered "${ps.currentSong.id}" on stage "${ps.currentStageId}"');
    }

    if (skipConversations && ps.currentConversation != null)
    {
      if (conversationMark < 0) conversationMark = now();
      if (now() - conversationMark > 2.0)
      {
        ps.currentConversation.skipConversation();
        conversationMark = -1.0;
      }
      failReason = 'dialogue in ${ps.currentSong.id}';
      return null;
    }
    conversationMark = -1.0;

    if (NXVideoPlayer.isCutscenePlaying())
    {
      if (cutsceneMark < 0) cutsceneMark = now();
      if (fullLength)
      {
        failReason = 'cutscene in ${ps.currentSong.id} (full length)';
        return null;
      }
      if (now() - cutsceneMark > 2.0)
      {
        NXVideoPlayer.finishCutscene();
        cutsceneMark = -1.0;
      }
      failReason = 'cutscene in ${ps.currentSong.id}';
      return null;
    }

    switch (songPhase)
    {
      case 0:
        if (songPlaying())
        {
          songPhase = 1;
          songMark = now();
        }
        failReason = 'waiting for ${ps.currentSong.id} to play (${describeState()})';
      case 1:
        if (now() - songMark >= 2.5 && pendingVisualCheck == "" && !songVisualRequested)
        {
          songVisualRequested = true;
          var stage = ps.currentStage;
          if (stage == null || !stage.visible || !stage.alive || !ps.camGame.visible || ps.camGame.alpha < 0.99)
          {
            failReason = 'black stage in ${ps.currentSong.id}: stage=${stage != null} visible=${stage?.visible} alive=${stage?.alive} camGame=${ps.camGame.visible}/${ps.camGame.alpha}';
            return false;
          }
          if (captureSongFrames)
          {
            pendingVisualCheck = 'soak_r${round}_${ps.currentSong.id}';
            NXAutoTest.lastCaptureName = "";
            @:privateAccess NXAutoTest.requestFrameCapture(pendingVisualCheck);
          }
        }
        if (fullLength)
        {
          // Real playthrough: botplay plays the song to its natural end.
          failReason = 'playing ${ps.currentSong.id} to the end (${Math.round(Conductor.instance.songPosition / 1000)}s)';
          return null;
        }
        if (now() - songMark >= 3.0 && songVisualRequested && pendingVisualCheck == "")
        {
          if (stopAtSong != null && ps.currentSong.id == stopAtSong)
          {
            songPhase = 3;
            return null;
          }
          songPhase = 2;
          ps.endSong(true);
        }
      case 2:
        failReason = 'waiting after endSong of ${ps.currentSong.id}';
      default:
    }
    return null;
  }

  /**
   * Fails if the last requested frame capture is (almost) completely black.
   */
  static function checkPendingVisual():Null<Bool>
  {
    if (pendingVisualCheck == "" || NXAutoTest.lastCaptureName != pendingVisualCheck) return null;
    var coverage:Float = NXAutoTest.lastCaptureCoverage;
    var name:String = pendingVisualCheck;
    if (coverage < 25.0)
    {
      // Retry: a single dark frame can be a transient (e.g. emulator shader compilation); a black stage persists.
      if (visualRetries < 3)
      {
        visualRetries++;
        trace('[AUTOTEST] Frame $name is dark ($coverage%), retrying capture ($visualRetries/3)...');
        NXAutoTest.lastCaptureName = "";
        haxe.Timer.delay(() -> @:privateAccess NXAutoTest.requestFrameCapture(name), 1000);
        return null;
      }
      pendingVisualCheck = "";
      failReason = 'frame $name is black after 3 retries (non-black coverage $coverage%)';
      return false;
    }
    pendingVisualCheck = "";
    visualRetries = 0;
    return true;
  }

  /**
   * Enters a week, leaves it from the pause menu while `exitSong` is playing, enters it again and checks
   * that the first song renders its stage (the old "black screen when re-entering a week" bug).
   */
  static function reenterWeekAfterMidExit(levelId:String, exitSong:String, round:Int):Null<Bool>
  {
    var visual:Null<Bool> = checkPendingVisual();
    if (visual == false) return false;

    switch (phase)
    {
      case 0:
        resetWeekTracking();
        phase = 1;
      case 1:
        driveStorySong(round, exitSong);
        if (songPhase == 3)
        {
          trace('[AUTOTEST] Leaving $levelId from the pause menu during $exitSong');
          phase = 2;
          counter = 0;
          mark = now();
        }
      case 2:
        var r = pauseAndQuitToMenuRaw();
        if (r == false) return false;
        if (r == true)
        {
          trace('[AUTOTEST] Re-entering $levelId');
          launchStory(levelId);
          resetWeekTracking();
          phase = 3;
          mark = now();
        }
      case 3:
        driveStorySong(round + 10, weekFirstSong(levelId));
        if (songPhase == 3)
        {
          var visualDone:Null<Bool> = checkPendingVisual();
          if (visualDone == false) return false;
          phase = 4;
          counter = 0;
          mark = now();
        }
      case 4:
        var r = pauseAndQuitToMenuRaw();
        if (r != null) return r;
    }
    return null;
  }

  static function weekFirstSong(levelId:String):String
  {
    var songs = LevelRegistry.instance.fetchEntry(levelId)?.getSongs() ?? [];
    return songs.length > 0 ? songs[0] : "";
  }

  static var quitPhase:Int = 0;
  static var quitMark:Float = 0.0;

  /**
   * Pause -> Exit to menu, usable inside other steps (own phase counter).
   */
  static function pauseAndQuitToMenuRaw():Null<Bool>
  {
    if (counter == 0)
    {
      quitPhase = 0;
      counter = 1;
    }
    switch (quitPhase)
    {
      case 0:
        if (!songPlaying()) return null;
        @:privateAccess PlayState.instance.pause();
        quitPhase = 1;
        quitMark = now();
      case 1:
        var pause = findPauseSubState();
        if (pause != null && now() - quitMark > 0.5)
        {
          @:privateAccess PauseSubState.quitToMenu(pause);
          quitPhase = 2;
          quitMark = now();
        }
        else if (pause == null && now() - quitMark > 3.0)
        {
          failReason = 'pause menu did not open';
          return false;
        }
      case 2:
        if (Std.isOfType(FlxG.state, StoryMenuState) && now() - quitMark > 2.0) return true;
    }
    return null;
  }

  static function memoryCheckpoint(label:String, round:Int):Null<Bool>
  {
    if (!Std.isOfType(FlxG.state, StoryMenuState) || now() - mark < 3.0) return null;
    #if cpp
    cpp.vm.Gc.run(true);
    cpp.vm.Gc.compact();
    #end
    var native:Float = NXPerformance.getNativeHeapUsed();
    var gc:Float = #if cpp cpp.vm.Gc.memInfo(0) / (1024.0 * 1024.0) #else 0.0 #end;
    memoryFloors.set(label, native);
    trace('[AUTOTEST] Memory floor [$label]: native ${Math.round(native * 10) / 10} MB, GC ${Math.round(gc * 10) / 10} MB'
      + ', malloc free ${Math.round(NXPerformance.getNativeHeapFree())} MB, largest free block ${Math.round(NXPerformance.getLargestAllocatableMB())} MB');
    NXDeepTrace.logMemorySnapshot('SOAK $label', true);
    NXDeepTrace.logGraphicsByFolder('SOAK $label');
    NXDeepTrace.logTopGraphics('SOAK $label', 15);
    return true;
  }

  /**
   * Leak check between rounds at the END of each round (`endLabel`): same point of the same sequence. The other
   * checkpoints are only logged: in round 1 every week is played for the first time and loads what then stays (UI,
   * fonts, the GC growing to its working size), so round 1 vs round 2 there measures warm-up, not leaks (MEMORY_BUDGET:
   * the floor climbs from 415 to 795 MB during round 1, then stays at 790-840 MB through round 2).
   */
  static function compareRounds(maxGrowthMb:Float, endLabel:String, rounds:Int = 2):Null<Bool>
  {
    for (label => r2 in memoryFloors)
    {
      if (!StringTools.startsWith(label, "R2-") || label.substr(3) == endLabel) continue;
      var r1:Null<Float> = memoryFloors.get("R1-" + label.substr(3));
      if (r1 == null) continue;
      trace('[AUTOTEST] Round floors ${label.substr(3)}: round 1 = ${Math.round(r1)} MB, round 2 = ${Math.round(r2)} MB (warm-up included, not checked)');
    }
    for (round in 2...(rounds + 1))
    {
      var before:Null<Float> = memoryFloors.get('R${round - 1}-$endLabel');
      var after:Null<Float> = memoryFloors.get('R$round-$endLabel');
      if (before == null || after == null)
      {
        failReason = 'missing end-of-round memory floor for $endLabel (round $round)';
        return false;
      }
      var growth:Float = after - before;
      trace('[AUTOTEST] Leak check (end of round, $endLabel): round ${round - 1} = ${Math.round(before)} MB, round $round = ${Math.round(after)} MB, growth = ${Math.round(growth)} MB (limit $maxGrowthMb MB)');
      if (growth > maxGrowthMb)
      {
        failReason = 'native memory grew ${Math.round(growth)} MB in round $round (end of round, $endLabel; limit $maxGrowthMb MB)';
        return false;
      }
    }
    return true;
  }

  // ---------------------------------------------------------------------------
  // Audio health
  // ---------------------------------------------------------------------------

  static var hcStamp:Float = -1.0;
  static var hcMusic:Float = 0.0;
  static var hcPos:Float = 0.0;
  static var lastHealthIssue:String = "";

  static function resetHealthSampler():Void
  {
    hcStamp = -1.0;
  }

  /**
   * True once two samples 0.8 s apart show: song running, OpenAL source Playing, music clock and
   * Conductor both advancing, Conductor/music offset and every voice drift back to the healthy baseline.
   */
  static function pollAudioHealthy():Bool
  {
    if (!songPlaying())
    {
      lastHealthIssue = 'not playing (${describeState()})';
      hcStamp = -1.0;
      return false;
    }
    var music = FlxG.sound.music;
    var t:Float = now();
    var m:Float = music.time;
    var p:Float = Conductor.instance.songPosition;
    if (hcStamp < 0)
    {
      hcStamp = t;
      hcMusic = m;
      hcPos = p;
      return false;
    }
    if (t - hcStamp < 0.8) return false;

    var wallMs:Float = (t - hcStamp) * 1000.0;
    var dm:Float = m - hcMusic;
    var dp:Float = p - hcPos;
    hcStamp = t;
    hcMusic = m;
    hcPos = p;

    var alState:String = NXAudioDiagnostics.getOpenALSourceState(music);
    if (alState != "Playing")
    {
      lastHealthIssue = 'OpenAL music source state = $alState';
      return false;
    }
    if (dm < wallMs * 0.6)
    {
      lastHealthIssue = 'music clock not advancing (${Math.round(dm)}ms in ${Math.round(wallMs)}ms)';
      return false;
    }
    if (dp < wallMs * 0.6)
    {
      lastHealthIssue = 'Conductor not advancing (${Math.round(dp)}ms in ${Math.round(wallMs)}ms)';
      return false;
    }
    if (hasBaseline)
    {
      var offset:Float = p - m;
      if (Math.abs(offset - baselineOffset) > 120)
      {
        lastHealthIssue = 'Conductor/music desync ${Math.round(offset - baselineOffset)}ms';
        return false;
      }
      var vs = voices();
      for (i in 0...vs.length)
      {
        var v = vs[i];
        if (v.length > 0 && m >= v.length - 300) continue; // Voice track already finished.
        if (!v.playing)
        {
          lastHealthIssue = 'voice $i not playing';
          return false;
        }
        var drift:Float = v.time - m;
        var base:Float = (i < baselineVoiceDrift.length) ? baselineVoiceDrift[i] : 0.0;
        if (Math.abs(drift - base) > 120)
        {
          lastHealthIssue = 'voice $i desync ${Math.round(drift - base)}ms';
          return false;
        }
      }
    }
    return true;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static inline function now():Float
    return Timer.stamp();

  static function currentSongId():String
    return (PlayState.instance != null && PlayState.instance.currentSong != null) ? PlayState.instance.currentSong.id : "none";

  static function songIs(id:String):Bool
    return currentSongId() == id;

  static function songPlaying():Bool
  {
    var ps = PlayState.instance;
    if (ps == null || ps.currentSong == null) return false;
    if (@:privateAccess ps.startingSong || ps.isInCutscene || @:privateAccess ps.isGamePaused) return false;
    return FlxG.sound.music != null && FlxG.sound.music.playing;
  }

  static function describeState():String
  {
    var ps = PlayState.instance;
    var state:String = Type.getClassName(Type.getClass(FlxG.state));
    if (ps == null) return 'state=$state';
    return 'song=${currentSongId()} starting=${@:privateAccess ps.startingSong} cutscene=${ps.isInCutscene} paused=${@:privateAccess ps.isGamePaused}'
      + ' music=${FlxG.sound.music != null ? Std.string(FlxG.sound.music.playing) : "null"} pos=${Math.round(Conductor.instance.songPosition)}';
  }

  static var acceptReleaseFrames:Int = -1;

  /**
   * Presses and releases ENTER (bound to ACCEPT in every keyboard scheme), so `controls.ACCEPT_P`
   * fires exactly like a real button press, including the menu's own confirm logic and animations.
   */
  static function tapAccept():Void
  {
    var key = @:privateAccess FlxG.keys._keyListMap.get(flixel.input.keyboard.FlxKey.ENTER);
    if (key == null) return;
    key.press();
    if (acceptReleaseFrames < 0) FlxG.signals.postUpdate.add(releaseAccept);
    acceptReleaseFrames = 3;
  }

  static function releaseAccept():Void
  {
    if (--acceptReleaseFrames > 0) return;
    var key = @:privateAccess FlxG.keys._keyListMap.get(flixel.input.keyboard.FlxKey.ENTER);
    if (key != null) key.release();
    acceptReleaseFrames = -1;
    FlxG.signals.postUpdate.remove(releaseAccept);
  }

  static function describeSubStates():String
  {
    var chain:Array<String> = [Type.getClassName(Type.getClass(FlxG.state))];
    var sub = (FlxG.state != null) ? FlxG.state.subState : null;
    while (sub != null)
    {
      chain.push(Type.getClassName(Type.getClass(sub)));
      sub = sub.subState;
    }
    var freeplay = findFreeplay();
    var caps:String = (freeplay != null) ? ' capsules=${@:privateAccess freeplay.grpCapsules.countLiving()}/${@:privateAccess freeplay.grpCapsules.length}' : '';
    return 'states=' + chain.join(' > ') + caps;
  }

  static function voices():Array<funkin.audio.FunkinSound>
  {
    var result:Array<funkin.audio.FunkinSound> = [];
    var ps = PlayState.instance;
    if (ps == null || ps.vocals == null) return result;
    ps.vocals.forEachAlive(function(v) result.push(v));
    return result;
  }

  static function findSub<T>(cls:Class<T>):Null<T>
  {
    var sub = (FlxG.state != null) ? FlxG.state.subState : null;
    while (sub != null)
    {
      if (Std.isOfType(sub, cls)) return cast sub;
      sub = sub.subState;
    }
    return null;
  }

  static function findPauseSubState():Null<PauseSubState>
    return findSub(PauseSubState);

  static function findResults():Null<ResultState>
  {
    if (Std.isOfType(FlxG.state, ResultState)) return cast FlxG.state;
    return findSub(ResultState);
  }

  static function findFreeplay():Null<FreeplayState>
  {
    if (Std.isOfType(FlxG.state, FreeplayState)) return cast FlxG.state;
    return findSub(FreeplayState);
  }

  static function sourceHandle(sound:Null<flixel.sound.FlxSound>):Dynamic
  {
    if (sound == null) return null;
    @:privateAccess
    {
      var sc:Dynamic = sound._channel;
      if (sc == null) return null;
      var src:Dynamic = (sc.__audioSource != null) ? sc.__audioSource : sc.__source;
      if (src == null || src.__backend == null) return null;
      return src.__backend.handle;
    }
  }

  /**
   * Stops the OpenAL sources of the instrumental and every voice directly, without the engine knowing,
   * the way the audio renderer can drop them while Horizon suspends the process.
   */
  static function stopSourcesBehindEngine():Void
  {
    #if lime
    var sounds:Array<flixel.sound.FlxSound> = [FlxG.sound.music];
    for (v in voices())
      sounds.push(v);
    for (s in sounds)
    {
      var handle = sourceHandle(s);
      if (handle != null) AL.sourceStop(handle);
    }
    trace('[AUTOTEST] Stopped ${sounds.length} OpenAL sources behind the engine.');
    #end
  }

  /**
   * Mirrors how SDL on Horizon reports the events: HOME = focus out/in, Sleep = background + focus out/in.
   */
  static function simulateFocusLoss(sleep:Bool):Void
  {
    var window = lime.app.Application.current.window;
    if (sleep) window.onDeactivate.dispatch();
    window.onFocusOut.dispatch();
  }

  static function simulateFocusGain(sleep:Bool):Void
  {
    var window = lime.app.Application.current.window;
    if (sleep) window.onActivate.dispatch();
    window.onFocusIn.dispatch();
  }
}
