#!/usr/bin/env python3
"""timing.py - Gowin timing summary: Fmax and the N worst (setup) paths.
   usage: python tools/timing.py [N] [-v]"""
import re, html, sys, os
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
pnr = os.path.join(root, "impl", "pnr")
n = int(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].isdigit() else 10
verbose = "-v" in sys.argv
s = open(os.path.join(pnr, "bltfast_tr_content.html"), encoding="utf-8", errors="ignore").read()
t = " ".join(html.unescape(re.sub(r"<[^>]+>", " ", s)).split())
m = re.search(r"Max Frequency Summary:(.*?)Total Negative", t)
if m:
    print(m.group(1).split("No timing")[0].strip())
blocks = open(os.path.join(pnr, "bltfast.timing_paths")).read().split("=====")
for b in blocks[1:n + 1]:
    w = b.split()
    if len(w) < 4:
        continue
    slack = w[1]
    nodes = [w[i] for i in range(4, len(w), 3)]
    short = []
    for x in nodes:
        base = re.sub(r"_s\d*$", "", x)
        base = re.sub(r"_\d+$", "", base)
        if not short or short[-1] != base:
            short.append(base)
    print(f"slack {slack:>7}: " + (" > ".join(short) if verbose else f"{nodes[0]} -> {nodes[-1]}"))
