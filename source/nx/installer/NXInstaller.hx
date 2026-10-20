package nx.installer;

import lime.ui.Gamepad;
import lime.ui.GamepadButton;
import openfl.display.Bitmap;
import openfl.display.BitmapData;
import openfl.display.Shape;
import openfl.display.Sprite;
import openfl.display.Stage;
import openfl.events.Event;
import openfl.events.KeyboardEvent;
import openfl.text.TextField;
import openfl.text.TextFormat;

/**
 * Asset installer of the asset-less Switch build (-DNX_SD_ASSETS), run by ApplicationMain before lime loads any
 * asset library:
 *
 * 1. prepare(): copies the lime manifests (and the code licence files) from RomFS to the SD card, where lime reads
 *    them with the SD card as root.
 * 2. run(): if the install state matches the manifest of this build, the game starts at once. Otherwise a quick
 *    check by file sizes; if something is missing, a screen offers to download it from The Funkin' Crew's official
 *    GitHub repository (raw.githubusercontent.com, the exact commit of this version), or to copy it from a computer.
 *    Every downloaded file is checked against the SHA-256 of the manifest before it takes its final name.
 * 3. When everything is in place, the game relaunches itself (hbloader), so it starts clean with the fonts and
 *    libraries of the SD card. Without a relaunch (Citron, some forwarders) it asks to reopen the game.
 *
 * Native part: nx_install_core.h (manifest, checks, state) and nx_install_download.h (libcurl).
 */
