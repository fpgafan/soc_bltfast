#!/usr/bin/env python3
"""
midi2c.py - Converts a MIDI file (.mid) into a C header for the
bltfast SoC MIDI player (sw/lib/midi.c).

    python tools/midi2c.py song.mid sw/apps/my_app/song.h [options]

The SoC player reads standard MIDI directly (type 0 and 1, up to 32
tracks, tempo changes, General MIDI programs, volume, expression, pan and
pitch bend; drums on channel 10) and plays it with 24 hardware voices, so
the file is stored as is. This tool checks it, reports anything that
may cause trouble and, if asked, modifies it:

    --name N            array name (default: the name of the .h file)
    --transpose S       shift up/down S semitones (does not affect drums)
    --no-drums          remove channel 10
    --channels 1,2,3    keep only those channels (1..16)
    --tempo F           multiply the speed by F (1.5 = 50 % faster)
    --max-sec S         cut at S seconds
    --vol V             scale note velocities (1.0 = unchanged)

Generates:
    #define NAME_LEN   bytes
    #define NAME_SEC   approximate duration in seconds
    static const uint8_t name[]   the SMF file

In C:
    #include "song.h"
    snd_init();
    if (midi_load(song, SONG_LEN) == 0) midi_play(1);           // 1 = loop
    for (;;) { midi_update(); ... }                             // often (>= 200 Hz)
"""
import argparse
import os
import re
import struct
import sys

MIDI_VOICES = 24        # sw/lib/audio.h
MAXTRK = 32             # sw/lib/midi.c
DRUM_CH = 9

GM_FAMILY = ["piano", "chromatic percussion", "organ", "guitar", "bass", "strings",
             "ensemble", "brass", "reed", "pipe", "synth lead",
             "synth pad", "synth effects", "ethnic", "percussive", "sound effects"]


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


def read_smf(data):
    """Returns (format, division, tracks); each track is a list of
    (absolute_tick, event_bytes) with an explicit status byte."""
    if data[:4] != b"MThd":
        sys.exit("not a standard MIDI file (MThd missing)")
    hl, fmt, ntrk, div = struct.unpack(">IHHH", data[4:14])
    if div & 0x8000:
        sys.exit("SMPTE division: not supported by the SoC player")
    if fmt == 2:
        sys.exit("type 2 MIDI (independent tracks): not supported")
    i = 8 + hl
    tracks = []
    while i + 8 <= len(data):
        kind, l = data[i:i + 4], struct.unpack(">I", data[i + 4:i + 8])[0]
        j, end = i + 8, min(i + 8 + l, len(data))
        i += 8 + l
        if kind != b"MTrk":
            continue
        ev, t, run = [], 0, 0
        while j < end:
            dt, j = varlen(data, j)
            t += dt
            st = data[j]
            if st & 0x80:
                j += 1
                if st < 0xF0:
                    run = st
            else:
                if not run:
                    sys.exit("damaged file: data without a status byte")
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
        tracks.append(ev)
    if not tracks:
        sys.exit("the file has no tracks")
    return fmt, div, tracks


def tempo_map(tracks):
    changes = sorted((t, int.from_bytes(e[3:6], "big")) for p in tracks for t, e in p
                     if e[0] == 0xFF and e[1] == 0x51 and len(e) >= 6)
    return changes


def tick_to_sec(tick, changes, div):
    sec, t0, us = 0.0, 0, 500000
    for t, new in changes:
        if t >= tick:
            break
        sec += (t - t0) * us / div / 1e6
        t0, us = t, new
    return sec + (tick - t0) * us / div / 1e6


