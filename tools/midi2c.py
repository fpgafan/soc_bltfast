#!/usr/bin/env python3
"""
midi2c.py - Convierte un fichero MIDI (.mid) a una cabecera C para el
reproductor MIDI del SoC bltfast (sw/lib/midi.c).

    python tools/midi2c.py cancion.mid sw/apps/mi_app/cancion.h [opciones]

El reproductor del SoC lee MIDI estándar directamente (tipo 0 y 1, hasta 32
pistas, cambios de tempo, programas General MIDI, volumen, expresión, pan y
pitch bend; batería en el canal 10) y lo toca con 24 voces de hardware, así que
el fichero se guarda tal cual. Esta herramienta lo comprueba, informa de lo que
puede dar problemas y, si se pide, lo modifica:

    --nombre N          nombre del array (por defecto, el del archivo .h)
    --transponer S      subir/bajar S semitonos (no afecta a la batería)
    --sin-bateria       quitar el canal 10
    --canales 1,2,3     quedarse solo con esos canales (1..16)
    --tempo F           multiplicar la velocidad por F (1.5 = un 50 % más rápido)
    --max-seg S         cortar a los S segundos
    --vol V             escalar las velocidades de las notas (1.0 = igual)

Genera:
    #define NOMBRE_LEN   bytes
    #define NOMBRE_SEG   duración aproximada en segundos
    static const uint8_t nombre[]   el fichero SMF

En C:
    #include "cancion.h"
    snd_init();
    if (midi_load(cancion, CANCION_LEN) == 0) midi_play(1);     // 1 = en bucle
    for (;;) { midi_update(); ... }                             // a menudo (>= 200 Hz)
"""
import argparse
import os
import re
import struct
import sys

MIDI_VOICES = 24        # sw/lib/audio.h
MAXTRK = 32             # sw/lib/midi.c
DRUM_CH = 9

GM_FAMILIA = ["piano", "percusión cromática", "órgano", "guitarra", "bajo", "cuerdas",
              "conjunto", "metales", "lengüetas", "flautas", "sintetizador solista",
              "sintetizador de fondo", "efectos de sintetizador", "étnicos", "percusión", "efectos"]


def varlen(d, i):
    v = 0
    while True:
        b = d[i]; i += 1
        v = (v << 7) | (b & 0x7F)
        if not b & 0x80:
            return v, i


def vlq(n):
    b = [n & 0x7F]
    n >>= 7
    while n:
        b.append(0x80 | (n & 0x7F)); n >>= 7
    return bytes(reversed(b))


def leer_smf(data):
    """Devuelve (formato, división, pistas); cada pista es una lista de
    (tick_absoluto, bytes_del_evento) con el estado explícito."""
    if data[:4] != b"MThd":
        sys.exit("no es un fichero MIDI estándar (falta MThd)")
    hl, fmt, ntrk, div = struct.unpack(">IHHH", data[4:14])
    if div & 0x8000:
        sys.exit("división SMPTE: el reproductor del SoC no la admite")
    if fmt == 2:
        sys.exit("MIDI de tipo 2 (pistas independientes): no admitido")
    i = 8 + hl
    pistas = []
    while i + 8 <= len(data):
        tipo, l = data[i:i + 4], struct.unpack(">I", data[i + 4:i + 8])[0]
        j, fin = i + 8, min(i + 8 + l, len(data))
        i += 8 + l
        if tipo != b"MTrk":
            continue
        ev, t, run = [], 0, 0
        while j < fin:
            dt, j = varlen(data, j)
            t += dt
            st = data[j]
            if st & 0x80:
                j += 1
                if st < 0xF0:
                    run = st
            else:
                if not run:
                    sys.exit("fichero dañado: datos sin byte de estado")
                st = run
            if st == 0xFF:
                typ = data[j]
                l2, k = varlen(data, j + 1)
                ev.append((t, bytes([0xFF, typ]) + vlq(l2) + data[k:k + l2]))
                j = k + l2
                if typ == 0x2F:
                    break
            elif st in (0xF0, 0xF7):
                l2, k = varlen(data, j)
                ev.append((t, bytes([st]) + vlq(l2) + data[k:k + l2]))
                j = k + l2
            else:
                n = 1 if st & 0xF0 in (0xC0, 0xD0) else 2
                ev.append((t, bytes([st]) + data[j:j + n]))
                j += n
        pistas.append(ev)
    if not pistas:
        sys.exit("el fichero no tiene pistas")
    return fmt, div, pistas


