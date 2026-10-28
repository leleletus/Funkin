#!/usr/bin/env python3
"""
Draws the Homebrew App Store art from the game's own sprites (the official logo, the title screen Girlfriend and the
Character Select portraits of Boyfriend, Pico and Nene), read from the assets submodule without touching it.

  python3 tools/nx-tools/branding/make_store_art.py

Writes into tools/nx-tools/store/:
  icon.png    256x150, the store tile
  screen.png  848x208, the store banner

The store screenshots (screen1.png ... 1280x720) are real frames captured by the SCREENSHOTS autotest, see
docs/SWITCH_PORT_TRACKER.md, "Publicación en la Homebrew App Store".
"""
import os
import re

from PIL import Image, ImageDraw

from make_branding import badge, dilate, place, shadow, stage_background

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..', '..'))
IMAGES = os.path.join(ROOT, 'assets', 'preload', 'images')
STORE = os.path.join(ROOT, 'tools', 'nx-tools', 'store')


def sparrow_frame(name, prefix):
    """First frame of an animation in a Sparrow atlas (png + xml), trimmed to its pixels."""
    xml = open(os.path.join(IMAGES, name + '.xml'), encoding='utf-8').read()
    for tag in re.findall(r'<SubTexture[^>]*/>', xml):
        a = dict(re.findall(r'(\w+)="([^"]*)"', tag))
        if a['name'].startswith(prefix):
            x, y, w, h = (int(a[k]) for k in ('x', 'y', 'width', 'height'))
            frame = Image.open(os.path.join(IMAGES, name + '.png')).convert('RGBA').crop((x, y, x + w, y + h))
            return frame.rotate(90, expand=True) if a.get('rotated') == 'true' else frame
    raise SystemExit(f'[make_store_art] no "{prefix}" frame in {name}.xml (is the assets submodule checked out?)')


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


def make_icon():
    W, H = 1024, 600
    img = stage_background(W, H, (W * 0.35, H * 0.45), H * 0.8)
    halftone(img, (0xFF, 0x3B, 0x6B, 60), 28, 9)
    bf = sticker(scaled(sprite('charSelect/bfChill.png'), H * 0.88), 9)
    stand(img, bf, W * 0.80, H * 1.04)
    logo = sticker(scaled(sparrow_frame('logoBumpin', 'logo bumpin'), H * 0.80), 8)
    place(img, logo, W * 0.38, H * 0.45)
    img.convert('RGB').resize((256, 150), Image.LANCZOS).save(os.path.join(STORE, 'icon.png'))


def make_banner():
    W, H = 2544, 624
    img = stage_background(W, H, (W * 0.62, H * 0.40), H * 1.3)
    halftone(img, (0xFF, 0x3B, 0x6B, 55), 34, 11)
    rim = 9
    cast = [  # back to front: (sprite, height, centre x, bottom)
        (sprite('charSelect/neneChill.png'), H * 0.66, W * 0.915, H * 1.02),
        (sprite('charSelect/picoChill.png'), H * 0.80, W * 0.775, H * 1.03),
        (sprite('charSelect/bfChill.png'), H * 0.82, W * 0.455, H * 1.03),
        (sparrow_frame('gfDanceTitle', 'gfDance'), H * 0.95, W * 0.615, H * 1.05),
    ]
    for img_, height, cx, bottom in cast:
        stand(img, sticker(scaled(img_, height), rim), cx, bottom)
    logo = sticker(scaled(sparrow_frame('logoBumpin', 'logo bumpin'), H * 0.86), rim)
    place(img, logo, W * 0.175, H * 0.43)
    badge(img, 'NINTENDO SWITCH PORT', W * 0.175, H * 0.90, H * 0.12)
    img.convert('RGB').resize((848, 208), Image.LANCZOS).save(os.path.join(STORE, 'screen.png'))


if __name__ == '__main__':
    make_icon()
    make_banner()
    print(f'[make_store_art] icon.png and screen.png written to {os.path.relpath(STORE)}')
