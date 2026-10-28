#!/usr/bin/env python3
"""
Draws all the artwork of the Switch port from the game's own sprites (the official logo, the title screen
Girlfriend and the Character Select portraits of Boyfriend, Pico and Nene), read from the assets submodule without
touching it. Background, stickers and badges are drawn here.

  python3 tools/nx-tools/branding/make_branding.py

Writes:
  branding/icon.jpg          256x256, the .nro icon (package_sd_build.py; elf2nro wants a JPEG), and icon.png
  branding/icon-rounded.png  512x512 with rounded corners, for previews
  branding/banner.png        1280x720, README banner
  store/icon.png             256x150, Homebrew App Store icon
  store/screen.png           848x208, Homebrew App Store banner

The store screenshots (store/screen1.png ... 1280x720) are real frames captured by the SCREENSHOTS autotest, see
docs/SWITCH_PORT_TRACKER.md, "Publicación en la Homebrew App Store". Fonts: Noto Sans Black (SIL Open Font Licence),
looked up in the usual system font folders.
"""
import math
import os
import re
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..', '..'))
IMAGES = os.path.join(ROOT, 'assets', 'preload', 'images')
STORE = os.path.join(ROOT, 'tools', 'nx-tools', 'store')
FONT_CANDIDATES = [
    '/usr/share/fonts/noto/NotoSans-Black.ttf',
    '/usr/share/fonts/truetype/noto/NotoSans-Black.ttf',
    '/usr/share/fonts/google-noto/NotoSans-Black.ttf',
]

INK = (0x16, 0x0A, 0x2A)
BG_TOP = (0x3A, 0x12, 0x6E)
BG_BOTTOM = (0x0C, 0x04, 0x1C)
SPOT = (0xA0, 0x5C, 0xFF)
ACCENT = (0xFF, 0x3B, 0x6B)


def font(size):
    for path in FONT_CANDIDATES:
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    sys.exit('[make_branding] Noto Sans Black not found (install the Noto fonts)')


# ------------------------------------------------------------------ helpers

