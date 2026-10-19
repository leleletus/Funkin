package nx;

/**
 * Test-only tools of the Switch port (botplay and automated tests).
 *
 * Compiled in only when building with `-DNX_DEV_TOOLS` (test builds). A build without it (public
 * release) has no botplay at all: the R3 shortcut is gone, songs never start in botplay and
 * `autotest.cfg` is ignored, so nobody can use it to cheat.
 *
 * In test builds the options come from `nx_devtools.cfg` next to the .nro (copied by
 * tools/nx-tools/deploy_switch.sh from tools/nx-tools/nx_devtools.cfg on every deploy):
 *
 *   botplay_toggle=true   # R3 (right stick click) toggles botplay during a song
 *   botplay_start=false   # songs start with botplay already on
 *   heap_cap_mb=0         # 0 = off; e.g. 3110 caps the heap to emulate the console in Citron (INC49_REPRO)
 *   single_copy_decode=true  # false = lime's stock double-copy PNG decode, for A/B memory runs (INC-49)
 *
 * Automated tests (NXAutoTest) always run with botplay on. The botplay state is never saved, so a
 * save made with a test build cannot carry it into a release build.
 */
class NXDevTools
{
  #if NX_DEV_TOOLS
  static var loaded:Bool = false;
  static var cfgBotplayToggle:Bool = true;
  static var cfgBotplayStart:Bool = false;
  static var cfgHeapCapMb:Int = 0;
  static var botplayOverride:Null<Bool> = null;

  /**
   * Reads nx_devtools.cfg once (missing file = defaults) and logs the active options.
   */
  public static function init():Void
  {
    if (loaded) return;
    loaded = true;
    var source:String = 'defaults (no nx_devtools.cfg)';
    #if sys
    try
    {
      var path:String = #if switch NXMain.getSafeAppSubPath('nx_devtools.cfg') #else 'nx_devtools.cfg' #end;
      if (sys.FileSystem.exists(path))
      {
        source = path;
        for (rawLine in sys.io.File.getContent(path).split('\n'))
        {
          var line:String = StringTools.trim(rawLine.split('#')[0]);
          var eq:Int = line.indexOf('=');
          if (eq <= 0) continue;
          var key:String = StringTools.trim(line.substr(0, eq)).toLowerCase();
          var raw:String = StringTools.trim(line.substr(eq + 1)).toLowerCase();
          var value:Bool = ['1', 'true', 'yes', 'on'].contains(raw);
          switch (key)
          {
            case 'botplay_toggle':
              cfgBotplayToggle = value;
            case 'botplay_start':
              cfgBotplayStart = value;
            case 'heap_cap_mb':
              var mb:Null<Int> = Std.parseInt(raw);
              cfgHeapCapMb = (mb != null && mb > 0) ? mb : 0;
            case 'single_copy_decode':
              NXImageDecode.enabled = value;
            default:
          }
        }
      }
    }
    catch (e:Dynamic)
    {
      source = 'defaults (nx_devtools.cfg unreadable: $e)';
    }
    #end
    NXDeepTrace.writeEntry('DEVTOOLS', 'Test build: botplay_toggle=$cfgBotplayToggle botplay_start=$cfgBotplayStart heap_cap_mb=$cfgHeapCapMb single_copy_decode=${NXImageDecode.enabled} from $source');
    #if switch
    NXDeepTrace.writeEntry('MEMORY', '[HEAP] boot: ${NXPerformance.describeHeapBounds()} | ${NXPerformance.describeHeap()}');
    // Citron's heap is ~98 MB larger than the console's: heap_cap_mb lets long-session tests run with the console's ceiling.
    if (cfgHeapCapMb > 0) NXDeepTrace.writeEntry('MEMORY', '[HEAP] ${NXPerformance.capHeap(cfgHeapCapMb)}');
    #end
  }

  /**
   * Whether the R3 botplay shortcut works in songs.
   */
  public static function botplayToggleAllowed():Bool
  {
    init();
    return cfgBotplayToggle || NXAutoTest.isActive();
  }

  /**
   * Current botplay state (cfg start value, forced on during automated tests, or the last R3 toggle).
   */
  public static function isBotplayOn():Bool
  {
    init();
    if (NXAutoTest.isActive()) return true;
    if (botplayOverride != null) return botplayOverride;
    return cfgBotplayStart || NXAutoTest.isActive();
  }

  public static function setBotplay(value:Bool):Void
  {
    botplayOverride = value;
  }

  /**
   * Whether autotest.cfg may start an automated test.
   */
  public static inline function autotestsAllowed():Bool
    return true;
  #else
  public static inline function init():Void {}

  public static inline function botplayToggleAllowed():Bool
    return false;

  public static inline function isBotplayOn():Bool
    return false;

  public static inline function setBotplay(value:Bool):Void {}

  public static inline function autotestsAllowed():Bool
    return false;
  #end
}