def sec_to_tick(s, changes, div):
    t0, us, acc = 0, 500000, 0.0
    for t, new in changes:
        d = (t - t0) * us / div / 1e6
        if acc + d >= s:
            break
        acc += d
        t0, us = t, new
    return t0 + int((s - acc) * 1e6 * div / us)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("midi")
    ap.add_argument("output")
    ap.add_argument("--name")
    ap.add_argument("--transpose", type=int, default=0)
    ap.add_argument("--no-drums", action="store_true")
    ap.add_argument("--channels")
    ap.add_argument("--tempo", type=float, default=1.0)
    ap.add_argument("--max-sec", type=float, default=0)
    ap.add_argument("--vol", type=float, default=1.0)
    a = ap.parse_args()

    name = re.sub(r"\W", "_", a.name or os.path.splitext(os.path.basename(a.output))[0])
    if name[0].isdigit():
        name = "_" + name
    NAME = name.upper()

    data = open(a.midi, "rb").read()
    fmt, div, tracks = read_smf(data)
    channels = {int(c) - 1 for c in a.channels.split(",")} if a.channels else None
    if a.tempo <= 0:
        sys.exit("--tempo must be > 0")
    modify = bool(a.transpose or a.no_drums or channels is not None or a.tempo != 1.0
                  or a.max_sec or a.vol != 1.0)

    if modify:
        cut = sec_to_tick(a.max_sec * a.tempo, tempo_map(tracks), div) if a.max_sec else None
        new_tracks = []
        for k, p in enumerate(tracks):
            q = []
            for t, e in p:
                if cut is not None and t > cut:
                    break
                st = e[0]
                if st == 0xFF and e[1] == 0x2F:
                    continue
                if st == 0xFF and e[1] == 0x51 and len(e) >= 6:
                    us = max(1, min(0xFFFFFF, round(int.from_bytes(e[3:6], "big") / a.tempo)))
                    e = e[:3] + us.to_bytes(3, "big")
                elif st < 0xF0:
                    c = st & 15
                    if (channels is not None and c not in channels) or (a.no_drums and c == DRUM_CH):
                        continue
                    if st & 0xF0 in (0x80, 0x90, 0xA0) and c != DRUM_CH and a.transpose:
                        n = e[1] + a.transpose
                        if not 0 <= n <= 127:
                            continue
                        e = bytes([st, n]) + e[2:]
                    if st & 0xF0 == 0x90 and e[2] and a.vol != 1.0:
                        e = e[:2] + bytes([max(1, min(127, round(e[2] * a.vol)))])
                q.append((t, e))
            if a.tempo != 1.0 and k == 0 and not any(e[0] == 0xFF and e[1] == 0x51 for _, e in q):
                q.insert(0, (0, b"\xff\x51\x03" + round(500000 / a.tempo).to_bytes(3, "big")))
            if cut is not None:                         # silence whatever is still sounding
                for c in sorted({e[0] & 15 for _, e in q if e[0] < 0xF0}):
                    q.append((cut, bytes([0xB0 | c, 123, 0])))
            end = max([t for t, _ in q], default=0)
            q.append((end, b"\xff\x2f\x00"))
            new_tracks.append(q)
        tracks = new_tracks
        out = b"MThd" + struct.pack(">IHHH", 6, 1 if len(tracks) > 1 else 0, len(tracks), div)
        for p in tracks:
            body, last = b"", 0
            for t, e in p:
                body += vlq(t - last) + e
                last = t
            out += b"MTrk" + struct.pack(">I", len(body)) + body
        data = out

    # ------------------------------------------------------------ report
    changes = tempo_map(tracks)
    ev = sorted(((t, e) for p in tracks for t, e in p if e[0] < 0xF0), key=lambda x: x[0])
    notes, active, maxpoly, progs, bend = 0, set(), 0, {}, False
    used = set()
    for t, e in ev:
        st, c = e[0] & 0xF0, e[0] & 15
        if st == 0x90 and e[2]:
            used.add(c)
            notes += 1
            if c != DRUM_CH:
                active.add((c, e[1]))
                maxpoly = max(maxpoly, len(active))
        elif st == 0x80 or (st == 0x90 and not e[2]):
            active.discard((c, e[1]))
        elif st == 0xC0:
            progs.setdefault(c, e[1])
        elif st == 0xE0:
            bend = True
    end = max((t for p in tracks for t, _ in p), default=0)
    dur = tick_to_sec(end, changes, div)

    guard = "ASSET_" + NAME + "_INCLUDED"
    lines = [f"// {os.path.basename(a.output)} - generated by tools/midi2c.py from "
             f"{os.path.basename(a.midi)}",
             f"// {len(tracks)} tracks, {notes} notes, {dur:.1f} s"
             + (" (modified)" if modify else ""),
             f"#ifndef {guard}\n#define {guard}\n#include <stdint.h>\n",
             f"#define {NAME}_LEN {len(data)}",
             f"#define {NAME}_SEC {round(dur)}\n",
             f"static const uint8_t {name}[{len(data)}] __attribute__((aligned(4))) = {{"]
    for i in range(0, len(data), 16):
        lines.append("    " + ",".join(f"0x{b:02x}" for b in data[i:i + 16]) + ",")
    lines.append("};\n\n#endif")
    os.makedirs(os.path.dirname(os.path.abspath(a.output)), exist_ok=True)
    with open(a.output, "w", newline="\n") as f:
        f.write("\n".join(lines) + "\n")

    print(f"{a.output}: {name}, {len(data)} bytes, MIDI type {1 if len(tracks) > 1 else fmt}, "
          f"{len(tracks)} tracks, {notes} notes, {dur:.1f} s")
    for c in sorted(used):
        if c == DRUM_CH:
            print(f"  channel 10: drums")
        else:
            p = progs.get(c, 0)
            print(f"  channel {c + 1}: program {p + 1} ({GM_FAMILY[p // 8]})")
    print(f"  max polyphony (without drums): {maxpoly} simultaneous notes")
    if maxpoly > MIDI_VOICES:
        print(f"  WARNING: more than {MIDI_VOICES} simultaneous notes; the player will steal voices")
    if len(tracks) > MAXTRK:
        print(f"  WARNING: {len(tracks)} tracks; the player only reads the first {MAXTRK}")
    if bend:
        print("  uses pitch bend (the SoC applies it with ±2 semitones)")


if __name__ == "__main__":
    main()
