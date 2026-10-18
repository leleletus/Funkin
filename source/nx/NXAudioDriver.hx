package nx;

#if (switch && cpp)
/**
 * Replacement for SDL2's Nintendo Switch audio driver (INC-43).
 *
 * Audio chain on Switch: OpenAL Soft -> SDL2 audio thread -> SDL's "switch" driver -> libnx audren.
 * The driver shipped in devkitPro's switch-sdl2 2.28.5-4 (src/audio/switch/SDL_switchaudio.c, commit
 * 78899b66f) queues a wave buffer in PlayDevice() and then spins until that buffer is reported as
 * "Playing". libnx (_audrvVoiceUpdate) can move a buffer straight from Queued to Done when more than
 * one buffer is consumed between two updates, i.e. whenever the audio thread is late by more than one
 * buffer (~20 ms). The buffer never becomes "Playing" again, PlayDevice() never returns, the OpenAL
 * callback is never called again and the whole game goes silent while SDL still reports the device
 * as playing. This is the permanent audio death seen on hardware.
 *
 * SDL_audio.c only references the driver through the global `SWITCHAUDIO_bootstrap`. Defining it here
 * (libApplicationMain is linked before -lSDL2) makes SDL use this driver and the original object is
 * never pulled from libSDL2.a (a duplicate would be a link error, never a silent fallback).
 *
 * This driver keeps the same audren setup but never waits for a specific state transition:
 * PlayDevice() only queues; WaitDevice() waits until any buffer is free, restarts the voice if it
 * stopped and resets it if no buffer completes for 1 s (renderer stalled, e.g. after a suspension).
 * Counters are exposed for the [MIXER] diagnostics. The legacy mode reproduces the original
 * PlayDevice() exactly and exists only for the Citron A/B test (AUDIO_DRIVER_STALL_LEGACY).
 */
