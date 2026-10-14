#!/usr/bin/env python3
"""Draw the app's geometric icon; standard library only, no copied platform art."""
import json
from pathlib import Path
import math
import struct
import zlib


def rounded_distance(x, y, cx, cy, width, height, radius):
    dx = abs(x - cx) - width / 2 + radius
    dy = abs(y - cy) - height / 2 + radius
    return math.hypot(max(dx, 0), max(dy, 0)) + min(max(dx, dy), 0) - radius


def blend(bottom, top, amount):
    amount = max(0, min(1, amount))
    return tuple(int(b * (1 - amount) + t * amount) for b, t in zip(bottom, top))


def chunk(kind, payload):
    return struct.pack('>I', len(payload)) + kind + payload + struct.pack('>I', zlib.crc32(kind + payload) & 0xFFFFFFFF)


def main():
    output = Path(__file__).resolve().parent.parent / 'ios/Live/Assets.xcassets/AppIcon.appiconset'
    output.mkdir(parents=True, exist_ok=True)
    width = 1024
    raw = bytearray()
    for y in range(width):
        raw.append(0)
        for x in range(width):
            glow = max(0, 1 - math.hypot(x - 200, y - 150) / 1000)
            color = blend((9, 16, 27), (21, 57, 65), glow * .65)
            distance = rounded_distance(x, y, 512, 470, 650, 454, 92)
            if distance < 1:
                color = blend(color, (76, 232, 189), min(1, 1 - distance))
            inner = rounded_distance(x, y, 512, 470, 606, 410, 70)
            if inner < 1:
                color = blend(color, (16, 35, 45), min(1, 1 - inner))
            # Right-pointing triangle with slightly softened edges.
            triangle = min(x - 441, (645 - x) * .61 - abs(y - 470))
            if triangle > -1:
                color = blend(color, (208, 255, 239), min(1, triangle + 1))
            for cx, h in [(426, 38), (484, 66), (542, 44), (600, 26)]:
                distance = rounded_distance(x, y, cx, 790, 20, h, 10)
                if distance < 1:
                    color = blend(color, (76, 232, 189), min(1, 1 - distance))
            raw.extend(color)
    png = b'\x89PNG\r\n\x1a\n'
    png += chunk(b'IHDR', struct.pack('>IIBBBBB', width, width, 8, 2, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(bytes(raw), 9))
    png += chunk(b'IEND', b'')
    (output / 'AppIcon.png').write_bytes(png)
    (output / 'Contents.json').write_text(json.dumps({'images': [{'filename': 'AppIcon.png', 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'}], 'info': {'author': 'xcode', 'version': 1}}, indent=2) + '\n')
    (output.parent / 'Contents.json').write_text('{"info":{"author":"xcode","version":1}}\n')


if __name__ == '__main__':
    main()
