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
   * Dynamically determines the app directory on Nintendo Switch.
   * If the .nro is inside a folder like sdmc:/switch/Friday-Night-Funkin/, it returns that folder.
   * If the .nro is loose in sdmc:/switch/, it returns the default sdmc:/switch/Friday-Night-Funkin.
   */
  public static function getAppDir():String
  {
    #if switch
    try
    {
      var progPath:String = Sys.programPath();
      if (progPath != null && progPath.length > 0)
      {
        var dir:String = haxe.io.Path.directory(progPath);
        dir = sanitizePath(dir);
        if (dir != "sdmc:/switch" && dir != "sdmc:/" && dir != "sdmc:" && dir.length > 0)
        {
          return dir;
        }
      }
    }
    catch (e:Dynamic)
    {
      trace('Error determining Switch app dir: ' + e);
    }
    return "sdmc:/switch/Friday-Night-Funkin";
    #else
    return sanitizePath(Sys.getCwd());
    #end
  }

  /**
   * Sanitizes a path string against directory traversal attacks (e.g. "../", redundant slashes, null bytes).
   */
  public static function sanitizePath(path:String):String
  {
    if (path == null) return "";
    var clean:String = StringTools.replace(path, "\\", "/");
    clean = StringTools.replace(clean, "\x00", "");
    while (clean.indexOf("../") != -1) clean = StringTools.replace(clean, "../", "");
    while (clean.indexOf("/..") != -1) clean = StringTools.replace(clean, "/..", "");
    var parts:Array<String> = clean.split("://");
    if (parts.length > 1)
    {
      var scheme:String = parts[0];
      var rest:String = parts.slice(1).join("://");
      while (rest.indexOf("//") != -1) rest = StringTools.replace(rest, "//", "/");
      clean = scheme + ":/" + (StringTools.startsWith(rest, "/") ? rest.substr(1) : rest);
    }
    else
    {
      while (clean.indexOf("//") != -1) clean = StringTools.replace(clean, "//", "/");
    }
    return clean;
  }

  /**
   * Confines and resolves a relative subpath strictly inside the application root directory.
   */
  public static function getSafeAppSubPath(subPath:String):String
  {
    var appDir:String = getAppDir();
    var cleanSub:String = sanitizePath(subPath);
    while (StringTools.startsWith(cleanSub, "/")) cleanSub = cleanSub.substr(1);
    return sanitizePath('$appDir/$cleanSub');
  }

  /**
   * Initialize Nintendo Switch systems
   */
  public static function init()
  {
    #if switch
    nxController = new NXController();
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
