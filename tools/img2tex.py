#!/usr/bin/env python3
"""
img2tex.py - Converts an image (PNG, BMP...) into an 8 bpp texture for the blitter.

  python img2tex.py image.png output [--pal default|own] [--key R,G,B] [--c name]

  --pal default : uses the gfx_palette_default() palette (nearest color)
  --pal own     : quantizes to 255 custom colors and writes output.pal (256 x 0x00RRGGBB)
  --key R,G,B   : that color (or alpha transparency < 128) becomes index 0
  --c name      : generates output.c with C arrays instead of .bin
.bin format: 4 bytes width, 4 bytes height, width*height indices.
"""
import sys, struct, argparse
from PIL import Image


def default_palette():
    ega = [0x000000, 0x0000AA, 0x00AA00, 0x00AAAA, 0xAA0000, 0xAA00AA, 0xAA5500, 0xAAAAAA,
           0x555555, 0x5555FF, 0x55FF55, 0x55FFFF, 0xFF5555, 0xFF55FF, 0xFFFF55, 0xFFFFFF]
    pal = list(ega)
    for r in range(6):
        for g in range(7):
            for b in range(6):
                if len(pal) < 240:
                    pal.append(((r * 51) << 16) | ((g * 85 // 2) << 8) | (b * 51))
    for k in range(16):
        v = k * 17
        pal.append((v << 16) | (v << 8) | v)
    return pal[:256]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("img"); ap.add_argument("out")
    ap.add_argument("--pal", default="default")
    ap.add_argument("--key")
    ap.add_argument("--c")
    a = ap.parse_args()
    im = Image.open(a.img).convert("RGBA")
    w, h = im.size
    key = tuple(int(x) for x in a.key.split(",")) if a.key else None
    px = im.load()
    if a.pal == "own":
        q = im.convert("RGB").quantize(colors=255)
        qp = q.getpalette()[:255 * 3]
        pal = [0] + [(qp[3 * i] << 16) | (qp[3 * i + 1] << 8) | qp[3 * i + 2] for i in range(255)]
        qd = q.load()
        idx = [[qd[x, y] + 1 for x in range(w)] for y in range(h)]
        with open(a.out + ".pal", "wb") as f:
            for c in pal + [0] * (256 - len(pal)):
                f.write(struct.pack("<I", c))
    else:
        pal = default_palette()
        cache = {}
        def near(c):
            if c not in cache:
                r, g, b = c
                cache[c] = min(range(1, 256), key=lambda i: ((pal[i] >> 16) - r) ** 2 * 3 +
                               (((pal[i] >> 8) & 255) - g) ** 2 * 4 + ((pal[i] & 255) - b) ** 2 * 2)
            return cache[c]
        idx = [[near(px[x, y][:3]) for x in range(w)] for y in range(h)]
    for y in range(h):
        for x in range(w):
            r, g, b, al = px[x, y]
            if al < 128 or (key and (r, g, b) == key):
                idx[y][x] = 0
    data = bytes(v for row in idx for v in row)
    if a.c:
        with open(a.out + ".c", "w") as f:
            f.write(f"#include <stdint.h>\nconst uint16_t {a.c}_w = {w}, {a.c}_h = {h};\n")
            f.write(f"const uint8_t {a.c}[{w * h}] = {{\n")
            for i in range(0, len(data), 24):
                f.write("  " + ", ".join(str(v) for v in data[i:i + 24]) + ",\n")
            f.write("};\n")
    else:
        with open(a.out + ".bin", "wb") as f:
            f.write(struct.pack("<II", w, h) + data)
    print(f"{w}x{h} -> {a.out}")


if __name__ == "__main__":
    main()
