package nx;

import flixel.FlxG;
import funkin.Preferences;
import funkin.ui.debug.FunkinDebugDisplay.DebugDisplayMode;
#if switch
import nx.NXMain;
#if cpp
@:cppInclude("switch.h")
@:cppInclude("malloc.h")
#end
#end

/**
 * Performance and display manager for Nintendo Switch.
 * Centralizes resolution scaling, hardware HUD monitoring, and graphics profiling.
 */
class NXPerformance
{
  /**
   * Last recorded docked status to detect transitions.
   */
  public static var lastDockedState:Bool = false;

  /**
   * Initialize performance settings and hooks.
   */
  public static function init():Void
  {
    #if switch
    lastDockedState = NXMain.IS_DOCKED;
    applyResolutionMode(Preferences.switchResolutionMode);
    updatePerfHud();
    NXTextureMemory.init();
    #end
  }

  static var comboHoldTimer:Float = 0.0;
  static var comboTriggered:Bool = false;
  static final COMBO_HOLD_DURATION:Float = 3.0;

  static var lastL3PressTime:Float = -1.0;
  static final L3_DEBOUNCE_COOLDOWN:Float = 0.25; // Minimum 250ms debounce cooldown

  /**
   * Called every frame from NXMain.update() to handle dock/undock transitions and button combos.
   */
  public static function update():Void
  {
    #if switch
    var currentDocked:Bool = NXMain.IS_DOCKED;
    if (currentDocked != lastDockedState)
    {
      lastDockedState = currentDocked;
      onDockStateChanged(currentDocked);
    }

    NXAudioDiagnostics.checkSystemSuspension();
    NXHaptics.update();

    #if NX_DEV_TOOLS
    updatePerfTelemetry();
    logGamepadInput();

    // Universal HUD Toggle: L3 (Left Stick click) with unified single-source read and debounce cooldown
    var l3Pressed:Bool = false;
    try
    {
      if (NXMain.nxController != null)
      {
        l3Pressed = NXMain.nxController.isJustPressed(nx.controls.NXControlButton.STICK_L);
      }
      else if (FlxG.gamepads != null)
      {
        l3Pressed = FlxG.gamepads.anyJustPressed(LEFT_STICK_CLICK);
      }
    }
    catch (e:Dynamic) {}

    var now:Float = Sys.time();
    if (l3Pressed && (lastL3PressTime < 0 || (now - lastL3PressTime) >= L3_DEBOUNCE_COOLDOWN))
    {
      lastL3PressTime = now;
      try
      {
        var nextMode:DebugDisplayMode;
        switch (Preferences.debugDisplay)
        {
          case DebugDisplayMode.Off:
            nextMode = DebugDisplayMode.Simple;
          case DebugDisplayMode.Simple:
            nextMode = DebugDisplayMode.Advanced;
          case DebugDisplayMode.Advanced:
            nextMode = DebugDisplayMode.Off;
        }
        Preferences.debugDisplay = nextMode;
        Preferences.switchShowPerfHud = (nextMode != DebugDisplayMode.Off);
        updatePerfHud();
        try
        {
          funkin.audio.FunkinSound.playOnce(funkin.Paths.sound('confirmMenu'), 0.7);
        }
        catch (e:Dynamic) {}
        nx.NXDeepTrace.logButtonEvent('L3', 'Cycled Performance HUD to $nextMode');
        trace('Switch: Cycled Performance HUD via L3 to: ' + Preferences.debugDisplay);
      }
      catch (e:Dynamic)
      {
        trace('Warning: Failed to cycle debug display via L3: ' + e);
      }
    }

    // Secondary button combo: hold PLUS and R for 3.0 seconds to toggle Performance HUD (FPS/RAM)
    var plusPressed:Bool = (NXMain.nxController != null && NXMain.nxController.isPressed(nx.controls.NXControlButton.PLUS)) || FlxG.gamepads.anyPressed(START);
    var rPressed:Bool = (NXMain.nxController != null && NXMain.nxController.isPressed(nx.controls.NXControlButton.R)) || FlxG.gamepads.anyPressed(RIGHT_SHOULDER);

    if (plusPressed && rPressed)
    {
      comboHoldTimer += FlxG.elapsed;
      if (comboHoldTimer >= COMBO_HOLD_DURATION && !comboTriggered)
      {
        comboTriggered = true;
        var nextMode:DebugDisplayMode = (Preferences.debugDisplay == DebugDisplayMode.Off) ? DebugDisplayMode.Advanced : DebugDisplayMode.Off;
        Preferences.debugDisplay = nextMode;
        try
        {
          funkin.audio.FunkinSound.playOnce(funkin.Paths.sound('confirmMenu'), 0.7);
        }
        catch (e:Dynamic) {}
        trace('Switch: Toggled Performance HUD via PLUS+R combo to: ' + Preferences.debugDisplay);
      }
    }
    else
    {
      comboHoldTimer = 0.0;
      comboTriggered = false;
    }
    #end // NX_DEV_TOOLS
    #end
  }

