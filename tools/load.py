#!/usr/bin/env python3
"""
load.py - Carga un programa en el SoC bltfast por la UART (USB del BL616).

  python load.py prog.bin [--port COM4] [--baud 2000000] [--term] [--addr 0x40000000]
  python load.py --monitor-only [--port COM4] [--baud 2000000]
                                     solo el terminal, sin reiniciar la placa

  1. Envía "RVRST!" a 115200 y a la velocidad rápida (el programa anterior puede
     haber dejado la UART en cualquiera de las dos): la placa vuelve a la ROM
  2. Espera "RVBOOT", pide la velocidad rápida ("RVSP" + divisor) si --baud
  3. Envía "RVLD" + dirección + longitud + CRC32 + datos y espera "OK"
  4. Con --term se queda mostrando lo que llega (Ctrl+C para salir)
"""
import os, sys, time, struct, zlib, argparse
import serial
import serial.tools.list_ports

CLK = int(os.environ.get("BLT_CLK", 90_000_000))   # frecuencia del SoC


def find_port():
    ps = list(serial.tools.list_ports.comports())
    for p in ps:
        d = (p.description or "") + (p.hwid or "")
        if "BL616" in d or "SIPEED" in d.upper() or "JTAG" in d.upper():
            return p.device
    return ps[-1].device if ps else None


def wait_for(s, token, timeout):
    buf = b""
    t0 = time.time()
    while time.time() - t0 < timeout:
        b = s.read(256)
        if b:
            buf += b
            sys.stdout.write(b.decode("latin-1"))
            sys.stdout.flush()
            if token in buf:
                return True
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("bin", nargs="?")
    ap.add_argument("--port")
    ap.add_argument("--baud", type=int, default=2_000_000)
    ap.add_argument("--addr", type=lambda x: int(x, 0), default=0x40000000)
    ap.add_argument("--term", action="store_true")
    ap.add_argument("--monitor-only", action="store_true", help="solo abrir el terminal, sin cargar")
    a = ap.parse_args()
    port = a.port or find_port()
    if not port:
        print("no encuentro el puerto serie"); sys.exit(1)
    if a.monitor_only:
        s = serial.Serial(port, round(CLK / round(CLK / a.baud)), timeout=0.05)
        print(f"puerto {port} a {s.baudrate} baudios (Ctrl+C para salir)")
        terminal(s)
        return
    if not a.bin:
        ap.error("falta el .bin (o --monitor-only)")
    data = open(a.bin, "rb").read()
    print(f"puerto {port}, {len(data)} bytes")
    s = serial.Serial(port, round(CLK / round(CLK / a.baud)), timeout=0.05)
    s.write(b"RVRST!")
    s.flush(); time.sleep(0.02)
    s.baudrate = 115200
    s.reset_input_buffer()
    s.write(b"RVRST!")
    if not wait_for(s, b"RVBOOT", 5):
        print("\nla placa no responde (¿bitstream cargado?)"); sys.exit(1)
    if a.baud != 115200:
        div = round(CLK / a.baud)
        s.write(b"RVSP" + struct.pack("<I", div))
        if not wait_for(s, b"OK", 2):
            print("\nno acepta el cambio de velocidad"); sys.exit(1)
        time.sleep(0.01)
        s.baudrate = round(CLK / div)
    t0 = time.time()
    s.write(b"RVLD" + struct.pack("<III", a.addr, len(data), zlib.crc32(data)) + data)
    ok = wait_for(s, b"OK", 10 + len(data) / 20000)
    print(f"\n{'cargado' if ok else 'ERROR'} en {time.time() - t0:.2f} s")
    if not ok:
        sys.exit(1)
    if a.term:
        terminal(s)


def terminal(s):
    try:
        while True:
            b = s.read(256)
            if b:
                sys.stdout.write(b.decode("latin-1")); sys.stdout.flush()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
