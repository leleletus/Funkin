package nx;

#if (switch && cpp)
/**
 * Native probes of the Switch audio stack: OpenAL Soft 1.21 -> SDL2 audio backend -> SDL's Switch
 * driver (libnx audren). Used to tell a dead mixer (the SDL audio thread stuck) from a paused or
 * starved one, and to reproduce starvation on purpose in Citron.
 */
@:buildXml("<files id='haxe'><compilerflag value='-I${DEVKITPRO}/portlibs/switch/include'/></files>")
@:cppFileCode('
#include <SDL2/SDL.h>
#include <AL/alc.h>
#include <AL/alext.h>

static SDL_AudioDeviceID nx_findOpenAudioDevice()
{
  for (SDL_AudioDeviceID id = 1; id < 16; id++)
  {
    if (SDL_GetAudioDeviceStatus(id) != SDL_AUDIO_STOPPED) return id;
  }
  return 0;
}

static long long nx_alcDeviceClockNs()
{
  ALCcontext *ctx = alcGetCurrentContext();
  if (!ctx) return -1;
  ALCdevice *dev = alcGetContextsDevice(ctx);
  if (!dev) return -2;
  static LPALCGETINTEGER64VSOFT getInt64 = NULL;
  if (!getInt64) getInt64 = (LPALCGETINTEGER64VSOFT)alcGetProcAddress(dev, "alcGetInteger64vSOFT");
  if (!getInt64) return -3;
  ALCint64SOFT value = 0;
  getInt64(dev, ALC_DEVICE_CLOCK_SOFT, 1, &value);
  return (long long)value;
}
')
#end
class NXAudioNative
{
  /**
   * OpenAL device clock in ms (ALC_DEVICE_CLOCK_SOFT): advances only while the mixer renders audio.
   * Negative values mean the probe is unavailable (-1 no context, -2 no device, -3 no extension).
   */
  public static function deviceClockMs():Float
  {
    #if (switch && cpp)
    var ns:Float = untyped __cpp__('(double)nx_alcDeviceClockNs()');
    return (ns < 0) ? ns : ns / 1000000.0;
    #else
    return -1.0;
    #end
  }

  /**
   * SDL audio device used by OpenAL: "id:status" (status 0 stopped, 1 playing, 2 paused).
   */
  public static function sdlAudioStatus():String
  {
    #if (switch && cpp)
    var id:Int = untyped __cpp__('(int)nx_findOpenAudioDevice()');
    if (id == 0) return 'none';
    var status:Int = untyped __cpp__('(int)SDL_GetAudioDeviceStatus((SDL_AudioDeviceID){0})', id);
    return '$id:$status';
    #else
    return 'n/a';
    #end
  }

  /**
   * Holds the SDL audio device lock for `ms` milliseconds from the calling (main) thread, so the
   * audio thread cannot mix in time: the same starvation a long main-thread hitch causes on hardware.
   * @return The SDL device id that was locked (0 if none was found).
   */
  public static function starveAudioThread(ms:Int):Int
  {
    #if (switch && cpp)
    var id:Int = untyped __cpp__('(int)nx_findOpenAudioDevice()');
    if (id == 0) return 0;
    untyped __cpp__('SDL_LockAudioDevice((SDL_AudioDeviceID){0}); SDL_Delay((Uint32){1}); SDL_UnlockAudioDevice((SDL_AudioDeviceID){0})', id, ms);
    return id;
    #else
    return 0;
    #end
  }
}
