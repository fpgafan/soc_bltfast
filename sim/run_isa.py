#!/usr/bin/env python3
"""
run_isa.py - Runs the riscv-tests (rv32ui + rv32um) on the RTL with Icarus.

  python run_isa.py               all
  python run_isa.py add lw div    some
Environment options: PHASE (ns, SDRAM clock delay), RDLAT.
"""
import os, sys, subprocess, glob, struct

HERE  = os.path.dirname(os.path.abspath(__file__))
ROOT  = os.path.dirname(HERE)
GCC   = r"C:\riscv\xpack-riscv-none-elf-gcc-15.2.0-1\bin"
OCS   = r"C:\tools\oss-cad-suite"
BUILD = os.path.join(HERE, "build")
os.makedirs(BUILD, exist_ok=True)
os.environ["PATH"] = os.pathsep.join([os.path.join(OCS, "bin"), os.path.join(OCS, "lib"),
                                      GCC, os.environ["PATH"]])

SKIP = {"ma_data"}            # misaligned accesses: they raise an exception here

RTL = ["rtl/cpu/rv_core.v", "rtl/cpu/rv_muldiv.v", "rtl/cpu/icache.v", "rtl/cpu/dcache.v",
       "rtl/cpu/cpu_mem.v", "rtl/cpu/cpu.v", "rtl/mem/sdram_ctrl.v",
       "sim/models/sdram_model.v", "sim/tb/tb_cpu.v"]


def bin2hex(binf, hexf, base_words=0):
    data = open(binf, "rb").read()
    data += b"\0" * (-len(data) % 4)
    with open(hexf, "w") as f:
        if base_words:
            f.write("@%x\n" % base_words)
        for i in range(0, len(data), 4):
            f.write("%08x\n" % struct.unpack_from("<I", data, i)[0])


def build_tb(phase, rdlat):
    vvp = os.path.join(BUILD, f"tb_cpu_{phase}_{rdlat}.vvp")
    srcs = [os.path.join(ROOT, s) for s in RTL]
    subprocess.check_call(["iverilog", "-g2012", "-DSIM", "-o", vvp, "-s", "tb_cpu",
                           f"-Ptb_cpu.SD_PHASE={phase}", f"-Ptb_cpu.RD_LAT={rdlat}"] + srcs)
    # ROM: lui t0,0x40000 ; jr t0
    with open(os.path.join(BUILD, "rom_jump.hex"), "w") as f:
        f.write("400002b7\n00028067\n")
    return vvp


def build_test(src, name):
    elf = os.path.join(BUILD, name + ".elf")
    env = os.path.join(HERE, "tests", "env")
    subprocess.check_call(["riscv-none-elf-gcc", "-march=rv32im_zicsr_zifencei", "-mabi=ilp32",
                           "-nostdlib", "-nostartfiles", "-I" + env,
                           "-I" + os.path.join(HERE, "tests", "rv64ui"),
                           "-T" + os.path.join(env, "link.ld"), src, "-o", elf])
    binf = os.path.join(BUILD, name + ".bin")
    subprocess.check_call(["riscv-none-elf-objcopy", "-O", "binary", elf, binf])
    hexf = os.path.join(BUILD, name + ".hex")
    bin2hex(binf, hexf)
    return hexf


def main():
    phase = os.environ.get("PHASE", "2.0")
    rdlat = os.environ.get("RDLAT", "2")
    vvp = build_tb(phase, rdlat)
    tests = []
    for d in ("rv32ui", "rv32um"):
        for s in sorted(glob.glob(os.path.join(HERE, "tests", d, "*.S"))):
            n = os.path.splitext(os.path.basename(s))[0]
            if n in SKIP:
                continue
            if len(sys.argv) > 1 and n not in sys.argv[1:]:
                continue
            tests.append((d + "-" + n, s))
    fails = 0
    for name, src in tests:
        hexf = build_test(src, name)
        r = subprocess.run(["vvp", "-n", vvp, "+prog=" + hexf, "+maxcyc=200000"],
                           cwd=BUILD, capture_output=True, text=True)
        out = r.stdout.strip().splitlines()
        res = [l for l in out if l.startswith(("PASS", "FAIL", "TIMEOUT"))]
        line = res[0] if res else "SIN RESULTADO: " + " | ".join(out[-3:])
        extra = [l for l in out if "SDRAM" in l]
        print(f"{name:20s} {line} {' '.join(extra[:2])}")
        if not line.startswith("PASS") or extra:
            fails += 1
    print(f"\n{len(tests) - fails}/{len(tests)} PASS")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
