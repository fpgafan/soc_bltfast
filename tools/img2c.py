#!/usr/bin/env python3
"""
img2c.py - Converts an image (PNG, BMP, JPG, GIF...) into a C header with
an 8 bpp texture for the bltfast SoC blitter.

    python tools/img2c.py image.png sw/apps/my_app/image.h [options]

Options:
    --name N          array name (default: the name of the .h file)
    --width W         resize to width W (if only one is given, the
    --height H        aspect ratio is kept)
    --pixelated       resize without smoothing (nearest neighbor: pixel art)
    --palette default (default) use the gfx_palette_default() palette
                      (16 EGA + color cube + grays): nothing has to be loaded and
                      several images can coexist without trouble
    --palette custom  quantize to a custom palette of --colors colors that is
                      loaded into the SoC palette starting at index --base
    --colors N        colors in the custom palette (1..256, default 256 - base)
    --base B          first index of the custom palette (default 0)
    --transparent     pixels with alpha < 128 use the KEY index (0 with the
                      default palette; B with the custom one, and the colors go from
                      B+1 onwards). When drawing: flags GFX_KEY, key = NAME_KEY
    --key R,G,B       additionally, that exact color is also transparent
    --dither          Floyd-Steinberg dithering when reducing colors (photos)

Generates:
    #define NAME_W / NAME_H / NAME_STRIDE   size (stride multiple of 4)
    #define NAME_KEY                        transparent index (-1 if none)
    static const uint8_t name[]             palette indices, row by row
    #define NAME_SURF                       surface ready for gfx_blit
  with --palette custom, also:
    #define NAME_PAL_BASE / NAME_PAL_N
    static const uint32_t name_pal[]        colors 0x00RRGGBB
    static inline void name_pal_load(void)  loads it into the SoC palette

In C:
    #include "image.h"
    surface img = IMAGE_SURF;
    image_pal_load();                                        // only with a custom palette
    gfx_blit(&img, 0, 0, IMAGE_W, IMAGE_H, x, y, 0, 0);      // opaque
    gfx_blit(&img, 0, 0, IMAGE_W, IMAGE_H, x, y, GFX_KEY, IMAGE_KEY);
    gfx_blit_scaled(&img, 0, 0, IMAGE_W, IMAGE_H, x, y, 2 * IMAGE_W, 2 * IMAGE_H, GFX_KEY, IMAGE_KEY);
    (for sprite sheets, pick the frame with sx/sy)

The array is part of the program, which is loaded into SDRAM, so the blitter
reads it directly: there is no need to copy it.
"""
import argparse
import os
import re
import sys

from PIL import Image


