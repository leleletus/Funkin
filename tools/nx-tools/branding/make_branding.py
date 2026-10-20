#!/usr/bin/env python3
"""
Draws the artwork of the Switch port from scratch (no FunkinCrew art): the .nro / store icon and the store banner.

  python3 tools/nx-tools/branding/make_branding.py

Writes, next to this script:
  icon.png          256x256, store listing icon
  icon.jpg          256x256, .nro icon (elf2nro wants a JPEG)
  icon-rounded.png  512x512 with rounded corners, for the README and previews
  banner.png        1280x720, store banner

Everything is drawn at a large size with masks (rounded shapes, gradients, bevels, gloss and shadows) and then
downscaled. The only external input is the Noto Sans Black font (SIL Open Font License), looked up in the usual
system font folders.
"""
import math
import os
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
FONT_CANDIDATES = [
    '/usr/share/fonts/noto/NotoSans-Black.ttf',
    '/usr/share/fonts/truetype/noto/NotoSans-Black.ttf',
    '/usr/share/fonts/google-noto/NotoSans-Black.ttf',
]

# Lane colours (left, down, up, right): base and light tone of each note.
LANES = [
    ((0xB8, 0x3A, 0xA0), (0xF2, 0x8C, 0xE0)),
    ((0x00, 0xA8, 0xE8), (0x8C, 0xF4, 0xFF)),
    ((0x14, 0xC8, 0x3C), (0x9C, 0xFF, 0x8C)),
    ((0xE8, 0x24, 0x40), (0xFF, 0x9C, 0x9C)),
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


def soften(mask, radius):
    """Rounds the corners of a hard mask: blur, then threshold back to a crisp edge."""
    return mask.filter(ImageFilter.GaussianBlur(radius)).point(lambda v: 255 if v > 127 else 0)


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


# ------------------------------------------------------------------ note arrow

def arrow_mask(size):
    """Up-pointing note arrow on a size x size canvas, with rounded corners."""
    m = Image.new('L', (size, size), 0)
    s = size
    shape = [(0.50, 0.08), (0.92, 0.50), (0.69, 0.50), (0.69, 0.90), (0.31, 0.90), (0.31, 0.50), (0.08, 0.50)]
    ImageDraw.Draw(m).polygon([(x * s, y * s) for x, y in shape], fill=255)
    return soften(m, s * 0.035)


def note_arrow(size, base, light, angle):
    """A glossy note arrow (RGBA, size x size) pointing up, rotated clockwise by `angle` degrees."""
    pad = int(size * 0.22)
    canvas = size + pad * 2
    body = Image.new('L', (canvas, canvas), 0)
    body.paste(arrow_mask(size), (pad, pad))
    body = body.rotate(-angle, resample=Image.BICUBIC, center=(canvas / 2, canvas / 2)).point(lambda v: 255 if v > 127 else 0)

    out = Image.new('RGBA', (canvas, canvas), (0, 0, 0, 0))
    outline = dilate(body, int(size * 0.055))
    shadow(out, outline, (int(size * 0.035), int(size * 0.07)), size * 0.05, 150)
    paste_color(out, INK, outline)
    rim = dilate(body, int(size * 0.018))
    paste_color(out, (255, 255, 255), rim, 235)

    fill = gradient(canvas, canvas, light, base).convert('RGBA')
    out.paste(fill, (0, 0), body)

    inner = erode(body, int(size * 0.09))
    bevel = ImageChops.subtract(body, inner).filter(ImageFilter.GaussianBlur(size * 0.02))
    dark = tuple(int(c * 0.55) for c in base)
    paste_color(out, dark, ImageChops.multiply(bevel, Image.new('L', (canvas, canvas), 150)))
    core = gradient(canvas, canvas, light, base).convert('RGBA')
    out.paste(core, (0, 0), inner.filter(ImageFilter.GaussianBlur(size * 0.015)))

    gloss = Image.new('L', (canvas, canvas), 0)
    ImageDraw.Draw(gloss).ellipse([canvas * 0.18, canvas * 0.10, canvas * 0.70, canvas * 0.48], fill=140)
    gloss = ImageChops.multiply(gloss.filter(ImageFilter.GaussianBlur(size * 0.05)), erode(body, int(size * 0.05)))
    paste_color(out, (255, 255, 255), gloss)
    return out


# ------------------------------------------------------------------ title text

def styled_text(text, size, fill_top, fill_bottom, outline_px, skew=0.18, tracking=0.02):
    """Bold italic text with a gradient fill, a thick dark outline, a light rim and a drop shadow."""
    f = font(size)
    tmp = ImageDraw.Draw(Image.new('L', (1, 1)))
    widths = [tmp.textlength(ch, font=f) for ch in text]
    w = int(sum(widths) + tracking * size * (len(text) - 1) + size * 1.2)
    h = int(size * 1.6)
    mask = Image.new('L', (w, h), 0)
    d = ImageDraw.Draw(mask)
    x = size * 0.6
    for ch, cw in zip(text, widths):
        d.text((x, h / 2), ch, font=f, fill=255, anchor='lm')
        x += cw + tracking * size
    mask = mask.transform((w, h), Image.AFFINE, (1, skew, -skew * h / 2, 0, 1, 0), resample=Image.BICUBIC)

    out = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    outline = dilate(mask, outline_px)
    shadow(out, outline, (int(outline_px * 0.6), int(outline_px * 1.1)), outline_px * 0.8, 170)
    paste_color(out, INK, outline)
    paste_color(out, (255, 255, 255), dilate(mask, max(1, outline_px // 4)), 200)
    out.paste(gradient(w, h, fill_top, fill_bottom).convert('RGBA'), (0, 0), mask)
    shine = Image.new('L', (w, h), 0)
    ImageDraw.Draw(shine).rectangle([0, 0, w, h * 0.45], fill=90)
    paste_color(out, (255, 255, 255), ImageChops.multiply(shine.filter(ImageFilter.GaussianBlur(size * 0.04)), erode(mask, max(1, outline_px // 3))))
    bbox = out.getbbox()
    return out.crop(bbox) if bbox else out


def place(dest, img, cx, cy):
    dest.alpha_composite(img, (int(cx - img.width / 2), int(cy - img.height / 2)))


def badge(dest, text, cx, cy, height):
    f = font(int(height * 0.62))
    d = ImageDraw.Draw(dest)
    w = d.textlength(text, font=f) + height * 0.9
    box = [cx - w / 2, cy - height / 2, cx + w / 2, cy + height / 2]
    d.rounded_rectangle(box, radius=height / 2, fill=ACCENT, outline=INK, width=max(2, int(height * 0.09)))
    d.text((cx, cy + height * 0.02), text, font=f, fill=(255, 255, 255), anchor='mm')


# ------------------------------------------------------------------ outputs

def make_icon():
    S = 1024
    img = stage_background(S, S, (S / 2, S * 0.36), S * 0.62)
    title = styled_text('FNF', int(S * 0.36), (0xFF, 0xFF, 0xFF), (0xC8, 0xB4, 0xFF), int(S * 0.028))
    place(img, title, S / 2, S * 0.34)
    arrow = int(S * 0.215)
    for i, (angle, (base, light)) in enumerate(zip([270, 180, 0, 90], LANES)):
        place(img, note_arrow(arrow, base, light, angle), S / 2 + (i - 1.5) * arrow * 1.06, S * 0.665)
    sub = styled_text('V-SLICE', int(S * 0.095), (0xFF, 0xFF, 0xFF), (0xE6, 0xDC, 0xFF), int(S * 0.012), skew=0.12, tracking=0.06)
    place(img, sub, S * 0.43, S * 0.885)
    badge(img, 'NX', S * 0.80, S * 0.885, S * 0.105)

    rgb = img.convert('RGB')
    rgb.resize((256, 256), Image.LANCZOS).save(os.path.join(HERE, 'icon.png'))
    rgb.resize((256, 256), Image.LANCZOS).save(os.path.join(HERE, 'icon.jpg'), quality=95)
    mask = Image.new('L', (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, S - 1, S - 1], radius=S * 0.12, fill=255)
    rounded = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    rounded.paste(rgb, (0, 0), mask)
    rounded.resize((512, 512), Image.LANCZOS).save(os.path.join(HERE, 'icon-rounded.png'))


def make_banner():
    W, H = 2560, 1440
    img = stage_background(W, H, (W * 0.5, H * 0.32), H * 0.80)
    arrow = int(H * 0.21)
    for i, (angle, (base, light)) in enumerate(zip([270, 180, 0, 90], LANES)):
        place(img, note_arrow(arrow, base, light, angle), W / 2 + (i - 1.5) * arrow * 1.12, H * 0.25)
    title = styled_text("FRIDAY NIGHT FUNKIN'", int(H * 0.125), (0xFF, 0xFF, 0xFF), (0xC8, 0xB4, 0xFF), int(H * 0.012), skew=0.16,
                        tracking=0.01)
    place(img, title, W / 2, H * 0.55)
    sub = styled_text('V-SLICE  ·  UNOFFICIAL NINTENDO SWITCH PORT', int(H * 0.05), (0xE6, 0xDC, 0xFF), (0xC8, 0xB4, 0xFF),
                      int(H * 0.006), skew=0.1, tracking=0.03)
    place(img, sub, W / 2, H * 0.69)
    line = styled_text("Official game files downloaded from The Funkin' Crew on first launch", int(H * 0.034), (0xD8, 0xD0, 0xF0),
                       (0xC0, 0xB6, 0xE0), int(H * 0.004), skew=0.0, tracking=0.0)
    place(img, line, W / 2, H * 0.79)
    img.convert('RGB').resize((1280, 720), Image.LANCZOS).save(os.path.join(HERE, 'banner.png'))


if __name__ == '__main__':
    make_icon()
    make_banner()
    print(f'[make_branding] icon.png, icon.jpg, icon-rounded.png and banner.png written to {os.path.relpath(HERE)}')
