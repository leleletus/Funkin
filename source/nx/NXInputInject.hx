package nx;

#if (switch && cpp)
/**
 * Test-only input injection: pushes real SDL game controller events, so a simulated press travels the
 * same path as a physical one (SDL -> lime -> flixel gamepad -> Controls). Pressing flixel's gamepad
 * objects directly is not equivalent: the next input update overwrites them before the game reads them.
 */
@:buildXml("<files id='haxe'><compilerflag value='-I${DEVKITPRO}/portlibs/switch/include'/></files>")
@:cppFileCode('
#include <SDL2/SDL.h>

static int nx_pushControllerButton(int button, int down)
{
  if (SDL_NumJoysticks() <= 0) return -1;
  SDL_Event e;
  SDL_zero(e);
  e.type = down ? SDL_CONTROLLERBUTTONDOWN : SDL_CONTROLLERBUTTONUP;
  e.cbutton.timestamp = SDL_GetTicks();
  e.cbutton.which = SDL_JoystickGetDeviceInstanceID(0);
  e.cbutton.button = (Uint8)button;
  e.cbutton.state = down ? SDL_PRESSED : SDL_RELEASED;
  return SDL_PushEvent(&e);
}
')
#end
class NXInputInject
{
  /**
   * SDL game controller button that the Switch's physical A produces (SDL maps buttons by position:
   * A is the east button, SDL_CONTROLLER_BUTTON_B).
   */
  public static inline final SWITCH_A:Int = 1;

  /**
   * SDL game controller buttons for the Switch's + and D-pad.
   */
  public static inline final SWITCH_PLUS:Int = 6;

  public static inline final SWITCH_DPAD_DOWN:Int = 12;

  public static inline final SWITCH_DPAD_UP:Int = 11;

  static var pendingRelease:Int = -1;
  static var releaseFrames:Int = -1;

  /**
   * Presses `button` now and releases it 3 frames later, like a quick tap.
   * @return false if no controller is connected.
   */
  public static function tap(button:Int):Bool
  {
    #if (switch && cpp)
    var result:Int = untyped __cpp__('nx_pushControllerButton({0}, 1)', button);
    if (result < 0) return false;
    pendingRelease = button;
    if (releaseFrames < 0) flixel.FlxG.signals.postUpdate.add(releaseLater);
    releaseFrames = 3;
    return true;
    #else
    return false;
    #end
  }

  static function releaseLater():Void
  {
    #if (switch && cpp)
    if (--releaseFrames > 0) return;
    untyped __cpp__('nx_pushControllerButton({0}, 0)', pendingRelease);
    releaseFrames = -1;
    flixel.FlxG.signals.postUpdate.remove(releaseLater);
    #end
  }
}
