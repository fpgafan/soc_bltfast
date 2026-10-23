#!/usr/bin/env python3
"""sddump.py - Copies a file from the board's microSD to the PC over the UART.

  python sddump.py NAME.EXT output [--port COM4]

Loads sw/build/sddump.bin (tools/load.py) and receives the file (with CRC32).
"""
import sys, os, struct, zlib, time, argparse, subprocess
import serial

HERE = os.path.dirname(os.path.abspath(__file__))
CLK = 90_000_000

ap = argparse.ArgumentParser()
ap.add_argument("name")
ap.add_argument("out")
ap.add_argument("--port", default="COM4")
ap.add_argument("--baud", type=int, default=2_000_000)
a = ap.parse_args()

base, _, ext = a.name.upper().partition(".")
name83 = (base[:8].ljust(8) + ext[:3].ljust(3)).encode()

binf = os.path.join(HERE, "..", "sw", "build", "sddump.bin")
subprocess.check_call([sys.executable, os.path.join(HERE, "load.py"), binf, "--port", a.port, "--baud", str(a.baud)])
s = serial.Serial(a.port, round(CLK / round(CLK / a.baud)), timeout=5)
t0 = time.time()
buf = b""
while b"LISTO" not in buf and time.time() - t0 < 10:     # "ready" token sent by sddump.bin
    buf += s.read(64)
s.reset_input_buffer()
s.write(b"G" + name83)
hdr = s.read(6)
if hdr[:2] != b"SZ":
    sys.exit(f"unexpected response: {hdr!r}")
size = struct.unpack("<I", hdr[2:])[0]
print(f"{a.name}: {size} bytes")
data = bytearray()
t0 = time.time()
while len(data) < size:
    n = min(4096, size - len(data))
    chunk = s.read(n)
    if len(chunk) < n:
        if chunk.startswith(b"ER") or b"ER" in chunk[:2]:
            sys.exit("read error on the board")
        open(a.out + ".partial", "wb").write(data + chunk)
        sys.exit(f"timed out after {len(data) + len(chunk)} bytes")
    data += chunk
    s.write(b"K")
    if len(data) % (256 * 1024) < 4096 or len(data) == size:
        print(f"\r{len(data) * 100 // size}%  {len(data) / (time.time() - t0) / 1024:.0f} KB/s", end="", flush=True)
tail = s.read(6)
crc = struct.unpack("<I", tail[2:])[0] if tail[:2] == b"CR" else None
ok = crc == (zlib.crc32(data) & 0xFFFFFFFF)
print(f"\nCRC {'OK' if ok else 'MISMATCH'}")
open(a.out, "wb").write(data)
sys.exit(0 if ok else 1)
