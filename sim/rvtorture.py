#!/usr/bin/env python3
"""
rvtorture.py - Genera programas aleatorios RV32IM para comparar la CPU real
con un emulador (tools/socemu.js) instrucción a instrucción en resultado.

  python rvtorture.py SEMILLA salida.S [--n 20000]

El programa ejecuta un cuerpo aleatorio (ALU, MUL/DIV, cargas/stores de 8/16/32
bits, saltos, llamadas a funciones con prólogo/epílogo en la pila) y al final
imprime por la UART "SIG <semilla> <crc de registros + memoria>".
"""
import random, sys, argparse

ap = argparse.ArgumentParser()
ap.add_argument("seed", type=int)
ap.add_argument("out")
ap.add_argument("--n", type=int, default=20000)
ap.add_argument("--funcs", type=int, default=24)
ap.add_argument("--video", action="store_true", help="vídeo + blitter activos durante la prueba")
ap.add_argument("--io", action="store_true", help="incluir E/S (SYS_SCRATCH) y accesos sin caché")
ap.add_argument("--cut", type=int, default=0, help="conservar solo las K primeras líneas del cuerpo")
ap.add_argument("--loops", type=int, default=1, help="repeticiones del cuerpo")
a = ap.parse_args()
R = random.Random(a.seed)

# x1 ra, x2 sp, x3 gp, x4 tp (no se usan), x26 = base del buffer A, x27 = base B
POOL = [5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 28, 29, 30, 31]
SAVED = [8, 9, 18, 19, 20, 21]          # s0, s1, s2..s5: los conserva cada función
BUFA, BUFB = 26, 27                     # BUFB = BUFA + 8 KB (mismo índice de caché)
lines = []
lab = [0]


def newlab():
    lab[0] += 1
    return "L%d" % lab[0]


def r():
    return R.choice(POOL)


def imm12():
    return R.randint(-2048, 2047)


def body(n, depth, fn_names, leaf):
    out = []
    i = 0
    while i < n:
        k = R.random()
        d, s1, s2 = r(), r(), r()
        if k < 0.30:
            op = R.choice(["add", "sub", "and", "or", "xor", "sll", "srl", "sra", "slt", "sltu"])
            out.append(f"{op} x{d}, x{s1}, x{s2}")
        elif k < 0.45:
            op = R.choice(["addi", "andi", "ori", "xori", "slti", "sltiu"])
            out.append(f"{op} x{d}, x{s1}, {imm12()}")
        elif k < 0.50:
            op = R.choice(["slli", "srli", "srai"])
            out.append(f"{op} x{d}, x{s1}, {R.randint(0, 31)}")
        elif k < 0.53:
            out.append(f"lui x{d}, {R.randint(0, 0xFFFFF)}")
        elif k < 0.60:
            op = R.choice(["mul", "mulh", "mulhu", "mulhsu", "div", "divu", "rem", "remu"])
            out.append(f"{op} x{d}, x{s1}, x{s2}")
        elif k < 0.75:                                  # carga
            size = R.choice([1, 2, 4])
            op = {1: R.choice(["lb", "lbu"]), 2: R.choice(["lh", "lhu"]), 4: "lw"}[size]
            base = R.choice([BUFA, BUFB])
            off = R.randrange(0, 2048, size)
            out.append(f"{op} x{d}, {off}(x{base})")
            if R.random() < 0.5:                        # uso inmediato del dato
                out.append(f"add x{r()}, x{d}, x{r()}")
        elif k < 0.88:                                  # store
            size = R.choice([1, 2, 4])
            op = {1: "sb", 2: "sh", 4: "sw"}[size]
            base = R.choice([BUFA, BUFB])
            off = R.randrange(0, 2048, size)
            out.append(f"{op} x{s1}, {off}(x{base})")
            if R.random() < 0.3:                        # store y load seguidos
                off2 = off & ~3 if R.random() < 0.5 else R.randrange(0, 2048, 4)
                out.append(f"lw x{d}, {off2}(x{base})")
        elif a.io and k < 0.91:                         # E/S y SDRAM sin caché (base x4)
            kk = R.random()
            if kk < 0.25:   out.append(f"sw x{s1}, 0x34(x3)")          # SYS_SCRATCH
            elif kk < 0.5:  out.append(f"lw x{d}, 0x34(x3)")
            elif kk < 0.65: out.append(f"lw x{d}, 0x0C(x3)")           # SYS_CLK_HZ (constante)
            elif kk < 0.8:  out.append(f"sw x{s1}, {R.randrange(0, 2048, 4)}(x4)")
            else:           out.append(f"lw x{d}, {R.randrange(0, 2048, 4)}(x4)")
            if R.random() < 0.5: out.append(f"add x{r()}, x{d}, x{r()}")
        elif k < 0.95:                                  # salto hacia delante
            L = newlab()
            op = R.choice(["beq", "bne", "blt", "bge", "bltu", "bgeu"])
            out.append(f"{op} x{s1}, x{s2}, {L}")
            for _ in range(R.randint(1, 4)):
                out.append(f"addi x{r()}, x{r()}, {imm12()}")
            out.append(f"{L}:")
        elif k < 0.965 and depth < 2:                   # bucle con salto hacia atrás
            c = R.choice(POOL)
            POOL.remove(c)
            L = newlab()
            out.append(f"li x{c}, {R.randint(1, 9)}")
            out.append(f"{L}:")
            out += body(R.randint(1, 8), depth + 1, [], True)
            out.append(f"addi x{c}, x{c}, -1")
            out.append(f"bnez x{c}, {L}")
            POOL.append(c)
            POOL.sort()
        elif k < 0.975:                                 # carga cuyo valor decide un salto
            L = newlab()
            base = R.choice([BUFA, BUFB])
            out.append(f"lw x{d}, {R.randrange(0, 2048, 4)}(x{base})")
            out.append(f"{R.choice(['beqz', 'bnez', 'bltz', 'bgez'])} x{d}, {L}")
            out.append(f"xori x{r()}, x{r()}, {imm12()}")
            out.append(f"{L}:")
        elif fn_names and not leaf and k < 0.99:        # llamada directa
            out.append(f"call {R.choice(fn_names)}")
        elif fn_names and not leaf:                     # llamada indirecta (puntero a función)
            t = R.choice(POOL)
            out.append(f"la x{t}, {R.choice(fn_names)}")
            out.append(f"jalr ra, 0(x{t})")
        i += 1
    return out


