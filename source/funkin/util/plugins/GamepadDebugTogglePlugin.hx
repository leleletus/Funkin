package funkin.util.plugins;

import flixel.FlxBasic;
import flixel.input.gamepad.FlxGamepadInputID;

/**
 * A plugin which adds functionality to press Select (BACK) on a gamepad to toggle the debug console.
 */
@:nullSafety
class GamepadDebugTogglePlugin extends FlxBasic
{
  public function new()
  {
    super();
  }

  public static function initialize():Void
  {
    #if !switch
    FlxG.plugins.addPlugin(new GamepadDebugTogglePlugin());
    #end
  }

  public override function update(elapsed:Float):Void
  {
    super.update(elapsed);

    #if !switch
    for (gamepad in FlxG.gamepads.getActiveGamepads())
    {
      if (gamepad != null && gamepad.justPressed.BACK)
      {
        FlxG.debugger.visible = !FlxG.debugger.visible;
        break;
      }
    }
    #end
  }

  public override function destroy():Void
  {
    super.destroy();
  }
}
