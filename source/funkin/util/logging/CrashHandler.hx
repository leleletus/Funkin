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
  #if switch
  public static var LOG_FOLDER(get, never):String;

  static function get_LOG_FOLDER():String
  {
    #if switch
    return nx.NXMain.getSafeAppSubPath('logs');
    #else
    return 'logs';
    #end
  }
  #else
  public static final LOG_FOLDER = 'logs';
  #end

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
      #if switch
      if (errorSignal != null)
      {
        errorSignal.dispatch(generateErrorMessage(error));
      }
      #else
      errorSignal.dispatch(generateErrorMessage(error));
      #end

      try
      {
        #if sys
        logError(error);
        #if switch
        nx.NXDeepTrace.logError('UNCAUGHT ERROR: ' + generateErrorMessage(error));
        #end
        #end
      }
      catch (e:Dynamic)
      {
        #if switch
        trace('CrashHandler fallback: Error while logging error: ' + e);
        #else
        trace('Error while logging error: ' + e);
        #end
      }

      displayError(error);
    }
    catch (e:Dynamic)
    {
      #if switch
      trace('CrashHandler fallback: Error while handling crash: ' + e);
      #else
      trace('Error while handling crash: ' + e);
      #end
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
      #if switch
      if (criticalErrorSignal != null)
      {
        criticalErrorSignal.dispatch(message);
      }
      #else
      criticalErrorSignal.dispatch(message);
      #end

      #if sys
      logErrorMessage(message, true);
      #if switch
      nx.NXDeepTrace.logError('CRITICAL ERROR: ' + message);
      #end
      #end

      displayErrorMessage(message);
    }
    catch (e:Dynamic)
    {
      #if switch
      trace('CrashHandler fallback: Error while handling crash: ' + e);
      #else
      trace('Error while handling crash: $e');
      #end

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
    #if switch
    try
    {
      funkin.util.WindowUtil.showError("Fatal Uncaught Exception", message);
    }
    catch (e:Dynamic)
    {
      trace('CrashHandler fallback: ' + e);
    }
    #else
    funkin.util.WindowUtil.showError("Fatal Uncaught Exception", message);
    #end
  }

  #if sys
  static function logError(error:UncaughtErrorEvent):Void
  {
    #if switch
    try
    {
      logErrorMessage(generateErrorMessage(error));
    }
    catch (e:Dynamic)
    {
      trace('CrashHandler fallback: ' + e);
    }
    #else
    logErrorMessage(generateErrorMessage(error));
    #end
  }

  static function logErrorMessage(message:String, critical:Bool = false):Void
  {
    #if switch
    try
    {
      FileUtil.createDirIfNotExists(LOG_FOLDER);
    #else
    FileUtil.createDirIfNotExists(LOG_FOLDER);
    #end

      #if switch
      var report:String = buildCrashReport(message);
      var timestamp:String = try { DateUtil.generateTimestamp(); } catch (e:Dynamic) { 'unknown'; };
      sys.io.File.saveContent('$LOG_FOLDER/crash${critical ? '-critical' : ''}-$timestamp.log', report);
    }
    catch (e:Dynamic)
    {
      trace('CrashHandler fallback: ' + e);
    }
      #else
    sys.io.File.saveContent('$LOG_FOLDER/crash${critical ? '-critical' : ''}-${DateUtil.generateTimestamp()}.log', buildCrashReport(message));
      #end
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
    #if switch
    try
    #else
    if (FlxG.game != null && FlxG.state != null)
    #end
    {
      #if switch
      if (FlxG.game != null && FlxG.state != null)
      #else
      var currentStateCls:Null<Class<Dynamic>> = Type.getClass(FlxG.state);
      if (currentStateCls != null)
      #end
      {
        #if switch
        var currentStateCls:Null<Class<Dynamic>> = Type.getClass(FlxG.state);
        if (currentStateCls != null)
        {
          currentState = Type.getClassName(currentStateCls) ?? 'No state loaded';
        }
        #else
        currentState = Type.getClassName(currentStateCls) ?? 'No state loaded';
        #end
      }
    #if switch
    }
    catch (e:Dynamic)
    {
      currentState = 'Error querying state: ' + e;
      trace('CrashHandler fallback: ' + e);
    #end
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

    #if switch
    try
    #else
    if (funkin.modding.PolymodHandler.loadedModIds.length == 0)
    #end
    {
      #if switch
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
      #else
      fullContents += 'No mods loaded.\n';
      #end
    }
    #if switch
    catch (e:Dynamic)
    #else
    else
    #end
    {
      #if switch
      fullContents += 'Error querying loaded mods: $e\n';
      trace('CrashHandler fallback: ' + e);
      #else
      for (mod in funkin.modding.PolymodHandler.loadedModIds)
      {
        fullContents += '- ${mod}\n';
      }
      #end
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
    #if switch
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
    #else
    fullContents += 'System timestamp: ${DateUtil.generateTimestamp()}\n';
    var driverInfo = FlxG?.stage?.context3D?.driverInfo ?? 'N/A';
    #end
    fullContents += 'Driver info: ${driverInfo}\n';
    #if sys
    #if switch
    try
    {
      fullContents += 'Platform: ${Sys.systemName()}\n';
    }
    catch (e:Dynamic)
    {
      fullContents += 'Platform: N/A\n';
      trace('CrashHandler fallback: ' + e);
    }
    #else
    fullContents += 'Platform: ${Sys.systemName()}\n';
    #end
    #end
    fullContents += 'Render method: ${renderMethod()}\n';

    fullContents += '\n';

    fullContents += '=====================\n';

    fullContents += '\n';

    #if switch
    try
    {
      fullContents += MemoryUtil.buildGCInfo();
    }
    catch (e:Dynamic)
    {
      fullContents += 'Error querying memory info: $e\n';
      trace('CrashHandler fallback: ' + e);
    }
    #else
    fullContents += MemoryUtil.buildGCInfo();
    #end

    return fullContents;
  }

  static function generateErrorMessage(error:UncaughtErrorEvent):String
  {
    var errorMessage:String = "";
    #if switch
    try
    {
      var callStack:Array<haxe.CallStack.StackItem> = haxe.CallStack.exceptionStack(true);
    #else
    var callStack:Array<haxe.CallStack.StackItem> = haxe.CallStack.exceptionStack(true);
    #end

      #if switch
      if (error != null)
      {
        errorMessage += '${error.error}\n';
      }
      else
      {
        errorMessage += 'Unknown error (null event)\n';
      }
      #else
    errorMessage += '${error.error}\n';
      #end

      #if switch
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
      #else
    for (stackItem in callStack)
      #end
    {
      #if switch
      errorMessage += 'Error generating error message: $e\n';
      trace('CrashHandler fallback: ' + e);
      #else
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
      #end
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
    #if switch
    try
    #else
    outputStr = try
    #end
    {
      #if switch
      if (FlxG.game != null)
      #else
      switch (FlxG.renderMethod)
      #end
      {
        #if switch
        switch (FlxG.renderMethod)
        {
          case FlxRenderMethod.DRAW_TILES:
            outputStr = 'DRAW_TILES';
          case FlxRenderMethod.BLITTING:
            outputStr = 'BLITTING';
          default:
            outputStr = 'UNKNOWN';
        }
      }
      else
      {
        outputStr = 'NO_GAME_INSTANCE';
        #else
        case FlxRenderMethod.DRAW_TILES:
          'DRAW_TILES';
        case FlxRenderMethod.BLITTING:
          'BLITTING';
        default:
          'UNKNOWN';
        #end
      }
    }
    #if switch
    catch (e:Dynamic)
    #else
    catch (e)
    #end
    {
      #if switch
      outputStr = 'ERROR ON QUERY RENDER METHOD: ${e}';
      trace('CrashHandler fallback: ' + e);
      #else
      'ERROR ON QUERY RENDER METHOD: ${e}';
      #end
    }

    return outputStr;
  }
}
