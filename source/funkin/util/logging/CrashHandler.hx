package funkin.util.logging;

import openfl.Lib;
import openfl.events.UncaughtErrorEvent;
import flixel.util.FlxSignal.FlxTypedSignal;
import flixel.FlxG.FlxRenderMethod;

/**
 * A custom crash handler that writes to a log file and displays a message box.
 */
@:nullSafety
class CrashHandler
{
  public static var LOG_FOLDER(get, never):String;

  static function get_LOG_FOLDER():String
  {
    #if switch
    return nx.NXMain.getSafeAppSubPath('logs');
    #else
    return 'logs';
    #end
  }

  /**
   * Called before exiting the game when a standard error occurs, like a thrown exception.
   * @param message The error message.
   */
  public static var errorSignal(default, null):FlxTypedSignal<String->Void> = new FlxTypedSignal<String->Void>();

  /**
   * Called before exiting the game when a critical error occurs, like a stack overflow or null object reference.
   * CAREFUL: The game may be in an unstable state when this is called.
   * @param message The error message.
   */
  public static var criticalErrorSignal(default, null):FlxTypedSignal<String->Void> = new FlxTypedSignal<String->Void>();

  /**
   * Initializes
   */
  public static function initialize():Void
  {
    trace('[LOG] Enabling standard uncaught error handler...');
    Lib.current.loaderInfo.uncaughtErrorEvents.addEventListener(UncaughtErrorEvent.UNCAUGHT_ERROR, onUncaughtError);

    #if cpp
    trace('[LOG] Enabling C++ critical error handler...');
    untyped __global__.__hxcpp_set_critical_error_handler(onCriticalError);
    #end
  }

  /**
   * Called when an uncaught error occurs.
   * This handles most thrown errors, and is sufficient to handle everything alone on HTML5.
   * @param error Information on the error that was thrown.
   */
  static function onUncaughtError(error:UncaughtErrorEvent):Void
  {
    try
    {
      if (errorSignal != null)
      {
        errorSignal.dispatch(generateErrorMessage(error));
      }

      try
      {
        #if sys
        logError(error);
        #end
      }
      catch (e:Dynamic)
      {
        trace('CrashHandler fallback: Error while logging error: ' + e);
      }

      displayError(error);
    }
    catch (e:Dynamic)
    {
      trace('CrashHandler fallback: Error while handling crash: ' + e);
    }

    #if sys
    Sys.sleep(1); // wait a few moments of margin to process.
    // Exit the game. Since it threw an error, we use a non-zero exit code.
    openfl.Lib.application.window.close();
    #end
  }

  static function onCriticalError(message:String):Void
  {
    try
    {
      if (criticalErrorSignal != null)
      {
        criticalErrorSignal.dispatch(message);
      }

      #if sys
      logErrorMessage(message, true);
      #end

      displayErrorMessage(message);
    }
    catch (e:Dynamic)
    {
      trace('CrashHandler fallback: Error while handling crash: ' + e);

      trace('Message: $message');
    }

    #if sys
    Sys.sleep(1); // wait a few moments of margin to process.
    // Exit the game. Since it threw an error, we use a non-zero exit code.
    openfl.Lib.application.window.close();
    #end
  }

  static function displayError(error:UncaughtErrorEvent):Void
  {
    displayErrorMessage(generateErrorMessage(error));
  }

  static function displayErrorMessage(message:String):Void
  {
    try
    {
      funkin.util.WindowUtil.showError("Fatal Uncaught Exception", message);
    }
    catch (e:Dynamic)
    {
      trace('CrashHandler fallback: ' + e);
    }
  }

  #if sys
  static function logError(error:UncaughtErrorEvent):Void
  {
    try
    {
      logErrorMessage(generateErrorMessage(error));
    }
    catch (e:Dynamic)
    {
      trace('CrashHandler fallback: ' + e);
    }
  }

  static function logErrorMessage(message:String, critical:Bool = false):Void
  {
    try
    {
      FileUtil.createDirIfNotExists(LOG_FOLDER);

      var report:String = buildCrashReport(message);
      var timestamp:String = try { DateUtil.generateTimestamp(); } catch (e:Dynamic) { 'unknown'; };
      sys.io.File.saveContent('$LOG_FOLDER/crash${critical ? '-critical' : ''}-$timestamp.log', report);
    }
    catch (e:Dynamic)
    {
      trace('CrashHandler fallback: ' + e);
    }
  }
  #end

  static function buildCrashReport(message:String):String
  {
    var fullContents:String = '=====================\n';
    fullContents += ' Funkin Crash Report\n';
    fullContents += '=====================\n';

    fullContents += '\n';

    fullContents += buildSystemInfo();

    fullContents += '\n\n';

    fullContents += '=====================\n';

    fullContents += '\n';

    var currentState:String = 'No state loaded';
    try
    {
      if (FlxG.game != null && FlxG.state != null)
      {
        var currentStateCls:Null<Class<Dynamic>> = Type.getClass(FlxG.state);
        if (currentStateCls != null)
        {
          currentState = Type.getClassName(currentStateCls) ?? 'No state loaded';
        }
      }
    }
    catch (e:Dynamic)
    {
      currentState = 'Error querying state: ' + e;
      trace('CrashHandler fallback: ' + e);
    }

    fullContents += 'Flixel Current State: ${currentState}\n';

    fullContents += '\n';

    fullContents += '=====================\n';

    fullContents += '\n';

    fullContents += 'Haxelibs: \n';

    for (lib in Constants.LIBRARY_VERSIONS)
    {
      fullContents += '- ${lib}\n';
    }

    fullContents += '\n';

    fullContents += '=====================\n';

    fullContents += '\n';

    fullContents += 'Loaded mods: \n';

    try
    {
      if (funkin.modding.PolymodHandler.loadedModIds == null || funkin.modding.PolymodHandler.loadedModIds.length == 0)
      {
        fullContents += 'No mods loaded.\n';
      }
      else
      {
        for (mod in funkin.modding.PolymodHandler.loadedModIds)
        {
          fullContents += '- ${mod}\n';
        }
      }
    }
    catch (e:Dynamic)
    {
      fullContents += 'Error querying loaded mods: $e\n';
      trace('CrashHandler fallback: ' + e);
    }

    fullContents += '\n';

    fullContents += '=====================\n';

    fullContents += '\n';

    fullContents += message;

    fullContents += '\n';

    return fullContents;
  }