funcs = []
names = ["f%d" % i for i in range(a.funcs)]
for i, nm in enumerate(names):
    leaf = i >= a.funcs // 2
    callees = names[i + 1:] if not leaf else []
    nsave = R.randint(1, len(SAVED))
    sv = SAVED[:nsave]
    frame = 16 * ((4 * (nsave + 1) + 15) // 16)
    f = [f"{nm}:", f"addi sp, sp, -{frame}", f"sw ra, {frame - 4}(sp)"]
    for j, s in enumerate(sv):
        f.append(f"sw x{s}, {frame - 8 - 4 * j}(sp)")
    # la función usa los registros guardados (como hace el compilador)
    pool_bak = list(POOL)
    f += body(R.randint(10, 60), 1, callees, leaf)
    for j, s in enumerate(sv):
        f.append(f"lw x{s}, {frame - 8 - 4 * j}(sp)")
    f += [f"lw ra, {frame - 4}(sp)", f"addi sp, sp, {frame}", "ret"]
    funcs.append(f)

# los registros guardados no deben cambiar entre llamadas en el cuerpo principal:
# el epílogo los restaura, así que cualquier error de carga se nota en la firma
main = body(a.n, 0, names[: a.funcs // 2], False)
if a.cut:
    main = main[:a.cut]
    while main and not main[-1].endswith(":") and any(l.endswith(":") and l[:-1] not in "".join(main) for l in []):
        pass
    # etiquetas de saltos cortados: añadirlas al final
    defined = {l[:-1] for l in main if l.endswith(":")}
    for l in list(main):
        t = l.split()[-1]
        if t.startswith("L") and t[1:].isdigit() and t not in defined:
            main.append(t + ":"); defined.add(t)

src = [
    "    .section .text.start",
    "    .globl _start",
    "_start:",
    "    li sp, 0x40600000",
    "    li ra, 0",
    "    li x26, 0x40200000",
    "    li x27, 0x40202000",
    "    li x3, 0x80000000",
    "    li x4, 0x50210000",          # zona sin caché aparte (no es alias de A/B)
    # memoria inicial conocida
    "    li t0, 0x40200000",
    "    li t1, 0x40204000",
    "    li t2, 0x9E3779B9",
    "1:  sw t2, 0(t0)",
    "    slli t3, t2, 5",
    "    xor t2, t2, t3",
    "    addi t0, t0, 4",
    "    bltu t0, t1, 1b",
    "    li t0, 0x40210000",
    "    li t1, 0x40210800",
    "1:  sw t2, 0(t0)",
    "    addi t2, t2, 77",
    "    addi t0, t0, 4",
    "    bltu t0, t1, 1b",
    "    fence",
]
if a.video:
    # vídeo 640x480 desde 0x40600000 y 30 escalados 320x200 -> 640x480 en cola
    src += ["    li t0, 0x80002000", "    li t1, 0x600000", "    sw t1, 4(t0)", "    li t1, 640", "    sw t1, 8(t0)",
            "    li t1, 5", "    sw t1, 0(t0)",
            "    li t0, 0x80004000", "    li t1, 0x680000", "    sw t1, 4(t0)", "    li t1, 640", "    sw t1, 8(t0)",
            "    sw zero, 12(t0)", "    li t1, 0x01E00280", "    sw t1, 16(t0)",
            "    li t1, 0x6B0000", "    sw t1, 20(t0)", "    li t1, 320", "    sw t1, 24(t0)",
            "    sw zero, 28(t0)", "    li t1, 0x01E00280", "    sw t1, 32(t0)", "    sw zero, 36(t0)",
            "    li t1, 0x4000", "    sw t1, 40(t0)", "    li t1, 0x3555", "    sw t1, 44(t0)",
            "    li t1, 0x8000", "    sw t1, 48(t0)", "    li t1, 0x6AAA", "    sw t1, 52(t0)",
            "    li t2, 30", "1:  li t1, 1", "    sw t1, 56(t0)", "    addi t2, t2, -1", "    bnez t2, 1b"]
for k, reg in enumerate(POOL):
    src.append(f"    li x{reg}, {R.randint(-2**31, 2**31 - 1)}")
if a.loops > 1:
    src += [f"    li x1, {a.loops}", "    li x2, 0x40205000", "    sw x1, 0(x2)", "    li x2, 0x40600000", "bucle_principal:"]
src += ["    " + l if not l.endswith(":") else l for l in main]
if a.loops > 1:
    src += ["    li x2, 0x40205000", "    lw x1, 0(x2)", "    addi x1, x1, -1", "    sw x1, 0(x2)",
            "    li x2, 0x40600000", "    bnez x1, bucle_principal", "    li x1, 0"]
src += [
    # firma: registros al buffer C y CRC de A..C
    "    li t0, 0x40204000",
] + [f"    sw x{reg}, {4 * k}(t0)" for k, reg in enumerate(POOL + [1, 2])] + [
    f"    li a0, {a.seed}",
    "    li a1, 0x40200000",
    f"    li a2, {0x40204000 + 4 * (len(POOL) + 2)}",   # buffers + registros volcados
    "    call firma",
    "2:  j 2b",
    "",
    # firma(seed, ini, fin): CRC32 e impresión "SIG seed crc\n"
    "firma:",
    "    mv s0, a0",
    "    li t0, -1",
    "3:  lbu t1, 0(a1)",
    "    xor t0, t0, t1",
    "    li t2, 8",
    "4:  andi t3, t0, 1",
    "    srli t0, t0, 1",
    "    beqz t3, 5f",
    "    li t4, 0xEDB88320",
    "    xor t0, t0, t4",
    "5:  addi t2, t2, -1",
    "    bnez t2, 4b",
    "    addi a1, a1, 1",
    "    bltu a1, a2, 3b",
    "    not s1, t0",
    "    la a0, msg",
    "    call puts_",
    "    mv a0, s0",
    "    call hex_",
    "    li a0, 32",
    "    call putc_",
    "    mv a0, s1",
    "    call hex_",
    "    li a0, 10",
    "    call putc_",
    # LEDs = 0x2A: fin (el emulador para aquí)
    "    li t0, 0x80000004",
    "    li t1, 0x2A",
    "    sw t1, 0(t0)",
    "6:  j 6b",
    "putc_:",
    "    li t0, 0x80001000",
    "7:  lw t1, 4(t0)",
    "    andi t1, t1, 1",
    "    bnez t1, 7b",
    "    sw a0, 0(t0)",
    "    ret",
    "puts_:",
    "    mv t5, ra",
    "    mv t6, a0",
    "8:  lbu a0, 0(t6)",
    "    beqz a0, 9f",
    "    call putc_",
    "    addi t6, t6, 1",
    "    j 8b",
    "9:  mv ra, t5",
    "    ret",
    "hex_:",
    "    mv t5, ra",
    "    mv t6, a0",
    "    li s2, 8",
    "10: srli a0, t6, 28",
    "    slli t6, t6, 4",
    "    addi a0, a0, 48",
    "    li t2, 58",
    "    blt a0, t2, 11f",
    "    addi a0, a0, 39",
    "11: call putc_",
    "    addi s2, s2, -1",
    "    bnez s2, 10b",
    "    mv ra, t5",
    "    ret",
]
for f in funcs:
    src += ["    " + l if not l.endswith(":") else l for l in f]
src += ["    .section .rodata", "msg: .asciz \"SIG \""]
open(a.out, "w").write("\n".join(src) + "\n")
