#!/usr/bin/env python3
"""
genprof.py - Table of the sampling profiler of a program (GENESIS.TXT prof=1).

  python genprof.py log.txt [build/genesis.map] [--top 40]

log.txt is the UART output (it must contain "PROF begin" ... "PROF end"; if
there are several dumps the last one is used). Each "P index count" bucket
covers 2^shift bytes from 0x4000_0000; its count is split between the
functions that overlap it (sections .text.* of the linker map).
"""
import re, sys, argparse, bisect, os
from collections import defaultdict

BASE = 0x40000000


def read_map(path):
    """[(start, end, function, object)] of the .text.* sections, sorted"""
    secs = []
    lines = open(path, encoding="latin-1").read().split("\n")
    for i, l in enumerate(lines):
        m = re.match(r"^ \.text\.?(\S*)\s*(0x[0-9a-f]+\s+0x[0-9a-f]+\s+\S.*)?$", l)
        if not m:
            continue
        rest = m.group(2)
        if not rest and i + 1 < len(lines):
            rest = lines[i + 1].strip()
        f = re.match(r"(0x[0-9a-f]+)\s+(0x[0-9a-f]+)\s+(\S.*)$", rest or "")
        if not f:
            continue
        a, n = int(f.group(1), 16), int(f.group(2), 16)
        if n and a >= BASE:
            obj = os.path.basename(f.group(3).strip()).replace("apps_genesis_picodrive_", "")
            secs.append((a, a + n, m.group(1) or "(.text)", obj))
    secs.sort()
    return secs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log")
    ap.add_argument("map", nargs="?", default=os.path.join(os.path.dirname(__file__), "..", "sw", "build", "genesis.map"))
    ap.add_argument("--top", type=int, default=40)
    a = ap.parse_args()

    txt = open(a.log, encoding="latin-1").read().replace("\r", "")
    k = txt.rfind("PROF begin")
    if k < 0:
        sys.exit("no 'PROF begin' in the log")
    hdr = re.match(r"PROF begin samples (\d+) outside (\d+) period (\d+) shift (\d+)", txt[k:])
    total, outside, period, shift = map(int, hdr.groups())
    buckets = [(int(i, 16), int(c)) for i, c in re.findall(r"^P ([0-9a-f]+) (\d+)$", txt[k:], re.M)]

    secs = read_map(a.map)
    starts = [s[0] for s in secs]
    func, obj = defaultdict(float), defaultdict(float)
    for i, c in buckets:
        lo = BASE + (i << shift)
        hi = lo + (1 << shift)
        j = max(bisect.bisect_right(starts, lo) - 1, 0)
        hits = []
        while j < len(secs) and secs[j][0] < hi:
            s = secs[j]
            ov = min(hi, s[1]) - max(lo, s[0])
            if ov > 0:
                hits.append((ov, s))
            j += 1
        if not hits:
            func["?"] += c; obj["?"] += c
            continue
        tot = sum(h[0] for h in hits)
        for ov, s in hits:
            func[s[2]] += c * ov / tot
            obj[s[3]] += c * ov / tot

    n = total or 1
    print(f"{total} samples every {period} cycles ({total * period / 90e6:.1f} s at 90 MHz), {outside} outside .text")
    print("\nby object:")
    for o, c in sorted(obj.items(), key=lambda x: -x[1])[:20]:
        print(f"  {100 * c / n:5.1f}%  {o}")
    print("\nby function:")
    for f, c in sorted(func.items(), key=lambda x: -x[1])[:a.top]:
        print(f"  {100 * c / n:5.1f}%  {f}")


if __name__ == "__main__":
    main()
