"""Draws the Kumo app icon (1024x1024 PNG) with no extra libraries.

Design: a paper-white cloud on warm black with one vermilion seal, matching
the app's "Sumi" theme. Original artwork made of plain shapes.
Run:  python tools/make_icon.py
"""
import math, struct, zlib, sys

SIZE = 1024
BG = (0x13, 0x12, 0x11)
PAPER = (0xEC, 0xE6, 0xDA)
SEAL = (0xD2, 0x45, 0x2A)

def circle(x, y, cx, cy, r):
    return math.hypot(x - cx, y - cy) - r

def rounded_box(x, y, cx, cy, hw, hh, r):
    dx, dy = abs(x - cx) - (hw - r), abs(y - cy) - (hh - r)
    return math.hypot(max(dx, 0), max(dy, 0)) + min(max(dx, dy), 0) - r

def cloud(x, y):
    return min(
        rounded_box(x, y, 512, 600, 280, 82, 82),
        circle(x, y, 392, 520, 118),
        circle(x, y, 540, 446, 160),
        circle(x, y, 676, 530, 104),
    )

def seal(x, y):
    return rounded_box(x, y, 722, 690, 62, 62, 10)

def cover(d):               # signed distance -> coverage (anti-aliasing)
    return min(1.0, max(0.0, 0.5 - d))

def mix(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))

rows = []
for y in range(SIZE):
    row = bytearray([0])
    for x in range(SIZE):
        px, py = x + 0.5, y + 0.5
        c = BG
        c = mix(c, PAPER, cover(cloud(px, py)))
        s = seal(px, py)
        c = mix(c, BG, cover(s - 14))      # dark gap around the seal
        c = mix(c, SEAL, cover(s))
        row += bytes(int(round(v)) for v in c)
    rows.append(bytes(row))

def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0)) \
    + chunk(b"IDAT", zlib.compress(b"".join(rows), 9)) + chunk(b"IEND", b"")
out = sys.argv[1] if len(sys.argv) > 1 else "App/Assets.xcassets/AppIcon.appiconset/icon.png"
open(out, "wb").write(png)
print("wrote", out, len(png), "bytes")
