#!/usr/bin/env python3
"""Draws Caz's app icon: the white calligraphic C over a square of the Sunshine Sweep backdrop.

Run from the repository root:  python3 scripts/make_icon.py
Writes Caz/Assets.xcassets/AppIcon.appiconset/AppIcon.png and a preview at three sizes. Needs numpy and Pillow.
"""
import math, sys
BACKDROP = 'Caz/Assets.xcassets/Backdrop.imageset/Backdrop.jpg'
import numpy as np
from PIL import Image, ImageDraw, ImageFilter
S = 1024
K = 2                       # supersample factor for smooth edges
SS = S * K
yy, xx = np.mgrid[0:S, 0:S]

# background: a square of the Sunshine Sweep backdrop, so the icon matches the app
crop = (0, 250, 1290, 1540)     # the square of the backdrop behind the C, then mirrored
img = Image.open(BACKDROP).convert('RGB').crop(crop).resize((S, S), Image.LANCZOS)
if True:
    img = img.transpose(Image.FLIP_LEFT_RIGHT)   # the sweep's light behind the C's opening, not its heavy stroke
img = img.convert('RGBA')

# the C: outer circle minus an offset counter gives calligraphic contrast
# (heavy at the lower left, hairline at the top right), then the mouth is cut at an angle
gy, gx = np.mgrid[0:SS, 0:SS] / K
cx, cy = 532.0, 512.0          # nudged right so the open letter looks centred
R, r = 330.0, 206.0
sx, sy = 62.0, -38.0           # counter offset: up and to the right
outer = (gx - cx) ** 2 + (gy - cy) ** 2 <= R ** 2
inner = (gx - (cx + sx)) ** 2 + (gy - (cy + sy)) ** 2 <= r ** 2
ang = np.degrees(np.arctan2(gy - cy, gx - cx))           # 0 = right, +90 = down
mouth = (ang > -44) & (ang < 36)                          # opening on the right
# angled terminal cuts: shear the mouth edges so the ends aren't radial
cut_top = (gy - cy) > -0.62 * (gx - cx) - 18
cut_bot = (gy - cy) < 0.86 * (gx - cx) - 6
mouth = mouth & cut_top & cut_bot | ((gx > cx + 40) & ((gy - cy) > -0.62 * (gx - cx) - 18) & ((gy - cy) < 0.86 * (gx - cx) - 6))
glyph = outer & ~inner & ~mouth
m = Image.fromarray((glyph * 255).astype(np.uint8), 'L')
# round the sharp corners a touch, then downsample for anti-aliasing
m = m.filter(ImageFilter.GaussianBlur(5 * K)).point(lambda v: 255 if v > 128 else 0)
m = m.filter(ImageFilter.GaussianBlur(1.0 * K)).resize((S, S), Image.LANCZOS)

# warm shadow so white reads on yellow
sh = Image.new('RGBA', (S, S), (176, 98, 0, 0)); sh.putalpha(m.filter(ImageFilter.GaussianBlur(26)).point(lambda v: int(v * 0.42)))
img = Image.alpha_composite(img, sh.transform((S, S), Image.AFFINE, (1, 0, -6, 0, 1, -16)))
# white letter with a whisper of warmth toward the bottom
tt = np.clip((yy - 180) / 700.0, 0, 1)
w1, w2 = np.array([255, 255, 255]), np.array([255, 246, 228])
fill = (w1 * (1 - tt[..., None]) + w2 * tt[..., None]).astype(np.uint8)
letter = Image.fromarray(fill, 'RGB').convert('RGBA'); letter.putalpha(m)
img = Image.alpha_composite(img, letter)
out = img.convert('RGB')
out.save(sys.argv[1] if len(sys.argv) > 1 else 'Caz/Assets.xcassets/AppIcon.appiconset/AppIcon.png', optimize=True)

canvas = Image.new('RGB', (620, 400), (232, 232, 238))
for size, x in ((360, 20), (120, 410), (60, 545)):
    p = out.resize((size, size), Image.LANCZOS)
    mk = Image.new('L', (size, size), 0); ImageDraw.Draw(mk).rounded_rectangle([0, 0, size - 1, size - 1], radius=int(size * 0.225), fill=255)
    canvas.paste(p, (x, 20 + (360 - size) // 2), mk)
canvas.save(sys.argv[2] if len(sys.argv) > 2 else '/tmp/caz-icon-preview.png')
print(out.size)
