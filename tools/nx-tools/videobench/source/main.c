/*
 * VIDEO_BENCH: how fast the Switch CPU decodes the 7 cutscenes at 1280x720 with the minimal FFmpeg
 * (tools/nx-tools/build_ffmpeg_nx.sh). Standalone homebrew, separate from the game: it decides
 * whether the native video player can replace the cutscene sheets (video plan, step 2a).
 *
 * Modes, each over the 7 videos in RomFS (tools/nx-tools/videobench/prepare_bench_videos.sh):
 *   decode     1 thread, original encode, frames discarded
 *   decode-fd  1 thread, x264 fastdecode encode
 *   decode-t2  2 threads (frame threading), original encode
 *   decode-fd-t2
 *   rgba       1 thread, original encode, plus sws_scale to RGBA (what an RGBA upload path would cost)
 *
 * One [VIDEOBENCH] line per video and mode in sdmc:/switch/Friday-Night-Funkin/logs/videobench.log
 * (pulled by deploy_switch.sh --logs-only). The bench thread runs on core 2.
 *
 * Builds:
 *   make                       console NRO (Funkin-videobench.nro), copied by deploy_switch.sh --bench
 *   make TARGET=Funkin-videobench-citron BUILD=build-citron DEFINES="-DBENCH_NO_CONSOLE -DBENCH_CITRON"
 *                              for run_citron_autotest.sh VIDEO_BENCH: Citron segfaults with the libnx text
 *                              console, and it only runs the first mode to check the frame counts
 *   cc on the host (see docs/SWITCH_SESSION_GUIDE.md) to compare frame counts with ffprobe
 */
#include <errno.h>
#include <malloc.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>

#ifdef __SWITCH__
#include <switch.h>
// "file:" so FFmpeg does not read "romfs:" as a protocol name.
#define VIDEO_DIR "file:romfs:/"
#define LOG_DIR "sdmc:/switch/Friday-Night-Funkin/logs"
#else
#include <pthread.h>
#define VIDEO_DIR "export/nx-generated/videobench/romfs/"
#define LOG_DIR "export/nx-generated/videobench"
#endif

static const char *VIDEOS[] = {"ughCutscene", "gunsCutscene", "stressCutscene", "stressPicoCutscene",
                               "darnellCutscene", "2hotCutscene", "blazinCutscene"};
#define VIDEO_COUNT (sizeof(VIDEOS) / sizeof(VIDEOS[0]))

typedef struct
{
  const char *name;
  const char *suffix;
  int threads;
  int rgba;
} Mode;

static const Mode MODES[] = {
    {"decode", ".mp4", 1, 0},
    {"decode-fd", ".fd.mp4", 1, 0},
    {"decode-t2", ".mp4", 2, 0},
    {"decode-fd-t2", ".fd.mp4", 2, 0},
    {"rgba", ".mp4", 1, 1},
};
#ifdef BENCH_CITRON
#define MODE_COUNT 1 // Citron only checks that every video decodes to the end; its timings are not valid
#else
#define MODE_COUNT (sizeof(MODES) / sizeof(MODES[0]))
#endif

typedef struct
{
  int frames;
  double nativeFps;
  double wallMs;
  double cpuMs;
  double p50, p95, p99, max;
  double peakMb;
  int width, height;
  char error[96];
} BenchResult;

static FILE *logFile = NULL;
#ifdef __SWITCH__
static Mutex consoleLock; // printf from the bench thread vs consoleUpdate on the main thread
#endif
static volatile int benchDone = 0;
static volatile int stopRequested = 0;

static void out(const char *fmt, ...)
{
  char line[768];
  va_list args;
  va_start(args, fmt);
  vsnprintf(line, sizeof(line), fmt, args);
  va_end(args);
#ifdef __SWITCH__
  mutexLock(&consoleLock);
#endif
  printf("%s\n", line);
#ifdef __SWITCH__
  mutexUnlock(&consoleLock);
#endif
  if (logFile != NULL)
  {
    fprintf(logFile, "%s\n", line);
    fflush(logFile);
  }
}

static uint64_t nowNs(void)
{
#ifdef __SWITCH__
  return armTicksToNs(armGetSystemTick());
#else
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
#endif
}