@:cppFileCode('
#include <switch.h>
#include <SDL2/SDL.h>
#include <malloc.h>
#include <string.h>

extern "C" {

// Mirror of SDL 2.28.5 internal audio structs (devkitPro switch-sdl2 2.28.5-4, src/audio/SDL_sysaudio.h @ 78899b66f).
struct SDL_DataQueue;
struct SDL_PrivateAudioData;
typedef struct SDL_AudioDevice
{
  SDL_AudioDeviceID id;
  SDL_AudioSpec spec;
  SDL_AudioSpec callbackspec;
  SDL_AudioStream *stream;
  SDL_atomic_t shutdown;
  SDL_atomic_t enabled;
  SDL_atomic_t paused;
  SDL_bool iscapture;
  Uint8 *work_buffer;
  Uint32 work_buffer_len;
  SDL_mutex *mixer_lock;
  SDL_Thread *thread;
  SDL_threadID threadid;
  struct SDL_DataQueue *buffer_queue;
  struct SDL_PrivateAudioData *hidden;
  void *handle;
} SDL_AudioDevice;

typedef struct SDL_AudioDriverImpl
{
  void (*DetectDevices)(void);
  int (*OpenDevice)(SDL_AudioDevice *dev, const char *devname);
  void (*ThreadInit)(SDL_AudioDevice *dev);
  void (*ThreadDeinit)(SDL_AudioDevice *dev);
  void (*WaitDevice)(SDL_AudioDevice *dev);
  void (*PlayDevice)(SDL_AudioDevice *dev);
  Uint8 *(*GetDeviceBuf)(SDL_AudioDevice *dev);
  int (*CaptureFromDevice)(SDL_AudioDevice *dev, void *buffer, int buflen);
  void (*FlushCapture)(SDL_AudioDevice *dev);
  void (*CloseDevice)(SDL_AudioDevice *dev);
  void (*LockDevice)(SDL_AudioDevice *dev);
  void (*UnlockDevice)(SDL_AudioDevice *dev);
  void (*FreeDeviceHandle)(void *handle);
  void (*Deinitialize)(void);
  int (*GetDefaultAudioInfo)(char **name, SDL_AudioSpec *spec, int iscapture);
  SDL_bool ProvidesOwnCallbackThread;
  SDL_bool HasCaptureSupport;
  SDL_bool OnlyHasDefaultOutputDevice;
  SDL_bool OnlyHasDefaultCaptureDevice;
  SDL_bool AllowsArbitraryDeviceNames;
  SDL_bool SupportsNonPow2Samples;
} SDL_AudioDriverImpl;

typedef struct AudioBootStrap
{
  const char *name;
  const char *desc;
  SDL_bool (*init)(SDL_AudioDriverImpl *impl);
  SDL_bool demand_only;
} AudioBootStrap;

void SDL_CalculateAudioSpec(SDL_AudioSpec *spec);

struct SDL_PrivateAudioData
{
  AudioDriver driver;
  AudioDriverWaveBuf buffer[2];
  void *buffer_tmp;
  void *pool;
  bool audr_device;
  bool audr_driver;
};

static const AudioRendererConfig nx_arConfig = {
  .output_rate = AudioRendererOutputRate_48kHz,
  .num_voices = 24,
  .num_effects = 0,
  .num_sinks = 1,
  .num_mix_objs = 1,
  .num_mix_buffers = 2,
};

// Diagnostics (written by the SDL audio thread, read by the game thread).
static volatile int nx_drv_opened = 0;
static volatile int nx_drv_freq = 0, nx_drv_channels = 0, nx_drv_samples = 0;
static volatile int nx_drv_queued = 0;      // buffers handed to audren
static volatile int nx_drv_underruns = 0;   // both buffers had finished when a new one was queued (thread was late)
static volatile int nx_drv_restarts = 0;    // voice found stopped and restarted
static volatile int nx_drv_watchdog = 0;    // voice reset because no buffer completed for 1 s
static volatile int nx_drv_maxWaitMs = 0;   // longest WaitDevice()
static volatile u64 nx_drv_lastQueueTick = 0;
// Test hooks.
static volatile int nx_drv_legacy = 0;
static volatile int nx_drv_injectMs = 0;

static inline int nx_tickMs(u64 ticks) { return (int)(armTicksToNs(ticks) / 1000000ULL); }

static int nx_findFreeBuffer(struct SDL_PrivateAudioData *h)
{
  for (int i = 0; i < 2; i++)
  {
    if (h->buffer[i].state == AudioDriverWaveBufState_Free || h->buffer[i].state == AudioDriverWaveBufState_Done) return i;
  }
  return -1;
}

static int NXAUDIO_OpenDevice(SDL_AudioDevice *dev, const char *devname)
{
  static const u8 sink_channels[] = {0, 1};
  (void)devname;

  dev->hidden = (struct SDL_PrivateAudioData *)SDL_calloc(1, sizeof(struct SDL_PrivateAudioData));
  if (dev->hidden == NULL) return SDL_OutOfMemory();
  struct SDL_PrivateAudioData *h = dev->hidden;

  Result res = audrenInitialize(&nx_arConfig);
  if (R_FAILED(res)) return SDL_SetError("audrenInitialize failed (0x%x)", res);
  h->audr_device = true;

  res = audrvCreate(&h->driver, &nx_arConfig, 2);
  if (R_FAILED(res)) return SDL_SetError("audrvCreate failed (0x%x)", res);
  h->audr_driver = true;

  dev->spec.format = AUDIO_S16SYS;
  SDL_CalculateAudioSpec(&dev->spec);

  u32 size = (u32)((dev->spec.size * 2) + 0xfff) & ~0xfff;
  h->pool = memalign(0x1000, size);
  h->buffer_tmp = malloc(dev->spec.size);
  if (h->pool == NULL || h->buffer_tmp == NULL) return SDL_OutOfMemory();
  memset(h->pool, 0, size);
  for (int i = 0; i < 2; i++)
  {
    h->buffer[i].data_raw = h->pool;
    h->buffer[i].size = dev->spec.size * 2;
    h->buffer[i].start_sample_offset = i * dev->spec.samples;
    h->buffer[i].end_sample_offset = h->buffer[i].start_sample_offset + dev->spec.samples;
  }

  int mpid = audrvMemPoolAdd(&h->driver, h->pool, size);
  audrvMemPoolAttach(&h->driver, mpid);
  audrvDeviceSinkAdd(&h->driver, AUDREN_DEFAULT_DEVICE_NAME, 2, sink_channels);

  res = audrenStartAudioRenderer();
  if (R_FAILED(res)) return SDL_SetError("audrenStartAudioRenderer failed (0x%x)", res);

  audrvVoiceInit(&h->driver, 0, dev->spec.channels, PcmFormat_Int16, dev->spec.freq);
  audrvVoiceSetDestinationMix(&h->driver, 0, AUDREN_FINAL_MIX_ID);
  if (dev->spec.channels == 1)
  {
    audrvVoiceSetMixFactor(&h->driver, 0, 1.0f, 0, 0);
    audrvVoiceSetMixFactor(&h->driver, 0, 1.0f, 0, 1);
  }
  else
  {
    audrvVoiceSetMixFactor(&h->driver, 0, 1.0f, 0, 0);
    audrvVoiceSetMixFactor(&h->driver, 0, 0.0f, 0, 1);
    audrvVoiceSetMixFactor(&h->driver, 0, 0.0f, 1, 0);
    audrvVoiceSetMixFactor(&h->driver, 0, 1.0f, 1, 1);
  }
  audrvVoiceStart(&h->driver, 0);

  nx_drv_freq = dev->spec.freq;
  nx_drv_channels = dev->spec.channels;
  nx_drv_samples = dev->spec.samples;
  nx_drv_opened++;
  return 0;
}

// Exact copy of the original driver behaviour (can hang forever). Only used by the A/B test.
static void nx_legacyPlayDevice(SDL_AudioDevice *dev)
{
  struct SDL_PrivateAudioData *h = dev->hidden;
  int current = nx_findFreeBuffer(h);
  if (current >= 0)
  {
    Uint8 *ptr = (Uint8 *)h->pool + (current * dev->spec.size);
    memcpy(ptr, h->buffer_tmp, dev->spec.size);
    armDCacheFlush(ptr, dev->spec.size);
    audrvVoiceAddWaveBuf(&h->driver, 0, &h->buffer[current]);
    nx_drv_queued++;
  }
  else if (!audrvVoiceIsPlaying(&h->driver, 0))
  {
    audrvVoiceStart(&h->driver, 0);
  }
  audrvUpdate(&h->driver);

  if (nx_drv_injectMs > 0)
  {
    int ms = nx_drv_injectMs;
    nx_drv_injectMs = 0;
    svcSleepThread((s64)ms * 1000000LL);
  }

  if (current >= 0)
  {
    while (h->buffer[current].state != AudioDriverWaveBufState_Playing)
    {
      audrvUpdate(&h->driver);
      audrenWaitFrame();
    }
  }
  else
  {
    current = -1;
    for (int i = 0; i < 2; i++)
    {
      if (h->buffer[i].state == AudioDriverWaveBufState_Playing) { current = i; break; }
    }
    while (current >= 0 && h->buffer[current].state == AudioDriverWaveBufState_Playing)
    {
      audrvUpdate(&h->driver);
      audrenWaitFrame();
    }
  }
}

static void NXAUDIO_PlayDevice(SDL_AudioDevice *dev)
{
  if (nx_drv_legacy)
  {
    nx_legacyPlayDevice(dev);
    return;
  }
  struct SDL_PrivateAudioData *h = dev->hidden;
  audrvUpdate(&h->driver);
  int current = nx_findFreeBuffer(h);
  if (current < 0) return; // WaitDevice() guarantees a free buffer; never block here.

  int other = current ^ 1;
  if (nx_drv_queued > 0 && h->buffer[other].state != AudioDriverWaveBufState_Queued
      && h->buffer[other].state != AudioDriverWaveBufState_Playing && h->buffer[other].state != AudioDriverWaveBufState_Waiting)
  {
    nx_drv_underruns++;
  }

  Uint8 *ptr = (Uint8 *)h->pool + (current * dev->spec.size);
  memcpy(ptr, h->buffer_tmp, dev->spec.size);
  armDCacheFlush(ptr, dev->spec.size);
  audrvVoiceAddWaveBuf(&h->driver, 0, &h->buffer[current]);
  if (!audrvVoiceIsPlaying(&h->driver, 0))
  {
    if (nx_drv_queued > 0) nx_drv_restarts++;
    audrvVoiceStart(&h->driver, 0);
  }
  audrvUpdate(&h->driver);
  nx_drv_queued++;
  nx_drv_lastQueueTick = armGetSystemTick();

  if (nx_drv_injectMs > 0)
  {
    int ms = nx_drv_injectMs;
    nx_drv_injectMs = 0;
    svcSleepThread((s64)ms * 1000000LL);
  }
}

static void NXAUDIO_WaitDevice(SDL_AudioDevice *dev)
{
  if (nx_drv_legacy) return;
  struct SDL_PrivateAudioData *h = dev->hidden;
  u64 start = armGetSystemTick();
  for (;;)
  {
    audrvUpdate(&h->driver);
    if (nx_findFreeBuffer(h) >= 0) break;
    if (!audrvVoiceIsPlaying(&h->driver, 0))
    {
      nx_drv_restarts++;
      audrvVoiceStart(&h->driver, 0);
      audrvUpdate(&h->driver);
    }
    if (nx_tickMs(armGetSystemTick() - start) > 1000)
    {
      // The renderer stopped consuming buffers: drop them (flagged Done) and start over.
      nx_drv_watchdog++;
      audrvVoiceStop(&h->driver, 0);
      audrvVoiceStart(&h->driver, 0);
      audrvUpdate(&h->driver);
      break;
    }
    if (SDL_AtomicGet(&dev->shutdown)) break;
    svcSleepThread(2000000LL);
  }
  int waited = nx_tickMs(armGetSystemTick() - start);
  if (waited > nx_drv_maxWaitMs) nx_drv_maxWaitMs = waited;
}

static Uint8 *NXAUDIO_GetDeviceBuf(SDL_AudioDevice *dev)
{
  return (Uint8 *)dev->hidden->buffer_tmp;
}

static void NXAUDIO_CloseDevice(SDL_AudioDevice *dev)
{
  struct SDL_PrivateAudioData *h = dev->hidden;
  if (h == NULL) return;
  if (h->audr_driver) audrvClose(&h->driver);
  if (h->audr_device) audrenExit();
  if (h->buffer_tmp) free(h->buffer_tmp);
  if (h->pool) free(h->pool);
  SDL_free(h);
  dev->hidden = NULL;
}

static void NXAUDIO_ThreadInit(SDL_AudioDevice *dev)
{
  (void)dev;
}

static SDL_bool NXAUDIO_Init(SDL_AudioDriverImpl *impl)
{
  impl->OpenDevice = NXAUDIO_OpenDevice;
  impl->PlayDevice = NXAUDIO_PlayDevice;
  impl->WaitDevice = NXAUDIO_WaitDevice;
  impl->GetDeviceBuf = NXAUDIO_GetDeviceBuf;
  impl->CloseDevice = NXAUDIO_CloseDevice;
  impl->ThreadInit = NXAUDIO_ThreadInit;
  impl->OnlyHasDefaultOutputDevice = SDL_TRUE;
  return SDL_TRUE;
}

AudioBootStrap SWITCHAUDIO_bootstrap = {"switch", "Nintendo Switch audio driver (NX non-blocking)", NXAUDIO_Init, SDL_FALSE};

}
')
#end
class NXAudioDriver
{
  /**
   * True once SDL opened its audio device through this driver (proves the replacement is linked).
   */
  public static function isActive():Bool
  {
    #if (switch && cpp)
    return untyped __cpp__('nx_drv_opened > 0');
    #else
    return false;
    #end
  }

  /**
   * One-line driver state for [MIXER] / [AUDIO] logs.
   */
  public static function stats():String
  {
    #if (switch && cpp)
    var opened:Int = untyped __cpp__('nx_drv_opened');
    if (opened == 0) return 'drv=not-opened';
    var freq:Int = untyped __cpp__('nx_drv_freq');
    var channels:Int = untyped __cpp__('nx_drv_channels');
    var samples:Int = untyped __cpp__('nx_drv_samples');
    var queued:Int = untyped __cpp__('nx_drv_queued');
    var underruns:Int = untyped __cpp__('nx_drv_underruns');
    var restarts:Int = untyped __cpp__('nx_drv_restarts');
    var watchdog:Int = untyped __cpp__('nx_drv_watchdog');
    var maxWait:Int = untyped __cpp__('nx_drv_maxWaitMs');
    var sinceQueue:Int = untyped __cpp__('(nx_drv_lastQueueTick == 0) ? -1 : (int)(armTicksToNs(armGetSystemTick() - nx_drv_lastQueueTick) / 1000000ULL)');
    var legacy:Int = untyped __cpp__('nx_drv_legacy');
    return 'drv=nx${legacy != 0 ? "-LEGACY" : ""} ${freq}Hz/${channels}ch/${samples} opened=$opened queued=$queued underruns=$underruns restarts=$restarts watchdog=$watchdog maxWait=${maxWait}ms lastQueue=${sinceQueue}ms';
    #else
    return 'drv=n/a';
    #end
  }

  /**
   * Test hook: run the original SDL PlayDevice() (which can hang forever) instead of the fixed one.
   */
  public static function setLegacyMode(enabled:Bool):Void
  {
    #if (switch && cpp)
    untyped __cpp__('nx_drv_legacy = {0} ? 1 : 0', enabled);
    #end
  }

  /**
   * Test hook: makes the audio thread sleep `ms` once, right after queuing a buffer, like a thread
   * descheduled on the console. With the original driver a delay longer than one buffer hangs it.
   */
  public static function injectThreadDelay(ms:Int):Void
  {
    #if (switch && cpp)
    untyped __cpp__('nx_drv_injectMs = {0}', ms);
    #end
  }
}
