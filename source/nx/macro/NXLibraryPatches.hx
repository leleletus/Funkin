package nx.macro;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.ExprTools;

/**
 * Build-time patches applied to library classes on Switch, versioned in this repo instead of editing the
 * unpinned local library copies. Each patch matches the exact stock code and fails the build if it does not
 * find it exactly once, so a library update can never silently drop or misapply it.
 *
 * Registered from project.hxp (configureCustomMacros) with addMetadata('@:build(...)', '<library class>').
 */
class NXLibraryPatches
{
  /**
   * lime.graphics.Image: route the two decode calls through nx.NXImageDecode (single-copy decode, INC-49).
   * Disable with -Dnx_legacy_image_decode for A/B tests.
   */
  public static function singleCopyImageDecode():Array<Field>
  {
    if (!Context.defined('switch') || Context.defined('nx_legacy_image_decode')) return null;
    var fields:Array<Field> = Context.getBuildFields();
    var found:Map<String, Int> = ['__fromFile' => 0, '__fromBytes' => 0];
    for (field in fields)
    {
      if (!found.exists(field.name)) continue;
      switch (field.kind)
      {
        case FFun(f) if (f.expr != null):
          f.expr = rewriteDecodeCalls(f.expr, field.name, found);
        default:
      }
    }
    for (name => count in found)
    {
      if (count != 1)
      {
        Context.fatalError('NXLibraryPatches: expected exactly one stock NativeCFFI.lime_image_load_* call with an empty ImageBuffer in lime.graphics.Image.$name, found $count. Update the patch for this lime version.',
          Context.currentPos());
      }
    }
    return fields;
  }

  static function rewriteDecodeCalls(e:Expr, fieldName:String, found:Map<String, Int>):Expr
  {
    return switch (e.expr)
    {
      case ECall({expr: EField({expr: EConst(CIdent('NativeCFFI'))}, fn, _)}, [arg, buffer])
        if ((fn == 'lime_image_load_file' || fn == 'lime_image_load_bytes') && isStockEmptyBuffer(buffer)):
        found.set(fieldName, found.get(fieldName) + 1);
        var target:String = (fn == 'lime_image_load_file') ? 'loadFile' : 'loadBytes';
        var replacement:Expr = macro nx.NXImageDecode.$target($arg);
        replacement.pos = e.pos;
        replacement;
      default:
        ExprTools.map(e, (sub) -> rewriteDecodeCalls(sub, fieldName, found));
    };
  }

  /**
   * Matches `new ImageBuffer(new UInt8Array(Bytes.alloc(0)))`.
   */
  static function isStockEmptyBuffer(e:Expr):Bool
  {
    return switch (e.expr)
    {
      case ENew({name: 'ImageBuffer'}, [{expr: ENew({name: 'UInt8Array'}, [{expr: ECall({expr: EField({expr: EConst(CIdent('Bytes'))}, 'alloc', _)}, [{expr: EConst(CInt('0'))}])}])}]):
        true;
      default:
        false;
    };
  }
}
#end
