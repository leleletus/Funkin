package nx;

import openfl.Lib;
import openfl.text.TextField;
import openfl.text.TextFormat;

/**
 * Small on-screen status line for automated runs started on the console (L+R held 3 s), so progress and
 * the final result are visible without reading the log. Test builds only (NX_DEV_TOOLS).
 */
class NXDevOverlay
{
  static var field:Null<TextField> = null;
  static var hideAt:Float = -1.0;

  public static function show(text:String, ?seconds:Float = -1.0):Void
  {
    #if NX_DEV_TOOLS
    try
    {
      if (field == null)
      {
        field = new TextField();
        field.defaultTextFormat = new TextFormat('_sans', 18, 0xFFFFFF);
        field.background = true;
        field.backgroundColor = 0x000000;
        field.selectable = false;
        field.mouseEnabled = false;
        field.width = 1280;
        field.height = 28;
        field.x = 0;
        field.y = 0;
      }
      field.text = text;
      // Keep it above the game (re-added after every state switch).
      if (field.parent != null) field.parent.removeChild(field);
      Lib.current.stage.addChild(field);
      field.visible = true;
      hideAt = (seconds > 0) ? haxe.Timer.stamp() + seconds : -1.0;
    }
    catch (e:Dynamic) {}
    #end
  }

  /**
   * Called every frame (NXPerformance.update) to auto-hide timed messages.
   */
  public static function update():Void
  {
    #if NX_DEV_TOOLS
    if (field != null && hideAt > 0 && haxe.Timer.stamp() >= hideAt)
    {
      field.visible = false;
      hideAt = -1.0;
    }
    #end
  }

  public static function hide():Void
  {
    #if NX_DEV_TOOLS
    if (field != null) field.visible = false;
    hideAt = -1.0;
    #end
  }
}