  /**
   * Handle Dock insertion/removal.
   */
  public static function onDockStateChanged(isDocked:Bool):Void
  {
    trace('Switch Dock state changed: ' + (isDocked ? 'Docked' : 'Handheld'));
    applyResolutionMode(Preferences.switchResolutionMode);
  }

  /**
   * Applies the resolution configuration based on the user's preference.
   * - "720p" (default): Forces 1280x720 fixed framebuffer to avoid GPU fillrate bottleneck.
   * - "Docked": Allows 1080p (1920x1080) when docked, 720p when handheld.
   * - "540p": Lowers resolution to 960x540 for maximum performance.
   *
   * NOTE: resizing the SDL window (`window.resize`) does NOT resize the EGL surface on Horizon: the
   * backbuffer stays at the display size while OpenFL assumes the new size, rendering the game shifted
   * and cropped (verified in Citron, Build 18 development). A real internal resolution needs an
   * offscreen render target; until then this only reports the requested size.
   */
  public static function applyResolutionMode(mode:String):Void
  {
    #if switch
    var targetWidth:Int = 1280;
    var targetHeight:Int = 720;

    switch (mode)
    {
      case "Docked":
        if (NXMain.IS_DOCKED)
        {
          targetWidth = 1920;
          targetHeight = 1080;
        }
        else
        {
          targetWidth = 1280;
          targetHeight = 720;
        }
      case "540p":
        targetWidth = 960;
        targetHeight = 540;
      default: // "720p" / "Native 720p"
        targetWidth = 1280;
        targetHeight = 720;
    }

    if (FlxG.stage != null && FlxG.stage.window != null)
    {
      trace('Switch resolution set to: ${targetWidth}x${targetHeight} (Mode: $mode)');
    }
    #end
  }

  /**
   * Logs every gamepad button press (name and song position), so hardware logs show exactly what the
   * player did before a failure.
   */
  static function logGamepadInput():Void
  {
    var pad = FlxG.gamepads?.lastActive;
    if (pad == null || !pad.justPressed.ANY) return;
    var pressed:Array<String> = [];
    for (button in @:privateAccess pad.buttons)
    {
      if (button != null && button.justPressed) pressed.push(pad.mapping.getID(button.ID).toString());
    }
    var ps = funkin.play.PlayState.instance;
    var where:String = (ps != null && ps.currentSong != null) ? '${ps.currentSong.id}@${Math.round(funkin.Conductor.instance.songPosition)}ms' : Type.getClassName(Type.getClass(FlxG.state));
    NXDeepTrace.writeEntry('INPUT', '[PAD] ${pressed.join("+")} ($where)');
    NXAudioDiagnostics.record('pad ${pressed.join("+")} $where');
  }

  static var perfWindowStart:Float = -1.0;
  static var perfLastFrame:Float = -1.0;
  static var perfFrames:Int = 0;
  static var perfWorstFrameMs:Float = 0.0;
  static var perfSlowFrames:Int = 0;
  static final PERF_WINDOW_SECONDS:Float = 5.0;

  /**
   * Gameplay performance telemetry written to deep_engine_trace.log every 5 s while a song is running:
   * average FPS, worst frame and frames slower than 20 ms (below ~50 FPS), with the active resolution.
   */
  static function updatePerfTelemetry():Void
  {
    var ps = funkin.play.PlayState.instance;
    var now:Float = haxe.Timer.stamp();
    if (ps == null || ps.subState != null || @:privateAccess ps.startingSong || ps.isInCutscene)
    {
      perfWindowStart = -1.0;
      perfLastFrame = -1.0;
      return;
    }
    if (perfWindowStart < 0)
    {
      perfWindowStart = now;
      perfLastFrame = now;
      perfFrames = 0;
      perfWorstFrameMs = 0.0;
      perfSlowFrames = 0;
      return;
    }
    var frameMs:Float = (now - perfLastFrame) * 1000.0;
    perfLastFrame = now;
    perfFrames++;
    if (frameMs > perfWorstFrameMs) perfWorstFrameMs = frameMs;
    if (frameMs > 20.0) perfSlowFrames++;

    var elapsed:Float = now - perfWindowStart;
    if (elapsed >= PERF_WINDOW_SECONDS)
    {
      var window = lime.app.Application.current?.window;
      var res:String = (window != null) ? '${window.width}x${window.height}' : '?';
      NXDeepTrace.writeEntry('PERF', '[${ps.currentSong?.id}@${Math.round(funkin.Conductor.instance.songPosition / 1000)}s] avg ${Math.round(perfFrames / elapsed * 10) / 10} FPS'
        + ' | worst frame ${Math.round(perfWorstFrameMs * 10) / 10} ms | slow frames (>20 ms): $perfSlowFrames/$perfFrames'
        + ' | res $res | ${NXMain.IS_DOCKED ? "docked" : "handheld"} | native ${Math.round(getNativeHeapUsed())} MB');
      perfWindowStart = now;
      perfFrames = 0;
      perfWorstFrameMs = 0.0;
      perfSlowFrames = 0;
    }
  }

  /**
   * Toggles or updates the performance HUD (FPS and RAM counter).
   */
  public static function updatePerfHud():Void
  {
    #if switch
    Preferences.setDebugDisplayMode(Preferences.debugDisplay);
    #end
  }