/** CPU time of the calling thread in ms, or -1 where the kernel cannot tell (firmware before 13.0.0). */
static double threadCpuMs(void)
{
#ifdef __SWITCH__
  u64 ticks = 0;
  if (R_FAILED(svcGetInfo(&ticks, InfoType_ThreadTickCount, CUR_THREAD_HANDLE, (u64)-1))) return -1;
  return (double)armTicksToNs(ticks) / 1e6;
#else
  struct timespec ts;
  clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts);
  return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
#endif
}

static size_t heapInUse(void)
{
#ifdef __SWITCH__
  return mallinfo().uordblks;
#else
  return mallinfo2().uordblks;
#endif
}

static int compareDouble(const void *a, const void *b)
{
  double x = *(const double *)a, y = *(const double *)b;
  return (x > y) - (x < y);
}

static double percentile(const double *sorted, int count, double p)
{
  if (count == 0) return 0;
  int index = (int)(p * (count - 1) + 0.5);
  return sorted[index];
}

#ifdef BENCH_TRACE
#define TRACE(...) out(__VA_ARGS__)
#else
#define TRACE(...)
#endif

static void runOne(const char *path, const Mode *mode, BenchResult *r)
{
  memset(r, 0, sizeof(*r));
  AVFormatContext *format = NULL;
  AVCodecContext *codec = NULL;
  AVPacket *packet = av_packet_alloc();
  AVFrame *frame = av_frame_alloc();
  struct SwsContext *sws = NULL;
  uint8_t *rgba[4] = {NULL};
  int rgbaLinesize[4] = {0};
  int capacity = 4096;
  double *frameMs = malloc(sizeof(double) * capacity);
  size_t heapBase = heapInUse(), heapPeak = heapBase;
  int stream, err;

  TRACE("[trace] open %s", path);
  if ((err = avformat_open_input(&format, path, NULL, NULL)) < 0 || (err = avformat_find_stream_info(format, NULL)) < 0)
  {
    av_strerror(err, r->error, sizeof(r->error));
    goto done;
  }
  const AVCodec *decoder = NULL;
  stream = av_find_best_stream(format, AVMEDIA_TYPE_VIDEO, -1, -1, &decoder, 0);
  if (stream < 0 || decoder == NULL)
  {
    snprintf(r->error, sizeof(r->error), "no decodable video stream");
    goto done;
  }
  TRACE("[trace] stream %d", stream);
  AVStream *video = format->streams[stream];
  r->nativeFps = av_q2d(video->avg_frame_rate);
  codec = avcodec_alloc_context3(decoder);
  avcodec_parameters_to_context(codec, video->codecpar);
  codec->thread_count = mode->threads;
  codec->thread_type = (mode->threads > 1) ? FF_THREAD_FRAME : 0;
  if ((err = avcodec_open2(codec, decoder, NULL)) < 0)
  {
    av_strerror(err, r->error, sizeof(r->error));
    goto done;
  }
  TRACE("[trace] codec open");
  r->width = codec->width;
  r->height = codec->height;

  double cpuStart = threadCpuMs();
  uint64_t start = nowNs(), last = start;
  int draining = 0;
  while (1)
  {
    if (!draining)
    {
      err = av_read_frame(format, packet);
      if (err < 0)
      {
        draining = 1;
        avcodec_send_packet(codec, NULL);
      }
      else
      {
        if (packet->stream_index == stream) avcodec_send_packet(codec, packet);
        av_packet_unref(packet);
      }
    }
    int got = 0;
    while ((err = avcodec_receive_frame(codec, frame)) == 0)
    {
      got = 1;
      if (mode->rgba)
      {
        if (sws == NULL)
        {
          sws = sws_getContext(frame->width, frame->height, frame->format, frame->width, frame->height, AV_PIX_FMT_RGBA,
                               SWS_BILINEAR, NULL, NULL, NULL);
          av_image_alloc(rgba, rgbaLinesize, frame->width, frame->height, AV_PIX_FMT_RGBA, 64);
        }
        sws_scale(sws, (const uint8_t *const *)frame->data, frame->linesize, 0, frame->height, rgba, rgbaLinesize);
      }
      if (r->frames < 2) TRACE("[trace] frame %d", r->frames);
      uint64_t now = nowNs();
      if (r->frames == capacity)
      {
        capacity *= 2;
        frameMs = realloc(frameMs, sizeof(double) * capacity);
      }
      frameMs[r->frames++] = (now - last) / 1e6;
      last = now;
      if ((r->frames & 31) == 0)
      {
        size_t heap = heapInUse();
        if (heap > heapPeak) heapPeak = heap;
      }
      av_frame_unref(frame);
    }
    if (err != AVERROR(EAGAIN) && err != AVERROR_EOF)
    {
      av_strerror(err, r->error, sizeof(r->error));
      break;
    }
    if (draining && (err == AVERROR_EOF || !got)) break;
  }
  r->wallMs = (nowNs() - start) / 1e6;
  double cpuEnd = threadCpuMs();
  r->cpuMs = (cpuStart < 0 || cpuEnd < 0) ? -1 : cpuEnd - cpuStart;
  size_t heap = heapInUse();
  if (heap > heapPeak) heapPeak = heap;
  r->peakMb = (heapPeak - heapBase) / (1024.0 * 1024.0);

  qsort(frameMs, r->frames, sizeof(double), compareDouble);
  r->p50 = percentile(frameMs, r->frames, 0.50);
  r->p95 = percentile(frameMs, r->frames, 0.95);
  r->p99 = percentile(frameMs, r->frames, 0.99);
  r->max = (r->frames > 0) ? frameMs[r->frames - 1] : 0;

done:
  free(frameMs);
  if (rgba[0] != NULL) av_freep(&rgba[0]);
  sws_freeContext(sws);
  av_frame_free(&frame);
  av_packet_free(&packet);
  avcodec_free_context(&codec);
  avformat_close_input(&format);
}

