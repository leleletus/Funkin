package funkin.ui.options;

#if switch

import flixel.FlxCamera;
import flixel.FlxObject;
import flixel.FlxSprite;
import flixel.text.FlxText;
import flixel.util.FlxColor;
import flixel.FlxG;
import flixel.group.FlxSpriteGroup.FlxTypedSpriteGroup;
import funkin.ui.AtlasText.AtlasFont;
import funkin.ui.Page;
import funkin.graphics.FunkinCamera;
import funkin.graphics.FunkinSprite;
import funkin.ui.TextMenuList.TextMenuItem;
import funkin.ui.options.items.CheckboxPreferenceItem;
import funkin.ui.options.items.EnumPreferenceItem;
import funkin.ui.options.items.NumberPreferenceItem;
import funkin.Preferences;
#if mobile
import funkin.mobile.ui.FunkinBackButton;
#end

/**
 * Dedicated Options Menu for Nintendo Switch hardware and performance settings.
 */
class SwitchSettingsMenu extends Page<OptionsState.OptionsMenuPageName>
{
  var items:TextMenuList;
  var preferenceItems:FlxTypedSpriteGroup<FlxSprite>;
  var preferenceDesc:Array<String> = [];
  var itemDesc:FlxText;
  var itemDescBox:FunkinSprite;

  var menuCamera:FlxCamera;
  var hudCamera:FlxCamera;
  var camFollow:FlxObject;

  public function new()
  {
    super();

    menuCamera = new FunkinCamera('switchSettingsMenu');
    FlxG.cameras.add(menuCamera, false);
    menuCamera.bgColor = 0x0;

    hudCamera = new FlxCamera();
    FlxG.cameras.add(hudCamera, false);
    hudCamera.bgColor = 0x0;

    camera = menuCamera;

    add(items = new TextMenuList());
    add(preferenceItems = new FlxTypedSpriteGroup<FlxSprite>());

    add(itemDescBox = new FunkinSprite());
    itemDescBox.cameras = [hudCamera];

    add(itemDesc = new FlxText(0, 0, 1180, null, 32));
    itemDesc.cameras = [hudCamera];

    createPrefItems();
    createPrefDescription();

    camFollow = new FlxObject(FlxG.width / 2, 0, 140, 70);

    menuCamera.follow(camFollow, null, 0.085);
    var margin = 160;
    menuCamera.deadzone.set(0, margin, menuCamera.width, menuCamera.height - margin * 2);
    menuCamera.minScrollY = 0;

    items.onChange.add(function(selected) {
      if (items.selectedIndex >= 0 && items.selectedIndex < preferenceDesc.length)
      {
        itemDesc.text = preferenceDesc[items.selectedIndex];
      }
    });

    #if FEATURE_TOUCH_CONTROLS
    var backButton:FunkinBackButton = new FunkinBackButton(FlxG.width - 230, FlxG.height - 200, exit, 1.0);
    add(backButton);
    #end
  }

