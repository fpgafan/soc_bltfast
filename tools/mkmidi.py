#!/usr/bin/env python3
"""mkmidi.py - Genera una canción de demostración (SMF tipo 1, dominio público:
'Oda a la alegría' de Beethoven con bajo y batería) como array C en
sw/apps/demo/song.c, o convierte un .mid cualquiera:  mkmidi.py [fichero.mid]"""
import os, sys, struct

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def vlq(n):
    b = [n & 0x7F]
    n >>= 7
    while n:
        b.append(0x80 | (n & 0x7F)); n >>= 7
    return bytes(reversed(b))


def track(events):
    """events: lista de (tick_absoluto, bytes)"""
    events.sort(key=lambda e: (e[0], e[1][0] & 0xF0 == 0x90))
    out, last = b"", 0
    for t, ev in events:
        out += vlq(t - last) + ev
        last = t
    out += vlq(0) + b"\xff\x2f\x00"
    return b"MTrk" + struct.pack(">I", len(out)) + out


def song():
    Q = 240                       # ticks por negra
    N = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}
    def n(s):                     # "E4" -> nota MIDI
        return 12 * (int(s[-1]) + 1) + N[s[0]] + (1 if "#" in s else 0)
    # nota:duración en corcheas
    mel = ("E4:2 E4:2 F4:2 G4:2 G4:2 F4:2 E4:2 D4:2 C4:2 C4:2 D4:2 E4:2 E4:3 D4:1 D4:4 "
           "E4:2 E4:2 F4:2 G4:2 G4:2 F4:2 E4:2 D4:2 C4:2 C4:2 D4:2 E4:2 D4:3 C4:1 C4:4 "
           "D4:2 D4:2 E4:2 C4:2 D4:2 E4:1 F4:1 E4:2 C4:2 D4:2 E4:1 F4:1 E4:2 D4:2 C4:2 D4:2 G3:4 "
           "E4:2 E4:2 F4:2 G4:2 G4:2 F4:2 E4:2 D4:2 C4:2 C4:2 D4:2 E4:2 D4:3 C4:1 C4:4").split()
    t = 0
    lead, bass, drums = [], [], []
    lead.append((0, bytes([0xFF, 0x51, 0x03]) + struct.pack(">I", 500000)[1:]))   # 120 bpm
    lead.append((0, bytes([0xC0, 0x49])))          # flauta
    bass.append((0, bytes([0xC1, 0x21])))          # bajo
    lead.append((0, bytes([0xB0, 0x07, 0x64])))
    bass.append((0, bytes([0xB1, 0x07, 0x5A])))
    for tok in mel:
        nm, d = tok.split(":")
        dur = int(d) * Q // 2
        k = n(nm)
        lead.append((t, bytes([0x90, k, 100])))
        lead.append((t + dur - 10, bytes([0x80, k, 0])))
        t += dur
    total = t
    roots = [48, 43, 48, 43, 48, 43, 48, 43, 43, 48, 43, 48, 48, 43, 48, 43]
    bar = 4 * Q
    for i in range(total // bar + 1):
        r = roots[i % len(roots)]
        for b in range(4):
            tt = i * bar + b * Q
            if tt >= total:
                break
            nn = r if b % 2 == 0 else r + 7
            bass.append((tt, bytes([0x91, nn - 12, 90])))
            bass.append((tt + Q - 20, bytes([0x81, nn - 12, 0])))
            drums.append((tt, bytes([0x99, 36 if b % 2 == 0 else 38, 110])))
            drums.append((tt + Q // 2, bytes([0x99, 42, 70])))
            drums.append((tt + 60, bytes([0x89, 36 if b % 2 == 0 else 38, 0])))
    hdr = b"MThd" + struct.pack(">IHHH", 6, 1, 3, Q)
    return hdr + track(lead) + track(bass) + track(drums)


def main():
    data = open(sys.argv[1], "rb").read() if len(sys.argv) > 1 else song()
    out = os.path.join(ROOT, "sw", "apps", "demo", "song.c")
    with open(out, "w") as f:
        f.write("// canción de demostración (generada por tools/mkmidi.py)\n#include <stdint.h>\n")
        f.write(f"const uint32_t song_len = {len(data)};\n")
        f.write("const uint8_t song[] = {\n")
        for i in range(0, len(data), 16):
            f.write("  " + ", ".join("0x%02x" % b for b in data[i:i + 16]) + ",\n")
        f.write("};\n")
    open(os.path.join(ROOT, "sw", "build", "demo_song.mid"), "wb").write(data)
    print(f"{out}: {len(data)} bytes")


if __name__ == "__main__":
    main()
