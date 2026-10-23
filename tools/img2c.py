#!/usr/bin/env python3
"""
img2c.py - Convierte una imagen (PNG, BMP, JPG, GIF...) a una cabecera C con
una textura de 8 bpp para el blitter del SoC bltfast.

    python tools/img2c.py imagen.png sw/apps/mi_app/imagen.h [opciones]

Opciones:
    --nombre N        nombre del array (por defecto, el del archivo .h)
    --ancho W         redimensionar a W de ancho (si solo se da uno, se
    --alto H          mantiene la proporción)
    --pixelado        redimensionar sin suavizar (vecino más cercano: pixel art)
    --paleta defecto  (por defecto) usar la paleta de gfx_palette_default()
                      (16 EGA + cubo de color + grises): no hay que cargar nada y
                      varias imágenes conviven sin problemas
    --paleta propia   cuantizar a una paleta propia de --colores colores que se
                      carga en la paleta del SoC a partir del índice --base
    --colores N       colores de la paleta propia (1..256, por defecto 256 - base)
    --base B          primer índice de la paleta propia (por defecto 0)
    --transparente    los píxeles con alfa < 128 usan el índice KEY (0 con la
                      paleta por defecto; B con la propia, y los colores van de
                      B+1 en adelante). Al dibujar: flags GFX_KEY, key = NOMBRE_KEY
    --clave R,G,B     además, ese color exacto también es transparente
    --difuminado      difuminado Floyd-Steinberg al reducir colores (fotos)

Genera:
    #define NOMBRE_W / NOMBRE_H / NOMBRE_STRIDE   tamaño (stride múltiplo de 4)
    #define NOMBRE_KEY                            índice transparente (-1 si no hay)
    static const uint8_t nombre[]                 índices de paleta, fila a fila
    #define NOMBRE_SURF                           surface lista para gfx_blit
  con --paleta propia, además:
    #define NOMBRE_PAL_BASE / NOMBRE_PAL_N
    static const uint32_t nombre_pal[]            colores 0x00RRGGBB
    static inline void nombre_pal_load(void)      la carga en la paleta del SoC

En C:
    #include "imagen.h"
    surface img = IMAGEN_SURF;
    imagen_pal_load();                                       // solo con paleta propia
    gfx_blit(&img, 0, 0, IMAGEN_W, IMAGEN_H, x, y, 0, 0);    // opaca
    gfx_blit(&img, 0, 0, IMAGEN_W, IMAGEN_H, x, y, GFX_KEY, IMAGEN_KEY);
    gfx_blit_scaled(&img, 0, 0, IMAGEN_W, IMAGEN_H, x, y, 2 * IMAGEN_W, 2 * IMAGEN_H, GFX_KEY, IMAGEN_KEY);
    (para hojas de sprites, elige el recuadro con sx/sy)

El array forma parte del programa, que se carga en la SDRAM, así que el blitter
lo lee directamente: no hace falta copiarlo.
"""
import argparse
import os
import re
import sys

from PIL import Image


