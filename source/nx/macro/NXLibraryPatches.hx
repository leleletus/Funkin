package nx.macro;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.ExprTools;
import haxe.macro.Type;

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
    // Marker checked by requirePatched(): proves the patch really ran in this compilation.
    Context.getLocalClass().get().meta.add(':nxPatched', [], Context.currentPos());
    return fields;
  }

  /**
   * The only native upload in openfl.display3D.textures.TextureBase.__uploadFromImage (TextureBase.hx:428). The html5
   * branches around it are already removed by the parser when build macros run.
   */
  static final STOCK_IMAGE_UPLOAD_ARGS:Array<String> = [
    'gl.TEXTURE_2D', '0', 'internalFormat', 'image.buffer.width', 'image.buffer.height', '0', 'format', 'gl.UNSIGNED_BYTE', 'image.data'
  ];

  /**
   * openfl.display3D.textures.TextureBase: route the single full-image glTexImage2D of __uploadFromImage through
   * nx.NXTextureUpload (row-band uploads, INC-49). Disable with -Dnx_legacy_texture_upload for A/B tests.
   */
  public static function bandedTextureUpload():Array<Field>
  {
    if (!Context.defined('switch') || Context.defined('nx_legacy_texture_upload')) return null;
    var fields:Array<Field> = Context.getBuildFields();
    var count:Array<Int> = [0];
    for (field in fields)
    {
      if (field.name != '__uploadFromImage') continue;
      switch (field.kind)
      {
        case FFun(f) if (f.expr != null):
          f.expr = rewriteImageUpload(f.expr, count);
        default:
      }
    }
    if (count[0] != 1)
    {
      Context.fatalError('NXLibraryPatches: expected exactly one stock gl.texImage2D(${STOCK_IMAGE_UPLOAD_ARGS.join(", ")}) in openfl.display3D.textures.TextureBase.__uploadFromImage, found ${count[0]}. Update the patch for this OpenFL version.',
        Context.currentPos());
    }
    Context.getLocalClass().get().meta.add(':nxBanded', [], Context.currentPos());
    return fields;
  }

  /**
   * openfl.display3D.textures.TextureBase: drop the GL_TEXTURE_LOD_BIAS call from __setSamplerState. The Switch context
   * is OpenGL ES, where that texture parameter does not exist: every sampler state change raised GL_INVALID_ENUM (the
   * 0x500 seen every frame), which also hid real GL errors from the upload checks. OpenFL never sets a bias other than
   * 0, so nothing changes on screen. Disable with -Dnx_stock_lod_bias for A/B tests.
   */
  public static function glesSamplerState():Array<Field>
  {
    if (!Context.defined('switch') || Context.defined('nx_stock_lod_bias')) return null;
    var fields:Array<Field> = Context.getBuildFields();
    var count:Array<Int> = [0];
    for (field in fields)
    {
      if (field.name != '__setSamplerState') continue;
      switch (field.kind)
      {
        case FFun(f) if (f.expr != null):
          f.expr = removeLodBias(f.expr, count);
        default:
      }
    }
    if (count[0] != 1)
    {
      Context.fatalError('NXLibraryPatches: expected exactly one stock gl.texParameterf(__textureTarget, 34049, state.lodBias) in openfl.display3D.textures.TextureBase.__setSamplerState, found ${count[0]}. Update the patch for this OpenFL version.',
        Context.currentPos());
    }
    Context.getLocalClass().get().meta.add(':nxNoLodBias', [], Context.currentPos());
    return fields;
  }

  static function removeLodBias(e:Expr, count:Array<Int>):Expr
  {
    return switch (e.expr)
    {
      case ECall({expr: EField({expr: EConst(CIdent('gl'))}, 'texParameterf', _)}, args)
        if (args.length == 3 && ExprTools.toString(args[0]) == '__textureTarget' && ExprTools.toString(args[1]) == '34049'
          && ExprTools.toString(args[2]) == 'state.lodBias'):
        count[0]++;
        var replacement:Expr = macro {};
        replacement.pos = e.pos;
        replacement;
      default:
        ExprTools.map(e, (sub) -> removeLodBias(sub, count));
    };
  }

  static function rewriteImageUpload(e:Expr, count:Array<Int>):Expr
  {
    return switch (e.expr)
    {
      case ECall({expr: EField({expr: EConst(CIdent('gl'))}, 'texImage2D', _)}, args) if (isStockImageUpload(args)):
        count[0]++;
        var replacement:Expr = macro nx.NXTextureUpload.upload(this, gl, internalFormat, format, image);
        replacement.pos = e.pos;
        replacement;
      default:
        ExprTools.map(e, (sub) -> rewriteImageUpload(sub, count));
    };
  }

  static function isStockImageUpload(args:Array<Expr>):Bool
  {
    if (args.length != STOCK_IMAGE_UPLOAD_ARGS.length) return false;
    for (i in 0...args.length)
    {
      if (ExprTools.toString(args[i]) != STOCK_IMAGE_UPLOAD_ARGS[i]) return false;
    }
    return true;
  }

  /**
   * Build guard registered from nx.NXMain (always compiled on Switch): fails the build if lime.graphics.Image or
   * openfl.display3D.textures.TextureBase was typed without its patch (class renamed or moved by a library update, or
   * typed before the metadata from project.hxp was registered), so no stock path can come back silently. Each
   * check is skipped only by its own flag (-Dnx_legacy_image_decode, -Dnx_legacy_texture_upload, -Dnx_stock_lod_bias).
   */
  public static function requirePatched():Array<Field>
  {
    if (!Context.defined('switch') || Context.defined('display')) return null;
    var checkDecode:Bool = !Context.defined('nx_legacy_image_decode');
    var checkUpload:Bool = !Context.defined('nx_legacy_texture_upload');
    var checkLodBias:Bool = !Context.defined('nx_stock_lod_bias');
    if (!checkDecode && !checkUpload && !checkLodBias) return null;
    // onGenerate runs once with every type that will be generated (onAfterTyping can be called again with only the
    // types added by other macros, which does not include lime.graphics.Image).
    Context.onGenerate(function(types) {
      var found:Bool = false;
      var patched:Bool = false;
      var textureFound:Bool = false;
      var texturePatched:Bool = false;
      var lodBiasPatched:Bool = false;
      for (type in types)
      {
        switch (type)
        {
          case TInst(ref, _):
            var cls = ref.get();
            var path:String = cls.pack.join('.') + '.' + cls.name;
            if (path == 'lime.graphics.Image')
            {
              found = true;
              patched = cls.meta.has(':nxPatched');
            }
            else if (path == 'openfl.display3D.textures.TextureBase')
            {
              textureFound = true;
              texturePatched = cls.meta.has(':nxBanded');
              lodBiasPatched = cls.meta.has(':nxNoLodBias');
            }
          default:
        }
      }
      if (checkDecode && (!found || !patched))
      {
        Context.fatalError('NXLibraryPatches: lime.graphics.Image was ${found ? "typed without the single-copy decode patch" : "not found"}. Check configureCustomMacros in project.hxp.',
          Context.currentPos());
      }
      if (checkUpload && (!textureFound || !texturePatched))
      {
        Context.fatalError('NXLibraryPatches: openfl.display3D.textures.TextureBase was ${textureFound ? "typed without the banded upload patch" : "not found"}. Check configureCustomMacros in project.hxp.',
          Context.currentPos());
      }
      if (checkLodBias && (!textureFound || !lodBiasPatched))
      {
        Context.fatalError('NXLibraryPatches: openfl.display3D.textures.TextureBase was ${textureFound ? "typed without the GLES sampler state patch" : "not found"}. Check configureCustomMacros in project.hxp.',
          Context.currentPos());
      }
    });
    return null;
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
