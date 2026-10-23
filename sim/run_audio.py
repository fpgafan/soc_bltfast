#!/usr/bin/env python3
"""
run_audio.py - Test of the sound engine against a bit-exact model.

  python run_audio.py [seed] [n_samples] [--vid]

32 voices with random parameters (formats, loops, pitches from 0.05x to 6x,
ADSR, volumes) and KEYON/KEYOFF/STOP at random moments.
"""
import os, sys, random, struct, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BUILD = os.path.join(HERE, "build")
OCS = r"C:\tools\oss-cad-suite"
os.environ["PATH"] = os.pathsep.join([os.path.join(OCS, "bin"), os.path.join(OCS, "lib"), os.environ["PATH"]])
MEMW = 1 << 18             # initialized words (1 MB)


def s16(x):
    x &= 0xFFFF
    return x - 0x10000 if x & 0x8000 else x


def s32(x):
    x &= 0xFFFFFFFF
    return x - (1 << 32) if x & 0x80000000 else x


class Model:
    def __init__(self, mem):
        self.mem = mem
        self.p = [[0] * 8 for _ in range(32)]
        self.pos = [0] * 32; self.frac = [0] * 32; self.ph = [0] * 32; self.env = [0] * 32
        self.active = [0] * 32
        self.kon = [0] * 32; self.koff = [0] * 32; self.stop = [0] * 32
        self.mvol, self.en = 0x80, 1
        self.ev = 0

    def write(self, off, d):
        if off < 0x400:
            self.p[off >> 5][(off >> 2) & 7] = d
        elif off == 0x800:
            self.mvol, self.en = d & 255, (d >> 8) & 1
        elif off in (0x804, 0x808, 0x81C):
            arr = {0x804: self.kon, 0x808: self.koff, 0x81C: self.stop}[off]
            for v in range(32):
                if d >> v & 1:
                    arr[v] = 1
        elif off == 0x810:
            self.ev &= ~d

    def word(self, byte_addr):
        return self.mem[(byte_addr >> 2) % (1 << 21)] if (byte_addr >> 2) % (1 << 21) < len(self.mem) else 0

    @staticmethod
    def samp(w, ba, fm):
        h = (w >> 16) & 0xFFFF if ba & 2 else w & 0xFFFF
        sh = (ba & 3) * 8
        b = (w >> sh) & 0xFF
        if fm == 0:
            l = r = s16(b << 8)
        elif fm == 1:
            l = r = s16(h)
        elif fm == 2:
            l, r = s16(w), s16(w >> 16)
        else:
            l, r = s16((h & 0xFF) << 8), s16(h & 0xFF00)
        return l, r

    @staticmethod
    def fofs(f, fm):
        return f if fm == 0 else (f * 2 if fm in (1, 3) else f * 4)

    @staticmethod
    def rate(r):
        return (16 + (r & 15)) << (r >> 4)

    def tick(self):
        if not self.en:
            return 0, 0
        accl = accr = 0
        for v in range(32):
            if not (self.active[v] or self.kon[v]):
                self.stop[v] = 0; self.koff[v] = 0
                continue
            von = 1
            if self.kon[v]:
                self.pos[v] = self.frac[v] = self.env[v] = self.ph[v] = 0
                self.kon[v] = self.koff[v] = self.stop[v] = 0
            elif self.stop[v]:
                von = 0
                self.stop[v] = self.koff[v] = 0
            elif self.koff[v]:
                self.ph[v] = 3
                self.koff[v] = 0
            if not von:
                self.active[v] = 0
                continue
            p = self.p[v]
            ctrl, start, ln, lp = p[0] & 31, p[1] & 0x7FFFFF, p[2] & 0xFFFFFF, p[3] & 0xFFFFFF
            pitch, vl, vr = p[4], p[5] & 255, (p[5] >> 8) & 255
            ar, dr, sl, rr = p[6] & 255, (p[6] >> 8) & 255, (p[6] >> 16) & 255, (p[6] >> 24) & 255
            fm = ctrl & 3
            pos, frac = self.pos[v], self.frac[v]
            if pos + 1 >= ln:
                f1 = lp if ctrl & 4 else pos
            else:
                f1 = pos + 1
            ad0 = (start + self.fofs(pos, fm)) & 0x7FFFFF
            ad1 = (start + self.fofs(f1, fm)) & 0x7FFFFF
            l0, r0 = self.samp(self.word(ad0), ad0 & 3, fm)
            l1, r1 = self.samp(self.word(ad1), ad1 & 3, fm)
            dl = (l1 - l0) if ctrl & 8 else 0
            dr_ = (r1 - r0) if ctrl & 8 else 0
            il = s16(l0 + ((dl * frac) >> 16))
            ir = s16(r0 + ((dr_ * frac) >> 16))
            env = self.env[v]
            gl = ((env >> 8) * vl) >> 8
            gr = ((env >> 8) * vr) >> 8
            accl += (il * gl) >> 16
            accr += (ir * gr) >> 16
            span = (ln - lp) & 0xFFFFFF
            pn = (((pos << 16) | frac) + pitch) & ((1 << 40) - 1)
            pw = ((((pos - span) & 0xFFFFFF) << 16 | frac) + pitch) & ((1 << 40) - 1)
            if (pn >> 16) >= ln:
                if ctrl & 4:
                    self.pos[v] = lp if (pw >> 16) >= ln else (pw >> 16)
                    self.frac[v] = pn & 0xFFFF
                else:
                    von = 0
                if ctrl & 16:
                    self.ev |= 1 << v
            else:
                self.pos[v], self.frac[v] = pn >> 16, pn & 0xFFFF
            sus = sl << 16
            ph = self.ph[v]
            if ph == 0:
                e = env + self.rate(ar)
                if e >= 0xFFFFFF:
                    self.env[v], self.ph[v] = 0xFFFFFF, 1
                else:
                    self.env[v] = e
            elif ph == 1:
                e = env - self.rate(dr)
                if e < 0 or e <= sus:
                    self.env[v], self.ph[v] = sus, 2
                else:
                    self.env[v] = e
            elif ph == 2:
                self.env[v] = sus
            else:
                e = env - self.rate(rr)
                if e <= 0:
                    self.env[v] = 0
                    von = 0
                else:
                    self.env[v] = e
            self.active[v] = von
        ml = (accl * self.mvol) >> 7
        mr = (accr * self.mvol) >> 7
        sat = lambda x: max(-32768, min(32767, x)) & 0xFFFF
        return sat(ml), sat(mr)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    seed = int(args[0]) if args else 1
    n = int(args[1]) if len(args) > 1 else 300
    rng = random.Random(seed)
    mem = [rng.randrange(1 << 32) for _ in range(MEMW)]
    with open(os.path.join(BUILD, "aud_init.hex"), "w") as f:
        for w in mem:
            f.write("%08x\n" % w)
    evs = []
    for v in range(32):
        fm = rng.randrange(4)
        ctrl = fm | (rng.random() < 0.6) * 4 | (rng.random() < 0.8) * 8 | (rng.random() < 0.5) * 16
        ln = rng.choice([rng.randrange(2, 40), rng.randrange(40, 3000)])
        lp = rng.randrange(0, ln)
        pitch = rng.choice([0x10000, rng.randrange(0x800, 0x60000), rng.randrange(0x100, 0x2000)])
        regs = [ctrl, rng.randrange(0, (1 << 20) - 16000), ln, lp, pitch,
                rng.randrange(1 << 16), rng.randrange(1 << 32), 0]
        for i, d in enumerate(regs):
            evs.append((0, v * 32 + i * 4, d))
    evs.append((0, 0x800, 0x100 | rng.choice([0x80, 0x20, 0xFF])))
    for k in range(n):
        if rng.random() < 0.15:
            evs.append((k, 0x804, rng.randrange(1 << 32) & rng.randrange(1 << 32)))
        if rng.random() < 0.08:
            evs.append((k, 0x808, rng.randrange(1 << 32) & rng.randrange(1 << 32)))
        if rng.random() < 0.03:
            evs.append((k, 0x81C, 1 << rng.randrange(32)))
        if rng.random() < 0.05:                        # change the pitch of a voice
            v = rng.randrange(32)
            evs.append((k, v * 32 + 16, rng.randrange(0x800, 0x40000)))
    evs.sort(key=lambda e: e[0])
    with open(os.path.join(BUILD, "aud_ev.txt"), "w") as f:
        for k, o, d in evs:
            f.write("%d %x %x\n" % (k, o, d))
    model = Model(mem)
    exp = []
    ei = 0
    for k in range(n):
        while ei < len(evs) and evs[ei][0] <= k:
            model.write(evs[ei][1], evs[ei][2]); ei += 1
        exp.append(model.tick())

    vvp = os.path.join(BUILD, "tb_audio.vvp")
    srcs = [os.path.join(ROOT, p) for p in ("rtl/audio/audio.v", "rtl/mem/sdram_ctrl.v",
                                            "sim/models/sdram_model.v", "sim/tb/tb_audio.v")]
    subprocess.check_call(["iverilog", "-g2012", "-DSIM", "-o", vvp, "-s", "tb_audio"] + srcs)
    extra = ["+vid"] if "--vid" in sys.argv else []
    r = subprocess.run(["vvp", "-n", vvp, "+ev=aud_ev.txt", "+init=aud_init.hex",
                        "+out=aud_out.txt", f"+n={n}"] + extra, cwd=BUILD, capture_output=True, text=True)
    lines = r.stdout.strip().splitlines()
    print("\n".join(l for l in lines if "AUDIO" in l or "WARNING" in l)[:2000])
    got = []
    for l in open(os.path.join(BUILD, "aud_out.txt")):
        w = int(l, 16)
        got.append((w & 0xFFFF, w >> 16))
    bad = [k for k in range(n) if k >= len(got) or got[k] != exp[k]]
    if bad:
        k = bad[0]
        print(f"FAIL: {len(bad)} differing samples; first {k}: rtl={got[k] if k < len(got) else None} ref={exp[k]}")
        sys.exit(1)
    nz = sum(1 for e in exp if e != (0, 0))
    print(f"PASS seed={seed} samples={n} (non-zero: {nz})")


if __name__ == "__main__":
    main()
