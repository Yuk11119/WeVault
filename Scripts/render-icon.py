#!/usr/bin/env python3
"""Render the WeVault macOS app icon.

Concept: a deep-forest-green tile (full-bleed square; macOS applies the squircle
and shadow at display time) holding a large ivory circular "vault door". On the
door sits the brand "W" — crisp outer strokes with two smooth vaulted inner
arches — in deep green, with a small amber keyhole nested under the central arch.
W for WeChat, the arched door + keyhole for the vault.

Outputs (relative to the project root):
    Packaging/AppIcon.png     1024px master, full-bleed
    Packaging/AppIcon.icns    multi-resolution icon

Run from the project root:  python3 Scripts/render-icon.py
"""
import os
import shutil
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

S = 1024          # final master size
SS = 4            # supersampling factor for clean anti-aliasing
F = S * SS        # render canvas (4096)

# --- palette -------------------------------------------------------------
GREEN_TOP = (0x22, 0x6b, 0x50)     # brighter green, top-left
GREEN_BOT = (0x0c, 0x2d, 0x1f)     # deep green, bottom-right
W_GREEN = (0x13, 0x38, 0x2a)       # W monogram green (on ivory)
IVORY_TOP = (0xfb, 0xf9, 0xf1)
IVORY_BOT = (0xe6, 0xe1, 0xce)
RIM = (0xd6, 0xd0, 0xb8)           # recessed rim ring
AMBER = (0xb0, 0x7d, 0x1e)         # keyhole accent


def _sc(x):
    """Convert 1024-space coordinate to render-space (supersampled)."""
    return int(round(x * SS))


def diagonal_gradient(size, c0, c1):
    axis = np.linspace(0.0, 1.0, size, dtype=np.float32)
    xx, yy = np.meshgrid(axis, axis)
    t = (xx + yy) * 0.5
    arr = np.empty((size, size, 3), dtype=np.float32)
    for i in range(3):
        arr[:, :, i] = c0[i] * (1.0 - t) + c1[i] * t
    return arr.astype(np.uint8)


def sheen_layer(size):
    y, x = np.mgrid[0:size, 0:size].astype(np.float32)
    cx, cy = size * 0.30, size * 0.24
    d = np.sqrt((x - cx) ** 2 + (y - cy) ** 2) / (size * 0.85)
    a = np.clip(1.0 - d, 0.0, 1.0) ** 2 * 0.11
    layer = np.zeros((size, size, 4), dtype=np.float32)
    layer[:, :, 0] = 1.0
    layer[:, :, 1] = 1.0
    layer[:, :, 2] = 1.0
    layer[:, :, 3] = a
    return (layer * 255.0).astype(np.uint8)


def disc_layer(size, cx, cy, r, c0, c1):
    """Vertical gradient clipped to a disc, plus a recessed rim ring."""
    y, x = np.mgrid[0:size, 0:size].astype(np.float32)
    t = np.clip((y - (cy - r)) / (2.0 * r), 0.0, 1.0)
    rgb = np.empty((size, size, 3), dtype=np.float32)
    for i in range(3):
        rgb[:, :, i] = c0[i] * (1.0 - t) + c1[i] * t
    dist = np.sqrt((x - cx) ** 2 + (y - cy) ** 2)
    alpha = np.clip((r - dist) + 0.5, 0.0, 1.0) * 255.0
    layer = np.dstack([rgb, alpha]).astype(np.uint8)
    return Image.fromarray(layer, 'RGBA')


def quadratic(p0, p1, p2, n=60):
    """Sample a quadratic bezier; returns list of (x, y) in 1024 space."""
    pts = []
    for i in range(n + 1):
        t = i / n
        mt = 1.0 - t
        x = mt * mt * p0[0] + 2 * mt * t * p1[0] + t * t * p2[0]
        y = mt * mt * p0[1] + 2 * mt * t * p1[1] + t * t * p2[1]
        pts.append((x, y))
    return pts


def w_curve(cx, cy):
    """W centreline: crisp outer diagonals + two smooth vaulted inner arches."""
    ltop = (cx - 270, cy - 188)
    lval = (cx - 156, cy + 172)
    mtop = (cx, cy - 60)
    rval = (cx + 156, cy + 172)
    rtop = (cx + 270, cy - 188)
    arch1 = quadratic(lval, (cx - 148, cy + 48), mtop)
    arch2 = quadratic(mtop, (cx + 148, cy + 48), rval)
    return [ltop] + arch1 + arch2[1:] + [rtop]


def draw_w(layer, cx, cy, color, width):
    """Draw the W stroke (square outer ends, rounded joins)."""
    pts = [(x * SS, y * SS) for x, y in w_curve(cx, cy)]
    w = _sc(width)
    ImageDraw.Draw(layer).line(pts, fill=color + (255,), width=w, joint='curve')


