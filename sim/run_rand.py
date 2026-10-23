#!/usr/bin/env python3
"""
run_rand.py - Differential test of the CPU with random RV32IM programs.

  python run_rand.py [seed] [n_blocks]

The program mixes ALU, mul/div, cached loads/stores and loads/stores through the
uncached alias (same area), I/O stores, FENCE, branches, loops and calls.
At the end it saves the registers, and registers and memory are compared with pyiss.
"""
import os, sys, random, subprocess, struct
import pyiss
import run_isa

HERE = os.path.dirname(os.path.abspath(__file__))
BUILD = os.path.join(HERE, "build")

RSV = {0, 1, 8, 9, 18, 19, 31}            # x0, ra, s0, s1, s2, s3, t6 (loops)
REGS = [r for r in range(32) if r not in RSV]


def R(rng):
    return f"x{rng.choice(REGS)}"


def S(rng):
    return f"x{rng.choice(REGS + [0])}"


def gen(rng, nblk):
    out = []
    lab = [0]

    def L():
        lab[0] += 1
        return f".L{lab[0]}"

    def alu():
        k = rng.random()
        if k < 0.35:
            op = rng.choice(["add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and"])
            return [f"{op} {R(rng)}, {S(rng)}, {S(rng)}"]
        if k < 0.6:
            op = rng.choice(["addi", "slti", "sltiu", "xori", "ori", "andi"])
            return [f"{op} {R(rng)}, {S(rng)}, {rng.randrange(-2048, 2048)}"]
        if k < 0.7:
            op = rng.choice(["slli", "srli", "srai"])
            return [f"{op} {R(rng)}, {S(rng)}, {rng.randrange(32)}"]
        if k < 0.78:
            return [f"lui {R(rng)}, {rng.randrange(1 << 20)}"]
        op = rng.choice(["mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu"])
        return [f"{op} {R(rng)}, {S(rng)}, {S(rng)}"]

    def mem():
        sz = rng.choice([1, 2, 4])
        off = rng.randrange(0, 4096 // sz) * sz - 2048
        off = max(-2048, min(2047 - 3, off))
        off -= off % sz
        base = rng.choice(["x8", "x8", "x8", "x9"])            # s0 cached / s1 uncached
        if rng.random() < 0.5:
            op = {1: rng.choice(["lb", "lbu"]), 2: rng.choice(["lh", "lhu"]), 4: "lw"}[sz]
            return [f"{op} {R(rng)}, {off}({base})"]
        op = {1: "sb", 2: "sh", 4: "sw"}[sz]
        seq = [f"{op} {S(rng)}, {off}({base})"]
        if rng.random() < 0.4:                                  # store -> immediate load
            lop = {1: "lbu", 2: "lh", 4: "lw"}[sz]
            seq.append(f"{lop} {R(rng)}, {off}({rng.choice(['x8', 'x9'])})")
        return seq

    def simple():
        k = rng.random()
        if k < 0.55:
            return alu()
        if k < 0.92:
            return mem()
        if k < 0.96:
            return [f"sw {S(rng)}, 0(x18)"]                     # I/O (ignored)
        return ["fence"]

    funcs = []
    for b in range(nblk):
        k = rng.random()
        if k < 0.6:
            for _ in range(rng.randrange(1, 6)):
                out += simple()
        elif k < 0.75:
            l = L()
            op = rng.choice(["beq", "bne", "blt", "bge", "bltu", "bgeu"])
            out.append(f"{op} {S(rng)}, {S(rng)}, {l}")
            for _ in range(rng.randrange(1, 5)):
                out += simple()
            out.append(f"{l}:")
        elif k < 0.88:
            l = L()
            out.append(f"li x31, {rng.randrange(1, 9)}")
            out.append(f"{l}:")
            for _ in range(rng.randrange(1, 5)):
                out += simple()
            out.append("addi x31, x31, -1")
            out.append(f"bnez x31, {l}")
        else:
            f = f"func{len(funcs)}"
            body = []
            for _ in range(rng.randrange(1, 5)):
                body += simple()
            funcs.append((f, body))
            out.append(f"jal ra, {f}")
    asm = [".section .text.init", ".globl _start", "_start:",
           "li x8, 0x40100800", "li x9, 0x50100800", "li x18, 0x80000F10", "li x19, 0x40180000"]
    for r in REGS:
        asm.append(f"li x{r}, {rng.randrange(1 << 32)}")
    asm += out
    for r in range(32):
        asm.append(f"sw x{r}, {4 * r}(x19)")
    asm += ["fence", "li t0, 0x80000F00", "li t1, 1", "sw t1, 0(t0)", "9: j 9b"]
    for f, body in funcs:
        asm += [f"{f}:"] + body + ["ret"]
    return "\n".join(asm) + "\n"


def main():
    seed = int(sys.argv[1]) if len(sys.argv) > 1 else 1
    nblk = int(sys.argv[2]) if len(sys.argv) > 2 else 300
    rng = random.Random(seed)
    src = os.path.join(BUILD, f"rand{seed}.S")
    open(src, "w").write(gen(rng, nblk))
    elf = os.path.join(BUILD, "rand.elf")
    env = os.path.join(HERE, "tests", "env")
    subprocess.check_call(["riscv-none-elf-gcc", "-march=rv32im_zicsr", "-mabi=ilp32", "-nostdlib",
                           "-nostartfiles", "-T" + os.path.join(env, "link.ld"), src, "-o", elf,
                           "-Wl,--no-warn-rwx-segments"])
    binf = os.path.join(BUILD, "rand.bin")
    subprocess.check_call(["riscv-none-elf-objcopy", "-O", "binary", elf, binf])
    run_isa.bin2hex(binf, os.path.join(BUILD, "rand.hex"))
    img = open(binf, "rb").read()

    iss = pyiss.ISS(img)
    if iss.run(2_000_000) != 1:
        print("the ISS did not finish"); sys.exit(1)

    vvp = run_isa.build_tb(os.environ.get("PHASE", "2.0"), os.environ.get("RDLAT", "2"))
    r = subprocess.run(["vvp", "-n", vvp, "+prog=rand.hex", "+maxcyc=3000000", "+dump"],
                       cwd=BUILD, capture_output=True, text=True)
    res = [l for l in r.stdout.splitlines() if l.startswith(("PASS", "FAIL", "TIMEOUT", "SDRAM"))]
    print(" | ".join(res), f"(ISS: {iss.n} instr)")
    if not res or not res[0].startswith("PASS"):
        sys.exit(1)

    def rd(f):
        w = []
        for l in open(os.path.join(BUILD, f)):
            l = l.strip()
            if l and not l.startswith(("//", "@")):
                w.append(int(l, 16))
        return w
    data, sig = rd("rand_data.hex"), rd("rand_sig.hex")
    bad = 0
    for i in range(32):
        e = struct.unpack_from("<I", iss.mem, 0x180000 + 4 * i)[0]
        if sig[i] != e:
            print(f"  x{i}: rtl={sig[i]:08x} iss={e:08x}"); bad += 1
    base = 0x100000
    for i in range(1024):
        e = struct.unpack_from("<I", iss.mem, base + 4 * i)[0]
        if data[i] != e:
            if bad < 10:
                print(f"  mem[{0x40000000 + base + 4 * i:08x}]: rtl={data[i]:08x} iss={e:08x}")
            bad += 1
    if bad:
        print(f"FAIL seed={seed}: {bad} differences"); sys.exit(1)
    print(f"PASS seed={seed}")


if __name__ == "__main__":
    main()