static void logConditions(const char *when)
{
#ifdef __SWITCH__
  u32 cpuHz = 0, memHz = 0;
  ClkrstSession session;
  if (R_SUCCEEDED(clkrstOpenSession(&session, PcvModuleId_CpuBus, 3)))
  {
    clkrstGetClockRate(&session, &cpuHz);
    clkrstCloseSession(&session);
  }
  if (R_SUCCEEDED(clkrstOpenSession(&session, PcvModuleId_EMC, 3)))
  {
    clkrstGetClockRate(&session, &memHz);
    clkrstCloseSession(&session);
  }
  float celsius = -1;
  TsSession ts;
  if (R_SUCCEEDED(tsOpenSession(&ts, TsDeviceCode_LocationInternal)))
  {
    tsSessionGetTemperature(&ts, &celsius);
    tsSessionClose(&ts);
  }
  else
  {
    s32 legacy = 0;
    if (R_SUCCEEDED(tsGetTemperature(TsLocation_Internal, &legacy))) celsius = (float)legacy;
  }
  SetSysFirmwareVersion firmware;
  memset(&firmware, 0, sizeof(firmware));
  setsysGetFirmwareVersion(&firmware);
  out("[VIDEOBENCH] conditions(%s) cpu_mhz=%u mem_mhz=%u temp_c=%.1f docked=%d firmware=%s", when, cpuHz / 1000000,
      memHz / 1000000, celsius, appletGetOperationMode() == AppletOperationMode_Console, firmware.display_version);
#else
  out("[VIDEOBENCH] conditions(%s) host", when);
#endif
}

