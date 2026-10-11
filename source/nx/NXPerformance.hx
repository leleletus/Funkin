package nx;

import flixel.FlxG;
import funkin.Preferences;
import funkin.ui.debug.FunkinDebugDisplay.DebugDisplayMode;
#if switch
import nx.NXMain;
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
    #end
  }

  static var comboHoldTimer:Float = 0.0;
  static var comboTriggered:Bool = false;
  static final COMBO_HOLD_DURATION:Float = 3.0;

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

    // Universal HUD Toggle: L3 (Left Stick click) cycles Performance HUD anywhere in the game
    var l3Pressed:Bool = (FlxG.gamepads != null && FlxG.gamepads.anyJustPressed(LEFT_STICK_CLICK))
      #if switch
      || (NXMain.nxController != null && NXMain.nxController.isJustPressed(nx.controls.NXControlButton.STICK_L))
      #end;

    if (l3Pressed)
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
      trace('Switch: Cycled Performance HUD via L3 to: ' + Preferences.debugDisplay);
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
        Preferences.switchShowPerfHud = !Preferences.switchShowPerfHud;
        updatePerfHud();
        try
        {
          funkin.audio.FunkinSound.playOnce(funkin.Paths.sound('confirmMenu'), 0.7);
        }
        catch (e:Dynamic) {}
        trace('Switch: Toggled Performance HUD via PLUS+R combo: ' + Preferences.switchShowPerfHud);
      }
    }
    else
    {
      comboHoldTimer = 0.0;
      comboTriggered = false;
    }
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
   * Toggles or updates the performance HUD (FPS and RAM counter).
   */
  public static function updatePerfHud():Void
  {
    if (FlxG.game == null || FlxG.game.parent == null) return;

    if (Preferences.switchShowPerfHud)
    {
      if (Preferences.debugDisplay == DebugDisplayMode.Off)
      {
        Preferences.debugDisplay = DebugDisplayMode.Simple;
      }
    }
    else
    {
      Preferences.debugDisplay = DebugDisplayMode.Off;
    }
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
}
