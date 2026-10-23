#!/usr/bin/env python3
"""
run_vid.py - Video + HDMI test: records one TMDS frame from the RTL and decodes it.

  python run_vid.py [seed] [--sx=N --sy=N --wrapw=N --wraph=N --stride=N]

It checks: structure (525 lines, 480 video periods of 640 pixels with
preamble and guards, syncs), pixels == palette[framebuffer] with the
requested scroll/wrap, data islands (guards, header and subpacket BCH
ECC), ACR (N=6144, CTS=25200), AVI/Audio InfoFrame (checksums) and that the
audio samples arrive in order, with correct parity and IEC 60958 blocks.
"""
import os, sys, random, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BUILD = os.path.join(HERE, "build")
OCS = r"C:\tools\oss-cad-suite"
os.environ["PATH"] = os.pathsep.join([os.path.join(OCS, "bin"), os.path.join(OCS, "lib"), os.environ["PATH"]])

CTRL = {0b1101010100: 0, 0b0010101011: 1, 0b0101010100: 2, 0b1010101011: 3}
TERC = [0b1010011100, 0b1001100011, 0b1011100100, 0b1011100010, 0b0101110001, 0b0100011110,
        0b0110001110, 0b0100111100, 0b1011001100, 0b0100111001, 0b0110011100, 0b1011000110,
        0b1010001110, 0b1001110001, 0b0101100011, 0b1011000011]
TERC_D = {v: i for i, v in enumerate(TERC)}
VG = (0b1011001100, 0b0100110011, 0b1011001100)
DG12 = 0b0100110011


def tmds_dec(q):
    d = q & 0xFF
    if q & 0x200:
        d ^= 0xFF
    o = d & 1
    for i in range(1, 8):
        b = ((d >> i) ^ (d >> (i - 1))) & 1
        if not (q & 0x100):
            b ^= 1
        o |= b << i
    return o