def default_palette():
    """La misma paleta que gfx_palette_default() (sw/lib/gfx.c)."""
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
    """Índices en 'pal' (solo de 'first' en adelante) con PIL, con o sin difuminado."""
    usable = pal[first:]
    pimg = Image.new("P", (1, 1))
    flat = [v for c in usable for v in rgb(c)]
    flat += flat[-3:] * (256 - len(usable))            # rellenar con el último color
    pimg.putpalette(flat)
    q = img.quantize(palette=pimg, dither=Image.Dither.FLOYDSTEINBERG if dither else Image.Dither.NONE)
    return [first + min(v, len(usable) - 1) for v in pixels(q)]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("imagen")
    ap.add_argument("salida")
    ap.add_argument("--nombre")
    ap.add_argument("--ancho", type=int)
    ap.add_argument("--alto", type=int)
    ap.add_argument("--pixelado", action="store_true")
    ap.add_argument("--paleta", choices=("defecto", "propia"), default="defecto")
    ap.add_argument("--colores", type=int)
    ap.add_argument("--base", type=int, default=0)
    ap.add_argument("--transparente", action="store_true")
    ap.add_argument("--clave")
    ap.add_argument("--difuminado", action="store_true")
    a = ap.parse_args()

    nombre = a.nombre or os.path.splitext(os.path.basename(a.salida))[0]
    nombre = re.sub(r"\W", "_", nombre)
    if nombre[0].isdigit():
        nombre = "_" + nombre
    NOM = nombre.upper()

    im = Image.open(a.imagen).convert("RGBA")
    if a.ancho or a.alto:
        w0, h0 = im.size
        w = a.ancho or max(1, round(w0 * a.alto / h0))
        h = a.alto or max(1, round(h0 * a.ancho / w0))
        im = im.resize((w, h), Image.NEAREST if a.pixelado else Image.LANCZOS)
    w, h = im.size
    if w > 2048 or h > 2048:
        sys.exit(f"imagen demasiado grande ({w}x{h}); usa --ancho/--alto")

    clave = tuple(int(v) for v in a.clave.split(",")) if a.clave else None
    px = pixels(im)
    transp = [p[3] < 128 or (clave is not None and p[:3] == clave) for p in px]
    usa_key = a.transparente or clave is not None
    rgb_img = im.convert("RGB")

    pal_propia = None
    if a.paleta == "defecto":
        if a.base or a.colores:
            sys.exit("--base y --colores solo valen con --paleta propia")
        key = 0
        # con transparencia, el índice 0 queda reservado: el negro opaco sale por el 16 (también negro)
        idx = quantize_fixed(rgb_img, default_palette(), 1 if usa_key else 0, a.difuminado)
    else:
        base = a.base
        primero = base + (1 if usa_key else 0)
        maxc = 256 - primero
        n = a.colores or maxc
        if not 1 <= n <= maxc:
            sys.exit(f"--colores debe estar entre 1 y {maxc} (base {base})")
        opacos = [p[:3] for p, t in zip(px, transp) if not t] or [(0, 0, 0)]
        muestra = Image.new("RGB", (len(opacos), 1))
        muestra.putdata(opacos)
        q = muestra.quantize(colors=n, method=Image.Quantize.MEDIANCUT if n > 1 else Image.Quantize.MAXCOVERAGE)
        qp = q.getpalette()[:3 * n]
        cols = [(qp[3 * i] << 16) | (qp[3 * i + 1] << 8) | qp[3 * i + 2] for i in range(len(qp) // 3)]
        full = [0] * primero + cols
        idx = quantize_fixed(rgb_img, full, primero, a.difuminado)
        key = base
        pal_propia = ([0] if usa_key else []) + cols          # desde 'base'

    if usa_key:
        idx = [key if t else v for v, t in zip(idx, transp)]
    else:
        key = -1

    stride = (w + 3) & ~3
    filas = []
    for y in range(h):
        filas.append(idx[y * w:(y + 1) * w] + [key if key >= 0 else 0] * (stride - w))
    datos = [v for f in filas for v in f]

    guarda = "ASSET_" + NOM + "_INCLUDED"           # no puede ser NOMBRE_H: es la altura
    out = []
    out.append(f"// {os.path.basename(a.salida)} - generado por tools/img2c.py a partir de "
               f"{os.path.basename(a.imagen)}: {w}x{h}, 8 bpp")
    out.append(f"#ifndef {guarda}\n#define {guarda}\n#include <stdint.h>\n#include \"gfx.h\"\n")
    out.append(f"#define {NOM}_W      {w}")
    out.append(f"#define {NOM}_H      {h}")
    out.append(f"#define {NOM}_STRIDE {stride}")
    out.append(f"#define {NOM}_KEY    ({key})")
    if pal_propia is not None:
        out.append(f"#define {NOM}_PAL_BASE {a.base}")
        out.append(f"#define {NOM}_PAL_N    {len(pal_propia)}")
        out.append(f"\nstatic const uint32_t {nombre}_pal[{len(pal_propia)}] = {{")
        for i in range(0, len(pal_propia), 8):
            out.append("    " + ", ".join(f"0x{c:06X}" for c in pal_propia[i:i + 8]) + ",")
        out.append("};")
        out.append(f"static inline void {nombre}_pal_load(void)\n{{\n"
                   f"    for (int i = 0; i < {NOM}_PAL_N; i++) gfx_palette({NOM}_PAL_BASE + i, {nombre}_pal[i]);\n}}")
    out.append(f"\nstatic const uint8_t {nombre}[{len(datos)}] __attribute__((aligned(4))) = {{")
    for i in range(0, len(datos), 24):
        out.append("    " + ",".join(str(v) for v in datos[i:i + 24]) + ",")
    out.append("};")
    out.append(f"#define {NOM}_SURF ((surface){{ (uint32_t){nombre}, {NOM}_W, {NOM}_H, {NOM}_STRIDE }})")
    out.append(f"\n#endif")
    os.makedirs(os.path.dirname(os.path.abspath(a.salida)), exist_ok=True)
    with open(a.salida, "w", newline="\n") as f:
        f.write("\n".join(out) + "\n")

    usados = len(set(v for v, t in zip(idx, transp) if not t))
    print(f"{a.salida}: {nombre} {w}x{h} (stride {stride}), {len(datos)} bytes, "
          f"{usados} colores, paleta {a.paleta}"
          + (f" {a.base}..{a.base + len(pal_propia) - 1}" if pal_propia else "")
          + (f", transparente = {key}" if key >= 0 else ""))


if __name__ == "__main__":
    main()
