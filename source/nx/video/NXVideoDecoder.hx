package nx.video;

#if (switch && cpp && NX_NATIVE_VIDEO)
/**
 * Native cutscene decoder (Step 3): the minimal LGPL FFmpeg of tools/nx-tools/build_ffmpeg_nx.sh decodes the
 * official video file on its own thread (core 2, the priority of the main thread) into a ring of NXV_SLOTS
 * YUV 4:2:0 frames. The main thread picks the frame for the audio clock and uploads its planes straight from
 * the ring with glTexSubImage2D: luma as an RGBA texture of width/4 texels (4 samples per texel) and both
 * chroma planes in one texture of width/8 texels (U rows, then V rows). NXYuvShader turns them into colour.
 *
 * One decoder at a time (cutscenes never overlap). Only the decoder thread calls FFmpeg after open().
 */
@:buildXml("<files id='haxe'><compilerflag value='-I${NX_FFMPEG_DIR}/include'/></files>")
@:cppFileCode('
#include <switch.h>
#include <EGL/egl.h>
extern "C"
{
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/cpu.h>
#include <libswscale/swscale.h>
}
#include <stdlib.h>
#include <string.h>

#define NXV_SLOTS 6

typedef struct
{
  unsigned char *y;
  unsigned char *uv;
  double pts;
} NxvSlot;

typedef void (*NxvTexSubImage2D)(unsigned int target, int level, int x, int y, int w, int h, unsigned int format,
                                 unsigned int type, const void *pixels);

static struct
{
  AVFormatContext *format;
  AVCodecContext *codec;
  AVPacket *packet;
  AVFrame *frame;
  struct SwsContext *sws;
  int stream;
  double timeBase;
  double startTime;
  double fps;
  double duration;
  int width;
  int height;
  int threads;
  NxvSlot slots[NXV_SLOTS];
  int readIndex;
  int writeIndex;
  int count;
  int held;
  Mutex lock;
  CondVar wake;
  Thread thread;
  int threadStarted;
  volatile int quit;
  volatile int seekRequest;
  volatile int draining;
  volatile int eof;
  volatile int failed;
  int decoded;
  int dropped;
  int shown;
  double decodeMsMax;
  double decodeMsTotal;
  NxvTexSubImage2D texSubImage2D;
} nxv;

static int nxv_isOpen = 0;

static double nxv_nowMs(void)
{
  return (double)armTicksToNs(armGetSystemTick()) / 1000000.0;
}

static void nxv_copyFrame(NxvSlot *slot, AVFrame *f)
{
  const int w = nxv.width, h = nxv.height, cw = w / 2, ch = h / 2;
  uint8_t *data[4] = {f->data[0], f->data[1], f->data[2], NULL};
  int linesize[4] = {f->linesize[0], f->linesize[1], f->linesize[2], 0};
  if (f->format != AV_PIX_FMT_YUV420P && f->format != AV_PIX_FMT_YUVJ420P)
  {
    // Rare: other pixel formats are converted to 4:2:0 straight into the slot.
    if (nxv.sws == NULL)
      nxv.sws = sws_getContext(f->width, f->height, f->format, w, h, AV_PIX_FMT_YUV420P, SWS_BILINEAR, NULL, NULL, NULL);
    if (nxv.sws == NULL) return;
    uint8_t *dst[4] = {slot->y, slot->uv, slot->uv + cw * ch, NULL};
    int dstLinesize[4] = {w, cw, cw, 0};
    sws_scale(nxv.sws, (const uint8_t *const *)f->data, f->linesize, 0, f->height, dst, dstLinesize);
    return;
  }
  for (int row = 0; row < h; row++) memcpy(slot->y + row * w, data[0] + row * linesize[0], w);
  for (int row = 0; row < ch; row++) memcpy(slot->uv + row * cw, data[1] + row * linesize[1], cw);
  for (int row = 0; row < ch; row++) memcpy(slot->uv + (ch + row) * cw, data[2] + row * linesize[2], cw);
}

/** Decodes the next frame into the free slot. 1 = frame stored, 0 = nothing yet, -1 = end of file. */
static int nxv_decodeOne(void)
{
  for (;;)
  {
    int err = avcodec_receive_frame(nxv.codec, nxv.frame);
    if (err == 0) break;
    if (err == AVERROR_EOF) return -1;
    if (err != AVERROR(EAGAIN))
    {
      nxv.failed = err;
      return -1;
    }
    if (nxv.draining) return -1;
    err = av_read_frame(nxv.format, nxv.packet);
    if (err < 0)
    {
      nxv.draining = 1;
      avcodec_send_packet(nxv.codec, NULL);
      continue;
    }
    if (nxv.packet->stream_index == nxv.stream) avcodec_send_packet(nxv.codec, nxv.packet);
    av_packet_unref(nxv.packet);
  }
  NxvSlot *slot = &nxv.slots[nxv.writeIndex];
  nxv_copyFrame(slot, nxv.frame);
  int64_t ts = nxv.frame->best_effort_timestamp;
  slot->pts = (ts == AV_NOPTS_VALUE) ? nxv.decoded / nxv.fps : ts * nxv.timeBase - nxv.startTime;
  av_frame_unref(nxv.frame);
  return 1;
}

static void nxv_threadMain(void *arg)
{
  (void)arg;
  while (!nxv.quit)
  {
    if (nxv.seekRequest)
    {
      av_seek_frame(nxv.format, nxv.stream, 0, AVSEEK_FLAG_BACKWARD);
      avcodec_flush_buffers(nxv.codec);
      mutexLock(&nxv.lock);
      // The frame held by the main thread (if any) stays valid: only queued frames are dropped.
      if (nxv.held)
      {
        nxv.count = 1;
        nxv.writeIndex = (nxv.readIndex + 1) % NXV_SLOTS;
      }
      else
      {
        nxv.count = 0;
        nxv.writeIndex = nxv.readIndex;
      }
      nxv.draining = 0;
      nxv.eof = 0;
      nxv.seekRequest = 0;
      mutexUnlock(&nxv.lock);
      continue;
    }
    mutexLock(&nxv.lock);
    while (!nxv.quit && !nxv.seekRequest && (nxv.eof || nxv.count == NXV_SLOTS))
      condvarWaitTimeout(&nxv.wake, &nxv.lock, 20000000);
    mutexUnlock(&nxv.lock);
    if (nxv.quit || nxv.seekRequest) continue;
    double start = nxv_nowMs();
    int result = nxv_decodeOne();
    double spent = nxv_nowMs() - start;
    mutexLock(&nxv.lock);
    if (result == 1 && !nxv.seekRequest)
    {
      nxv.writeIndex = (nxv.writeIndex + 1) % NXV_SLOTS;
      nxv.count++;
      nxv.decoded++;
      nxv.decodeMsTotal += spent;
      if (spent > nxv.decodeMsMax) nxv.decodeMsMax = spent;
    }
    else if (result < 0)
    {
      nxv.eof = 1;
    }
    mutexUnlock(&nxv.lock);
  }
}

static void nxv_close(void)
{
  if (!nxv_isOpen) return;
  if (nxv.threadStarted)
  {
    nxv.quit = 1;
    condvarWakeAll(&nxv.wake);
    threadWaitForExit(&nxv.thread);
    threadClose(&nxv.thread);
  }
  for (int i = 0; i < NXV_SLOTS; i++)
  {
    free(nxv.slots[i].y);
    free(nxv.slots[i].uv);
  }
  sws_freeContext(nxv.sws);
  av_frame_free(&nxv.frame);
  av_packet_free(&nxv.packet);
  avcodec_free_context(&nxv.codec);
  avformat_close_input(&nxv.format);
  memset(&nxv, 0, sizeof(nxv));
  nxv_isOpen = 0;
}

/** Opens `path` and starts the decoder thread. Returns 0 or a negative error (see nxv_errorText). */
static int nxv_open(const char *path, int simd)
{
  nxv_close();
  memset(&nxv, 0, sizeof(nxv));
  nxv_isOpen = 1;
  mutexInit(&nxv.lock);
  condvarInit(&nxv.wake);
  // Citron lacks the vector SQRSHL the HEVC NEON code uses; test builds can fall back to plain C there.
  av_force_cpu_flags(simd ? -1 : 0);
  int err = avformat_open_input(&nxv.format, path, NULL, NULL);
  if (err < 0) return err;
  if ((err = avformat_find_stream_info(nxv.format, NULL)) < 0) return err;
  const AVCodec *decoder = NULL;
  nxv.stream = av_find_best_stream(nxv.format, AVMEDIA_TYPE_VIDEO, -1, -1, &decoder, 0);
  if (nxv.stream < 0 || decoder == NULL) return -1001;
  AVStream *video = nxv.format->streams[nxv.stream];
  nxv.codec = avcodec_alloc_context3(decoder);
  avcodec_parameters_to_context(nxv.codec, video->codecpar);
  // HEVC 1080p (2Hot) needs two threads (VIDEO_BENCH: 1.22x its fps with one, 2.26x with two).
  nxv.threads = (decoder->id == AV_CODEC_ID_HEVC && nxv.codec->height > 720) ? 2 : 1;
  nxv.codec->thread_count = nxv.threads;
  nxv.codec->thread_type = (nxv.threads > 1) ? FF_THREAD_FRAME : 0;
  if ((err = avcodec_open2(nxv.codec, decoder, NULL)) < 0) return err;
  nxv.width = nxv.codec->width;
  nxv.height = nxv.codec->height;
  if (nxv.width <= 0 || nxv.height <= 0 || (nxv.width % 8) != 0 || (nxv.height % 2) != 0) return -1002;
  nxv.timeBase = av_q2d(video->time_base);
  nxv.startTime = (video->start_time == AV_NOPTS_VALUE) ? 0 : video->start_time * nxv.timeBase;
  nxv.fps = av_q2d(video->avg_frame_rate);
  if (nxv.fps <= 0) nxv.fps = 24;
  nxv.duration = (nxv.format->duration > 0) ? nxv.format->duration / (double)AV_TIME_BASE : 0;
  nxv.packet = av_packet_alloc();
  nxv.frame = av_frame_alloc();
  for (int i = 0; i < NXV_SLOTS; i++)
  {
    nxv.slots[i].y = (unsigned char *)malloc(nxv.width * nxv.height);
    nxv.slots[i].uv = (unsigned char *)malloc(nxv.width * nxv.height / 2);
    if (nxv.slots[i].y == NULL || nxv.slots[i].uv == NULL) return -1003;
  }
  nxv.texSubImage2D = (NxvTexSubImage2D)eglGetProcAddress("glTexSubImage2D");
  if (nxv.texSubImage2D == NULL) return -1004;
  // Core 2 (the main thread is on core 0, the audio thread on core 1), same priority as the main thread.
  Result rc = threadCreate(&nxv.thread, nxv_threadMain, NULL, NULL, 0x100000, 0x2C, 2);
  if (R_SUCCEEDED(rc)) rc = threadStart(&nxv.thread);
  if (R_FAILED(rc)) return -1005;
  nxv.threadStarted = 1;
  return 0;
}

/**
 * Takes the newest queued frame whose time is <= clock (older ones are dropped) and holds it for upload.
 * 1 = a new frame is held, 0 = keep showing the current one.
 */
static int nxv_acquire(double clock)
{
  if (!nxv_isOpen) return 0;
  mutexLock(&nxv.lock);
  if (nxv.held)
  {
    // The previous frame was uploaded: free its slot.
    nxv.readIndex = (nxv.readIndex + 1) % NXV_SLOTS;
    nxv.count--;
    nxv.held = 0;
  }
  int best = -1;
  for (int i = 0; i < nxv.count; i++)
  {
    if (nxv.slots[(nxv.readIndex + i) % NXV_SLOTS].pts <= clock + 0.004) best = i;
    else break;
  }
  if (best > 0)
  {
    nxv.readIndex = (nxv.readIndex + best) % NXV_SLOTS;
    nxv.count -= best;
    nxv.dropped += best;
  }
  if (best >= 0)
  {
    nxv.held = 1;
    nxv.shown++;
  }
  mutexUnlock(&nxv.lock);
  condvarWakeOne(&nxv.wake);
  return best >= 0;
}

/** Uploads plane 0 (luma) or 1 (chroma) of the held frame into the texture bound to GL_TEXTURE_2D. */
static void nxv_upload(int plane, unsigned int glFormat)
{
  if (!nxv_isOpen || !nxv.held) return;
  NxvSlot *slot = &nxv.slots[nxv.readIndex];
  if (plane == 0) nxv.texSubImage2D(0x0DE1, 0, 0, 0, nxv.width / 4, nxv.height, glFormat, 0x1401, slot->y);
  else nxv.texSubImage2D(0x0DE1, 0, 0, 0, nxv.width / 8, nxv.height, glFormat, 0x1401, slot->uv);
}

static int nxv_finished(void)
{
  if (!nxv_isOpen) return 1;
  mutexLock(&nxv.lock);
  int done = nxv.eof && nxv.count - nxv.held <= 0;
  mutexUnlock(&nxv.lock);
  return done;
}

/** Frames decoded and waiting (0 while a seek is pending). */
static int nxv_queued(void)
{
  if (!nxv_isOpen || nxv.seekRequest) return 0;
  mutexLock(&nxv.lock);
  int queued = nxv.count - nxv.held;
  mutexUnlock(&nxv.lock);
  return queued;
}

static void nxv_seekStart(void)
{
  if (!nxv_isOpen) return;
  nxv.seekRequest = 1;
  condvarWakeAll(&nxv.wake);
}
')
#end
class NXVideoDecoder
{
  /**
   * Opens `path` (e.g. romfs:/assets/videos/native/ughCutscene.mkv) and starts decoding. `simd` = false runs
   * FFmpeg without NEON (Citron). Returns '' or an error description.
   */
  public static function open(path:String, simd:Bool = true):String
  {
    #if (switch && cpp && NX_NATIVE_VIDEO)
    // "file:" so FFmpeg does not read "romfs:" as a protocol name.
    var err:Int = untyped __cpp__('nxv_open(({0}).utf8_str(), {1} ? 1 : 0)', 'file:' + path, simd);
    if (err == 0) return '';
    close();
    return switch (err)
    {
      case -1001: 'no video stream';
      case -1002: 'unsupported frame size';
      case -1003: 'out of memory for the frame queue';
      case -1004: 'glTexSubImage2D not found';
      case -1005: 'could not start the decoder thread';
      default: 'FFmpeg error ' + err;
    }
    #else
    return 'native video not built';
    #end
  }

  public static function close():Void
  {
    #if (switch && cpp && NX_NATIVE_VIDEO)
    untyped __cpp__('nxv_close()');
    #end
  }

  public static function width():Int
  {
    #if (switch && cpp && NX_NATIVE_VIDEO)
    return untyped __cpp__('nxv.width');
    #else
    return 0;
    #end
  }

  public static function height():Int
  {
    #if (switch && cpp && NX_NATIVE_VIDEO)
    return untyped __cpp__('nxv.height');
    #else
    return 0;
    #end
  }

  public static function fps():Float
  {
    #if (switch && cpp && NX_NATIVE_VIDEO)
    return untyped __cpp__('nxv.fps');
    #else
    return 0;
    #end
  }

  /**
   * Video length in seconds (0 if the container does not say).
   */
  public static function duration():Float
  {
    #if (switch && cpp && NX_NATIVE_VIDEO)
    return untyped __cpp__('nxv.duration');
    #else
    return 0;
    #end
  }

  /**
   * Holds the frame for `clock` (seconds). True when a new frame must be uploaded with upload().
   */
  public static function acquire(clock:Float):Bool
  {
    #if (switch && cpp && NX_NATIVE_VIDEO)
    return untyped __cpp__('nxv_acquire({0})', clock) == 1;
    #else
    return false;
    #end
  }

  /**
   * Uploads plane 0 (luma) or 1 (chroma) of the held frame into the texture currently bound to GL_TEXTURE_2D.
   */
  public static function upload(plane:Int, glFormat:Int):Void
  {
    #if (switch && cpp && NX_NATIVE_VIDEO)
    untyped __cpp__('nxv_upload({0}, (unsigned int){1})', plane, glFormat);
    #end
  }

  /**
   * True once the last frame has been decoded and shown.
   */
  public static function finished():Bool
  {
    #if (switch && cpp && NX_NATIVE_VIDEO)
    return untyped __cpp__('nxv_finished()') == 1;
    #else
    return true;
    #end
  }

  /**
   * Decoded frames waiting in the queue (0 while a seek is still pending).
   */
  public static function queued():Int
  {
    #if (switch && cpp && NX_NATIVE_VIDEO)
    return untyped __cpp__('nxv_queued()');
    #else
    return 0;
    #end
  }

  /**
   * Back to the first frame (Restart Cutscene). The decoder thread seeks; the current frame stays on screen.
   */
  public static function seekStart():Void
  {
    #if (switch && cpp && NX_NATIVE_VIDEO)
    untyped __cpp__('nxv_seekStart()');
    #end
  }

  /**
   * Counters for the log, e.g. 'decoded=360 shown=358 dropped=2 threads=1 decode_avg=9.1ms max=31.0ms'.
   */
  public static function stats():String
  {
    #if (switch && cpp && NX_NATIVE_VIDEO)
    var decoded:Int = untyped __cpp__('nxv.decoded');
    var shown:Int = untyped __cpp__('nxv.shown');
    var dropped:Int = untyped __cpp__('nxv.dropped');
    var threads:Int = untyped __cpp__('nxv.threads');
    var total:Float = untyped __cpp__('nxv.decodeMsTotal');
    var max:Float = untyped __cpp__('nxv.decodeMsMax');
    var avg:Float = decoded > 0 ? total / decoded : 0;
    return 'decoded=$decoded shown=$shown dropped=$dropped threads=$threads decode_avg=${Math.round(avg * 10) / 10}ms max=${Math.round(max * 10) / 10}ms';
    #else
    return 'native video not built';
    #end
  }
}