def mapa_tempo(pistas):
    cambios = sorted((t, int.from_bytes(e[3:6], "big")) for p in pistas for t, e in p
                     if e[0] == 0xFF and e[1] == 0x51 and len(e) >= 6)
    return cambios


def tick_a_seg(tick, cambios, div):
    seg, t0, us = 0.0, 0, 500000
    for t, nuevo in cambios:
        if t >= tick:
            break
        seg += (t - t0) * us / div / 1e6
        t0, us = t, nuevo
    return seg + (tick - t0) * us / div / 1e6


def seg_a_tick(s, cambios, div):
    t0, us, acc = 0, 500000, 0.0
    for t, nuevo in cambios:
        d = (t - t0) * us / div / 1e6
        if acc + d >= s:
            break
        acc += d
        t0, us = t, nuevo
    return t0 + int((s - acc) * 1e6 * div / us)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("midi")
    ap.add_argument("salida")
    ap.add_argument("--nombre")
    ap.add_argument("--transponer", type=int, default=0)
    ap.add_argument("--sin-bateria", action="store_true")
    ap.add_argument("--canales")
    ap.add_argument("--tempo", type=float, default=1.0)
    ap.add_argument("--max-seg", type=float, default=0)
    ap.add_argument("--vol", type=float, default=1.0)
    a = ap.parse_args()

    nombre = re.sub(r"\W", "_", a.nombre or os.path.splitext(os.path.basename(a.salida))[0])
    if nombre[0].isdigit():
        nombre = "_" + nombre
    NOM = nombre.upper()

    data = open(a.midi, "rb").read()
    fmt, div, pistas = leer_smf(data)
    canales = {int(c) - 1 for c in a.canales.split(",")} if a.canales else None
    if a.tempo <= 0:
        sys.exit("--tempo debe ser > 0")
    modificar = bool(a.transponer or a.sin_bateria or canales is not None or a.tempo != 1.0
                     or a.max_seg or a.vol != 1.0)

    if modificar:
        corte = seg_a_tick(a.max_seg * a.tempo, mapa_tempo(pistas), div) if a.max_seg else None
        nuevas = []
        for k, p in enumerate(pistas):
            q = []
            for t, e in p:
                if corte is not None and t > corte:
                    break
                st = e[0]
                if st == 0xFF and e[1] == 0x2F:
                    continue
                if st == 0xFF and e[1] == 0x51 and len(e) >= 6:
                    us = max(1, min(0xFFFFFF, round(int.from_bytes(e[3:6], "big") / a.tempo)))
                    e = e[:3] + us.to_bytes(3, "big")
                elif st < 0xF0:
                    c = st & 15
                    if (canales is not None and c not in canales) or (a.sin_bateria and c == DRUM_CH):
                        continue
                    if st & 0xF0 in (0x80, 0x90, 0xA0) and c != DRUM_CH and a.transponer:
                        n = e[1] + a.transponer
                        if not 0 <= n <= 127:
                            continue
                        e = bytes([st, n]) + e[2:]
                    if st & 0xF0 == 0x90 and e[2] and a.vol != 1.0:
                        e = e[:2] + bytes([max(1, min(127, round(e[2] * a.vol)))])
                q.append((t, e))
            if a.tempo != 1.0 and k == 0 and not any(e[0] == 0xFF and e[1] == 0x51 for _, e in q):
                q.insert(0, (0, b"\xff\x51\x03" + round(500000 / a.tempo).to_bytes(3, "big")))
            if corte is not None:                       # apagar lo que siga sonando
                for c in sorted({e[0] & 15 for _, e in q if e[0] < 0xF0}):
                    q.append((corte, bytes([0xB0 | c, 123, 0])))
            fin = max([t for t, _ in q], default=0)
            q.append((fin, b"\xff\x2f\x00"))
            nuevas.append(q)
        pistas = nuevas
        out = b"MThd" + struct.pack(">IHHH", 6, 1 if len(pistas) > 1 else 0, len(pistas), div)
        for p in pistas:
            body, last = b"", 0
            for t, e in p:
                body += vlq(t - last) + e
                last = t
            out += b"MTrk" + struct.pack(">I", len(body)) + body
        data = out

    # ------------------------------------------------------------ informe
    cambios = mapa_tempo(pistas)
    ev = sorted(((t, e) for p in pistas for t, e in p if e[0] < 0xF0), key=lambda x: x[0])
    notas, activas, maxpoli, progs, bend = 0, set(), 0, {}, False
    usados = set()
    for t, e in ev:
        st, c = e[0] & 0xF0, e[0] & 15
        if st == 0x90 and e[2]:
            usados.add(c)
            notas += 1
            if c != DRUM_CH:
                activas.add((c, e[1]))
                maxpoli = max(maxpoli, len(activas))
        elif st == 0x80 or (st == 0x90 and not e[2]):
            activas.discard((c, e[1]))
        elif st == 0xC0:
            progs.setdefault(c, e[1])
        elif st == 0xE0:
            bend = True
    fin = max((t for p in pistas for t, _ in p), default=0)
    dur = tick_a_seg(fin, cambios, div)

    guarda = "ASSET_" + NOM + "_INCLUDED"
    lines = [f"// {os.path.basename(a.salida)} - generado por tools/midi2c.py a partir de "
             f"{os.path.basename(a.midi)}",
             f"// {len(pistas)} pistas, {notas} notas, {dur:.1f} s"
             + (" (modificado)" if modificar else ""),
             f"#ifndef {guarda}\n#define {guarda}\n#include <stdint.h>\n",
             f"#define {NOM}_LEN {len(data)}",
             f"#define {NOM}_SEG {round(dur)}\n",
             f"static const uint8_t {nombre}[{len(data)}] __attribute__((aligned(4))) = {{"]
    for i in range(0, len(data), 16):
        lines.append("    " + ",".join(f"0x{b:02x}" for b in data[i:i + 16]) + ",")
    lines.append("};\n\n#endif")
    os.makedirs(os.path.dirname(os.path.abspath(a.salida)), exist_ok=True)
    with open(a.salida, "w", newline="\n") as f:
        f.write("\n".join(lines) + "\n")

    print(f"{a.salida}: {nombre}, {len(data)} bytes, MIDI tipo {1 if len(pistas) > 1 else fmt}, "
          f"{len(pistas)} pistas, {notas} notas, {dur:.1f} s")
    for c in sorted(usados):
        if c == DRUM_CH:
            print(f"  canal 10: batería")
        else:
            p = progs.get(c, 0)
            print(f"  canal {c + 1}: programa {p + 1} ({GM_FAMILIA[p // 8]})")
    print(f"  polifonía máxima (sin batería): {maxpoli} notas a la vez")
    if maxpoli > MIDI_VOICES:
        print(f"  AVISO: más de {MIDI_VOICES} notas a la vez; el reproductor robará voces")
    if len(pistas) > MAXTRK:
        print(f"  AVISO: {len(pistas)} pistas; el reproductor solo lee las {MAXTRK} primeras")
    if bend:
        print("  usa pitch bend (el SoC lo aplica con ±2 semitonos)")


if __name__ == "__main__":
    main()
