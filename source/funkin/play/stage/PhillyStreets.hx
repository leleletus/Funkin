package funkin.play.stage;

import flixel.FlxG;
import openfl.filters.ShaderFilter;
import funkin.graphics.FunkinCamera;
import funkin.graphics.shaders.RuntimeRainShader;

/**
 * Native compiled helper and stage controller for Philly Streets and Philly Blazin on Nintendo Switch.
 * Ensures rain shaders and camera filter passes are strictly validated and handled safely without
 * touching Polymod .hxc asset scripts or saturating Mesa/Tegra X1 framebuffers to pure white.
 */
class PhillyStreets
{
  /**
   * Safely applies the rain shader filter to a camera.
   * Validates that the shader compiled and linked cleanly.
   * If the shader fails, has linking warnings/errors, or if shaders are disabled,
   * camera filters are completely cleared (`filtersEnabled = false; flashSprite.filters = null;`).
   */
  public static function applyRainShaderSafe(cam:Null<FunkinCamera>, rainShader:Null<RuntimeRainShader>):Void
  {
    if (cam == null) return;

    #if switch
    if (!funkin.Preferences.switchEnableShaders)
    {
      disableFilters(cam);
      return;
    }
    #end

    if (rainShader == null)
    {
      disableFilters(cam);
      return;
    }

    try
    {
      if (rainShader.data == null)
      {
        #if switch
        nx.NXDeepTrace.writeEntry('SHADER', 'PhillyStreets: Rain shader has no data/unlinked. Disabling camera filters.');
        #end
        disableFilters(cam);
        return;
      }

      var filter = new ShaderFilter(rainShader);
      cam.setFilters([filter]);
    }
    catch (e:Dynamic)
    {
      #if switch
      nx.NXDeepTrace.logError('PhillyStreets: Exception applying rain shader: ' + e);
      #end
      disableFilters(cam);
    }
  }

  /**
   * Completely clears filters from the camera and resets the render pass.
   */
  public static function disableFilters(cam:Null<FunkinCamera>):Void
  {
    if (cam == null) return;
    cam.filters = null;
    cam.filtersEnabled = false;
    if (cam.flashSprite != null)
    {
      cam.flashSprite.filters = null;
    }
  }
}
