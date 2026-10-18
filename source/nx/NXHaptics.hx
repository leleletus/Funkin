package nx;

#if (switch && cpp)
/**
 * Native HD Rumble for Nintendo Switch (libnx HID vibration).
 *
 * The game's haptics (HapticUtil) only existed for mobile (extension-haptics), so on Switch every
 * vibration call compiled to nothing. This module implements the same API (one-shot and patterns)
 * for the controller currently in use: Joy-Cons attached in handheld mode, Pro Controller or a pair
 * of Joy-Cons (player 1). Vibrations stop by themselves after their duration (update() every frame).
 */
@:cppFileCode('
#include <switch.h>

static HidVibrationDeviceHandle nx_vibHandles[2];
static s32 nx_vibCount = 0;
static int nx_vibId = -1;
static int nx_vibStyle = 0;
static int nx_vibLastRc = 0;

// Picks the active controller (handheld first, then player 1) and (re)initializes its handles.
static bool nx_vibPrepare()
{
  HidNpadIdType ids[2] = { HidNpadIdType_Handheld, HidNpadIdType_No1 };
  for (int i = 0; i < 2; i++)
  {
    u32 styles = hidGetNpadStyleSet(ids[i]);
    HidNpadStyleTag tag;
    if (styles & HidNpadStyleTag_NpadHandheld) tag = HidNpadStyleTag_NpadHandheld;
    else if (styles & HidNpadStyleTag_NpadFullKey) tag = HidNpadStyleTag_NpadFullKey;
    else if (styles & HidNpadStyleTag_NpadJoyDual) tag = HidNpadStyleTag_NpadJoyDual;
    else if (styles & HidNpadStyleTag_NpadJoyLeft) tag = HidNpadStyleTag_NpadJoyLeft;
    else if (styles & HidNpadStyleTag_NpadJoyRight) tag = HidNpadStyleTag_NpadJoyRight;
    else continue;

    if (nx_vibId == (int)ids[i] && nx_vibStyle == (int)tag && nx_vibCount > 0) return true;

    s32 count = (tag == HidNpadStyleTag_NpadJoyLeft || tag == HidNpadStyleTag_NpadJoyRight) ? 1 : 2;
    Result rc = hidInitializeVibrationDevices(nx_vibHandles, count, ids[i], tag);
    if (R_FAILED(rc)) { nx_vibLastRc = (int)rc; continue; }
    nx_vibId = (int)ids[i];
    nx_vibStyle = (int)tag;
    nx_vibCount = count;
    return true;
  }
  nx_vibCount = 0;
  nx_vibId = -1;
  nx_vibStyle = 0;
  return false;
}

// amplitude 0..1, sharpness 0..1 (0 = deep/low band, 1 = crisp/high band)
// Returns 0 sent, 1 no controller / init failed, 2 send failed (nx_vibLastRc has the libnx code).
static int nx_vibSend(float amplitude, float sharpness)
{
  if (!nx_vibPrepare()) return 1;
  if (amplitude < 0.0f) amplitude = 0.0f;
  if (amplitude > 1.0f) amplitude = 1.0f;
  if (sharpness < 0.0f) sharpness = 0.0f;
  if (sharpness > 1.0f) sharpness = 1.0f;
  HidVibrationValue values[2];
  for (int i = 0; i < 2; i++)
  {
    values[i].amp_low = amplitude * (1.0f - 0.5f * sharpness);
    values[i].freq_low = 160.0f;
    values[i].amp_high = amplitude * (0.5f + 0.5f * sharpness);
    values[i].freq_high = 320.0f;
  }
  Result rc = hidSendVibrationValues(nx_vibHandles, values, nx_vibCount);
  if (R_FAILED(rc)) { nx_vibLastRc = (int)rc; return 2; }
  return 0;
}
')
#end
class NXHaptics
{
  /**
   * HD Rumble needs a few frames to be felt; shorter requests (the game uses 0.01 s taps) are stretched to this.
   */
  static final MIN_SEGMENT_SECONDS:Float = 0.03;

  /**
   * Segments still to play: [duration s, amplitude, sharpness].
   */
  static var queue:Array<Array<Float>> = [];
  static var segmentEnd:Float = -1.0;
  static var active:Bool = false;

  static var lastDevice:String = '';

  /**
   * Result of the last native send: 0 sent, 1 no controller / init failed, 2 send failed.
   */
  public static var lastResult(default, null):Int = 0;

  /**
   * Non-zero pulses sent since boot.
   */
  public static var sentCount(default, null):Int = 0;

  public static function isActive():Bool
  {
    return active;
  }

  public static function describeStatus():String
  {
    return 'device=${describeDevice()} result=$lastResult sent=$sentCount active=$active';
  }

  /**
   * Single vibration of `duration` seconds.
   */
  public static function vibrateOneShot(duration:Float, amplitude:Float, sharpness:Float):Void
  {
    queue = [[duration, amplitude, sharpness]];
    startNext();
  }

  /**
   * Sequence of vibrations (same contract as extension-haptics Haptic.vibratePattern).
   */
  public static function vibratePattern(durations:Array<Float>, amplitudes:Array<Float>, sharpnesses:Array<Float>):Void
  {
    queue = [];
    for (i in 0...durations.length)
    {
      queue.push([durations[i], amplitudes[i] ?? amplitudes[amplitudes.length - 1], sharpnesses[i] ?? 1.0]);
    }
    startNext();
  }

  public static function stop():Void
  {
    queue = [];
    if (active) send(0.0, 0.0);
    active = false;
    segmentEnd = -1.0;
  }

  /**
   * Called every frame (NXPerformance.update): advances the pattern and stops the motors on time.
   */
  public static function update():Void
  {
    if (!active) return;
    if (haxe.Timer.stamp() >= segmentEnd) startNext();
  }

  static function startNext():Void
  {
    if (queue.length == 0)
    {
      send(0.0, 0.0);
      active = false;
      segmentEnd = -1.0;
      return;
    }
    var segment = queue.shift();
    send(segment[1], segment[2]);
    active = true;
    segmentEnd = haxe.Timer.stamp() + Math.max(MIN_SEGMENT_SECONDS, segment[0]);
  }

  static function send(amplitude:Float, sharpness:Float):Void
  {
    #if (switch && cpp)
    var result:Int = untyped __cpp__('nx_vibSend((float){0}, (float){1})', amplitude, sharpness);
    if (result == 0 && amplitude > 0) sentCount++;

    var device:String = describeDevice();
    if (device != lastDevice)
    {
      NXDeepTrace.writeEntry('HAPTICS', 'Controller: $device (vibrations sent so far: $sentCount)');
      lastDevice = device;
    }
    if (result != lastResult)
    {
      if (result != 0)
      {
        var rc:Int = untyped __cpp__('nx_vibLastRc');
        NXDeepTrace.writeEntry('HAPTICS', (result == 1 ? 'No vibration device' : 'Send failed') + ' (libnx rc 0x${StringTools.hex(rc)})');
      }
      else
      {
        NXDeepTrace.writeEntry('HAPTICS', 'Vibration working again');
      }
      lastResult = result;
    }
    #end
  }

  static function describeDevice():String
  {
    #if (switch && cpp)
    var id:Int = untyped __cpp__('nx_vibId');
    var style:Int = untyped __cpp__('nx_vibStyle');
    var count:Int = untyped __cpp__('(int)nx_vibCount');
    if (id < 0) return 'none';
    var name:String = switch (style)
    {
      case 2: 'Handheld (Joy-Cons attached)';
      case 1: 'Pro Controller';
      case 4: 'Joy-Con pair';
      case 8: 'Joy-Con L';
      case 16: 'Joy-Con R';
      default: 'style $style';
    }
    return '$name, npad ${id == 0x20 ? "handheld" : "P" + (id + 1)}, $count motor(s)';
    #else
    return 'n/a';
    #end
  }
}
