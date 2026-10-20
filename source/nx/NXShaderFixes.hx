package nx;

/**
 * Switch-only adjustments to the source of the game's shaders, applied right before the GL program is created so
 * the official shader files and headers stay untouched.
 */
class NXShaderFixes
{
  static inline final STOCK_BITMAP_COORD_SCALE:String = 'return openfl_TextureCoordv / screenCoord;';
  static inline final SAFE_BITMAP_COORD_SCALE:String = 'return openfl_TextureCoordv / max(screenCoord, vec2(0.0001));';

  static var warnedMissing:Bool = false;

  /**
   * RuntimePostEffectShader (and the rain shader that extends it): bitmapCoordScale() divides by the normalized
   * screen coordinate, which is 0 on the first row and column; the divisor is clamped to avoid the division by zero.
   */
  public static function postEffectFragment(source:String):String
  {
    if (source == null) return source;
    if (source.indexOf(STOCK_BITMAP_COORD_SCALE) == -1)
    {
      // The official header changed: the fix no longer applies and has to be updated.
      if (!warnedMissing && source.indexOf('bitmapCoordScale') != -1)
      {
        warnedMissing = true;
        NXDeepTrace.writeEntry('SHADER', '[NXShaderFixes] bitmapCoordScale() no longer matches the stock code; the division guard was not applied');
      }
      return source;
    }
    return StringTools.replace(source, STOCK_BITMAP_COORD_SCALE, SAFE_BITMAP_COORD_SCALE);
  }
}