def default_palette():
    """The same palette as gfx_palette_default() (sw/lib/gfx.c)."""
    pal = [0x000000, 0x0000AA, 0x00AA00, 0x00AAAA, 0xAA0000, 0xAA00AA, 0xAA5500, 0xAAAAAA,
           0x555555, 0x5555FF, 0x55FF55, 0x55FFFF, 0xFF5555, 0xFF55FF, 0xFFFF55, 0xFFFFFF]
    for r in range(6):
        for g in range(7):
            for b in range(6):
                if len(pal) < 240:
                    pal.append(((r * 51) << 16) | ((g * 85 // 2) << 8) | (b * 51))
    for k in range(16):
        v = k * 17
        pal.append((v << 16) | (v << 8) | v)
    return pal


def pixels(im):
    f = getattr(im, "get_flattened_data", None)        # Pillow >= 12.1
    return list(f() if f else im.getdata())


def rgb(c):
    return (c >> 16) & 255, (c >> 8) & 255, c & 255


def quantize_fixed(img, pal, first, dither):
    """Indices into 'pal' (only from 'first' onwards) with PIL, with or without dithering."""
    usable = pal[first:]
    pimg = Image.new("P", (1, 1))
    flat = [v for c in usable for v in rgb(c)]
    flat += flat[-3:] * (256 - len(usable))            # pad with the last color
    pimg.putpalette(flat)
    q = img.quantize(palette=pimg, dither=Image.Dither.FLOYDSTEINBERG if dither else Image.Dither.NONE)
    return [first + min(v, len(usable) - 1) for v in pixels(q)]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("image")
    ap.add_argument("output")
    ap.add_argument("--name")
    ap.add_argument("--width", type=int)
    ap.add_argument("--height", type=int)
    ap.add_argument("--pixelated", action="store_true")
    ap.add_argument("--palette", choices=("default", "custom"), default="default")
    ap.add_argument("--colors", type=int)
    ap.add_argument("--base", type=int, default=0)
    ap.add_argument("--transparent", action="store_true")
    ap.add_argument("--key")
    ap.add_argument("--dither", action="store_true")
    a = ap.parse_args()

    name = a.name or os.path.splitext(os.path.basename(a.output))[0]
    name = re.sub(r"\W", "_", name)
    if name[0].isdigit():
        name = "_" + name
    NAME = name.upper()

    im = Image.open(a.image).convert("RGBA")
    if a.width or a.height:
        w0, h0 = im.size
        w = a.width or max(1, round(w0 * a.height / h0))
        h = a.height or max(1, round(h0 * a.width / w0))
        im = im.resize((w, h), Image.NEAREST if a.pixelated else Image.LANCZOS)
    w, h = im.size
    if w > 2048 or h > 2048:
        sys.exit(f"image too large ({w}x{h}); use --width/--height")

    keycol = tuple(int(v) for v in a.key.split(",")) if a.key else None
    px = pixels(im)
    transp = [p[3] < 128 or (keycol is not None and p[:3] == keycol) for p in px]
    use_key = a.transparent or keycol is not None
    rgb_img = im.convert("RGB")

    custom_pal = None
    if a.palette == "default":
        if a.base or a.colors:
            sys.exit("--base and --colors only apply with --palette custom")
        key = 0
        # with transparency, index 0 is reserved: opaque black comes out as 16 (also black)
        idx = quantize_fixed(rgb_img, default_palette(), 1 if use_key else 0, a.dither)
    else:
        base = a.base
        first = base + (1 if use_key else 0)
        maxc = 256 - first
        n = a.colors or maxc
        if not 1 <= n <= maxc:
            sys.exit(f"--colors must be between 1 and {maxc} (base {base})")
        opaque = [p[:3] for p, t in zip(px, transp) if not t] or [(0, 0, 0)]
        sample = Image.new("RGB", (len(opaque), 1))
        sample.putdata(opaque)
        q = sample.quantize(colors=n, method=Image.Quantize.MEDIANCUT if n > 1 else Image.Quantize.MAXCOVERAGE)
        qp = q.getpalette()[:3 * n]
        cols = [(qp[3 * i] << 16) | (qp[3 * i + 1] << 8) | qp[3 * i + 2] for i in range(len(qp) // 3)]
        full = [0] * first + cols
        idx = quantize_fixed(rgb_img, full, first, a.dither)
        key = base
        custom_pal = ([0] if use_key else []) + cols          # from 'base'

    if use_key:
        idx = [key if t else v for v, t in zip(idx, transp)]
    else:
        key = -1

    stride = (w + 3) & ~3
    rows = []
    for y in range(h):
        rows.append(idx[y * w:(y + 1) * w] + [key if key >= 0 else 0] * (stride - w))
    data = [v for r in rows for v in r]

    guard = "ASSET_" + NAME + "_INCLUDED"           # cannot be NAME_H: that is the height
    out = []
    out.append(f"// {os.path.basename(a.output)} - generated by tools/img2c.py from "
               f"{os.path.basename(a.image)}: {w}x{h}, 8 bpp")
    out.append(f"#ifndef {guard}\n#define {guard}\n#include <stdint.h>\n#include \"gfx.h\"\n")
    out.append(f"#define {NAME}_W      {w}")
    out.append(f"#define {NAME}_H      {h}")
    out.append(f"#define {NAME}_STRIDE {stride}")
    out.append(f"#define {NAME}_KEY    ({key})")
    if custom_pal is not None:
        out.append(f"#define {NAME}_PAL_BASE {a.base}")
        out.append(f"#define {NAME}_PAL_N    {len(custom_pal)}")
        out.append(f"\nstatic const uint32_t {name}_pal[{len(custom_pal)}] = {{")
        for i in range(0, len(custom_pal), 8):
            out.append("    " + ", ".join(f"0x{c:06X}" for c in custom_pal[i:i + 8]) + ",")
        out.append("};")
        out.append(f"static inline void {name}_pal_load(void)\n{{\n"
                   f"    for (int i = 0; i < {NAME}_PAL_N; i++) gfx_palette({NAME}_PAL_BASE + i, {name}_pal[i]);\n}}")
    out.append(f"\nstatic const uint8_t {name}[{len(data)}] __attribute__((aligned(4))) = {{")
    for i in range(0, len(data), 24):
        out.append("    " + ",".join(str(v) for v in data[i:i + 24]) + ",")
    out.append("};")
    out.append(f"#define {NAME}_SURF ((surface){{ (uint32_t){name}, {NAME}_W, {NAME}_H, {NAME}_STRIDE }})")
    out.append(f"\n#endif")
    os.makedirs(os.path.dirname(os.path.abspath(a.output)), exist_ok=True)
    with open(a.output, "w", newline="\n") as f:
        f.write("\n".join(out) + "\n")

    used = len(set(v for v, t in zip(idx, transp) if not t))
    print(f"{a.output}: {name} {w}x{h} (stride {stride}), {len(data)} bytes, "
          f"{used} colors, palette {a.palette}"
          + (f" {a.base}..{a.base + len(custom_pal) - 1}" if custom_pal else "")
          + (f", transparent = {key}" if key >= 0 else ""))


if __name__ == "__main__":
    main()
