#!/usr/bin/env python3
"""
wav2pcm.py - Convierte un WAV a PCM crudo para el motor de sonido.

  python wav2pcm.py entrada.wav salida.raw [--8bit] [--mono] [--c nombre]

Salida: 16 bits con signo (o 8 bits con --8bit), mono o estéreo intercalado
(L,R), a la frecuencia original (el motor la ajusta con el PITCH:
pitch = rate * 65536 / 48000). Imprime la frecuencia y el número de tramas.
"""
import sys, wave, struct, argparse


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("wav"); ap.add_argument("out")
    ap.add_argument("--8bit", dest="b8", action="store_true")
    ap.add_argument("--mono", action="store_true")
    ap.add_argument("--c")
    a = ap.parse_args()
    w = wave.open(a.wav)
    ch, sw, rate, n = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
    raw = w.readframes(n)
    frames = []
    for i in range(n):
        s = []
        for c in range(ch):
            o = (i * ch + c) * sw
            if sw == 1:
                v = (raw[o] - 128) << 8
            elif sw == 2:
                v = struct.unpack_from("<h", raw, o)[0]
            else:
                v = int.from_bytes(raw[o:o + sw], "little", signed=True) >> (8 * (sw - 2))
            s.append(v)
        if a.mono or ch == 1:
            s = [sum(s) // len(s)]
        else:
            s = s[:2]
        frames.append(s)
    out = bytearray()
    for s in frames:
        for v in s:
            out += struct.pack("<b", v >> 8) if a.b8 else struct.pack("<h", v)
    fmt = ("S8" if a.b8 else "S16") + ("ST" if len(frames[0]) == 2 else "")
    if a.c:
        with open(a.out + ".c", "w") as f:
            f.write(f"#include <stdint.h>\n// formato AUD_FMT_{fmt}, {rate} Hz\n")
            f.write(f"const uint32_t {a.c}_frames = {n}, {a.c}_rate = {rate};\n")
            f.write(f"const uint8_t {a.c}[{len(out)}] __attribute__((aligned(4))) = {{\n")
            for i in range(0, len(out), 24):
                f.write("  " + ", ".join(str(v) for v in out[i:i + 24]) + ",\n")
            f.write("};\n")
    else:
        open(a.out, "wb").write(out)
    print(f"{n} tramas, {rate} Hz, formato AUD_FMT_{fmt}, {len(out)} bytes")


if __name__ == "__main__":
    main()
