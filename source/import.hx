// Global imports of the Switch port only; other platforms compile exactly as upstream.
#if (switch && !macro)
import cpp.*;

// Nintendo Switch imports
#if switch
import switchLib.Result;
import switchLib.Types.ResultType;
import switchLib.runtime.Pad;
import switchLib.services.Hid;
import switchLib.arm.Counter;
import switchLib.services.Applet;
import nx.NXMain;
import nx.NXGame;
import nx.NXSimpleWeb;
import nx.controls.NXController;
import nx.controls.NXControlButton;
import nx.controls.NXVibrationHD;
#end

// Flixel
import flixel.FlxG;
import flixel.FlxSprite;
import flixel.math.FlxMath;
import flixel.util.FlxColor;
import flixel.util.FlxTimer;
import flixel.text.FlxText;
import flixel.tweens.FlxEase;
import flixel.tweens.FlxTween;
import flixel.group.FlxSpriteGroup;
import flixel.group.FlxGroup.FlxTypedGroup;

#if sys
import sys.*;
import sys.io.*;
#end

using StringTools;
#end
