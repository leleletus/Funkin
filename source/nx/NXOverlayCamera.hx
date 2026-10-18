package nx;

import flixel.FlxCamera;
import flixel.FlxG;
import flixel.util.FlxColor;
import openfl.display.Graphics;

/**
 * Overlay camera for PlayState's camCutscene on Switch.
 *
 * Every visible FlxCamera fills its whole view with its background colour each frame. For an overlay
 * camera the background is fully transparent, so that full-screen quad changes no pixel but still costs
 * GPU fill rate on the Tegra X1. Build 15 avoided it by hiding camCutscene, but the official stage and song
 * scripts draw on that camera (Spaghetti's "Skip [A]" prompt and its fades, Eggnog Erect, Philly Erect,
 * Stress...), so their content was invisible on Switch. This camera stays visible like upstream and only
 * skips the transparent fill; fades and flashes (alpha > 0) are drawn as usual.
 */
class NXOverlayCamera extends FlxCamera
{
  override public function fill(Color:FlxColor, BlendAlpha:Bool = true, FxAlpha:Float = 1.0, ?graphics:Graphics):Void
  {
    if (!FlxG.renderBlit && FxAlpha <= 0) return;
    super.fill(Color, BlendAlpha, FxAlpha, graphics);
  }
}
