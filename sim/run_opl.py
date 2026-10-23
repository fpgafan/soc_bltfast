#!/usr/bin/env python3
"""
run_opl.py - Test of the OPL2 (rtl/audio/opl2.v) against the bit-exact model
(sim/oplmodel.py, validated against Nuked-OPL3).

  python run_opl.py [seed] [n_samples] [--musical]

By default it writes random registers (every combination); with
--musical it plays notes with reasonable instruments (audible envelopes,
vibrato, tremolo, feedback) to exercise the slow phases.
The gain is left at 0x40 (1.0) to compare with the chip's output.
"""
import os, sys, random, subprocess
from oplmodel import OPL2

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BUILD = os.path.join(HERE, "build")
OCS = r"C:\tools\oss-cad-suite"
os.environ["PATH"] = os.pathsep.join([os.path.join(OCS, "bin"), os.path.join(OCS, "lib"), os.environ["PATH"]])
SLOTREG = [0x20, 0x40, 0x60, 0x80, 0xE0]


def off(s):
    return s + 2 * (s // 6)


def gen_random(rng, n):
    ev = [(0, 0x01, 0x20)]
    for k in range(n):
        if rng.random() < 0.05:
            for _ in range(rng.randrange(1, 9)):
                t = rng.randrange(9)
                v = rng.randrange(256)
                if t < 5:
                    reg = SLOTREG[t] + off(rng.randrange(18))
                elif t == 5:
                    reg = 0xA0 + rng.randrange(9)
                elif t == 6:
                    reg = 0xB0 + rng.randrange(9)
                elif t == 7:
                    reg = 0xC0 + rng.randrange(9); v &= 0x0F
                else:
                    reg, v = rng.choice([(0x08, v & 0x40), (0xBD, v & 0xC0), (0x01, v & 0x20)])
                ev.append((k, reg, v))
    return ev


def gen_musical(rng, n):
    ev = [(0, 0x01, 0x20), (0, 0xBD, rng.choice([0, 0x40, 0x80, 0xC0])), (0, 0x08, rng.choice([0, 0x40]))]
    for ch in range(9):
        m = (ch // 3) * 6 + ch % 3
        for s in (m, m + 3):
            o = off(s)
            ev += [(0, 0x20 + o, rng.randrange(256)),
                   (0, 0x40 + o, rng.randrange(256) if s == m else rng.randrange(0, 0x20) | rng.randrange(4) << 6),
                   (0, 0x60 + o, rng.randrange(0x40, 0x100) | rng.randrange(1, 16) ),
                   (0, 0x80 + o, rng.randrange(256)),
                   (0, 0xE0 + o, rng.randrange(4))]
        ev.append((0, 0xC0 + ch, rng.randrange(16)))
    on = [0] * 9
    for k in range(n):
        if rng.random() < 0.004:
            ch = rng.randrange(9)
            f = rng.randrange(0x150, 0x2B0)
            b = rng.randrange(1, 7)
            if on[ch] and rng.random() < 0.6:
                ev.append((k, 0xB0 + ch, ((f >> 8) & 3) | (b << 2)))
                on[ch] = 0
            else:
                ev.append((k, 0xA0 + ch, f & 0xFF))
                ev.append((k, 0xB0 + ch, 0x20 | ((f >> 8) & 3) | (b << 2)))
                on[ch] = 1
    return ev


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    seed = int(args[0]) if args else 1
    n = int(args[1]) if len(args) > 1 else 3000
    musical = "--musical" in sys.argv
    rng = random.Random(seed)
    ev = gen_musical(rng, n) if musical else gen_random(rng, n)
    ev = [(0, 0x100, 0x40)] + ev                         # gain 1.0 (register +0x400)
    os.makedirs(BUILD, exist_ok=True)
    tag = "%s%d" % ("m" if musical else "r", seed)       # unique names: they can run in parallel
    fev = os.path.join(BUILD, "opl_ev_%s.txt" % tag)
    fout = os.path.join(BUILD, "opl_out_%s.txt" % tag)
    with open(fev, "w") as f:
        for k, r, d in ev:
            f.write("%d %x %x\n" % (k, r * 4, d))
    vvp = os.path.join(BUILD, "tb_opl_%s.vvp" % tag)
    subprocess.check_call(["iverilog", "-g2005", "-o", vvp, os.path.join(HERE, "tb", "tb_opl.v"),
                           os.path.join(ROOT, "rtl", "audio", "opl2.v")])
    r = subprocess.run(["vvp", "-n", vvp, "+ev=" + fev, "+out=" + fout, "+n=%d" % n],
                       capture_output=True, text=True)
    print(" ".join(l for l in r.stdout.splitlines() if l.startswith("OPL:")) or r.stderr)
    hw = [int(l, 16) for l in open(fout)]
    m = OPL2()
    bad, nz, i = 0, 0, 0
    for k in range(n):
        while i < len(ev) and ev[i][0] <= k:
            if ev[i][1] < 0x100:
                m.write(ev[i][1], ev[i][2])
            i += 1
        y = m.sample() & 0xFFFF
        nz += y != 0
        if k >= len(hw) or hw[k] != y:
            bad += 1
            if bad <= 10:
                print("sample %d: RTL %s model %04x" % (k, "%04x" % hw[k] if k < len(hw) else "-", y))
    print("OPL2 %s seed %d: %d samples (%d non-zero), %d differing -> %s"
          % ("musical" if musical else "random", seed, n, nz, bad, "OK" if bad == 0 else "BAD"))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
