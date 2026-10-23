#!/usr/bin/env python3
"""
run_blit.py - Random test of the blitter against a reference model.

  python run_blit.py [seed] [n_commands] [--vid]

Generates random commands (FILL, BLIT with scaling/mirroring/transparency/
palette, EXPAND 1 bpp, LINE) with clipping, runs them on the RTL (Icarus) and
compares the first MB of SDRAM with the model byte by byte.
"""
import os, sys, random, subprocess, struct

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BUILD = os.path.join(HERE, "build")
OCS = r"C:\tools\oss-cad-suite"
os.environ["PATH"] = os.pathsep.join([os.path.join(OCS, "bin"), os.path.join(OCS, "lib"), os.environ["PATH"]])
os.makedirs(BUILD, exist_ok=True)

MEMB = 1 << 23
REGION = 1 << 20           # the first MB is compared


def s32(x):
    x &= 0xFFFFFFFF
    return x - (1 << 32) if x & 0x80000000 else x


def s16(x):
    x &= 0xFFFF
    return x - 0x10000 if x & 0x8000 else x


class Model:
    def __init__(self, mem):
        self.m = mem

    def rd(self, a):
        return self.m[a % MEMB]

    def wr(self, a, v):
        self.m[a % MEMB] = v & 0xFF

    def run(self, r, cmd):
        op = cmd & 15
        f_tr, f_bgtr, f_pal = (cmd >> 4) & 1, (cmd >> 5) & 1, (cmd >> 6) & 1
        dbase, dstr = r[1] & 0x7FFFFF, r[2] & 0xFFFF
        cx0, cy0 = s16(r[3]), s16(r[3] >> 16)
        cx1, cy1 = s16(r[4]), s16(r[4] >> 16)
        src, sstr = r[5] & 0x7FFFFF, r[6] & 0xFFFF
        dx, dy = s16(r[7]), s16(r[7] >> 16)
        w, h = s16(r[8]), s16(r[8] >> 16)
        fg, bg, key, pal = r[9] & 255, (r[9] >> 8) & 255, (r[9] >> 16) & 255, (r[9] >> 24) & 255
        u0, v0, du, dv = s32(r[10]), s32(r[11]), s32(r[12]), s32(r[13])
        if op == 3:
            self.line(dbase, dstr, cx0, cy0, cx1, cy1, dx, dy, w, h, fg)
            return
        vx0, vy0 = max(dx, cx0), max(dy, cy0)
        vx1, vy1 = min(dx + w, cx1), min(dy + h, cy1)
        if vx0 >= vx1 or vy0 >= vy1:
            return
        vw = vx1 - vx0
        u_st = s32(u0 + (vx0 - dx) * du)
        v = s32(v0 + (vy0 - dy) * dv)
        drow = (dbase + vy0 * dstr + vx0) % MEMB
        for y in range(vy0, vy1):
            row = s32(v) >> 16
            srow = (src + s32(row * sstr)) % MEMB
            for i in range(vw):
                u = s32(u_st + i * du)
                if op == 0:
                    c, tr = fg, False
                elif op == 1:
                    t = self.rd(srow + (u >> 16))
                    tr = bool(f_tr) and t == key
                    c = (t + pal) & 255 if f_pal else t
                else:
                    b = u >> 16
                    byte = self.rd(srow + (b >> 3))
                    bit = (byte >> (7 - (b & 7))) & 1
                    c = fg if bit else bg
                    tr = (not bit) and bool(f_bgtr)
                if not tr:
                    self.wr(drow + i, c)
            v = s32(v + dv)
            drow = (drow + dstr) % MEMB

    def line(self, dbase, dstr, cx0, cy0, cx1, cy1, x, y, x1, y1, fg):
        dxa = abs(x1 - x)
        dya = -abs(y1 - y)
        sx = 1 if x1 > x else -1
        sy = 1 if y1 > y else -1
        err = dxa + dya
        while True:
            if cx0 <= x < cx1 and cy0 <= y < cy1:
                self.wr(dbase + y * dstr + x, fg)
            if x == x1 and y == y1:
                break
            e2 = 2 * err
            if e2 >= dya:
                err += dya
                x += sx
            if e2 <= dxa:
                err += dxa
                y += sy