def gradient(w, h, top, bottom):
    img = Image.new('RGB', (w, h))
    d = ImageDraw.Draw(img)
    for y in range(h):
        t = y / max(1, h - 1)
        d.line([(0, y), (w, y)], fill=tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return img


def dilate(mask, px):
    return mask.filter(ImageFilter.MaxFilter(px * 2 + 1)) if px > 0 else mask


def erode(mask, px):
    return mask.filter(ImageFilter.MinFilter(px * 2 + 1)) if px > 0 else mask


def paste_color(dest, color, mask, alpha=255):
    layer = Image.new('RGBA', dest.size, color + (alpha,))
    dest.paste(layer, (0, 0), mask if alpha == 255 else ImageChops.multiply(mask, Image.new('L', dest.size, alpha)))


def shadow(dest, mask, offset, blur, alpha):
    shifted = Image.new('L', dest.size, 0)
    shifted.paste(mask, offset)
    shifted = shifted.filter(ImageFilter.GaussianBlur(blur)).point(lambda v: v * alpha // 255)
    dest.paste(Image.new('RGBA', dest.size, (0, 0, 0, 255)), (0, 0), shifted)


# ------------------------------------------------------------------ background

def stage_background(w, h, spot_center, spot_radius):
    img = gradient(w, h, BG_TOP, BG_BOTTOM).convert('RGBA')
    glow = Image.new('L', (w, h), 0)
    ImageDraw.Draw(glow).ellipse([spot_center[0] - spot_radius, spot_center[1] - spot_radius,
                                  spot_center[0] + spot_radius, spot_center[1] + spot_radius], fill=170)
    glow = glow.filter(ImageFilter.GaussianBlur(spot_radius * 0.45))
    img.paste(Image.new('RGBA', (w, h), SPOT + (255,)), (0, 0), glow)
    overlay = Image.new('RGBA', (w, h), (0, 0, 0, 0))  # translucent details, composited at the end
    lines = ImageDraw.Draw(overlay)
    horizon = int(h * 0.80)
    for i in range(-14, 15):
        lines.line([(w / 2 + i * w / 44, horizon), (w / 2 + i * w / 9, h)], fill=(255, 255, 255, 20), width=max(1, w // 420))
    for k in range(1, 7):
        y = horizon + (h - horizon) * (k / 7) ** 1.6
        lines.line([(0, y), (w, y)], fill=(255, 255, 255, 16), width=max(1, w // 520))
    for i in range(70):  # dust in the spotlight
        rx = (math.sin(i * 12.9898) * 43758.5453) % 1
        ry = (math.sin(i * 78.233) * 12345.678) % 1
        x, y = w * (0.15 + 0.7 * rx), h * (0.05 + 0.65 * ry)
        r = max(1, w // 700) * (1 + i % 3)
        lines.ellipse([x - r, y - r, x + r, y + r], fill=(255, 235, 255, 30 + (i * 7) % 50))
    img.alpha_composite(overlay)
    return img


# ------------------------------------------------------------------ composition

def place(dest, img, cx, cy):
    dest.alpha_composite(img, (int(cx - img.width / 2), int(cy - img.height / 2)))


def badge(dest, text, cx, cy, height):
    f = font(int(height * 0.62))
    d = ImageDraw.Draw(dest)
    w = d.textlength(text, font=f) + height * 0.9
    box = [cx - w / 2, cy - height / 2, cx + w / 2, cy + height / 2]
    d.rounded_rectangle(box, radius=height / 2, fill=ACCENT, outline=INK, width=max(2, int(height * 0.09)))
    d.text((cx, cy + height * 0.02), text, font=f, fill=(255, 255, 255), anchor='mm')


# ------------------------------------------------------------------ game sprites

def sparrow_frame(name, prefix):
    """First frame of an animation in a Sparrow atlas (png + xml), trimmed to its pixels."""
    xml = open(os.path.join(IMAGES, name + '.xml'), encoding='utf-8').read()
    for tag in re.findall(r'<SubTexture[^>]*/>', xml):
        a = dict(re.findall(r'(\w+)="([^"]*)"', tag))
        if a['name'].startswith(prefix):
            x, y, w, h = (int(a[k]) for k in ('x', 'y', 'width', 'height'))
            frame = Image.open(os.path.join(IMAGES, name + '.png')).convert('RGBA').crop((x, y, x + w, y + h))
            return frame.rotate(90, expand=True) if a.get('rotated') == 'true' else frame
    raise SystemExit(f'[make_branding] no "{prefix}" frame in {name}.xml (is the assets submodule checked out?)')


def sprite(path):
    img = Image.open(os.path.join(IMAGES, path)).convert('RGBA')
    return img.crop(img.getbbox())


def scaled(img, height):
    return img.resize((round(img.width * height / img.height), round(height)), Image.LANCZOS)


def sticker(img, rim):
    """White sticker rim and a soft drop shadow around a sprite, so it pops off the background."""
    pad = rim * 4
    canvas = Image.new('RGBA', (img.width + pad * 2, img.height + pad * 2), (0, 0, 0, 0))
    alpha = Image.new('L', canvas.size, 0)
    alpha.paste(img.getchannel('A'), (pad, pad))
    outline = dilate(alpha.point(lambda v: 255 if v > 40 else 0), rim)
    shadow(canvas, outline, (rim, rim * 2), rim * 1.5, 160)
    canvas.paste(Image.new('RGBA', canvas.size, (255, 255, 255, 255)), (0, 0), outline)
    canvas.alpha_composite(img, (pad, pad))
    return canvas


def stand(dest, img, cx, bottom):
    """Places a sticker so the sprite inside sits on `bottom`."""
    dest.alpha_composite(img, (int(cx - img.width / 2), int(bottom - img.height)))


def halftone(img, color, step, max_r, left_to_right=True):
    """Comic dots that grow towards one side, drawn over the background."""
    d = ImageDraw.Draw(img)
    for gy in range(0, img.height + step, step):
        for gx in range(0, img.width + step, step):
            t = gx / img.width if left_to_right else 1 - gx / img.width
            r = max_r * max(0.0, t - 0.25) / 0.75
            if r >= 1:
                ox = step / 2 if (gy // step) % 2 else 0
                d.ellipse([gx + ox - r, gy - r, gx + ox + r, gy + r], fill=color)


# ------------------------------------------------------------------ outputs

def logo(height, rim):
    return sticker(scaled(sparrow_frame('logoBumpin', 'logo bumpin'), height), rim)


def make_icon():
    """The .nro icon: the logo with Boyfriend sitting on his speaker."""
    S = 1024
    img = stage_background(S, S, (S * 0.45, S * 0.40), S * 0.75)
    halftone(img, (0xFF, 0x3B, 0x6B, 60), 30, 10)
    stand(img, sticker(scaled(sprite('charSelect/bfChill.png'), S * 0.62), 10), S * 0.73, S * 1.03)
    place(img, logo(S * 0.60, 10), S * 0.40, S * 0.34)
    badge(img, 'SWITCH', S * 0.22, S * 0.87, S * 0.11)

    rgb = img.convert('RGB')
    rgb.resize((256, 256), Image.LANCZOS).save(os.path.join(HERE, 'icon.png'))
    rgb.resize((256, 256), Image.LANCZOS).save(os.path.join(HERE, 'icon.jpg'), quality=95)
    mask = Image.new('L', (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, S - 1, S - 1], radius=S * 0.12, fill=255)
    rounded = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    rounded.paste(rgb, (0, 0), mask)
    rounded.resize((512, 512), Image.LANCZOS).save(os.path.join(HERE, 'icon-rounded.png'))


def cast(img, W, H, height, left, right, bottom):
    """Nene, Pico, Boyfriend and Girlfriend in a row between `left` and `right` (back to front)."""
    span = right - left
    for sprite_, h, x, b in [
        (sprite('charSelect/neneChill.png'), height * 0.70, left + span * 0.88, bottom - H * 0.01),
        (sprite('charSelect/picoChill.png'), height * 0.84, left + span * 0.66, bottom),
        (sprite('charSelect/bfChill.png'), height * 0.86, left + span * 0.10, bottom),
        (sparrow_frame('gfDanceTitle', 'gfDance'), height, left + span * 0.38, bottom + H * 0.02),
    ]:
        stand(img, sticker(scaled(sprite_, h), max(4, int(H * 0.015))), x, b)


def make_banner():
    """README banner: the logo and the port badge on top, the cast along the bottom."""
    W, H = 2560, 1440
    img = stage_background(W, H, (W * 0.5, H * 0.30), H * 0.9)
    halftone(img, (0xFF, 0x3B, 0x6B, 55), 48, 15)
    cast(img, W, H, H * 0.50, W * 0.10, W * 0.90, H * 1.02)
    place(img, logo(H * 0.42, 14), W * 0.5, H * 0.24)
    badge(img, 'UNOFFICIAL NINTENDO SWITCH PORT', W * 0.5, H * 0.495, H * 0.07)
    img.convert('RGB').resize((1280, 720), Image.LANCZOS).save(os.path.join(HERE, 'banner.png'))


def make_store_icon():
    """256x150 store tile: the logo with Boyfriend."""
    W, H = 1024, 600
    img = stage_background(W, H, (W * 0.35, H * 0.45), H * 0.8)
    halftone(img, (0xFF, 0x3B, 0x6B, 60), 28, 9)
    stand(img, sticker(scaled(sprite('charSelect/bfChill.png'), H * 0.88), 9), W * 0.80, H * 1.04)
    place(img, logo(H * 0.80, 8), W * 0.38, H * 0.45)
    img.convert('RGB').resize((256, 150), Image.LANCZOS).save(os.path.join(STORE, 'icon.png'))


def make_store_banner():
    """848x208 store banner: the logo and the port badge, then the cast."""
    W, H = 2544, 624
    img = stage_background(W, H, (W * 0.62, H * 0.40), H * 1.3)
    halftone(img, (0xFF, 0x3B, 0x6B, 55), 34, 11)
    cast(img, W, H, H * 0.95, W * 0.39, W * 0.96, H * 1.03)
    place(img, logo(H * 0.86, 9), W * 0.175, H * 0.43)
    badge(img, 'NINTENDO SWITCH PORT', W * 0.175, H * 0.90, H * 0.12)
    img.convert('RGB').resize((848, 208), Image.LANCZOS).save(os.path.join(STORE, 'screen.png'))


if __name__ == '__main__':
    make_icon()
    make_banner()
    make_store_icon()
    make_store_banner()
    print('[make_branding] branding/icon.jpg, icon.png, icon-rounded.png, banner.png, store/icon.png and store/screen.png written')