static void *benchMain(void *unused)
{
  (void)unused;
  out("[VIDEOBENCH] start: %s | libavcodec %s", avcodec_license(), av_version_info());
  logConditions("start");
  for (size_t m = 0; m < MODE_COUNT && !stopRequested; m++)
  {
    const Mode *mode = &MODES[m];
    int totalFrames = 0;
    double totalMs = 0, worstRatio = 1e9;
    const char *worstVideo = "-";
    for (size_t v = 0; v < VIDEO_COUNT && !stopRequested; v++)
    {
      char path[256];
      snprintf(path, sizeof(path), "%s%s%s", VIDEO_DIR, VIDEOS[v], mode->suffix);
      BenchResult r;
      runOne(path, mode, &r);
      double fps = (r.wallMs > 0) ? r.frames * 1000.0 / r.wallMs : 0;
      double ratio = (r.nativeFps > 0) ? fps / r.nativeFps : 0;
      double period = (r.nativeFps > 0) ? 1000.0 / r.nativeFps : 0;
      out("[VIDEOBENCH] video=%s mode=%s threads=%d size=%dx%d frames=%d native_fps=%.0f wall_ms=%.0f fps=%.1f ratio=%.2f "
          "cpu_ms=%.0f p50=%.1f p95=%.1f p99=%.1f max=%.1f period=%.1f peak_mb=%.1f%s%s",
          VIDEOS[v], mode->name, mode->threads, r.width, r.height, r.frames, r.nativeFps, r.wallMs, fps, ratio, r.cpuMs,
          r.p50, r.p95, r.p99, r.max, period, r.peakMb, r.error[0] ? " error=" : "", r.error);
      totalFrames += r.frames;
      totalMs += r.wallMs;
      if (ratio < worstRatio)
      {
        worstRatio = ratio;
        worstVideo = VIDEOS[v];
      }
    }
    out("[VIDEOBENCH] summary mode=%s frames=%d wall_ms=%.0f fps=%.1f worst_ratio=%.2f (%s)", mode->name, totalFrames,
        totalMs, totalMs > 0 ? totalFrames * 1000.0 / totalMs : 0, worstRatio, worstVideo);
    logConditions(mode->name);
  }
  out(stopRequested ? "[VIDEOBENCH] stopped before the end" : "[VIDEOBENCH] done");
  // Close the log here, not at exit: Citron only shows the last write on the host once the file is closed.
  if (logFile != NULL) fclose(logFile);
  logFile = NULL;
  benchDone = 1;
  return NULL;
}

#ifdef __SWITCH__
static void benchThread(void *arg)
{
  benchMain(arg);
}
#endif

int main(int argc, char **argv)
{
  (void)argc;
  (void)argv;
#ifdef __SWITCH__
#ifndef BENCH_NO_CONSOLE
  consoleInit(NULL);
#endif
  padConfigureInput(1, HidNpadStyleSet_NpadStandard);
  PadState pad;
  padInitializeDefault(&pad);
  romfsInit();
  clkrstInitialize();
  tsInitialize();
  setsysInitialize();
  mkdir("sdmc:/switch", 0777);
  mkdir("sdmc:/switch/Friday-Night-Funkin", 0777);
#endif
  mkdir(LOG_DIR, 0777);
  logFile = fopen(LOG_DIR "/videobench.log", "a");
  time_t wall = time(NULL);
  out("[VIDEOBENCH] ===== %s", ctime(&wall));
  out("Decoding the 7 cutscenes in 5 modes (about 10 minutes). Keep the console awake (touch the screen now and then, or turn off auto-sleep); + exits when done.");

#ifdef __SWITCH__
  Thread thread;
  // Core 2, priority 0x2C: where the player's decoder thread would run (the game's main thread is on core 0).
  Result rc = threadCreate(&thread, benchThread, NULL, NULL, 0x100000, 0x2C, 2);
  if (R_SUCCEEDED(rc)) rc = threadStart(&thread);
  if (R_FAILED(rc))
  {
    out("[VIDEOBENCH] could not start the bench thread on core 2 (0x%x)", rc);
    benchDone = 1;
  }
  while (appletMainLoop())
  {
    padUpdate(&pad);
    if (benchDone && (padGetButtonsDown(&pad) & HidNpadButton_Plus)) break;
#ifndef BENCH_NO_CONSOLE
    mutexLock(&consoleLock);
    consoleUpdate(NULL);
    mutexUnlock(&consoleLock);
#endif
    svcSleepThread(50000000);
  }
  stopRequested = 1;
  if (R_SUCCEEDED(rc))
  {
    threadWaitForExit(&thread);
    threadClose(&thread);
  }
#else
  pthread_t thread;
  pthread_create(&thread, NULL, benchMain, NULL);
  pthread_join(thread, NULL);
#endif

  if (logFile != NULL) fclose(logFile);
#ifdef __SWITCH__
  setsysExit();
  tsExit();
  clkrstExit();
  romfsExit();
#ifndef BENCH_NO_CONSOLE
  consoleExit(NULL);
#endif
#endif
  return 0;
}