def gen(rng, n):
    cmds = []
    for _ in range(n):
        r = [0] * 14
        op = rng.choice([0, 1, 1, 1, 2, 3])
        dst = rng.choice([0x40000, 0x40000 + rng.randrange(0, 4096)])
        dstr = rng.choice([640, 1024, 700, 512])
        r[1], r[2] = dst, dstr
        cx0, cy0 = rng.randrange(0, 40), rng.randrange(0, 40)
        cx1, cy1 = rng.randrange(cx0, min(dstr, 900)), rng.randrange(cy0, 300)
        if rng.random() < 0.3:
            cx0, cy0, cx1, cy1 = 0, 0, min(dstr, 640), 300
        r[3] = (cx0 & 0xFFFF) | (cy0 << 16)
        r[4] = (cx1 & 0xFFFF) | (cy1 << 16)
        dx, dy = rng.randrange(-60, 700), rng.randrange(-60, 320)
        w, h = rng.randrange(1, 300), rng.randrange(1, 80)
        if rng.random() < 0.2:
            w = rng.randrange(1, 9)
        flags = 0
        if op in (1, 2):
            src = rng.randrange(0, 0x30000)
            sstr = rng.choice([64, 128, 256, 333, 640, 1024])
            r[5], r[6] = src, sstr
            mode = rng.choice(["copy", "flip", "scale", "scale", "down"])
            if mode == "copy":
                du, dv, u0, v0 = 0x10000, 0x10000, 0, 0
            elif mode == "flip":
                du, dv = -0x10000, rng.choice([0x10000, -0x10000])
                u0, v0 = (w - 1) << 16, (h - 1) << 16 if dv < 0 else 0
            elif mode == "scale":
                du = rng.choice([1, -1]) * rng.randrange(0x2000, 0x10001)
                dv = rng.choice([1, -1]) * rng.randrange(0x2000, 0x20000)
                u0, v0 = rng.randrange(0, 200 << 16), rng.randrange(0, 50 << 16)
            else:
                du = rng.choice([1, -1]) * rng.randrange(0x10001, 0x40000)
                dv = rng.randrange(0x8000, 0x30000)
                u0, v0 = rng.randrange(0, 200 << 16), rng.randrange(0, 50 << 16)
            if op == 2:
                du = rng.choice([0x10000, 0x10000, 0x8000, 0x20000, -0x10000])
            # limit the source span to 2044 bytes
            span = abs(du) * w >> 16
            if op == 2:
                span >>= 3
            if span > 2000:
                w = max(1, (2000 << 16) // max(1, abs(du)) - 1)
                if op == 2:
                    w = max(1, w * 8 - 8)
            r[10], r[11], r[12], r[13] = u0 & 0xFFFFFFFF, v0 & 0xFFFFFFFF, du & 0xFFFFFFFF, dv & 0xFFFFFFFF
            if rng.random() < 0.5:
                flags |= 0x10
            if rng.random() < 0.3:
                flags |= 0x40
            if op == 2 and rng.random() < 0.5:
                flags |= 0x20
        else:
            r[10], r[11], r[12], r[13] = 0, 0, 0x10000, 0x10000
        if op == 3:
            w, h = rng.randrange(-60, 700), rng.randrange(-60, 320)    # extreme
        r[7] = (dx & 0xFFFF) | ((dy & 0xFFFF) << 16)
        r[8] = (w & 0xFFFF) | ((h & 0xFFFF) << 16)
        r[9] = rng.randrange(1 << 32)
        cmds.append((r, op | flags))
    return cmds


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    seed = int(args[0]) if args else 1
    n = int(args[1]) if len(args) > 1 else 40
    rng = random.Random(seed)
    mem = bytearray(rng.randrange(256) for _ in range(REGION))
    mem += bytearray(MEMB - REGION)
    with open(os.path.join(BUILD, "blit_init.hex"), "w") as f:
        for i in range(0, REGION, 4):
            f.write("%08x\n" % struct.unpack_from("<I", mem, i)[0])
    cmds = gen(rng, n)
    upto = [int(a.split("=")[1]) for a in sys.argv if a.startswith("--upto=")]
    only = [int(a.split("=")[1]) for a in sys.argv if a.startswith("--only=")]
    if upto:
        cmds = cmds[:upto[0]]
    if only:
        cmds = [cmds[only[0]]]
        r, c = cmds[0]
        print("op", c & 15, "flags", hex(c & 0xF0), "dst", hex(r[1]), "dstr", r[2],
              "clip", [s16(r[3]), s16(r[3] >> 16), s16(r[4]), s16(r[4] >> 16)],
              "src", hex(r[5]), r[6], "dxy", s16(r[7]), s16(r[7] >> 16), "wh", s16(r[8]), s16(r[8] >> 16),
              "col", hex(r[9]), "u0", hex(r[10]), "v0", hex(r[11]), "du", s32(r[12]), "dv", s32(r[13]))
    with open(os.path.join(BUILD, "blit_cmds.txt"), "w") as f:
        for r, c in cmds:
            for i in range(1, 14):
                f.write("W %02x %08x\n" % (i * 4, r[i]))
            f.write("W 38 %08x\n" % c)
            if rng.random() < 0.1:
                f.write("I\n")
    model = Model(mem)
    for r, c in cmds:
        model.run(r, c)

    vvp = os.path.join(BUILD, "tb_blit.vvp")
    srcs = [os.path.join(ROOT, p) for p in ("rtl/video/blitter.v", "rtl/mem/sdram_ctrl.v",
                                            "sim/models/sdram_model.v", "sim/tb/tb_blit.v")]
    subprocess.check_call(["iverilog", "-g2012", "-DSIM", "-o", vvp, "-s", "tb_blit"] + srcs)
    extra = ["+vid"] if "--vid" in sys.argv else []
    dumpf = os.path.join(BUILD, "blit_dump.hex")
    if os.path.exists(dumpf):
        os.remove(dumpf)
    r = subprocess.run(["vvp", "-n", vvp, "+cmds=blit_cmds.txt", "+init=blit_init.hex",
                        "+dump=blit_dump.hex"] + extra, cwd=BUILD, capture_output=True, text=True)
    out = r.stdout.strip()
    print(out.splitlines()[-2] if out else r.stderr)
    if "TIMEOUT" in out:
        print("FAIL: TIMEOUT")
        sys.exit(1)
    got = bytearray()
    for line in open(os.path.join(BUILD, "blit_dump.hex")):
        line = line.strip()
        if not line or line.startswith("/") or line.startswith("@"):
            continue
        got += struct.pack("<I", int(line, 16))
    bad = [i for i in range(REGION) if got[i] != model.m[i]]
    if bad:
        print(f"FAIL: {len(bad)} differing bytes; first ones:",
              ", ".join(f"{b:#x}: rtl={got[b]:02x} ref={model.m[b]:02x}" for b in bad[:8]))
        sys.exit(1)
    print(f"PASS seed={seed} commands={n}")


if __name__ == "__main__":
    main()
