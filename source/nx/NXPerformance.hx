package nx;

import flixel.FlxG;
import funkin.Preferences;
import funkin.ui.debug.FunkinDebugDisplay.DebugDisplayMode;
#if switch
import nx.NXMain;
#if cpp
@:cppInclude("switch.h")
@:cppInclude("malloc.h")
@:cppFileCode('
#include <malloc.h>
#include <reent.h>
#include <stdio.h>
#include <switch.h>

// CPU time of the calling thread in ms (firmware 13.0.0+), or -1.
static double nx_threadCpuMs(void)
{
  u64 ticks = 0;
  if (R_FAILED(svcGetInfo(&ticks, InfoType_ThreadTickCount, CUR_THREAD_HANDLE, (u64)-1))) return -1.0;
  return (double)armTicksToNs(ticks) / 1000000.0;
}
extern "C" {
  extern char* fake_heap_start;
  extern char* fake_heap_end;
  // newlib malloc state (dlmalloc 2.6.x): bins, peak arena and top padding. Read only, under __malloc_lock.
  extern void* __malloc_av_[];
  extern unsigned long __malloc_max_sbrked_mem;
  extern unsigned long __malloc_top_pad;
  extern struct mallinfo __malloc_current_mallinfo; // .arena = bytes obtained from sbrk (sbrked_mem)
  // nx.NXLargeHeap (region for blocks of 2 MiB or more); null when built with -Dnx_legacy_heap.
  size_t nxl_totalBytes(void) __attribute__((weak));
  size_t nxl_allocBound(void) __attribute__((weak));
  size_t nxl_largestFree(void) __attribute__((weak));
  size_t nxl_usedBytes(void) __attribute__((weak));
  int nxl_cap(size_t) __attribute__((weak));
}

struct nx_mchunk { size_t prev_size; size_t size; struct nx_mchunk *fd; struct nx_mchunk *bk; };

struct nx_heapstat
{
  double total, used, freeAll, top, untouched, largestHole, allocBound, peakArena, start, end, brk;
  int n16, n64, n128, n256, walked, truncated;
};

// Last probe result, read field by field from Haxe (main thread only).
static struct nx_heapstat nx_hs;

// Never allocates: one pass over the free bins and the top chunk, all under the (recursive) malloc lock, so every
// number in a [HEAP] line comes from the same heap state. The old probe (malloc/free binary search) was removed by
// the compiler and always reported 3071 MB.
#define NX_WALK_CAP 200000
static void nx_heapProbe(struct nx_heapstat *st)
{
  __malloc_lock(_REENT);
  struct nx_mchunk *top = (struct nx_mchunk *)__malloc_av_[2];
  size_t topSize = top->size & ~(size_t)3;
  char *brk = (char *)top + topSize;
  size_t arena = __malloc_current_mallinfo.arena;
  size_t largest = 0, binSum = 0;
  int n16 = 0, n64 = 0, n128 = 0, n256 = 0, walked = 0, truncated = 0;
  // Bin 1 (last remainder) first, then from bin 126 (every free chunk of 512 KiB or more, sorted largest first)
  // down to bin 2: if the walk is capped, only small-chunk statistics are lost.
  for (int k = 0; k < 126 && !truncated; k++)
  {
    int i = (k == 0) ? 1 : 127 - k;
    struct nx_mchunk *bin = (struct nx_mchunk *)((char *)&__malloc_av_[2 * i + 2] - 2 * sizeof(size_t));
    for (struct nx_mchunk *p = bin->fd; p != bin; p = p->fd)
    {
      if (walked >= NX_WALK_CAP) { truncated = 1; break; }
      walked++;
      size_t s = p->size & ~(size_t)3;
      binSum += s;
      if (s > largest) largest = s;
      if (s >= ((size_t)16 << 20)) n16++;
      if (s >= ((size_t)64 << 20)) n64++;
      if (s >= ((size_t)128 << 20)) n128++;
      if (s >= ((size_t)256 << 20)) n256++;
    }
  }
  size_t freeAll = topSize + binSum;
  size_t used = arena > freeAll ? arena - freeAll : 0;
  if (truncated)
  {
    // Partial sum: take the exact totals from newlib (the lock is recursive).
    struct mallinfo mi = mallinfo();
    freeAll = mi.fordblks;
    used = mi.uordblks;
  }
  unsigned long topPad = __malloc_top_pad;
  unsigned long peak = __malloc_max_sbrked_mem;
  char *heapStart = fake_heap_start;
  char *heapEnd = fake_heap_end;
  __malloc_unlock(_REENT);

  size_t untouched = (heapEnd > brk) ? (size_t)(heapEnd - brk) : 0;
  // malloc_extend_top asks sbrk for nb + top_pad + MINSIZE without counting the old top, so the bound is a MAX.
  size_t fromTop = topSize > 32 ? topSize - 32 : 0;
  size_t fromSbrk = untouched > (topPad + 4096 + 64) ? ((untouched - topPad - 64) & ~(size_t)0xfff) - 32 : 0;
  size_t bound = largest;
  if (fromTop > bound) bound = fromTop;
  if (fromSbrk > bound) bound = fromSbrk;
  bound = bound > 64 ? bound - 64 : 0; // _memalign_r(32, n) overhead
  if (nxl_allocBound)
  {
    size_t largeBound = nxl_allocBound(); // requests of 2 MiB or more are served by the large region first
    if (largeBound > bound) bound = largeBound;
  }
  if (bound > 0x7fffffffUL) bound = 0x7fffffffUL;

  st->total = nxl_totalBytes ? (double)nxl_totalBytes() : (double)(heapEnd - heapStart);
  st->used = (double)used;
  st->freeAll = (double)freeAll;
  st->top = (double)topSize;
  st->untouched = (double)untouched;
  st->largestHole = (double)largest;
  st->allocBound = (double)bound;
  st->peakArena = (double)peak;
  st->start = (double)(size_t)heapStart;
  st->end = (double)(size_t)heapEnd;
  st->brk = (double)(size_t)brk;
  st->n16 = n16; st->n64 = n64; st->n128 = n128; st->n256 = n256; st->walked = walked; st->truncated = truncated;
}

// Largest block malloc can return right now without growing the arena: the head of bin 126 (every free chunk of
// 512 KiB or more, kept sorted largest first), the last split remainder (bin 1) and the top chunk. O(1), never
// allocates, read under the (recursive) malloc lock like nx_heapProbe.
static size_t nx_largestFreeChunk(void)
{
  __malloc_lock(_REENT);
  size_t largest = 0;
  struct nx_mchunk *big = (struct nx_mchunk *)((char *)&__malloc_av_[2 * 126 + 2] - 2 * sizeof(size_t));
  if (big->fd != big) largest = big->fd->size & ~(size_t)3;
  struct nx_mchunk *lr = (struct nx_mchunk *)((char *)&__malloc_av_[2 * 1 + 2] - 2 * sizeof(size_t));
  if (lr->fd != lr)
  {
    size_t s = lr->fd->size & ~(size_t)3;
    if (s > largest) largest = s;
  }
  struct nx_mchunk *top = (struct nx_mchunk *)__malloc_av_[2];
  size_t topSize = top->size & ~(size_t)3;
  if (topSize > largest) largest = topSize;
  if (nxl_largestFree)
  {
    size_t regionLargest = nxl_largestFree();
    if (regionLargest > largest) largest = regionLargest;
  }
  __malloc_unlock(_REENT);
  return largest;
}

// Test builds: lower the heap ceiling (libnx _sbrk_r re-reads fake_heap_end on every call) to emulate the
// console heap in Citron. Only allowed while the arena is well below the new ceiling.
static int nx_capHeap(size_t capBytes)
{
  // Under the malloc lock: every _sbrk_r call runs under it, so the margin check and the new ceiling are atomic
  // with respect to heap growth.
  __malloc_lock(_REENT);
  if (nxl_cap)
  {
    // The large region sits at the top of the heap: the cap becomes unusable space between it and newlib.
    int rc = nxl_cap(capBytes);
    __malloc_unlock(_REENT);
    return rc;
  }
  char *newEnd = fake_heap_start + capBytes;
  if (newEnd >= fake_heap_end) { __malloc_unlock(_REENT); return 1; }
  struct nx_mchunk *top = (struct nx_mchunk *)__malloc_av_[2];
  char *brk = (char *)top + (top->size & ~(size_t)3);
  if (newEnd < brk + ((size_t)256 << 20)) { __malloc_unlock(_REENT); return 2; }
  fake_heap_end = newEnd;
  __malloc_unlock(_REENT);
  return 0;
}
')
#end
#end

/**
 * Performance and display manager for Nintendo Switch.
 * Centralizes resolution scaling, hardware HUD monitoring, and graphics profiling.
 */
class NXPerformance
{
  /**
   * Last recorded docked status to detect transitions.
   */
  public static var lastDockedState:Bool = false;

  /**
   * Initialize performance settings and hooks.
   */
  public static function init():Void
  {
    #if switch
    lastDockedState = NXMain.IS_DOCKED;
    applyResolutionMode(Preferences.switchResolutionMode);
    updatePerfHud();
    NXTextureMemory.init();
    #if NX_DEV_TOOLS
    // Test builds: log touchscreen events to learn whether they reach the game (touch controls are mobile-only upstream).
    lime.ui.Touch.onStart.add(function(touch:lime.ui.Touch) {
      NXDeepTrace.writeEntry('TOUCH', 'start id ${touch.id} at ${Math.round(touch.x * 1280)},${Math.round(touch.y * 720)} (${NXMain.IS_DOCKED ? "docked" : "handheld"})');
    });
    lime.ui.Touch.onEnd.add(function(touch:lime.ui.Touch) {
      NXDeepTrace.writeEntry('TOUCH', 'end id ${touch.id} at ${Math.round(touch.x * 1280)},${Math.round(touch.y * 720)}');
    });
    #end
    #end
  }

  static var comboHoldTimer:Float = 0.0;
  static var comboTriggered:Bool = false;
  static final COMBO_HOLD_DURATION:Float = 3.0;

  static var lastL3PressTime:Float = -1.0;
  static final L3_DEBOUNCE_COOLDOWN:Float = 0.25; // Minimum 250ms debounce cooldown

  /**
   * Called every frame from NXMain.update() to handle dock/undock transitions and button combos.
   */
  public static function update():Void
  {
    #if switch
    var currentDocked:Bool = NXMain.IS_DOCKED;
    if (currentDocked != lastDockedState)
    {
      lastDockedState = currentDocked;
      onDockStateChanged(currentDocked);
    }

    NXAudioDiagnostics.checkSystemSuspension();
    NXHaptics.update();

    #if NX_DEV_TOOLS
    updatePerfTelemetry();
    logGamepadInput();
    NXDevOverlay.update();
    checkAutoPlayCombo();

    // Universal HUD Toggle: L3 (Left Stick click) with unified single-source read and debounce cooldown
    var l3Pressed:Bool = false;
    try
    {
      if (NXMain.nxController != null)
      {
        l3Pressed = NXMain.nxController.isJustPressed(nx.controls.NXControlButton.STICK_L);
      }
      else if (FlxG.gamepads != null)
      {
        l3Pressed = FlxG.gamepads.anyJustPressed(LEFT_STICK_CLICK);
      }
    }
    catch (e:Dynamic) {}

    var now:Float = Sys.time();
    if (l3Pressed && (lastL3PressTime < 0 || (now - lastL3PressTime) >= L3_DEBOUNCE_COOLDOWN))
    {
      lastL3PressTime = now;
      try
      {
        var nextMode:DebugDisplayMode;
        switch (Preferences.debugDisplay)
        {
          case DebugDisplayMode.Off:
            nextMode = DebugDisplayMode.Simple;
          case DebugDisplayMode.Simple:
            nextMode = DebugDisplayMode.Advanced;
          case DebugDisplayMode.Advanced:
            nextMode = DebugDisplayMode.Off;
        }
        Preferences.debugDisplay = nextMode;
        Preferences.switchShowPerfHud = (nextMode != DebugDisplayMode.Off);
        updatePerfHud();
        try
        {
          funkin.audio.FunkinSound.playOnce(funkin.Paths.sound('confirmMenu'), 0.7);
        }
        catch (e:Dynamic) {}
        nx.NXDeepTrace.logButtonEvent('L3', 'Cycled Performance HUD to $nextMode');
        trace('Switch: Cycled Performance HUD via L3 to: ' + Preferences.debugDisplay);
      }
      catch (e:Dynamic)
      {
        trace('Warning: Failed to cycle debug display via L3: ' + e);
      }
    }

    // Secondary button combo: hold PLUS and R for 3.0 seconds to toggle Performance HUD (FPS/RAM)
    var plusPressed:Bool = (NXMain.nxController != null && NXMain.nxController.isPressed(nx.controls.NXControlButton.PLUS)) || FlxG.gamepads.anyPressed(START);
    var rPressed:Bool = (NXMain.nxController != null && NXMain.nxController.isPressed(nx.controls.NXControlButton.R)) || FlxG.gamepads.anyPressed(RIGHT_SHOULDER);

    if (plusPressed && rPressed)
    {
      comboHoldTimer += FlxG.elapsed;
      if (comboHoldTimer >= COMBO_HOLD_DURATION && !comboTriggered)
      {
        comboTriggered = true;
        var nextMode:DebugDisplayMode = (Preferences.debugDisplay == DebugDisplayMode.Off) ? DebugDisplayMode.Advanced : DebugDisplayMode.Off;
        Preferences.debugDisplay = nextMode;
        try
        {
          funkin.audio.FunkinSound.playOnce(funkin.Paths.sound('confirmMenu'), 0.7);
        }
        catch (e:Dynamic) {}
        trace('Switch: Toggled Performance HUD via PLUS+R combo to: ' + Preferences.debugDisplay);
      }
    }
    else
    {
      comboHoldTimer = 0.0;
      comboTriggered = false;
    }
    #end // NX_DEV_TOOLS
    #end
  }

  #if NX_DEV_TOOLS
  static var autoPlayHold:Float = 0.0;
  static var autoPlayTriggered:Bool = false;

  /**
   * Test builds: holding L+R or ZL+ZR for 3 s starts the run set in nx_devtools.cfg (combo_lr / combo_zlzr; empty or
   * off = the combo does nothing). The repo cfg uses L+R for MEMORY_BUDGET_X3 (every Story week three times in a row,
   * memory budget per week, ~30 min) and ZL+ZR for PLAYTHROUGH (Weekend 1, Week 7, LE SSERAFIM and two Freeplay songs
   * played to the end with botplay).
   */
  static function checkAutoPlayCombo():Void
  {
    var shoulders:Bool = false;
    var triggers:Bool = false;
    try
    {
      if (NXMain.nxController != null)
      {
        shoulders = NXMain.nxController.isPressed(nx.controls.NXControlButton.L) && NXMain.nxController.isPressed(nx.controls.NXControlButton.R);
        triggers = NXMain.nxController.isPressed(nx.controls.NXControlButton.ZL) && NXMain.nxController.isPressed(nx.controls.NXControlButton.ZR);
      }
      else if (FlxG.gamepads != null)
      {
        shoulders = FlxG.gamepads.anyPressed(LEFT_SHOULDER) && FlxG.gamepads.anyPressed(RIGHT_SHOULDER);
        triggers = FlxG.gamepads.anyPressed(LEFT_TRIGGER) && FlxG.gamepads.anyPressed(RIGHT_TRIGGER);
      }
    }
    catch (e:Dynamic) {}

    var scenario:String = shoulders ? NXDevTools.comboScenario('lr') : (triggers ? NXDevTools.comboScenario('zlzr') : '');
    if (shoulders == triggers || scenario == '') // neither, all four at once, or not enabled in nx_devtools.cfg
    {
      autoPlayHold = 0.0;
      autoPlayTriggered = false;
      return;
    }
    autoPlayHold += FlxG.elapsed;
    if (autoPlayHold >= 3.0 && !autoPlayTriggered)
    {
      autoPlayTriggered = true;
      if (NXAutoTest.isActive())
      {
        NXDevOverlay.show('AUTO: a run is already active', 3.0);
        return;
      }
      NXDeepTrace.logButtonEvent(shoulders ? 'L+R' : 'ZL+ZR', 'held 3s: starting $scenario');
      NXAutoTest.startRuntime(scenario);
    }
  }
  #end

  /**
   * Handle Dock insertion/removal.
   */
  public static function onDockStateChanged(isDocked:Bool):Void
  {
    trace('Switch Dock state changed: ' + (isDocked ? 'Docked' : 'Handheld'));
    applyResolutionMode(Preferences.switchResolutionMode);
  }

  /**
   * Applies the resolution configuration based on the user's preference.
   * - "720p" (default): Forces 1280x720 fixed framebuffer to avoid GPU fillrate bottleneck.
   * - "Docked": Allows 1080p (1920x1080) when docked, 720p when handheld.
   * - "540p": Lowers resolution to 960x540 for maximum performance.
   *
   * NOTE: resizing the SDL window (`window.resize`) does NOT resize the EGL surface on Horizon: the
   * backbuffer stays at the display size while OpenFL assumes the new size, rendering the game shifted
   * and cropped (verified in Citron, Build 18 development). A real internal resolution needs an
   * offscreen render target; until then this only reports the requested size.
   */
  public static function applyResolutionMode(mode:String):Void
  {
    #if switch
    var targetWidth:Int = 1280;
    var targetHeight:Int = 720;

    switch (mode)
    {
      case "Docked":
        if (NXMain.IS_DOCKED)
        {
          targetWidth = 1920;
          targetHeight = 1080;
        }
        else
        {
          targetWidth = 1280;
          targetHeight = 720;
        }
      case "540p":
        targetWidth = 960;
        targetHeight = 540;
      default: // "720p" / "Native 720p"
        targetWidth = 1280;
        targetHeight = 720;
    }

    if (FlxG.stage != null && FlxG.stage.window != null)
    {
      trace('Switch resolution set to: ${targetWidth}x${targetHeight} (Mode: $mode)');
    }
    #end
  }

  /**
   * Logs every gamepad button press (name and song position), so hardware logs show exactly what the
   * player did before a failure.
   */
  static function logGamepadInput():Void
  {
    var pad = FlxG.gamepads?.lastActive;
    if (pad == null || !pad.justPressed.ANY) return;
    var pressed:Array<String> = [];
    for (button in @:privateAccess pad.buttons)
    {
      if (button != null && button.justPressed) pressed.push(pad.mapping.getID(button.ID).toString());
    }
    var ps = funkin.play.PlayState.instance;
    var where:String = (ps != null && ps.currentSong != null) ? '${ps.currentSong.id}@${Math.round(funkin.Conductor.instance.songPosition)}ms' : Type.getClassName(Type.getClass(FlxG.state));
    NXDeepTrace.writeEntry('INPUT', '[PAD] ${pressed.join("+")} ($where)');
    NXAudioDiagnostics.record('pad ${pressed.join("+")} $where');
  }

  static var perfWindowStart:Float = -1.0;
  static var perfLastFrame:Float = -1.0;
  static var perfFrames:Int = 0;
  static var perfWorstFrameMs:Float = 0.0;
  static var perfSlowFrames:Int = 0;
  static var perfCpuStart:Float = -1.0;
  static var perfWhere:String = '';
  static final PERF_WINDOW_SECONDS:Float = 5.0;

  static function mainThreadCpuMs():Float
  {
    #if (switch && cpp)
    return untyped __cpp__('nx_threadCpuMs()');
    #else
    return -1.0;
    #end
  }

  /**
   * Performance telemetry written to deep_engine_trace.log every 5 s while a song is running, and in menus (e.g.
   * Freeplay): average FPS, worst frame, frames slower than 20 ms (below ~50 FPS) and the main thread's CPU time
   * per frame. CPU per frame close to the frame time = the main thread is the limit; much lower = it waits for
   * the GPU (or the vsync).
   */
  static function updatePerfTelemetry():Void
  {
    var ps = funkin.play.PlayState.instance;
    var now:Float = haxe.Timer.stamp();
    var where:String;
    if (ps != null)
    {
      if (ps.subState != null || @:privateAccess ps.startingSong || ps.isInCutscene) where = '';
      else where = '${ps.currentSong?.id}@${Math.round(funkin.Conductor.instance.songPosition / 1000)}s';
    }
    else
    {
      var state = FlxG.state;
      where = (state == null) ? '' : Type.getClassName(Type.getClass(state)).split('.').pop();
      if (state != null && state.subState != null) where += '/' + Type.getClassName(Type.getClass(state.subState)).split('.').pop();
    }
    var windowKey:String = (ps != null) ? 'song' : where;
    if (where == '' || (perfWindowStart >= 0 && windowKey != perfWhere))
    {
      perfWindowStart = -1.0;
      perfLastFrame = -1.0;
      if (where == '') return;
    }
    if (perfWindowStart < 0)
    {
      perfWindowStart = now;
      perfLastFrame = now;
      perfFrames = 0;
      perfWorstFrameMs = 0.0;
      perfSlowFrames = 0;
      perfCpuStart = mainThreadCpuMs();
      perfWhere = windowKey;
      return;
    }
    var frameMs:Float = (now - perfLastFrame) * 1000.0;
    perfLastFrame = now;
    perfFrames++;
    if (frameMs > perfWorstFrameMs) perfWorstFrameMs = frameMs;
    if (frameMs > 20.0) perfSlowFrames++;

    var elapsed:Float = now - perfWindowStart;
    if (elapsed >= PERF_WINDOW_SECONDS)
    {
      var window = lime.app.Application.current?.window;
      var res:String = (window != null) ? '${window.width}x${window.height}' : '?';
      var cpuNow:Float = mainThreadCpuMs();
      var cpu:String = (perfCpuStart < 0 || cpuNow < 0 || perfFrames == 0) ? '?' : '${Math.round((cpuNow - perfCpuStart) / perfFrames * 10) / 10}';
      NXDeepTrace.writeEntry('PERF', '[$where] avg ${Math.round(perfFrames / elapsed * 10) / 10} FPS'
        + ' | worst frame ${Math.round(perfWorstFrameMs * 10) / 10} ms | slow frames (>20 ms): $perfSlowFrames/$perfFrames'
        + ' | main thread CPU $cpu ms/frame | antialiasing ${funkin.Preferences.switchAntialiasing ? "on" : "off"}'
        + ' | res $res | ${NXMain.IS_DOCKED ? "docked" : "handheld"} | ${describeHeap()}');
      perfWindowStart = now;
      perfFrames = 0;
      perfWorstFrameMs = 0.0;
      perfSlowFrames = 0;
      perfCpuStart = cpuNow;
    }
  }

  /**
   * Toggles or updates the performance HUD (FPS and RAM counter).
   */
  public static function updatePerfHud():Void
  {
    #if switch
    Preferences.setDebugDisplayMode(Preferences.debugDisplay);
    #end
  }

  /**
   * Helper check to determine if heavy shaders should run on Switch.
   */
  public static inline function areShadersEnabled():Bool
  {
    #if switch
    return Preferences.switchEnableShaders;
    #else
    return true;
    #end
  }

  /**
   * Helper check to determine if antialiasing is enabled on Switch.
   */
  public static inline function isAntialiasingEnabled():Bool
  {
    #if switch
    return Preferences.switchAntialiasing;
    #else
    return true;
    #end
  }

  /**
   * Helper check to determine if note splashes are enabled on Switch.
   */
  public static inline function areNoteSplashesEnabled():Bool
  {
    #if switch
    return Preferences.switchNoteSplashes;
    #else
    return true;
    #end
  }

  /**
   * Returns physical memory currently used by the process in megabytes (MB) directly from Horizon OS kernel (svcGetInfo).
   */
  public static function getPhysicalMemoryUsed():Float
  {
    #if (switch && cpp)
    var usedBytes:Float = 0;
    untyped __cpp__('
      u64 usedMemory = 0;
      #ifndef InfoType_UsedPhysicalMemory
      #define InfoType_UsedPhysicalMemory 7
      #endif
      svcGetInfo(&usedMemory, InfoType_UsedPhysicalMemory, CUR_PROCESS_HANDLE, 0);
      {0} = (double)usedMemory;
    ', usedBytes);
    return usedBytes / (1024.0 * 1024.0);
    #else
    return 0.0;
    #end
  }

  /**
   * Returns total physical memory available to the process in megabytes (MB) directly from Horizon OS kernel (svcGetInfo).
   * Title Override grants ~3200 MB (3.2 GB), while Applet Mode grants ~450 MB.
   */
  public static function getPhysicalMemoryTotal():Float
  {
    #if (switch && cpp)
    var totalBytes:Float = 0;
    untyped __cpp__('
      u64 totalMemory = 0;
      #ifndef InfoType_TotalPhysicalMemoryAvailable
      #define InfoType_TotalPhysicalMemoryAvailable 6
      #endif
      svcGetInfo(&totalMemory, InfoType_TotalPhysicalMemoryAvailable, CUR_PROCESS_HANDLE, 0);
      {0} = (double)totalMemory;
    ', totalBytes);
    return totalBytes / (1024.0 * 1024.0);
    #else
    return 0.0;
    #end
  }

  /**
   * Returns bytes currently allocated through malloc (newlib's `mallinfo().uordblks` plus NXLargeHeap's blocks), in MB.
   * Unlike `getPhysicalMemoryUsed()` (which reports the heap mapped by `svcSetHeapSize`), this tracks real
   * native allocations: decoded image pixel buffers, PCM audio buffers, and Mesa/nouveau driver allocations.
   */
  public static function getNativeHeapUsed():Float
  {
    #if (switch && cpp)
    var usedBytes:Float = 0;
    untyped __cpp__('
      struct mallinfo mi = mallinfo();
      {0} = (double)mi.uordblks + (nxl_usedBytes ? (double)nxl_usedBytes() : 0.0);
    ', usedBytes);
    return usedBytes / (1024.0 * 1024.0);
    #else
    return 0.0;
    #end
  }

  /**
   * Real state of the newlib heap (the only memory pool of the process: textures, audio, Mesa...):
   * total heap given by Horizon, bytes in use, free bytes inside the arena (holes) and memory never
   * touched yet above the arena. A large-allocation crash with plenty of "free" but little "untouched"
   * memory means fragmentation; little of both means memory really ran out.
   */
  public static function describeHeap():String
  {
    #if (switch && cpp)
    untyped __cpp__('nx_heapProbe(&nx_hs)');
    var total:Float = untyped __cpp__('nx_hs.total');
    var used:Float = untyped __cpp__('nx_hs.used');
    var freeAll:Float = untyped __cpp__('nx_hs.freeAll');
    var top:Float = untyped __cpp__('nx_hs.top');
    var untouched:Float = untyped __cpp__('nx_hs.untouched');
    var largestHole:Float = untyped __cpp__('nx_hs.largestHole');
    var allocBound:Float = untyped __cpp__('nx_hs.allocBound');
    var peakArena:Float = untyped __cpp__('nx_hs.peakArena');
    var n16:Int = untyped __cpp__('nx_hs.n16');
    var n64:Int = untyped __cpp__('nx_hs.n64');
    var n128:Int = untyped __cpp__('nx_hs.n128');
    var n256:Int = untyped __cpp__('nx_hs.n256');
    var walked:Int = untyped __cpp__('nx_hs.walked');
    var truncated:Bool = untyped __cpp__('nx_hs.truncated != 0');
    var mb = (x:Float) -> Math.round(x / 104857.6) / 10;
    // "free in bins" excludes the top chunk (mallinfo fordblks includes it).
    return 'heap ${mb(total)} MB | in use ${mb(used)} MB | free in bins ${mb(freeAll - top)} MB (largest hole ${mb(largestHole)} MB, holes >=16/64/128/256 MB: $n16/$n64/$n128/$n256, $walked chunks${truncated ? " TRUNCATED" : ""})'
      + ' | top ${mb(top)} MB | untouched ${mb(untouched)} MB | max single alloc ~${mb(allocBound)} MB | peak arena ${mb(peakArena)} MB'
      + ' | ${NXLargeHeap.describe()}';
    #else
    return 'heap n/a';
    #end
  }

  /**
   * Largest block malloc can hand out right now without growing the arena (largest free chunk, last split remainder
   * or top chunk), in bytes. O(1) and allocation-free: NXTextureMemory uses it to tell whether a GPU texture would
   * extend the heap (INC-49).
   */
  public static function getLargestFreeChunkBytes():Float
  {
    #if (switch && cpp)
    var bytes:Float = 0;
    untyped __cpp__('{0} = (double)nx_largestFreeChunk()', bytes);
    return bytes;
    #else
    return 0.0;
    #end
  }

  /**
   * Total heap size in MB (fake_heap_end - fake_heap_start), e.g. to check that a heap cap is in effect.
   */
  public static function getHeapTotalMB():Float
  {
    #if (switch && cpp)
    untyped __cpp__('nx_heapProbe(&nx_hs)');
    var total:Float = untyped __cpp__('nx_hs.total');
    return total / (1024.0 * 1024.0);
    #else
    return 0.0;
    #end
  }

  /**
   * Absolute heap bounds, for placing pointers from crash reports inside the arena.
   */
  public static function describeHeapBounds():String
  {
    #if (switch && cpp)
    var text:String = '';
    untyped __cpp__('
      nx_heapProbe(&nx_hs); // reads the bounds under the malloc lock
      char buf[160];
      snprintf(buf, sizeof(buf), "fake_heap_start %p fake_heap_end %p brk %p", (void *)(size_t)nx_hs.start, (void *)(size_t)nx_hs.end, (void *)(size_t)nx_hs.brk);
      {0} = ::String::create(buf);
    ', text);
    return text;
    #else
    return 'n/a';
    #end
  }

  /**
   * Test builds: caps the heap at `mb` MB (emulates the smaller console heap in Citron). Returns a log line.
   */
  public static function capHeap(mb:Int):String
  {
    #if (switch && cpp)
    var rc:Int = untyped __cpp__('nx_capHeap((size_t){0} << 20)', mb);
    return switch (rc)
    {
      case 0: 'heap capped at $mb MB (${describeHeapBounds()})';
      case 1: 'heap cap $mb MB ignored: the heap is already that small';
      default: 'heap cap $mb MB refused: the arena is too close to it';
    }
    #else
    return 'n/a';
    #end
  }

  /**
   * Largest single block malloc can currently return, in MB, computed without allocating (largest free bin
   * chunk, top chunk, or untouched heap). Decoding a 8192x4096 texture needs one contiguous 128 MB block even
   * when much more memory is free in smaller holes.
   */
  public static function getLargestAllocatableMB():Float
  {
    #if (switch && cpp)
    untyped __cpp__('nx_heapProbe(&nx_hs)');
    var bound:Float = untyped __cpp__('nx_hs.allocBound');
    return bound / (1024.0 * 1024.0);
    #else
    return 0.0;
    #end
  }

  /**
   * Free bytes inside the malloc arena (mallinfo().fordblks), in MB.
   */
  public static function getNativeHeapFree():Float
  {
    #if (switch && cpp)
    var freeBytes:Float = 0;
    untyped __cpp__('
      struct mallinfo mi = mallinfo();
      {0} = (double)mi.fordblks;
    ', freeBytes);
    return freeBytes / (1024.0 * 1024.0);
    #else
    return 0.0;
    #end
  }

  /**
   * Returns physical memory currently used by the process in raw bytes.
   */
  public static function getPhysicalMemoryUsedBytes():Float
  {
    #if (switch && cpp)
    var usedBytes:Float = 0;
    untyped __cpp__('
      u64 usedMemory = 0;
      #ifndef InfoType_UsedPhysicalMemory
      #define InfoType_UsedPhysicalMemory 7
      #endif
      svcGetInfo(&usedMemory, InfoType_UsedPhysicalMemory, CUR_PROCESS_HANDLE, 0);
      {0} = (double)usedMemory;
    ', usedBytes);
    return usedBytes;
    #else
    return 0.0;
    #end
  }
}