def ecc(bits):
    e = 0
    for b in bits:
        fb = (e ^ b) & 1
        e >>= 1
        if fb:
            e ^= 0x83
    return e


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    opt = dict(a[2:].split("=") for a in sys.argv[1:] if a.startswith("--") and "=" in a)
    seed = int(args[0]) if args else 1
    sx, sy = int(opt.get("sx", 0)), int(opt.get("sy", 0))
    ww, wh = int(opt.get("wrapw", 0)), int(opt.get("wraph", 0))
    stride = int(opt.get("stride", 640))
    rng = random.Random(seed)
    fb = bytearray(rng.randrange(256) for _ in range(1 << 20))
    pal = [rng.randrange(1 << 24) for _ in range(256)]
    with open(os.path.join(BUILD, "vid_init.hex"), "w") as f:
        f.write("@180000\n")
        for i in range(0, len(fb), 4):
            f.write("%08x\n" % int.from_bytes(fb[i:i + 4], "little"))
    with open(os.path.join(BUILD, "vid_pal.hex"), "w") as f:
        for p in pal:
            f.write("%08x\n" % p)
    vvp = os.path.join(BUILD, "tb_vid.vvp")
    srcs = [os.path.join(ROOT, p) for p in ("rtl/video/video.v", "rtl/video/hdmi_tx.v", "rtl/mem/sdram_ctrl.v",
                                            "sim/models/sdram_model.v", "sim/models/gowin_prims.v", "sim/tb/tb_vid.v")]
    subprocess.check_call(["iverilog", "-g2012", "-DSIM", "-o", vvp, "-s", "tb_vid"] + srcs)
    r = subprocess.run(["vvp", "-n", vvp, "+init=vid_init.hex", "+pal=vid_pal.hex", "+out=tmds.txt",
                        f"+sx={sx}", f"+sy={sy}", f"+wrapw={ww}", f"+wraph={wh}", f"+stride={stride}"],
                       cwd=BUILD, capture_output=True, text=True)
    print([l for l in r.stdout.splitlines() if "VID" in l])
    words = [int(l, 16) for l in open(os.path.join(BUILD, "tmds.txt"))]
    ch = [[(w >> (10 * c)) & 0x3FF for w in words] for c in range(3)]
    n = len(words)
    errs = []

    def err(m):
        if len(errs) < 15:
            print("  ERROR:", m)
        errs.append(m)

    # ------------------------------------------------ walk through the sequence
    vid_lines = []          # (start index, pixels)
    packets = []
    i = 0
    vs_prev, line_vs = None, []
    hs_count = 0
    while i < n:
        c0, c1, c2 = ch[0][i], ch[1][i], ch[2][i]
        # video / island preamble: 8 control periods with specific CTL values
        if c1 in CTRL and c2 in CTRL and c0 in CTRL:
            if i + 10 <= n and all(ch[1][i + k] == 0b0010101011 and ch[2][i + k] == 0b1101010100 and ch[0][i + k] in CTRL for k in range(8)) \
                    and (ch[0][i + 8], ch[1][i + 8], ch[2][i + 8]) == VG and (ch[0][i + 9], ch[1][i + 9], ch[2][i + 9]) == VG:
                j = i + 10
                px = []
                while j < n and not (ch[1][j] in CTRL and ch[2][j] in CTRL and ch[0][j] in CTRL):
                    px.append((tmds_dec(ch[2][j]) << 16) | (tmds_dec(ch[1][j]) << 8) | tmds_dec(ch[0][j]))
                    j += 1
                vid_lines.append((i, px))
                i = j
                continue
            if i + 10 <= n and all(ch[1][i + k] == 0b0010101011 and ch[2][i + k] == 0b0010101011 for k in range(8)):
                j = i + 8
                if not (ch[1][j] == DG12 and ch[2][j] == DG12 and ch[1][j + 1] == DG12 and ch[2][j + 1] == DG12):
                    err(f"wrong island leading guard at {j}")
                j += 2
                while ch[1][j] in TERC_D and ch[2][j] in TERC_D and ch[1][j] != DG12:
                    blk = []
                    for k in range(32):
                        d0 = TERC_D.get(ch[0][j + k]); d1 = TERC_D.get(ch[1][j + k]); d2 = TERC_D.get(ch[2][j + k])
                        if d0 is None or d1 is None or d2 is None:
                            err(f"non-TERC4 character inside the island at {j + k}")
                            d0 = d1 = d2 = 0
                        blk.append((d0, d1, d2))
                    packets.append((j, blk))
                    j += 32
                if not (ch[1][j] == DG12 and ch[2][j] == DG12 and ch[1][j + 1] == DG12):
                    err(f"wrong island trailing guard at {j}")
                i = j + 2
                continue
        i += 1

    # ------------------------------------------------ video
    if len(vid_lines) != 480:
        err(f"{len(vid_lines)} video lines (480 expected)")
    wrapb = (256 << ww) if ww else 0
    for y, (pos, px) in enumerate(vid_lines[:480]):
        if len(px) != 640:
            err(f"line {y}: {len(px)} pixels")
            continue
        row = (sy + y) % wh if wh else sy + y
        bad = 0
        for x in range(640):
            col = ((sx + x) & (wrapb - 1)) if wrapb else sx + x
            e = pal[fb[(row * stride + col) & 0xFFFFF]]
            if px[x] != e:
                bad += 1
                if bad == 1:
                    err(f"line {y} x={x}: {px[x]:06x} expected {e:06x}")
        if y > 0 and pos - vid_lines[y - 1][0] != 800:
            err(f"line {y}: spacing {pos - vid_lines[y - 1][0]} (800)")

    # ------------------------------------------------ syncs (channel 0 in control/islands)
    hs_low = 0
    vs_low_lines = set()
    invid = bytearray(n)
    for pos, px in vid_lines:
        for k in range(pos, min(n, pos + 10 + len(px))):
            invid[k] = 1
    for k in range(n):
        if invid[k]:
            continue
        v = ch[0][k]
        b = CTRL.get(v)
        if b is None:
            t = TERC_D.get(v)
            if t is None:
                continue
            b = t & 3
        if not (b & 1):
            hs_low += 1
        if not (b & 2):
            vs_low_lines.add(k // 800)
    if not 96 * 525 <= hs_low <= 96 * 526 + 4:
        err(f"HSYNC active for {hs_low} cycles (expected {96 * 525})")
    if len(vs_low_lines) not in (2, 3, 4):
        err(f"VSYNC active on {len(vs_low_lines)} lines")

    # ------------------------------------------------ packets
    types = {}
    samples = []
    fctr = []
    for pos, blk in packets:
        hb = [(d0 >> 2) & 1 for d0, _, _ in blk]
        sp = []
        for s in range(4):
            bits = []
            for k in range(32):
                bits.append((blk[k][1] >> s) & 1)
                bits.append((blk[k][2] >> s) & 1)
            sp.append(bits)
        if ecc(hb[:24]) != sum(b << i for i, b in enumerate(hb[24:32])):
            err(f"wrong header ECC at {pos}")
        for s in range(4):
            if ecc(sp[s][:56]) != sum(b << i for i, b in enumerate(sp[s][56:64])):
                err(f"wrong ECC for subpacket {s} at {pos}")
        # bit 3 of channel 0: 1 except for the first character of the island's first packet
        hv = sum(b << i for i, b in enumerate(hb[:24]))
        typ = hv & 0xFF
        types[typ] = types.get(typ, 0) + 1
        sb = [sum(b << i for i, b in enumerate(sp[s][:56])) for s in range(4)]
        byts = [[(x >> (8 * k)) & 0xFF for k in range(7)] for x in sb]
        if typ == 0x01:
            for s in range(4):
                cts = (byts[s][1] & 15) << 16 | byts[s][2] << 8 | byts[s][3]
                nn = (byts[s][4] & 15) << 16 | byts[s][5] << 8 | byts[s][6]
                if cts != 25200 or nn != 6144:
                    err(f"ACR: CTS={cts} N={nn}")
        elif typ in (0x82, 0x84):
            ln = (hv >> 16) & 31
            pb = [b for s in range(4) for b in byts[s]]
            tot = (typ + ((hv >> 8) & 0xFF) + ln + sum(pb[:ln + 1])) & 0xFF
            if tot != 0:
                err(f"InfoFrame {typ:#x}: checksum {tot:#x}")
            if typ == 0x82 and pb[4] != 1:
                err("AVI: VIC other than 1")
        elif typ == 0x02:
            present = (hv >> 8) & 15
            bflag = (hv >> 20) & 15
            for s in range(4):
                if present >> s & 1:
                    x = sb[s]
                    l, r_ = (x >> 8) & 0xFFFF, (x >> 32) & 0xFFFF
                    pl = bin(x & 0xFFFFFF).count("1") + ((x >> 50) & 1) + ((x >> 49) & 1) + ((x >> 48) & 1)
                    if ((x >> 51) & 1) != pl & 1:
                        err("wrong L parity")
                    pr = bin((x >> 24) & 0xFFFFFF).count("1") + ((x >> 54) & 1) + ((x >> 53) & 1) + ((x >> 52) & 1)
                    if ((x >> 55) & 1) != pr & 1:
                        err("wrong R parity")
                    samples.append((l, r_))
                    fctr.append(bflag >> s & 1)
        elif typ != 0x00:
            err(f"unknown packet {typ:#x}")
    print(f"islands: {len(packets)} packets, types { {hex(k): v for k, v in types.items()} }")
    print(f"audio samples: {len(samples)} in one frame (~800 expected)")
    for k in range(1, len(samples)):
        if samples[k][0] != (samples[k - 1][0] + 1) & 0xFFFF or samples[k][1] != samples[k][0] ^ 0xFFFF:
            err(f"sample {k}: {samples[k]} after {samples[k - 1]}")
            break
    bpos = [k for k, b in enumerate(fctr) if b]
    if any(bpos[k + 1] - bpos[k] != 192 for k in range(len(bpos) - 1)) or not bpos:
        err(f"IEC 60958 blocks: B marks at {bpos[:6]}")
    if not 780 <= len(samples) <= 825:
        err("number of samples out of range")
    if errs:
        print(f"FAIL: {len(errs)} errors"); sys.exit(1)
    print(f"PASS seed={seed} sx={sx} sy={sy} wrapw={ww} wraph={wh} stride={stride}")


if __name__ == "__main__":
    main()
