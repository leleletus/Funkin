package nx;

#if (switch && cpp)
/**
 * Clock speeds within what Nintendo allows games (no overclocking).
 *
 * - GPU: in handheld, games may choose 307.2, 384 or 460.8 MHz and an application gets 307.2 MHz by default; the
 *   game always asks for 460.8 MHz (performance configuration 0x92220008: CPU 1020 MHz, GPU 460.8 MHz, memory
 *   1331.2 MHz). Docked it asks for 0x00010001 (CPU 1020 MHz, GPU 768 MHz, memory 1600 MHz), the docked maximum.
 *   The CPU stays at 1020 MHz in both modes.
 * - Loading: like many games, the CPU boost mode (1785 MHz CPU, GPU at its minimum) is on from a state switch
 *   until the new state has been running for LOAD_BOOST_SECONDS, which shortens decoding and parsing.
 */
@:cppFileCode('
#include <switch.h>

static ClkrstSession nxc_cpu, nxc_gpu, nxc_emc;
static int nxc_clkrstOpen = 0;
static int nxc_apmOpen = 0;

static void nxc_init(void)
{
  if (!nxc_apmOpen && R_SUCCEEDED(apmInitialize())) nxc_apmOpen = 1;
  if (!nxc_clkrstOpen && R_SUCCEEDED(clkrstInitialize()))
  {
    nxc_clkrstOpen = 1;
    if (R_FAILED(clkrstOpenSession(&nxc_cpu, PcvModuleId_CpuBus, 3))) nxc_clkrstOpen = 0;
    if (R_FAILED(clkrstOpenSession(&nxc_gpu, PcvModuleId_GPU, 3))) nxc_clkrstOpen = 0;
    if (R_FAILED(clkrstOpenSession(&nxc_emc, PcvModuleId_EMC, 3))) nxc_clkrstOpen = 0;
  }
}

static int nxc_mhz(int which)
{
  if (!nxc_clkrstOpen) return -1;
  u32 hz = 0;
  ClkrstSession *s = (which == 0) ? &nxc_cpu : (which == 1 ? &nxc_gpu : &nxc_emc);
  if (R_FAILED(clkrstGetClockRate(s, &hz))) return -1;
  return (int)(hz / 1000000);
}

static int nxc_setConfig(int docked, u32 config)
{
  if (!nxc_apmOpen) return -1;
  return (int)apmSetPerformanceConfiguration(docked ? ApmPerformanceMode_Boost : ApmPerformanceMode_Normal, config);
}

static u32 nxc_currentConfig(void)
{
  u32 config = 0;
  if (R_FAILED(appletGetCurrentPerformanceConfiguration(&config))) return 0;
  return config;
}
')
#end
class NXClocks
{
  /**
   * CPU 1020 MHz, GPU 460.8 MHz, memory 1331.2 MHz: the fastest handheld GPU speed games may use.
   */
  static inline final HANDHELD_CONFIG:Int = 0x92220008;

  /**
   * CPU 1020 MHz, GPU 768 MHz, memory 1600 MHz: the docked maximum.
   */
  static inline final DOCKED_CONFIG:Int = 0x00010001;

  static inline final LOAD_BOOST_SECONDS:Float = 1.5;

  static var initialized:Bool = false;
  static var loadBoostOn:Bool = false;
  static var loadBoostUntil:Float = -1.0;

  public static function init():Void
  {
    #if (switch && cpp)
    if (initialized) return;
    initialized = true;
    untyped __cpp__('nxc_init()');
    applyConfigurations();
    flixel.FlxG.signals.preStateSwitch.add(function() setLoadBoost(true));
    flixel.FlxG.signals.postStateSwitch.add(function() loadBoostUntil = haxe.Timer.stamp() + LOAD_BOOST_SECONDS);
    #end
  }

  /**
   * Called every frame: ends the loading boost once the new state has run for a moment.
   */
  public static function update():Void
  {
    if (loadBoostOn && loadBoostUntil > 0 && haxe.Timer.stamp() >= loadBoostUntil) setLoadBoost(false);
  }

  /**
   * Sets the configuration used in handheld (GPU 460.8 MHz) and docked (GPU 768 MHz); the system switches between
   * them by itself when the console is docked or undocked.
   */
  static function applyConfigurations():Void
  {
    #if (switch && cpp)
    var handheldRc:Int = untyped __cpp__('nxc_setConfig(0, (u32){0})', HANDHELD_CONFIG);
    var dockedRc:Int = untyped __cpp__('nxc_setConfig(1, (u32){0})', DOCKED_CONFIG);
    NXDeepTrace.writeEntry('PERF', '[CLOCKS] handheld 0x${StringTools.hex(HANDHELD_CONFIG, 8)} (GPU 460.8 MHz) rc 0x${StringTools.hex(handheldRc)}, '
      + 'docked 0x${StringTools.hex(DOCKED_CONFIG, 8)} (GPU 768 MHz) rc 0x${StringTools.hex(dockedRc)} | now ${describe()}');
    #end
  }

  static function setLoadBoost(on:Bool):Void
  {
    #if (switch && cpp)
    if (on == loadBoostOn) return;
    loadBoostOn = on;
    if (!on) loadBoostUntil = -1.0;
    untyped __cpp__('appletSetCpuBoostMode({0} ? ApmCpuBoostMode_FastLoad : ApmCpuBoostMode_Normal)', on);
    #end
  }

  /**
   * Current clocks for the logs, e.g. 'cpu 1020 gpu 460 mem 1331 MHz (config 0x92220008)'.
   */
  public static function describe():String
  {
    #if (switch && cpp)
    var cpu:Int = untyped __cpp__('nxc_mhz(0)');
    var gpu:Int = untyped __cpp__('nxc_mhz(1)');
    var mem:Int = untyped __cpp__('nxc_mhz(2)');
    var config:Int = untyped __cpp__('(int)nxc_currentConfig()');
    return 'cpu $cpu gpu $gpu mem $mem MHz (config 0x${StringTools.hex(config, 8)})';
    #else
    return 'clocks n/a';
    #end
  }
}
