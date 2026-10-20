package nx.video;

import flixel.system.FlxAssets.FlxShader;

/**
 * Draws a YUV 4:2:0 video frame uploaded by NXVideoDecoder. The sprite's own texture (`bitmap`) holds the luma
 * plane packed 4 samples per RGBA texel (width/4 texels); `uvTex` holds both chroma planes the same way
 * (width/8 texels, U rows on top, V rows below). Both are sampled with NEAREST at texel centres, so each output
 * pixel reads exactly its own samples. BT.709, limited range (all the official cutscenes).
 */
class NXYuvShader extends FlxShader
{
  @:glFragmentSource('
    #pragma header

    uniform sampler2D uvTex;
    uniform vec2 videoSize;
    uniform float swapRB;

    // Byte i (0-3) of a texel, in memory order: with GL_BGRA_EXT the bytes come back as b, g, r, a.
    float pickByte(vec4 t, float i)
    {
      vec4 c = (swapRB > 0.5) ? t.bgra : t;
      if (i < 0.5) return c.x;
      if (i < 1.5) return c.y;
      if (i < 2.5) return c.z;
      return c.w;
    }

    void main()
    {
      vec2 coord = openfl_TextureCoordv;
      float px = min(floor(coord.x * videoSize.x), videoSize.x - 1.0);
      float py = min(floor(coord.y * videoSize.y), videoSize.y - 1.0);

      float lumaTexels = videoSize.x / 4.0;
      vec4 lumaTexel = texture2D(bitmap, vec2((floor(px / 4.0) + 0.5) / lumaTexels, (py + 0.5) / videoSize.y));
      float yValue = pickByte(lumaTexel, mod(px, 4.0));

      float cx = floor(px / 2.0);
      float cy = floor(py / 2.0);
      float chromaTexels = videoSize.x / 8.0;
      float tx = (floor(cx / 4.0) + 0.5) / chromaTexels;
      float uValue = pickByte(texture2D(uvTex, vec2(tx, (cy + 0.5) / videoSize.y)), mod(cx, 4.0));
      float vValue = pickByte(texture2D(uvTex, vec2(tx, (cy + videoSize.y * 0.5 + 0.5) / videoSize.y)), mod(cx, 4.0));

      float y = (yValue - 0.0627451) * 1.1643836;
      float u = (uValue - 0.5) * 1.1383929;
      float v = (vValue - 0.5) * 1.1383929;
      vec3 rgb = vec3(y + 1.5748 * v, y - 0.1873243 * u - 0.4681243 * v, y + 1.8556 * u);
      gl_FragColor = vec4(clamp(rgb, 0.0, 1.0), 1.0) * openfl_Alphav;
    }
  ')
  public function new()
  {
    super();
  }
}
