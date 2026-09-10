#!/usr/bin/env python3
"""Build the WeVault macOS app icon from a PNG.

Usage:
    python3 Scripts/render-icon.py
    python3 Scripts/render-icon.py /path/to/source.png
"""
import os
import shutil
import subprocess
import sys
import tempfile
import math
import struct
import zlib
from collections import deque
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MASTER = ROOT / 'Packaging' / 'AppIcon.png'
ICNS = ROOT / 'Packaging' / 'AppIcon.icns'
SAFE_AREA_SCALE = 0.85
ICONSET_FILES = [
    ('icon_16x16.png', 16),
    ('icon_16x16@2x.png', 32),
    ('icon_32x32.png', 32),
    ('icon_32x32@2x.png', 64),
    ('icon_128x128.png', 128),
    ('icon_128x128@2x.png', 256),
    ('icon_256x256.png', 256),
    ('icon_256x256@2x.png', 512),
    ('icon_512x512.png', 512),
    ('icon_512x512@2x.png', 1024),
]


def run(command):
    subprocess.run(command, check=True)


def read_png(path):
    data = Path(path).read_bytes()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise SystemExit(f'Not a PNG file: {path}')

    pos = 8
    width = height = color_type = bit_depth = interlace = None
    raw_parts = []
    while pos < len(data):
        length = struct.unpack('>I', data[pos:pos + 4])[0]
        chunk_type = data[pos + 4:pos + 8]
        chunk = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if chunk_type == b'IHDR':
            width, height, bit_depth, color_type, _, _, interlace = struct.unpack('>IIBBBBB', chunk)
        elif chunk_type == b'IDAT':
            raw_parts.append(chunk)
        elif chunk_type == b'IEND':
            break

    if bit_depth != 8 or color_type not in (2, 6) or interlace != 0:
        raise SystemExit('Icon source must be an 8-bit, non-interlaced RGB or RGBA PNG')

    channels = 3 if color_type == 2 else 4
    stride = width * channels
    raw = zlib.decompress(b''.join(raw_parts))
    rows = []
    prev = bytearray(stride)
    offset = 0
    bpp = channels
    for _ in range(height):
        filter_type = raw[offset]
        offset += 1
        row = bytearray(raw[offset:offset + stride])
        offset += stride
        for i in range(stride):
            left = row[i - bpp] if i >= bpp else 0
            up = prev[i]
            upper_left = prev[i - bpp] if i >= bpp else 0
            if filter_type == 1:
                row[i] = (row[i] + left) & 0xff
            elif filter_type == 2:
                row[i] = (row[i] + up) & 0xff
            elif filter_type == 3:
                row[i] = (row[i] + ((left + up) >> 1)) & 0xff
            elif filter_type == 4:
                p = left + up - upper_left
                pa = abs(p - left)
                pb = abs(p - up)
                pc = abs(p - upper_left)
                predictor = left if pa <= pb and pa <= pc else up if pb <= pc else upper_left
                row[i] = (row[i] + predictor) & 0xff
            elif filter_type != 0:
                raise SystemExit(f'Unsupported PNG filter: {filter_type}')
        rows.append(row)
        prev = row
    return width, height, channels, rows


def write_rgba_png(path, width, height, pixels):
    def chunk(kind, payload):
        return (
            struct.pack('>I', len(payload))
            + kind
            + payload
            + struct.pack('>I', zlib.crc32(kind + payload) & 0xffffffff)
        )

    raw = bytearray()
    stride = width * 4
    for y in range(height):
        raw.append(0)
        start = y * stride
        raw.extend(pixels[start:start + stride])

    payload = (
        b'\x89PNG\r\n\x1a\n'
        + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))
        + chunk(b'IDAT', zlib.compress(bytes(raw), 9))
        + chunk(b'IEND', b'')
    )
    Path(path).write_bytes(payload)


