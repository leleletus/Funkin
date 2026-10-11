package funkin.graphics.shaders;

import openfl.display.BitmapData;
import openfl.display.ShaderParameter;
import openfl.display.ShaderParameterType;
import flixel.util.FlxColor;

typedef Light =
{
  var position:Array<Float>;
  var color:Array<Float>;
  var radius:Float;
}

class RuntimeRainShader extends RuntimePostEffectShader
{
  static final MAX_LIGHTS:Int = 8;

  public var lights:Array<
    {
      position:ShaderParameter<Float>,
      color:ShaderParameter<Float>,
      radius:ShaderParameter<Float>,
    }>;

  public var time(default, set):Float = 1;

  function set_time(value:Float):Float
  {
    this.setFloat('uTime', value);
    return time = value;
  }

  public var spriteMode(default, set):Bool = false;

  function set_spriteMode(value:Bool):Bool
  {
    this.setBool('uSpriteMode', value);
    return spriteMode = value;
  }

  // The scale of the rain depends on the world coordinate system, so higher resolution makes
  // the raindrops smaller. This parameter can be used to adjust the total scale of the scene.
  // The size of the raindrops is proportional to the value of this parameter.
  public var scale(default, set):Float = 1;

  function set_scale(value:Float):Float
  {
    this.setFloat('uScale', value);
    return scale = value;
  }

  // The intensity of the rain. Zero means no rain and one means the maximum amount of rain.
  public var intensity(default, set):Float = 0.5;

  function set_intensity(value:Float):Float
  {
    this.setFloat('uIntensity', value);
    return intensity = value;
  }

  // the y coord of the puddle, used to mirror things
  public var puddleY(default, set):Float = 0;

  function set_puddleY(value:Float):Float
  {
    this.setFloat('uPuddleY', value);
    return puddleY = value;
  }

  // the y scale of the puddle, the less this value the more the puddle effects squished
  public var puddleScaleY(default, set):Float = 0;

  function set_puddleScaleY(value:Float):Float
  {
    this.setFloat('uPuddleScaleY', value);
    return puddleScaleY = value;
  }

  public var blurredScreen(default, set):BitmapData;

  function set_blurredScreen(value:BitmapData):BitmapData
  {
    if (value != null) this.setBitmapData('uBlurredScreen', value);
    return blurredScreen = value;
  }

  public var mask(default, set):BitmapData;

  function set_mask(value:BitmapData):BitmapData
  {
    if (value != null) this.setBitmapData('uMask', value);
    return mask = value;
  }

  public var rainColor(default, set):FlxColor;

  function set_rainColor(color:FlxColor):FlxColor
  {
    this.setFloatArray("uRainColor", [color.red / 255, color.green / 255, color.blue / 255]);
    return rainColor = color;
  }

  public var lightMap(default, set):BitmapData;

  function set_lightMap(value:BitmapData):BitmapData
  {
    if (value != null) this.setBitmapData('uLightMap', value);
    return lightMap = value;
  }

  public var numLightsSwag(default, set):Int = 0; // swag heads, we have never been more back (needs different name purely for hashlink casting fix)

  function set_numLightsSwag(value:Int):Int
  {
    this.setInt('numLights', value);
    return numLightsSwag = value;
  }

  public function new()
  {
    var fragSource:Null<String> = null;
    try
    {
      #if switch
      if (funkin.Preferences.switchEnableShaders)
      {
        if (openfl.utils.Assets.exists(Paths.frag('rain')))
          fragSource = openfl.utils.Assets.getText(Paths.frag('rain'));
        else if (openfl.utils.Assets.exists('assets/shaders/rain.frag'))
          fragSource = openfl.utils.Assets.getText('assets/shaders/rain.frag');
        else if (openfl.utils.Assets.exists('assets/preload/shaders/rain.frag'))
          fragSource = openfl.utils.Assets.getText('assets/preload/shaders/rain.frag');
      }
      #else
      if (openfl.utils.Assets.exists(Paths.frag('rain')))
        fragSource = openfl.utils.Assets.getText(Paths.frag('rain'));
      else if (openfl.utils.Assets.exists('assets/shaders/rain.frag'))
        fragSource = openfl.utils.Assets.getText('assets/shaders/rain.frag');
      else if (openfl.utils.Assets.exists('assets/preload/shaders/rain.frag'))
        fragSource = openfl.utils.Assets.getText('assets/preload/shaders/rain.frag');
      #end
    }
    catch (e:Dynamic)
    {
      fragSource = null;
    }

    if (fragSource != null && fragSource.length > 0)
    {
      super(fragSource);
    }
    else
    {
      super('
        #pragma header
        uniform float uTime;
        uniform float uScale;
        uniform float uIntensity;
        uniform float uPuddleY;
        uniform float uPuddleScaleY;
        uniform bool uSpriteMode;
        uniform vec3 uRainColor;
        uniform int numLights;
        void main() {
          gl_FragColor = flixel_texture2D(bitmap, openfl_TextureCoordv);
        }
      ');
    }
    this.rainColor = 0xFF6680cc;
  }

  public function update(elapsed:Float):Void
  {
    time += elapsed;
  }

  override function __processGLData(source:String, storageType:String):Void
  {
    super.__processGLData(source, storageType);
    if (storageType == 'uniform')
    {
      lights = [
        for (i in 0...MAX_LIGHTS)
          {
            position: addFloatUniform('lights[$i].position', 2),
            color: addFloatUniform('lights[$i].color', 3),
            radius: addFloatUniform('lights[$i].radius', 1),
          }
      ];
    }
  }

  @:access(openfl.display.ShaderParameter)
  function addFloatUniform(name:String, length:Int):ShaderParameter<Float>
  {
    final res = new ShaderParameter<Float>();
    res.name = name;
    res.type = [null, FLOAT, FLOAT2, FLOAT3, FLOAT4][length];
    res.__arrayLength = 1;
    res.__isFloat = true;
    res.__isUniform = true;
    res.__length = length;
    __paramFloat.push(res);
    return res;
  }
}