@:buildXml("<files id='haxe'><compilerflag value='-I${NX_INSTALLER_DIR}'/></files>")
@:cppFileCode('
#include <switch.h>
#include "nx_install_download.h"

static nxi_manifest nxinst_manifest;
static nxi_check nxinst_check;
static nxd_progress nxinst_progress;
static int nxinst_loaded = 0;
static int nxinst_curl = 0;

static int nxinst_load(const char *file)
{
  if (nxinst_loaded) nxi_manifest_free(&nxinst_manifest);
  nxinst_loaded = nxi_manifest_load(file, &nxinst_manifest) == 0;
  return nxinst_loaded;
}

static int nxinst_state_ok(const char *root)
{
  nxi_state s;
  if (!nxinst_loaded || nxi_state_read(root, &s) != 0) return 0;
  return nxi_state_matches(&s, &nxinst_manifest);
}

static int nxinst_write_state(const char *root)
{
  nxi_state s;
  memset(&s, 0, sizeof(s));
  snprintf(s.commit, sizeof(s.commit), "%s", nxinst_manifest.commit);
  snprintf(s.manifest_sha256, sizeof(s.manifest_sha256), "%s", nxinst_manifest.manifest_sha256);
  s.complete = 1;
  s.files = nxinst_manifest.count;
  s.bytes = nxinst_manifest.total_bytes;
  return nxi_state_write(root, &s) == 0;
}

static void nxinst_download(const char *root)
{
  if (!nxinst_curl)
  {
    curl_global_init(CURL_GLOBAL_DEFAULT);
    nxinst_curl = 1;
  }
  appletSetAutoSleepDisabled(true);
  nxd_download(&nxinst_manifest, &nxinst_check, root, &nxinst_progress);
  appletSetAutoSleepDisabled(false);
}

/* 1 when the console says it is connected to the internet (nifm), 0 if not, -1 if it cannot tell. */
static int nxinst_online(void)
{
  NifmInternetConnectionType type;
  u32 strength = 0;
  NifmInternetConnectionStatus status;
  int result = -1;
  if (R_FAILED(nifmInitialize(NifmServiceType_User))) return -1;
  if (R_SUCCEEDED(nifmGetInternetConnectionStatus(&type, &strength, &status)))
    result = status == NifmInternetConnectionStatus_Connected ? 1 : 0;
  else
    result = 0; /* nifm answers with an error when there is no network at all (airplane mode) */
  nifmExit();
  return result;
}

static int nxinst_relaunch(void)
{
  extern char **__system_argv;
  extern int __system_argc;
  char args[1024];
  if (!envHasNextLoad() || __system_argc < 1 || __system_argv[0] == NULL) return 0;
  snprintf(args, sizeof(args), "\\"%s\\"", __system_argv[0]);
  return R_SUCCEEDED(envSetNextLoad(__system_argv[0], args));
}
')
class NXInstaller
{
  static inline final MANIFEST:String = 'romfs:/nx/assets-manifest.tsv';

  /**
   * Files the game needs next to "assets/" on the SD card: lime reads its manifests from ROOT + "manifest/", and
   * the "art" library points at the code licence and changelog.
   */
  public static function prepare():Void
  {
    var started:Float = haxe.Timer.stamp();
    var root:String = nx.NXAssetRoot.ROOT;
    mkdirs(root + 'manifest');
    for (name in sys.FileSystem.readDirectory('romfs:/manifest'))
    {
      copyIfChanged('romfs:/manifest/' + name, root + 'manifest/' + name);
    }
    for (name in ['LICENSE.md', 'CHANGELOG.md'])
    {
      if (sys.FileSystem.exists('romfs:/' + name)) copyIfChanged('romfs:/' + name, root + name);
    }
    log('boot: manifests ready on the SD card in ${ms(started)}');
  }

  static var stage:Stage;
  static var onReady:Void->Void;
  static var screen:Sprite;
  static var title:TextField;
  static var body:TextField;
  static var footer:TextField;
  static var bar:Shape;
  static var percentText:TextField;
  static var note:TextField;
  static var mode:String = '';
  static var neededFiles:Int = 0;
  static var neededBytes:Float = 0;

  /**
   * Calls `ready` at once if the game files are complete; otherwise shows the installer first.
   */
  public static function run(stage:Stage, ready:Void->Void):Void
  {
    NXInstaller.stage = stage;
    onReady = ready;
    var assets:String = assetsDir();
    var started:Float = haxe.Timer.stamp();
    var loaded:Bool = untyped __cpp__('nxinst_load({0}.utf8_str()) != 0', MANIFEST);
    if (!loaded)
    {
      // No manifest in this build: nothing to check (should not happen in a build packaged by package_sd_build.py).
      log('boot: no $MANIFEST in this build, starting without checks');
      ready();
      return;
    }
    var version:String = untyped __cpp__('::String(nxinst_manifest.version)');
    var commit:String = untyped __cpp__('::String(nxinst_manifest.commit)');
    var total:Int = untyped __cpp__('(int)nxinst_manifest.count');
    var totalBytes:Float = untyped __cpp__('(double)nxinst_manifest.total_bytes');
    log('boot: manifest v$version ${commit.substr(0, 9)}, $total files, ${formatBytes(totalBytes)} (loaded in ${ms(started)})');
    started = haxe.Timer.stamp();
    if (untyped __cpp__('nxinst_state_ok({0}.utf8_str()) != 0', assets))
    {
      log('boot: install state matches this version (${ms(started)}), starting the game');
      ready();
      return;
    }
    neededFiles = untyped __cpp__('(int)nxi_quick_check(&nxinst_manifest, {0}.utf8_str(), &nxinst_check)', assets);
    neededBytes = untyped __cpp__('(double)nxinst_check.bytes_needed');
    var missing:Int = untyped __cpp__('(int)nxinst_check.missing');
    log('boot: quick check by sizes in ${ms(started)}: $neededFiles files to fetch ($missing missing, ${neededFiles - missing} with another size), ${formatBytes(neededBytes)}');
    if (neededFiles == 0)
    {
      // Everything is there (copied from a computer, or a previous install): remember it and start.
      untyped __cpp__('nxinst_write_state({0}.utf8_str())', assets);
      log('boot: all files present, install state written, starting the game');
      ready();
      return;
    }
    registerScreenFont();
    showScreen();
    showOffer();
    syncLabels();
    log('screen: font "${textFont()}", title "${title.text}" measured ${Math.round(title.textWidth)}x${Math.round(title.textHeight)}');
    #if NX_DEV_TOOLS
    // Test builds: installer_autostart=true in nx_devtools.cfg starts the download without input (Citron runs).
    var cfg:String = nx.NXAssetRoot.ROOT + 'nx_devtools.cfg';
    if (sys.FileSystem.exists(cfg) && ~/^installer_autostart\s*=\s*true\s*$/m.match(sys.io.File.getContent(cfg))) startDownload();
    #end
  }

  static function assetsDir():String
  {
    return nx.NXAssetRoot.ROOT + 'assets';
  }

  // ------------------------------------------------------------------ screen

  static function showScreen():Void
  {
    screen = new Sprite();
    screen.graphics.beginFill(0x000000);
    screen.graphics.drawRect(0, 0, 1280, 720);
    screen.graphics.endFill();
    title = makeText(60, 50, 1160, 34, 0xFFFFFF);
    body = makeText(60, 120, 1160, 21, 0xD8D8D8);
    footer = makeText(60, 640, 1160, 22, 0xFFFFFF);
    percentText = makeText(60, 500, 1160, 56, 0xFFFFFF);
    note = makeText(60, 120, 1160, 21, 0x9FD3FF);
    percentText.visible = false;
    note.visible = false;
    bar = new Shape();
    bar.x = 60;
    bar.y = 590;
    screen.addChild(bar);
    // OpenFL only draws a TextField on screen with lime's Cairo backend, which Switch builds don't have; like FlxText,
    // each text is drawn into a bitmap instead (see syncLabels).
    for (field in [title, body, footer, percentText, note])
    {
      var image:Bitmap = new Bitmap();
      labels.push({field: field, image: image, drawn: null});
      screen.addChild(image);
    }
    syncLabels();
    stage.addChild(screen);
    stage.addEventListener(Event.ENTER_FRAME, onFrame);
    stage.addEventListener(KeyboardEvent.KEY_DOWN, onKey);
    for (gamepad in Gamepad.devices)
      watchGamepad(gamepad);
    Gamepad.onConnect.add(watchGamepad);
  }

  static var labels:Array<{field:TextField, image:Bitmap, drawn:Null<String>}> = [];

  /**
   * Redraws the bitmap of every text whose content, position or visibility changed.
   */
  static function syncLabels():Void
  {
    for (label in labels)
    {
      var field:TextField = label.field;
      label.image.visible = field.visible && field.text.length > 0;
      label.image.x = field.x;
      label.image.y = field.y;
      if (!label.image.visible || label.drawn == field.text) continue;
      var height:Int = Std.int(Math.max(1, Math.min(field.textHeight + 8, field.height)));
      var bitmap:BitmapData = new BitmapData(Std.int(field.width), height, true, 0);
      bitmap.draw(field);
      if (label.image.bitmapData != null) label.image.bitmapData.dispose();
      label.image.bitmapData = bitmap;
      label.drawn = field.text;
    }
  }

  static inline final SCREEN_FONT:String = 'romfs:/assets/fonts/NotoSans-Regular.ttf';

  static var screenFont:Null<String> = null;

  /**
   * The installer's own font, OpenFL's Noto Sans (SIL OFL), read from the .nro's RomFS. lime registers the same font
   * with a path under the asset root (the SD card), where it doesn't exist; OpenFL skips a registered font that fails
   * to load and takes the next one with the same name, so this one is used, and the SD card gets no extra files.
   */
  static function registerScreenFont():Void
  {
    try
    {
      var font:Null<openfl.text.Font> = openfl.text.Font.fromFile(SCREEN_FONT);
      if (font != null && font.fontName != null)
      {
        openfl.text.Font.registerFont(font);
        screenFont = font.fontName;
      }
    }
    catch (e:Dynamic)
    {
      log('screen: could not load $SCREEN_FONT: $e');
    }
  }

  /**
   * Embedded fonts are looked up by their exact registered name ("_sans" would find nothing).
   */
  static function textFont():String
  {
    return screenFont ?? '_sans';
  }

  static function makeText(x:Float, y:Float, width:Float, size:Int, color:Int):TextField
  {
    var field:TextField = new TextField();
    field.embedFonts = true;
    field.defaultTextFormat = new TextFormat(textFont(), size, color);
    field.x = x;
    field.y = y;
    field.width = width;
    field.height = 520;
    field.multiline = true;
    field.wordWrap = true;
    field.selectable = false;
    return field;
  }

  static function watchGamepad(gamepad:Gamepad):Void
  {
    gamepad.onButtonDown.add(function(button:GamepadButton)
    {
      // SDL reports the Switch's right face button (A) as B, and the bottom one (B) as A.
      switch (button)
      {
        case GamepadButton.B: onConfirm();
        case GamepadButton.START: onExit();
        default:
      }
    });
  }

  static function onKey(event:KeyboardEvent):Void
  {
    if (event.keyCode == 13) onConfirm(); // Enter
    else if (event.keyCode == 27) onExit(); // Escape
  }

  static function showOffer():Void
  {
    mode = 'offer';
    var version:String = untyped __cpp__('::String(nxinst_manifest.version)');
    var commit:String = untyped __cpp__('::String(nxinst_manifest.commit)');
    var total:Int = untyped __cpp__('(int)nxinst_manifest.count');
    var resuming:Bool = neededFiles < total;
    title.text = resuming ? 'Resume download: ${formatBytes(neededBytes)} left ($neededFiles of $total files)' : 'Game files needed';
    body.text = 'This port doesn\'t include Friday Night Funkin\'s art, music, charts or videos. '
      + 'They can be downloaded now from The Funkin\' Crew\'s official GitHub repository (FunkinCrew/funkin.assets, files for v$version) '
      + 'to sdmc:/switch/Friday-Night-Funkin/assets/.\n\n'
      + 'Download: ${formatBytes(neededBytes)} ($neededFiles of $total files). Free space needed: about ${formatBytes(neededBytes * 1.1 + 50 * 1024 * 1024)}.\n\n'
      + 'These files are proprietary content of The Funkin\' Crew Inc., protected by copyright and trademark laws. '
      + 'Keep them for your own use; don\'t share them.\n\n'
      + 'Without internet on the console: on a computer, download github.com/FunkinCrew/funkin.assets/archive/$commit.zip, '
      + 'extract it and copy everything inside its folder to /switch/Friday-Night-Funkin/assets/ on the SD card '
      + '(so that assets/preload/ exists), then open the game again.';
    footer.text = '[A] Download     [+] Exit';
    drawBar(0);
  }

  static function onConfirm():Void
  {
    if (mode == 'offer' || mode == 'failed') startDownload();
    else if (mode == 'restart') onExit();
  }

  static function onExit():Void
  {
    if (mode == 'downloading')
    {
      untyped __cpp__('nxinst_progress.cancel = 1');
      footer.text = 'Stopping...';
      return;
    }
    lime.system.System.exit(0);
  }

  static var downloadStarted:Float = 0;
  static var lastLoggedPercent:Int = -1;
  static var lastLoggedWait:Int = 0;

  static function startDownload():Void
  {
    var online:Int = untyped __cpp__('nxinst_online()');
    if (online == 0)
    {
      log('download: not started, the console is not connected to the internet (nifm)');
      mode = 'failed';
      title.text = 'No internet connection';
      body.text = 'Connect the console to the internet (System Settings > Internet) and try again, '
        + 'or copy the files from a computer:\n\n'
        + 'download github.com/FunkinCrew/funkin.assets/archive/${untyped __cpp__('::String(nxinst_manifest.commit)')}.zip, '
        + 'extract it and copy everything inside its folder to /switch/Friday-Night-Funkin/assets/ on the SD card '
        + '(so that assets/preload/ exists), then open the game again.';
      footer.text = '[A] Try again     [+] Exit';
      return;
    }
    mode = 'downloading';
    downloadStarted = haxe.Timer.stamp();
    lastLoggedPercent = -1;
    log('download: start, ${formatBytes(neededBytes)} in $neededFiles files from raw.githubusercontent.com');
    title.text = 'Downloading game files';
    note.text = 'Downloading the official game files from The Funkin\' Crew\'s GitHub repository (FunkinCrew/funkin.assets). '
      + 'Nothing else on your console is changed: the files only go to /switch/Friday-Night-Funkin/assets/, and each one is checked '
      + 'against its official fingerprint (SHA-256) before it is kept.\n\n'
      + 'If the connection drops or the game is closed, the files already downloaded are kept and the download continues from there.';
    note.visible = true;
    percentText.visible = true;
    percentText.text = '0 %';
    body.y = 340;
    footer.text = 'Keep the console on and connected.     [+] Stop (continue later)';
    untyped __cpp__('memset((void *)&nxinst_progress, 0, sizeof(nxinst_progress))');
    var version:String = lime.app.Application.current.meta.get('version') ?? '?';
    untyped __cpp__('snprintf(nxinst_progress.user_agent, sizeof(nxinst_progress.user_agent), "FunkinNX-installer/%s", {0}.utf8_str())', version);
    var assets:String = assetsDir();
    sys.thread.Thread.create(function()
    {
      untyped __cpp__('hx::EnterGCFreeZone(); nxinst_download({0}.utf8_str()); hx::ExitGCFreeZone()', assets);
    });
  }

  static function onFrame(_:Event):Void
  {
    syncLabels();
    if (mode != 'downloading') return;
    var state:Int = untyped __cpp__('nxinst_progress.state');
    var done:Float = untyped __cpp__('(double)nxinst_progress.bytes_done');
    var total:Float = untyped __cpp__('(double)nxinst_progress.bytes_total');
    var filesDone:Int = untyped __cpp__('(int)nxinst_progress.files_done');
    var filesTotal:Int = untyped __cpp__('(int)nxinst_progress.files_total');
    var rate:Float = untyped __cpp__('nxinst_progress.bytes_per_second');
    var waiting:Int = untyped __cpp__('nxinst_progress.waiting_seconds');
    var current:String = untyped __cpp__('::String(nxinst_progress.current)');
    var line:String = '${formatBytes(done)} of ${formatBytes(total)}  ·  $filesDone of $filesTotal files';
    if (rate > 0) line += '  ·  ${formatBytes(rate)}/s';
    // Many small files come first, so neither bytes nor files alone give a fair estimate; average both fractions.
    var fraction:Float = total > 0 && filesTotal > 0 ? (done / total + filesDone / filesTotal) / 2 : 0;
    var elapsed:Float = haxe.Timer.stamp() - downloadStarted;
    if (fraction > 0.02 && fraction < 1) line += '  ·  about ${formatTime(elapsed * (1 - fraction) / fraction)} left';
    if (waiting > 0)
    {
      var status:Int = untyped __cpp__('(int)nxinst_progress.http_status');
      if (status == 429 || status == 403) line += '\n\nGitHub is limiting downloads from your network for a moment. Downloaded files are kept. Continuing in ${waiting} s...';
      else line += '\n\nConnection lost. Downloaded files are kept. Retrying in ${waiting} s...';
    }
    body.text = line + '\n\nNow: ' + current;
    percentText.text = '${total > 0 ? Std.int(done / total * 100) : 0} %';
    drawBar(total > 0 ? done / total : 0);
    var percent:Int = total > 0 ? Std.int(done / total * 100) : 0;
    if (percent >= lastLoggedPercent + 5)
    {
      lastLoggedPercent = percent - percent % 5;
      log('download: $percent% ${formatBytes(done)}, $filesDone/$filesTotal files, ${formatBytes(rate)}/s, ${Math.round(haxe.Timer.stamp() - downloadStarted)} s');
    }
    if (waiting > 0 && lastLoggedWait == 0)
    {
      var error:String = untyped __cpp__('::String(nxinst_progress.error)');
      log('download: waiting ${waiting}s before retrying ($current): $error');
    }
    lastLoggedWait = waiting;

    if (state == 2) finish();
    else if (state == 3) failed();
    else if (state == 4) onStopped();
  }

  static function finish():Void
  {
    untyped __cpp__('nxinst_write_state({0}.utf8_str())', assetsDir());
    drawBar(1);
    var rate:Float = untyped __cpp__('nxinst_progress.bytes_per_second');
    log('download: done in ${Math.round(haxe.Timer.stamp() - downloadStarted)} s (${formatBytes(rate)}/s average), install state written');
    if (untyped __cpp__('nxinst_relaunch() != 0'))
    {
      log('relaunch: hbloader will start the game again');
      mode = 'relaunch';
      title.text = 'Game files ready';
      body.text = 'Starting...';
      footer.text = '';
      lime.system.System.exit(0);
      return;
    }
    log('relaunch: not available (no hbloader next load), asking to reopen the game');
    mode = 'restart';
    note.visible = false;
    percentText.text = '100 %';
    body.y = 120;
    title.text = 'Game files ready';
    body.text = 'Close the game and open it again to play.';
    footer.text = '[A] / [+] Exit';
  }

  static function failed():Void
  {
    note.visible = false;
    percentText.visible = false;
    body.y = 120;
    mode = 'failed';
    var error:String = untyped __cpp__('::String(nxinst_progress.error)');
    var status:Int = untyped __cpp__('(int)nxinst_progress.http_status');
    log('download: FAILED after ${Math.round(haxe.Timer.stamp() - downloadStarted)} s, HTTP $status: $error');
    title.text = 'The download stopped';
    var hint:String = 'Check the internet connection and try again. Files already downloaded are kept.';
    if (status == 429 || status == 403) hint = 'GitHub is limiting downloads from your network right now. Try again later; files already downloaded are kept.';
    else if (error.indexOf('SSL') != -1 || error.indexOf('certificate') != -1)
      hint = 'Secure connection failed. Check that the console\'s date and time are correct (System Settings > System), then try again.';
    body.text = '$hint\n\n($error)\n\nYou can also copy the files from a computer (see the previous screen).';
    footer.text = '[A] Try again     [+] Exit';
  }

  static function onStopped():Void
  {
    note.visible = false;
    percentText.visible = false;
    body.y = 120;
    log('download: stopped by the player after ${Math.round(haxe.Timer.stamp() - downloadStarted)} s');
    mode = 'failed';
    title.text = 'Download stopped';
    body.text = 'Files already downloaded are kept; the next time it continues from there.';
    footer.text = '[A] Continue     [+] Exit';
  }

  static function drawBar(fraction:Float):Void
  {
    bar.graphics.clear();
    bar.graphics.beginFill(0x333333);
    bar.graphics.drawRect(0, 0, 1160, 18);
    bar.graphics.endFill();
    if (fraction > 0)
    {
      bar.graphics.beginFill(0x31A2FD);
      bar.graphics.drawRect(0, 0, 1160 * Math.min(1, fraction), 18);
      bar.graphics.endFill();
    }
  }

  // ------------------------------------------------------------------ helpers

  /**
   * Test builds (NX_DEV_TOOLS) write every installer step to logs/installer.log with its time; public builds write
   * nothing (the installer runs before the game's own log exists).
   */
  static function log(message:String):Void
  {
    #if NX_DEV_TOOLS
    try
    {
      var dir:String = nx.NXAssetRoot.ROOT + 'logs';
      if (!sys.FileSystem.exists(dir)) sys.FileSystem.createDirectory(dir);
      var out = sys.io.File.append(dir + '/installer.log', false);
      out.writeString('[${DateTools.format(Date.now(), '%Y-%m-%d %H:%M:%S')}] $message\n');
      out.close();
    }
    catch (e:Dynamic) {}
    #end
  }

  static function ms(since:Float):String
  {
    return '${Math.round((haxe.Timer.stamp() - since) * 1000)} ms';
  }

  static function formatBytes(bytes:Float):String
  {
    if (bytes >= 1024 * 1024 * 1024) return '${Math.round(bytes / (1024 * 1024 * 1024) * 100) / 100} GB';
    if (bytes >= 1024 * 1024) return '${Math.round(bytes / (1024 * 1024) * 10) / 10} MB';
    return '${Math.round(bytes / 1024)} KB';
  }

  static function formatTime(seconds:Float):String
  {
    if (seconds >= 60) return '${Math.ceil(seconds / 60)} min';
    return '${Math.ceil(seconds)} s';
  }

  static function mkdirs(dir:String):Void
  {
    if (!sys.FileSystem.exists(dir)) sys.FileSystem.createDirectory(dir);
  }

  static function copyIfChanged(from:String, to:String):Void
  {
    var bytes:haxe.io.Bytes = sys.io.File.getBytes(from);
    if (sys.FileSystem.exists(to))
    {
      var current:haxe.io.Bytes = sys.io.File.getBytes(to);
      if (current.length == bytes.length && current.compare(bytes) == 0) return;
    }
    sys.io.File.saveBytes(to, bytes);
  }
}