def remove_edge_background(source, output, threshold=245):
    width, height, channels, rows = read_png(source)

    def pixel_at(x, y):
        base = x * channels
        row = rows[y]
        if channels == 4:
            return row[base], row[base + 1], row[base + 2], row[base + 3]
        return row[base], row[base + 1], row[base + 2], 255

    def is_background(x, y):
        r, g, b, a = pixel_at(x, y)
        return a > 0 and r >= threshold and g >= threshold and b >= threshold

    background = bytearray(width * height)
    queue = deque()
    for x in range(width):
        for y in (0, height - 1):
            if is_background(x, y):
                queue.append((x, y))
    for y in range(height):
        for x in (0, width - 1):
            if is_background(x, y):
                queue.append((x, y))

    while queue:
        x, y = queue.popleft()
        index = y * width + x
        if background[index] or not is_background(x, y):
            continue
        background[index] = 1
        if x > 0:
            queue.append((x - 1, y))
        if x + 1 < width:
            queue.append((x + 1, y))
        if y > 0:
            queue.append((x, y - 1))
        if y + 1 < height:
            queue.append((x, y + 1))

    min_x, min_y = width, height
    max_x = max_y = -1
    for y in range(height):
        for x in range(width):
            if not background[y * width + x]:
                min_x = min(min_x, x)
                min_y = min(min_y, y)
                max_x = max(max_x, x)
                max_y = max(max_y, y)

    if max_x < min_x or max_y < min_y:
        raise SystemExit('Icon source has no visible foreground')

    cropped_width = max_x - min_x + 1
    cropped_height = max_y - min_y + 1
    pixels = bytearray(cropped_width * cropped_height * 4)
    for y in range(cropped_height):
        for x in range(cropped_width):
            src_x = min_x + x
            src_y = min_y + y
            r, g, b, a = pixel_at(src_x, src_y)
            if background[src_y * width + src_x]:
                a = 0
            dest = (y * cropped_width + x) * 4
            pixels[dest:dest + 4] = bytes((r, g, b, a))

    canvas_side = max(cropped_width, cropped_height, math.ceil(max(cropped_width, cropped_height) / SAFE_AREA_SCALE))
    offset_x = (canvas_side - cropped_width) // 2
    offset_y = (canvas_side - cropped_height) // 2
    canvas = bytearray(canvas_side * canvas_side * 4)
    for y in range(cropped_height):
        src_start = y * cropped_width * 4
        dest_start = ((y + offset_y) * canvas_side + offset_x) * 4
        canvas[dest_start:dest_start + cropped_width * 4] = pixels[src_start:src_start + cropped_width * 4]

    write_rgba_png(output, canvas_side, canvas_side, canvas)


def normalize_master(source):
    MASTER.parent.mkdir(parents=True, exist_ok=True)
    trimmed = MASTER.with_suffix('.trimmed.png')
    tmp = MASTER.with_suffix('.tmp.png')
    remove_edge_background(source, trimmed)
    run(['sips', '-s', 'format', 'png', '-z', '1024', '1024', str(trimmed), '--out', str(tmp)])
    trimmed.unlink(missing_ok=True)
    os.replace(tmp, MASTER)


def write_iconset(iconset_dir):
    if iconset_dir.exists():
        shutil.rmtree(iconset_dir)
    iconset_dir.mkdir(parents=True)
    for name, size in ICONSET_FILES:
        output = iconset_dir / name
        if size == 1024:
            shutil.copyfile(MASTER, output)
        else:
            run(['sips', '-z', str(size), str(size), str(MASTER), '--out', str(output)])


def main():
    source = Path(sys.argv[1]).expanduser().resolve() if len(sys.argv) > 1 else MASTER
    if not source.exists():
        raise SystemExit(f'Icon source not found: {source}')

    normalize_master(source)
    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / 'AppIcon.iconset'
        write_iconset(iconset)
        run(['iconutil', '-c', 'icns', str(iconset), '-o', str(ICNS)])

    print(f'Wrote {MASTER}')
    print(f'Wrote {ICNS}')


if __name__ == '__main__':
    main()