  function createPrefDescription():Void
  {
    itemDescBox.makeSolidColor(1, 1, FlxColor.BLACK);
    itemDescBox.alpha = 0.6;
    itemDesc.setFormat(Paths.font('vcr.ttf'), 32, FlxColor.WHITE, FlxTextAlign.CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
    itemDesc.borderSize = 3;

    if (preferenceDesc.length > 0 && items.selectedIndex >= 0 && items.selectedIndex < preferenceDesc.length)
    {
      itemDesc.text = preferenceDesc[items.selectedIndex];
    }
    itemDesc.screenCenter();
    itemDesc.y += 270;

    itemDescBox.setPosition(itemDesc.x - 10, itemDesc.y - 10);
    itemDescBox.setGraphicSize(Std.int(itemDesc.width + 20), Std.int(itemDesc.height + 25));
    itemDescBox.updateHitbox();
  }

  function createPrefItems():Void
  {
    createPrefItemCheckbox('Antialiasing', 'When enabled, scaled and rotated sprites have smooth edges. Disabling it can improve performance slightly. Applies to what loads next.', function(value:Bool):Void {
      Preferences.switchAntialiasing = value;
    }, Preferences.switchAntialiasing);

    createPrefItemCheckbox('Stage Shaders', 'When enabled, stage shaders and visual effects such as rain are displayed.', function(value:Bool):Void {
      Preferences.switchEnableShaders = value;
    }, Preferences.switchEnableShaders);

    createPrefItemCheckbox('Show Loading Screen', 'When enabled, a loading screen is shown between songs. When disabled, songs load directly, like on PC.', function(value:Bool):Void {
      Preferences.switchShowLoadingScreen = value;
    }, Preferences.switchShowLoadingScreen);

    #if NX_DEV_TOOLS
    // Test builds only: public builds write no logs (INC-47).
    createPrefItemCheckbox('Verbose Audio Telemetry', 'When enabled, detailed OpenAL audio and drift telemetry is written to the SD card logs.', function(value:Bool):Void {
      Preferences.switchVerboseAudioLog = value;
    }, Preferences.switchVerboseAudioLog);
    #end
    // No "Resolution Mode": it had no effect (INC-39, the game draws at the screen resolution).

    createPrefItemCheckbox('Note Splashes', 'When enabled, particle effects appear when hitting Sick notes. Disabling them can improve performance.', function(value:Bool):Void {
      Preferences.switchNoteSplashes = value;
    }, Preferences.switchNoteSplashes);
  }

  override function update(elapsed:Float):Void
  {
    super.update(elapsed);

    if (items != null && items.selectedItem != null) camFollow.y = items.selectedItem.y;

    items.forEach(function(daItem:TextMenuItem) {
      var thyOffset:Int = 0;
      var thyTextWidth:Int = 0;
      switch (Type.typeof(daItem))
      {
        case TClass(CheckboxPreferenceItem):
          thyTextWidth = 0;
          thyOffset = 0;
        case TClass(EnumPreferenceItem):
          thyTextWidth = cast(daItem, EnumPreferenceItem<Dynamic>).lefthandText.getWidth();
          thyOffset = 0 + thyTextWidth - 75;
        case TClass(NumberPreferenceItem):
          thyTextWidth = cast(daItem, NumberPreferenceItem).lefthandText.getWidth();
          thyOffset = 0 + thyTextWidth - 75;
        default:
      }

      if (items.selectedItem == daItem)
      {
        thyOffset += 150;
      }
      else
      {
        thyOffset += 120;
      }

      daItem.x = thyOffset + funkin.ui.FullScreenScaleMode.gameNotchSize.x;
    });
  }

  function createPrefItemCheckbox(prefName:String, prefDesc:String, onChange:Bool->Void, defaultValue:Bool, available:Bool = true):Void
  {
    var checkbox:CheckboxPreferenceItem = new CheckboxPreferenceItem(funkin.ui.FullScreenScaleMode.gameNotchSize.x, 120 * (items.length - 1 + 1),
      defaultValue, available);

    items.createItem(0, (120 * items.length) + 30, prefName, AtlasFont.BOLD, function() {
      var value = !checkbox.currentValue;
      onChange(value);
      checkbox.currentValue = value;
    }, false, available);

    preferenceItems.add(checkbox);
    preferenceDesc.push(prefDesc);
  }

  function createPrefItemEnum<T>(prefName:String, prefDesc:String, values:Map<String, T>, onChange:String->T->Void, defaultKey:String):Void
  {
    var item = new EnumPreferenceItem<T>(funkin.ui.FullScreenScaleMode.gameNotchSize.x, (120 * items.length) + 30, prefName, values, defaultKey, onChange);
    items.addItem(prefName, item);
    preferenceItems.add(item.lefthandText);
    preferenceDesc.push(prefDesc);
  }

  override function exit():Void
  {
    camFollow.setPosition(640, 30);
    menuCamera.snapToTarget();
    super.exit();
  }
}
#end