  public static function buildSystemInfo():String
  {
    var fullContents = 'Generated by: ${Constants.GENERATED_BY}\n';
    fullContents += ' Git hash: ${Constants.GIT_HASH} (${Constants.GIT_HAS_LOCAL_CHANGES ? 'MODIFIED' : 'CLEAN'})\n';
    try
    {
      fullContents += 'System timestamp: ${DateUtil.generateTimestamp()}\n';
    }
    catch (e:Dynamic)
    {
      fullContents += 'System timestamp: N/A ($e)\n';
      trace('CrashHandler fallback: ' + e);
    }
    var driverInfo:String = 'N/A';
    try
    {
      if (FlxG.stage != null && FlxG.stage.context3D != null)
      {
        driverInfo = FlxG.stage.context3D.driverInfo ?? 'N/A';
      }
    }
    catch (e:Dynamic)
    {
      driverInfo = 'Error querying driver: ' + e;
      trace('CrashHandler fallback: ' + e);
    }
    fullContents += 'Driver info: ${driverInfo}\n';
    #if sys
    try
    {
      fullContents += 'Platform: ${Sys.systemName()}\n';
    }
    catch (e:Dynamic)
    {
      fullContents += 'Platform: N/A\n';
      trace('CrashHandler fallback: ' + e);
    }
    #end
    fullContents += 'Render method: ${renderMethod()}\n';

    fullContents += '\n';

    fullContents += '=====================\n';

    fullContents += '\n';

    try
    {
      fullContents += MemoryUtil.buildGCInfo();
    }
    catch (e:Dynamic)
    {
      fullContents += 'Error querying memory info: $e\n';
      trace('CrashHandler fallback: ' + e);
    }

    return fullContents;
  }

  static function generateErrorMessage(error:UncaughtErrorEvent):String
  {
    var errorMessage:String = "";
    try
    {
      var callStack:Array<haxe.CallStack.StackItem> = haxe.CallStack.exceptionStack(true);

      if (error != null)
      {
        errorMessage += '${error.error}\n';
      }
      else
      {
        errorMessage += 'Unknown error (null event)\n';
      }

      for (stackItem in callStack)
      {
        switch (stackItem)
        {
          case FilePos(innerStackItem, file, line, column):
            errorMessage += ' in ${file}#${line}';
            if (column != null) errorMessage += ':${column}';
          case CFunction:
            errorMessage += '[Function] ';
          case Module(m):
            errorMessage += '[Module(${m})] ';
          case Method(classname, method):
            errorMessage += '[Function(${classname}.${method})] ';
          case LocalFunction(v):
            errorMessage += '[LocalFunction(${v})] ';
        }
        errorMessage += '\n';
      }
    }
    catch (e:Dynamic)
    {
      errorMessage += 'Error generating error message: $e\n';
      trace('CrashHandler fallback: ' + e);
    }

    return errorMessage;
  }

  public static function queryStatus():Void
  {
    @:privateAccess
    var currentStatus = Lib.current.stage.__uncaughtErrorEvents.__enabled;
    trace('ERROR HANDLER STATUS: ' + currentStatus);

    #if openfl_enable_handle_error
    trace('Define: openfl_enable_handle_error is enabled');
    #else
    trace('Define: openfl_enable_handle_error is disabled');
    #end

    #if openfl_disable_handle_error
    trace('Define: openfl_disable_handle_error is enabled');
    #else
    trace('Define: openfl_disable_handle_error is disabled');
    #end
  }

  public static function induceBasicCrash():Void
  {
    throw "This is an example of an uncaught exception.";
  }

  public static function induceNullObjectReference():Void
  {
    var obj:Dynamic = null;
    var value = obj.test;
  }

  public static function induceNullObjectReference2():Void
  {
    var obj:Dynamic = null;
    var value = obj.test();
  }

  public static function induceNullObjectReference3():Void
  {
    var obj:Dynamic = null;
    var value = obj();
  }

  static function renderMethod():String
  {
    var outputStr:String = 'UNKNOWN';
    try
    {
      if (FlxG.game != null)
      {
        switch (FlxG.renderMethod)
        {
          case FlxRenderMethod.DRAW_TILES: outputStr = 'DRAW_TILES';
          case FlxRenderMethod.BLITTING: outputStr = 'BLITTING';
          default: outputStr = 'UNKNOWN';
        }
      }
      else
      {
        outputStr = 'NO_GAME_INSTANCE';
      }
    }
    catch (e:Dynamic)
    {
      outputStr = 'ERROR ON QUERY RENDER METHOD: ${e}';
      trace('CrashHandler fallback: ' + e);
    }

    return outputStr;
  }
}