def draw_keyhole(layer, cx, cy, color, r):
    """Classic keyhole: round head + a parallel-sided slot."""
    d = ImageDraw.Draw(layer)
    head_r = _sc(r)
    head_cy = _sc(cy - int(r * 0.55))
    d.ellipse([_sc(cx) - head_r, head_cy - head_r, _sc(cx) + head_r, head_cy + head_r],
              fill=color + (255,))
    slot_hw = int(r * 0.55)
    d.rounded_rectangle(
        [_sc(cx - slot_hw), head_cy, _sc(cx + slot_hw), _sc(cy + int(r * 1.5))],
        radius=_sc(int(r * 0.35)), fill=color + (255,))


def build_master(with_keyhole=True):
    img = Image.fromarray(diagonal_gradient(F, GREEN_TOP, GREEN_BOT), 'RGB').convert('RGBA')
    img = Image.alpha_composite(img, Image.fromarray(sheen_layer(F), 'RGBA'))

    cx = cy = S / 2.0
    door_r = 418.0

    # Door drop shadow (subtle)
    sh = Image.new('RGBA', (F, F), (0, 0, 0, 0))
    dsh = ImageDraw.Draw(sh)
    rr = _sc(door_r)
    off = _sc(12)
    dsh.ellipse([_sc(cx) - rr, _sc(cy) - rr + off, _sc(cx) + rr, _sc(cy) + rr + off],
                fill=(0, 0, 0, 70))
    sh = sh.filter(ImageFilter.GaussianBlur(_sc(20)))
    img = Image.alpha_composite(img, sh)

    # Door disc + recessed rim ring
    door = disc_layer(F, _sc(cx), _sc(cy), _sc(door_r), IVORY_TOP, IVORY_BOT)
    dr = ImageDraw.Draw(door)
    dr.ellipse([_sc(cx) - _sc(door_r), _sc(cy) - _sc(door_r),
                _sc(cx) + _sc(door_r), _sc(cy) + _sc(door_r)],
               outline=RIM + (255,), width=_sc(14))
    dr.ellipse([_sc(cx) - _sc(door_r - 26), _sc(cy) - _sc(door_r - 26),
                _sc(cx) + _sc(door_r - 26), _sc(cy) + _sc(door_r - 26)],
               outline=RIM + (90,), width=_sc(6))
    img = Image.alpha_composite(img, door)

    # W monogram
    w = Image.new('RGBA', (F, F), (0, 0, 0, 0))
    draw_w(w, cx, cy, W_GREEN, 84)
    img = Image.alpha_composite(img, w)

    # Keyhole nested under the central arch
    if with_keyhole:
        kh = Image.new('RGBA', (F, F), (0, 0, 0, 0))
        draw_keyhole(kh, cx, cy + 60, AMBER, 30)
        img = Image.alpha_composite(img, kh)

    return img.resize((S, S), Image.LANCZOS)


def _report_geometry():
    cx = cy = 512.0
    pts = w_curve(cx, cy)
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    hw = 84 / 2
    print(f'W curve bbox: x [{min(xs):.0f}, {max(xs):.0f}]  '
          f'y [{min(ys):.0f}, {max(ys):.0f}]  (stroke half={hw})')
    print(f'Keyhole centre y = {cy + 60:.0f}; door radius = 418; '
          f'door inner bottom = {cy + 418:.0f}')


def write_iconset(master, iconset_dir):
    if os.path.isdir(iconset_dir):
        shutil.rmtree(iconset_dir)
    os.makedirs(iconset_dir)
    sizes = [
        ('icon_16x16.png', 16), ('icon_16x16@2x.png', 32),
        ('icon_32x32.png', 32), ('icon_32x32@2x.png', 64),
        ('icon_128x128.png', 128), ('icon_128x128@2x.png', 256),
        ('icon_256x256.png', 256), ('icon_256x256@2x.png', 512),
        ('icon_512x512.png', 512), ('icon_512x512@2x.png', 1024),
    ]
    for name, size in sizes:
        master.resize((size, size), Image.LANCZOS).save(os.path.join(iconset_dir, name))


def main():
    _report_geometry()
    with_keyhole = '--no-keyhole' not in sys.argv
    master = build_master(with_keyhole=with_keyhole)
    master_png = os.path.join(ROOT, 'Packaging', 'AppIcon.png')
    os.makedirs(os.path.dirname(master_png), exist_ok=True)
    master.save(master_png)

    with tempfile.TemporaryDirectory() as tmp:
        iconset = os.path.join(tmp, 'AppIcon.iconset')
        write_iconset(master, iconset)
        icns = os.path.join(ROOT, 'Packaging', 'AppIcon.icns')
        subprocess.run(['iconutil', '-c', 'icns', iconset, '-o', icns], check=True)

    print('Wrote', master_png)
    print('Wrote', icns)


if __name__ == '__main__':
    main()
