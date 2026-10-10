package nx;

import nx.controls.NXController;
#if switch
import funkin.input.PreciseInputManager;
#end

/**
 * States of the applet
 */
enum AppletStateMode
{
  /**
   * The applet/program is in focus
   */
  APP_IN_FOCUS;

  /**
   * The applet/program is out of focus
   */
  APP_OUT_OF_FOCUS;

  /**
   * The applet/program is suspended (In HOME menu or the console is sleeping)
   */
  APP_SUSPENDED;

  /**
   * Unknown state
   */
  APP_UNKNOWN;
}

/**
 * Main class for Nintendo Switch functionality
 *
 * Ported from Switch-Funkin
 */
class NXMain
{
  /**
   * Controller manager for Nintendo Switch controllers
   */
  public static var nxController:NXController = null;

  /**
   * Initialize Nintendo Switch systems
   */
  public static function init()
  {
    #if switch
    nxController = new NXController();
    nx.NXPerformance.init();
    #end
  }

  /**
   * Update Nintendo Switch systems - called every frame
   */
  public static function update()
  {
    #if switch
    if (nxController != null)
    {
      nxController.update();
    }

    nx.NXPerformance.update();

    if (PreciseInputManager.instance != null)
    {
      PreciseInputManager.instance.updateNXInput();
    }
    #end
  }

  /**
   * Clean up Nintendo Switch systems
   */
  public static function destroy()
  {
    #if switch
    if (nxController != null)
    {
      nxController.destroy();
    }
    #end
  }

  /**
   * Checks if the console is docked (TV mode)
   */
  public static var IS_DOCKED(get, never):Bool;

  private static function get_IS_DOCKED():Bool
  {
    #if switch
    return Applet.appletGetOperationMode() == AppletOperationMode.AppletOperationMode_Console;
    #else
    return false;
    #end
  }

  /**
   * The current applet state
   */
  public static var appState(get, never):AppletStateMode;

  private static function get_appState():AppletStateMode
  {
    #if switch
    return switch (Applet.appletGetFocusState())
    {
      case AppletFocusState.AppletFocusState_InFocus: AppletStateMode.APP_IN_FOCUS;
      case AppletFocusState.AppletFocusState_OutOfFocus: AppletStateMode.APP_OUT_OF_FOCUS;
      case AppletFocusState.AppletFocusState_Background: AppletStateMode.APP_SUSPENDED;
      default: AppletStateMode.APP_UNKNOWN;
    }
    #else
    return AppletStateMode.APP_UNKNOWN;
    #end
  }

  /**
   * Checks if the application is running in Applet mode (limited memory)
   * @return Bool
   */
  public static function isRunningAsApplet():Bool
  {
    #if switch
    return Applet.appletGetAppletType() != AppletType.AppletType_Application
      && Applet.appletGetAppletType() != AppletType.AppletType_SystemApplication;
    #else
    return false;
    #end
  }
}
