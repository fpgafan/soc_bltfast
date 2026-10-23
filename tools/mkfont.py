#!/usr/bin/env python3
"""mkfont.py - Extracts the Windows 8x8 CGA font (code page 850) into sw/lib/font8x8.c
   (256 characters x 8 bytes, MSB = leftmost pixel) plus a PNG preview."""
import os, struct, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
src = sys.argv[1] if len(sys.argv) > 1 else r"C:\Windows\Fonts\cga80850.fon"
d = open(src, "rb").read()

font = None
for off in range(0, len(d) - 120):
    ver = struct.unpack_from("<H", d, off)[0]
    if ver not in (0x200, 0x300):
        continue
    size = struct.unpack_from("<I", d, off + 2)[0]
    if size < 1000 or off + size > len(d) + 16:
        continue
    pw, ph = struct.unpack_from("<HH", d, off + 86)
    first, last = d[off + 95], d[off + 96]
    if ph != 8 or (pw not in (0, 8)):
        continue
    tbl = off + (118 if ver == 0x200 else 148)
    esz = 4 if ver == 0x200 else 6
    glyphs = {}
    ok = True
    for c in range(first, last + 1):
        e = tbl + (c - first) * esz
        w = struct.unpack_from("<H", d, e)[0]
        go = struct.unpack_from("<H" if ver == 0x200 else "<I", d, e + 2)[0]
        if w != 8 or off + go + 8 > len(d):
            ok = False; break
        glyphs[c] = d[off + go: off + go + 8]
    if ok and len(glyphs) > 90:
        font = glyphs
        break
if not font:
    print("no 8x8 font found"); sys.exit(1)

out = os.path.join(ROOT, "sw", "lib", "font8x8.c")
with open(out, "w") as f:
    f.write("// font8x8.c - 8x8 font, code page 850 (extracted from cga80850.fon)\n")
    f.write("// 256 characters x 8 rows, bit 7 = leftmost pixel\n#include <stdint.h>\n")
    f.write("const uint8_t font8x8[256 * 8] __attribute__((aligned(4))) = {\n")
    for c in range(256):
        g = font.get(c, bytes(8))
        f.write("  " + ", ".join("0x%02x" % b for b in g) + ",\n")
    f.write("};\n")
print("written", out)
try:
    from PIL import Image
    im = Image.new("L", (16 * 9, 16 * 9), 0)
    for c in range(256):
        g = font.get(c, bytes(8))
        for y in range(8):
            for x in range(8):
                if g[y] >> (7 - x) & 1:
                    im.putpixel(((c % 16) * 9 + x, (c // 16) * 9 + y), 255)
    im = im.resize((im.width * 3, im.height * 3), Image.NEAREST)
    im.save(os.path.join(ROOT, "sw", "build", "font_preview.png"))
except ImportError:
    pass