  /**
   * Helper check to determine if heavy shaders should run on Switch.
   */
  public static inline function areShadersEnabled():Bool
  {
    #if switch
    return Preferences.switchEnableShaders;
    #else
    return true;
    #end
  }

  /**
   * Helper check to determine if antialiasing is enabled on Switch.
   */
  public static inline function isAntialiasingEnabled():Bool
  {
    #if switch
    return Preferences.switchAntialiasing;
    #else
    return true;
    #end
  }

  /**
   * Helper check to determine if note splashes are enabled on Switch.
   */
  public static inline function areNoteSplashesEnabled():Bool
  {
    #if switch
    return Preferences.switchNoteSplashes;
    #else
    return true;
    #end
  }

  /**
   * Returns physical memory currently used by the process in megabytes (MB) directly from Horizon OS kernel (svcGetInfo).
   */
  public static function getPhysicalMemoryUsed():Float
  {
    #if (switch && cpp)
    var usedBytes:Float = 0;
    untyped __cpp__('
      u64 usedMemory = 0;
      #ifndef InfoType_UsedPhysicalMemory
      #define InfoType_UsedPhysicalMemory 7
      #endif
      svcGetInfo(&usedMemory, InfoType_UsedPhysicalMemory, CUR_PROCESS_HANDLE, 0);
      {0} = (double)usedMemory;
    ', usedBytes);
    return usedBytes / (1024.0 * 1024.0);
    #else
    return 0.0;
    #end
  }

  /**
   * Returns total physical memory available to the process in megabytes (MB) directly from Horizon OS kernel (svcGetInfo).
   * Title Override grants ~3200 MB (3.2 GB), while Applet Mode grants ~450 MB.
   */
  public static function getPhysicalMemoryTotal():Float
  {
    #if (switch && cpp)
    var totalBytes:Float = 0;
    untyped __cpp__('
      u64 totalMemory = 0;
      #ifndef InfoType_TotalPhysicalMemoryAvailable
      #define InfoType_TotalPhysicalMemoryAvailable 6
      #endif
      svcGetInfo(&totalMemory, InfoType_TotalPhysicalMemoryAvailable, CUR_PROCESS_HANDLE, 0);
      {0} = (double)totalMemory;
    ', totalBytes);
    return totalBytes / (1024.0 * 1024.0);
    #else
    return 0.0;
    #end
  }

  /**
   * Returns bytes currently allocated through newlib malloc (`mallinfo().uordblks`), in megabytes (MB).
   * Unlike `getPhysicalMemoryUsed()` (which reports the heap mapped by `svcSetHeapSize`), this tracks real
   * native allocations: decoded image pixel buffers, PCM audio buffers, and Mesa/nouveau driver allocations.
   */
  public static function getNativeHeapUsed():Float
  {
    #if (switch && cpp)
    var usedBytes:Float = 0;
    untyped __cpp__('
      struct mallinfo mi = mallinfo();
      {0} = (double)mi.uordblks;
    ', usedBytes);
    return usedBytes / (1024.0 * 1024.0);
    #else
    return 0.0;
    #end
  }

  /**
   * Largest single block malloc can currently return, in MB (binary search with malloc/free).
   * Compared with free memory it shows heap fragmentation: decoding a 4096x4096 texture needs one
   * contiguous 64 MB block even when much more memory is free in smaller holes.
   */
  public static function getLargestAllocatableMB():Float
  {
    #if (switch && cpp)
    var largest:Float = 0;
    untyped __cpp__('
      size_t lo = 0, hi = (size_t)3072 * 1024 * 1024;
      while (hi - lo > (size_t)1024 * 1024)
      {
        size_t mid = lo + (hi - lo) / 2;
        void *p = malloc(mid);
        if (p) { free(p); lo = mid; } else { hi = mid; }
      }
      {0} = (double)lo;
    ', largest);
    return largest / (1024.0 * 1024.0);
    #else
    return 0.0;
    #end
  }

  /**
   * Free bytes inside the malloc arena (mallinfo().fordblks), in MB.
   */
  public static function getNativeHeapFree():Float
  {
    #if (switch && cpp)
    var freeBytes:Float = 0;
    untyped __cpp__('
      struct mallinfo mi = mallinfo();
      {0} = (double)mi.fordblks;
    ', freeBytes);
    return freeBytes / (1024.0 * 1024.0);
    #else
    return 0.0;
    #end
  }

  /**
   * Returns physical memory currently used by the process in raw bytes.
   */
  public static function getPhysicalMemoryUsedBytes():Float
  {
    #if (switch && cpp)
    var usedBytes:Float = 0;
    untyped __cpp__('
      u64 usedMemory = 0;
      #ifndef InfoType_UsedPhysicalMemory
      #define InfoType_UsedPhysicalMemory 7
      #endif
      svcGetInfo(&usedMemory, InfoType_UsedPhysicalMemory, CUR_PROCESS_HANDLE, 0);
      {0} = (double)usedMemory;
    ', usedBytes);
    return usedBytes;
    #else
    return 0.0;
    #end
  }
}
