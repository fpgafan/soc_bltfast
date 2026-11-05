#!/usr/bin/env python3
"""
build.py - Builds the software for the bltfast SoC.

  python build.py boot                boot ROM -> build/boot.hex (8 KB, bitstream ROM)
  python build.py boot --bit          + synthesize the bitstream (gw_sh build.tcl)
  python build.py boot --bit --prog   + load it into the FPGA (SRAM: lost on power-off)
  python build.py boot --bit --flash  + write it to flash (permanent)
  python build.py --prog              only load the current .fs into the FPGA
  python build.py <app>               apps/<app>/*.c + lib -> build/<app>.bin (at 0x4000_0000)
  python build.py bootmenu            SD program chooser -> build/sd/BOOT.BIN
  python build.py doom                Doom (apps/doom, with newlib) -> build/doom.bin
  python build.py openjazz            OpenJazz (apps/open_jazz, C++ with newlib) -> build/openjazz.bin
  python build.py genesis             Genesis emulator (apps/genesis, PicoDrive core) -> build/genesis.bin
  python build.py sonic1              Sonic 1 recompiled from s1disasm (apps/sonic1) -> build/sonic1.bin
  python build.py sonic2              Sonic 2 recompiled from s2disasm (apps/sonic2) -> build/sonic2.bin
  python build.py sonic3              Sonic 3 recompiled from skdisasm (apps/sonic3) -> build/sonic3.bin
  python build.py sonick              Sonic & Knuckles recompiled from skdisasm (apps/sonick) -> build/sonick.bin
  python build.py smw                 Super Mario World (snesrev/smw in apps/smw) -> build/smw.bin
  python build.py <app> --run         builds, loads over UART (tools/load.py) and opens the terminal
  python build.py --src <file> --run
                                      if the file is in apps/<app>/, builds that app;
                                      otherwise builds that loose .c with the library
  --port COMx                         serial port (auto-detected by default)
"""
import os, sys, subprocess, glob, struct, argparse

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
GCC = r"C:\riscv\xpack-riscv-none-elf-gcc-15.2.0-1\bin"
GOWIN = r"C:\Gowin\Gowin_V1.9.12.04_x64"
FS = os.path.join(ROOT, "impl", "pnr", "bltfast.fs")
os.environ["PATH"] = GCC + os.pathsep + os.environ["PATH"]
B = os.path.join(HERE, "build")
os.makedirs(B, exist_ok=True)
CFLAGS = ["-march=rv32im_zicsr_zifencei", "-mabi=ilp32", "-O2", "-g", "-Wall", "-Wextra",
          "-Wno-unused-parameter", "-ffreestanding", "-fno-builtin", "-nostdlib", "-nostartfiles",
          "-ffunction-sections", "-fdata-sections", "-I" + os.path.join(HERE, "lib")]
LIB = [os.path.join(HERE, "lib", f) for f in ("lib.c", "sd.c", "fat.c")]


def run(cmd, cwd=None):
    print(" ".join(os.path.basename(c) if os.path.isabs(c) else c for c in cmd[:3]), "...")
    subprocess.check_call(cmd, cwd=cwd)


def link(name, srcs, ld, opt):
    elf = os.path.join(B, name + ".elf")
    cf = [x for c in CFLAGS for x in (opt.split() if c == "-O2" else [c])]
    run(["riscv-none-elf-gcc"] + cf + srcs + ["-T" + ld, "-Wl,--gc-sections",
         "-Wl,-Map," + os.path.join(B, name + ".map"), "-Wl,--no-warn-rwx-segments", "-lgcc", "-o", elf])
    binf = os.path.join(B, name + ".bin")
    subprocess.check_call(["riscv-none-elf-objcopy", "-O", "binary", elf, binf])
    with open(os.path.join(B, name + ".lst"), "w") as f:
        subprocess.check_call(["riscv-none-elf-objdump", "-d", "-S", elf], stdout=f)
    return binf


def build_boot():
    binf = link("boot", [os.path.join(HERE, "boot", "start.S"), os.path.join(HERE, "boot", "boot.c")] + LIB,
                os.path.join(HERE, "boot", "boot.ld"), "-Os -DBOOTROM")
    data = open(binf, "rb").read()
    if len(data) > 8192:
        print(f"ERROR: the ROM takes {len(data)} bytes (> 8192)"); sys.exit(1)
    data += b"\x13\x00\x00\x00" * ((8192 - len(data)) // 4)
    with open(os.path.join(B, "boot.hex"), "w") as f:
        for i in range(0, 8192, 4):
            f.write("%08x\n" % struct.unpack_from("<I", data, i)[0])
    print(f"boot.hex: {os.path.getsize(binf)} / 8192 bytes")


def build_app(name, srcs):
    extra = [os.path.join(HERE, "lib", f) for f in ("crt0.S", "trap.c", "gfx.c", "audio.c", "midi.c", "oplsynth.c",
                                                    "genmidi_fd.c", "font8x8.c")
             if os.path.exists(os.path.join(HERE, "lib", f))]
    binf = link(name, extra + srcs + LIB, os.path.join(HERE, "lib", "app.ld"), "-O2")
    print(f"{name}.bin: {os.path.getsize(binf)} bytes")
    return binf


def build_bootmenu():
    """bootmenu/: program chooser for the SD -> build/sd/BOOT.BIN (copy it to the card's root)."""
    d = os.path.join(HERE, "bootmenu")
    srcs = [os.path.join(d, "start.S"), os.path.join(d, "menu.c")] + \
           [os.path.join(HERE, "lib", f) for f in ("gfx.c", "font8x8.c")] + LIB
    binf = link("bootmenu", srcs, os.path.join(d, "menu.ld"), "-Os")
    os.makedirs(os.path.join(B, "sd"), exist_ok=True)
    out = os.path.join(B, "sd", "BOOT.BIN")
    with open(binf, "rb") as fi, open(out, "wb") as fo:
        fo.write(fi.read())
    print(f"sd/BOOT.BIN: {os.path.getsize(out)} bytes (copy it to the root of the microSD)")
    return binf


def build_openjazz():
    """apps/open_jazz: OpenJazz + bltfast layer. Objects in build/open_jazz/."""
    from concurrent.futures import ThreadPoolExecutor
    d = os.path.join(HERE, "apps", "open_jazz")
    ob = os.path.join(B, "open_jazz")
    os.makedirs(ob, exist_ok=True)
    arch = ["-march=rv32im_zicsr_zifencei", "-mabi=ilp32", "-g", "-ffunction-sections", "-fdata-sections"]
    inc = [
        "-I" + os.path.join(HERE, "lib"),
        "-I" + os.path.join(d, "include"),
        "-I" + os.path.join(d, "src"),
        "-I" + os.path.join(d, "ext", "xmp"),
        "-I" + os.path.join(d, "ext", "miniz"),
        "-I" + os.path.join(d, "ext", "argparse"),
        "-I" + os.path.join(d, "ext", "stb")
    ]
    defs = [
        "-DBLTFAST",
        "-DOJ_SDL1=1",
        "-DPORTABLE",
        "-DFULLSCREEN_ONLY",
        "-DNO_RESIZE",
        "-DDEFAULT_SCREEN_WIDTH=320",
        "-DDEFAULT_SCREEN_HEIGHT=200",
        "-DMUSIC_SETTINGS=0",
        "-DLIBXMP_CORE_PLAYER",
        "-DLIBXMP_CORE_DISABLE_IT",
        "-DLIBXMP_STATIC",
        "-DMINIZ_NO_ARCHIVE_APIS",
        '-DOJ_VERSION=\"20260301\"',
        '-DOJ_DATE=\"2026-10-23\"'
    ]
    lib_flags = arch + ["-I" + os.path.join(HERE, "lib"), "-O2", "-Wall", "-Wextra", "-Wno-unused-parameter",
                        "-ffreestanding", "-fno-builtin", "-Dprintf=lib_printf"]
    c_flags = arch + inc + defs + ["-O2", "-Wall", "-Wextra", "-Wno-unused-parameter", "-w"]
    cpp_flags = arch + inc + defs + ["-O2", "-std=c++14", "-fexceptions", "-fno-rtti", "-Wall", "-Wextra",
                                     "-Wno-unused-parameter", "-Wno-unused-variable", "-w"]

    lib_srcs = [os.path.join(HERE, "lib", f) for f in ("crt0.S", "trap.c", "lib.c", "sd.c", "fat.c", "gfx.c", "audio.c", "font8x8.c")]
    c_srcs = [
        os.path.join(d, "sys_bltfast.c"),
        os.path.join(d, "ext", "miniz", "miniz.c"),
        os.path.join(d, "ext", "argparse", "argparse.c"),
        os.path.join(d, "ext", "stb", "stb_rect_pack.c")
    ]
    c_srcs += sorted(glob.glob(os.path.join(d, "ext", "xmp", "src", "*.c")))
    c_srcs += sorted(glob.glob(os.path.join(d, "ext", "xmp", "src", "loaders", "*.c")))

    cpp_srcs = [os.path.join(d, "sdl_bltfast.cpp")]
    for root, dirs, files in os.walk(os.path.join(d, "src")):
        if "jj2" in root: continue
        for f in files:
            if f.endswith(".cpp"):
                if "platforms" in root and f != "platform_interface.cpp":
                    continue
                cpp_srcs.append(os.path.join(root, f))
    cpp_srcs = sorted(cpp_srcs)

    jobs = [("riscv-none-elf-gcc", s, lib_flags) for s in lib_srcs]
    jobs += [("riscv-none-elf-gcc", s, c_flags) for s in c_srcs]
    jobs += [("riscv-none-elf-g++", s, cpp_flags) for s in cpp_srcs]

    def cc(job):
        compiler, src, flags = job
        base = os.path.splitext(os.path.basename(src))[0]
        parent = os.path.basename(os.path.dirname(src))
        obj_name = f"{parent}_{base}.o" if parent not in ("open_jazz", "src") else f"{base}.o"
        obj = os.path.join(ob, obj_name)
        if os.path.exists(obj) and os.path.getmtime(obj) > os.path.getmtime(src):
            return obj, None
        r = subprocess.run([compiler] + flags + ["-c", src, "-o", obj], capture_output=True, text=True)
        return obj, (os.path.basename(src) + ":\n" + r.stdout + r.stderr) if (r.returncode or r.stderr) else None

    with ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as ex:
        res = list(ex.map(cc, jobs))
    for _, msg in res:
        if msg: print(msg)
    objs = [o for o, _ in res]
    if not all(os.path.exists(o) for o in objs):
        sys.exit("ERROR: compilation failed")

    elf = os.path.join(B, "openjazz.elf")
    run(["riscv-none-elf-g++"] + arch + ["-nostartfiles", "-nostdlib"] + objs +
        ["-T" + os.path.join(HERE, "lib", "app.ld"), "-Wl,--gc-sections", "-Wl,-Map," + os.path.join(B, "openjazz.map"),
         "-Wl,--no-warn-rwx-segments", "-Wl,--start-group", "-lstdc++", "-lc", "-lm", "-lgcc", "-Wl,--end-group", "-o", elf])
    binf = os.path.join(B, "openjazz.bin")
    subprocess.check_call(["riscv-none-elf-objcopy", "-O", "binary", elf, binf])
    subprocess.check_call(["riscv-none-elf-size", elf])
    print(f"openjazz.bin: {os.path.getsize(binf)} bytes")
    return binf


def build_doom():
    """apps/doom: doomgeneric (src/) + bltfast layer, with newlib. Objects in build/doom/."""
    from concurrent.futures import ThreadPoolExecutor
    d = os.path.join(HERE, "apps", "doom")
    ob = os.path.join(B, "doom")
    os.makedirs(ob, exist_ok=True)
    arch = ["-march=rv32im_zicsr_zifencei", "-mabi=ilp32", "-g", "-ffunction-sections", "-fdata-sections"]
    inc = ["-I" + os.path.join(HERE, "lib"), "-I" + os.path.join(d, "src")]
    defs = ["-DBLTFAST", "-DFEATURE_SOUND", "-D_DEFAULT_SOURCE"]
    # the SoC library has its own printf: it is renamed to avoid clashing with newlib
    libf = arch + inc + ["-O2", "-Wall", "-Wextra", "-Wno-unused-parameter", "-ffreestanding",
                         "-fno-builtin", "-Dprintf=lib_printf"]
    jobs = [(os.path.join(HERE, "lib", f), libf) for f in
            ("crt0.S", "trap.c", "lib.c", "sd.c", "fat.c", "gfx.c", "audio.c", "midi.c", "oplsynth.c",
             "genmidi_fd.c", "font8x8.c")]
    jobs += [(f, arch + inc + defs + ["-O2", "-Wall", "-Wextra", "-Wno-unused-parameter"])
             for f in sorted(glob.glob(os.path.join(d, "*.c")))]
    jobs += [(f, arch + inc + defs + ["-O2", "-w"]) for f in sorted(glob.glob(os.path.join(d, "src", "*.c")))]

    def cc(job):
        src, flags = job
        obj = os.path.join(ob, os.path.splitext(os.path.basename(src))[0] + ".o")
        if os.path.exists(obj) and os.path.getmtime(obj) > max(
                [os.path.getmtime(src)] + [os.path.getmtime(h) for h in
                 glob.glob(os.path.join(d, "src", "*.h")) + glob.glob(os.path.join(HERE, "lib", "*.h"))]):
            return obj, None
        r = subprocess.run(["riscv-none-elf-gcc"] + flags + ["-c", src, "-o", obj],
                           capture_output=True, text=True)
        return obj, (os.path.basename(src) + ":\n" + r.stdout + r.stderr) if (r.returncode or r.stderr) else None
    with ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as ex:
        res = list(ex.map(cc, jobs))
    for _, msg in res:
        if msg: print(msg)
    objs = [o for o, _ in res]
    if not all(os.path.exists(o) for o in objs):
        sys.exit("ERROR: compilation failed")
    elf = os.path.join(B, "doom.elf")
    run(["riscv-none-elf-gcc"] + arch + ["-nostartfiles", "-nostdlib"] + objs +
        ["-T" + os.path.join(HERE, "lib", "app.ld"), "-Wl,--gc-sections", "-Wl,-Map," + os.path.join(B, "doom.map"),
         "-Wl,--no-warn-rwx-segments", "-Wl,--start-group", "-lc", "-lm", "-lgcc", "-Wl,--end-group", "-o", elf])
    binf = os.path.join(B, "doom.bin")
    subprocess.check_call(["riscv-none-elf-objcopy", "-O", "binary", elf, binf])
    subprocess.check_call(["riscv-none-elf-size", elf])
    print(f"doom.bin: {os.path.getsize(binf)} bytes")
    return binf


def build_genesis():
    """apps/genesis: PicoDrive core (picodrive/) + bltfast frontend, with newlib. Objects in build/genesis/."""
    from concurrent.futures import ThreadPoolExecutor
    d = os.path.join(HERE, "apps", "genesis")
    pd = os.path.join(d, "picodrive")
    ob = os.path.join(B, "genesis")
    os.makedirs(ob, exist_ok=True)
    arch = ["-march=rv32im_zicsr_zifencei", "-mabi=ilp32", "-g", "-ffunction-sections", "-fdata-sections"]
    inc = ["-I" + os.path.join(HERE, "lib"), "-I" + pd, "-I" + os.path.join(pd, "zlib")]
    # C cores: FAME/C (68000), CZ80 (Z80); the SH2 interpreter is only there for the 32X code
    defs = ["-DEMU_F68K", "-D_USE_CZ80", "-DNDEBUG", "-falign-functions=2"]
    libf = arch + inc + ["-O2", "-Wall", "-Wextra", "-Wno-unused-parameter", "-ffreestanding",
                         "-fno-builtin", "-Dprintf=lib_printf"]
    core = []
    for sub in ("pico", "pico/cd", "pico/pico", "pico/32x", "pico/carthw", "pico/carthw/svp"):
        core += glob.glob(os.path.join(pd, sub, "*.c"))
    # files #included by other files
    skip = ("carthw_cfg.c", "pico_cmn.c", "cell_map.c")
    core = [f for f in core if os.path.basename(f) not in skip]
    core += [os.path.join(pd, "pico", "sound", f) for f in
             ("sound.c", "resampler.c", "sn76496.c", "ym2612.c", "ym2413.c", "mix.c")]
    core += [os.path.join(pd, f) for f in ("cpu/fame/famec.c", "cpu/cz80/cz80.c", "cpu/sh2/sh2.c",
                                           "cpu/sh2/mame/sh2pico.c", "unzip/unzip.c")]
    core += glob.glob(os.path.join(pd, "zlib", "*.c"))
    jobs = [(os.path.join(HERE, "lib", f), libf) for f in
            ("crt0.S", "trap.c", "lib.c", "sd.c", "fat.c", "gfx.c", "audio.c", "font8x8.c")]
    jobs += [(f, arch + inc + defs + ["-O2", "-Wall", "-Wextra", "-Wno-unused-parameter", "-Wno-sign-compare"])
             for f in sorted(glob.glob(os.path.join(d, "*.c")))]
    # names that clash with the SoC library
    ren = ["-Dgfx_init=mcd_gfx_init", "-Dcrc32=zlib_crc32"]
    # hot cores (see tools/genprof.py): -O3 measured +12 % on the board (GENESIS_HOT_OPT to change it)
    hot = ("famec.c", "cz80.c", "ym2612.c", "draw2.c", "sn76496.c")
    hot_opt = os.environ.get("GENESIS_HOT_OPT", "-O3").split()
    jobs += [(f, arch + inc + defs + ren + (hot_opt if os.path.basename(f) in hot else ["-O2"]) + ["-w"])
             for f in sorted(core)]
    hdrs = glob.glob(os.path.join(HERE, "lib", "*.h")) + glob.glob(os.path.join(pd, "pico", "*.h"))

    def cc(job):
        src, flags = job
        rel = os.path.relpath(src, HERE).replace(os.sep, "_").replace("/", "_")
        obj = os.path.join(ob, os.path.splitext(rel)[0] + ".o")
        # the CPU cores #include their opcode files
        inc_deps = glob.glob(os.path.join(os.path.dirname(src), "*.[ch]")) if src.endswith(("cz80.c", "famec.c")) else []
        if os.path.exists(obj) and os.path.getmtime(obj) > max([os.path.getmtime(src)] +
                                                              [os.path.getmtime(h) for h in hdrs + inc_deps]):
            return obj, None
        r = subprocess.run(["riscv-none-elf-gcc"] + flags + ["-c", src, "-o", obj],
                           capture_output=True, text=True)
        return obj, (os.path.basename(src) + ":\n" + r.stdout + r.stderr) if (r.returncode or r.stderr) else None
    with ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as ex:
        res = list(ex.map(cc, jobs))
    for _, msg in res:
        if msg: print(msg)
    objs = [o for o, _ in res]
    if not all(os.path.exists(o) for o in objs):
        sys.exit("ERROR: compilation failed")
    elf = os.path.join(B, "genesis.elf")
    run(["riscv-none-elf-gcc"] + arch + ["-nostartfiles", "-nostdlib"] + objs +
        ["-T" + os.path.join(HERE, "lib", "app.ld"), "-Wl,--gc-sections", "-Wl,-Map," + os.path.join(B, "genesis.map"),
         "-Wl,--no-warn-rwx-segments", "-Wl,--start-group", "-lc", "-lm", "-lgcc", "-Wl,--end-group", "-o", elf])
    binf = os.path.join(B, "genesis.bin")
    subprocess.check_call(["riscv-none-elf-objcopy", "-O", "binary", elf, binf])
    subprocess.check_call(["riscv-none-elf-size", elf])
    print(f"genesis.bin: {os.path.getsize(binf)} bytes")
    return binf


def build_sonic1():
    """apps/sonic1: Sonic 1 recompiled from s1disasm (recomp/) + runtime. Objects in build/sonic1/."""
    return build_sonic("sonic1", "s1disasm", "s1built.bin", "sonic.lst", "s1code.c", ["s1dac.c"], "s1syms.h", "S1_CFLAGS")


def build_sonic2():
    """apps/sonic2: Sonic 2 recompiled from s2disasm (recomp/) + runtime. Objects in build/sonic2/."""
    return build_sonic("sonic2", "s2disasm", "s2built.bin", "s2.lst", "s2code.c", ["z80code.c"], "s2syms.h", "S2_CFLAGS")


def build_sonic3():
    """apps/sonic3: Sonic 3 recompiled from skdisasm (recomp/) + runtime. Objects in build/sonic3/."""
    # -Os for the recompiled code: 1.8 MB instead of 3.1 MB with -O2, which
    # with the 2 MB ROM would not fit in the 6 MB of the program
    return build_sonic("sonic3", "skdisasm", "s3built.bin", "s3.lst", "s3code.c", ["z80code.c"], "s3syms.h", "S3_CFLAGS",
                       gen_opt="-Os")


def build_sonick():
    """apps/sonick: Sonic & Knuckles (alone) recompiled from the skdisasm of apps/sonic3 (buildSK).
    Same runtime as Sonic 3. Objects in build/sonick/."""
    return build_sonic("sonick", os.path.join("..", "sonic3", "skdisasm"), "skbuilt.bin", "sonic3k.lst", "s3code.c",
                       ["z80code.c"], "s3syms.h", "SK_CFLAGS", gen_opt="-Os")


def build_sonic(name, disasm, romname, lstname, codename, extra_gen, symsname, cflags_env, gen_opt="-O2"):
    """Sonic 1/2: the 68000 code of the game recompiled (apps/<name>/recomp) + runtime."""
    from concurrent.futures import ThreadPoolExecutor
    d = os.path.join(HERE, "apps", name)
    dis = os.path.join(d, disasm)
    ob = os.path.join(B, name)
    os.makedirs(ob, exist_ok=True)
    rom, lst = os.path.join(dis, romname), os.path.join(dis, lstname)
    if not (os.path.exists(rom) and os.path.exists(lst)):
        sys.exit(f"build the disassembly first (apps/{name}/{disasm}: build.bat) to get {romname} and {lstname}")
    gen = os.path.join(ob, codename)
    deps = [rom, lst] + glob.glob(os.path.join(d, "recomp", "*.py"))
    if not os.path.exists(gen) or os.path.getmtime(gen) < max(os.path.getmtime(f) for f in deps):
        run([sys.executable, os.path.join(d, "recomp", "recomp.py"), rom, lst, ob])
    with open(os.path.join(ob, "rom.S"), "w") as f:
        f.write('.section .rodata.rom,"a"\n.balign 16\n.global ROM\nROM:\n.incbin "%s"\n' %
                os.path.join(ob, "rom.bin").replace("\\", "/"))
    arch = ["-march=rv32im_zicsr_zifencei", "-mabi=ilp32", "-g", "-ffunction-sections", "-fdata-sections"]
    flags = arch + ["-I" + os.path.join(HERE, "lib"), "-I" + d, "-I" + ob, "-O2", "-Wall", "-Wextra",
                    "-Wno-unused-parameter", "-ffreestanding", "-fno-builtin"] + os.environ.get(cflags_env, "").split()
    jobs = [(os.path.join(HERE, "lib", f), flags) for f in
            ("crt0.S", "trap.c", "lib.c", "sd.c", "fat.c", "gfx.c", "audio.c", "font8x8.c")]
    jobs += [(f, flags) for f in sorted(glob.glob(os.path.join(d, "*.c")))]
    jobs += [(os.path.join(ob, f), flags) for f in extra_gen]
    jobs += [(os.path.join(ob, "rom.S"), flags),
             (gen, [gen_opt if f == "-O2" else f for f in flags] + ["-Wno-unused-label", "-Wno-unused-variable", "-Wno-unused-but-set-variable"])]
    hdrs = glob.glob(os.path.join(HERE, "lib", "*.h")) + glob.glob(os.path.join(d, "*.h")) + \
        [os.path.join(ob, symsname)]
    # other flags (S1_CFLAGS / S2_CFLAGS) than last time: everything again
    fl_file = os.path.join(ob, "cflags.txt")
    if not os.path.exists(fl_file) or open(fl_file).read() != " ".join(flags):
        with open(fl_file, "w") as f:
            f.write(" ".join(flags))
    hdrs.append(fl_file)

    def cc(job):
        src, fl = job
        obj = os.path.join(ob, "o_" + os.path.splitext(os.path.basename(src))[0] + ".o")
        if os.path.exists(obj) and os.path.getmtime(obj) > max([os.path.getmtime(src)] +
                                                              [os.path.getmtime(h) for h in hdrs]):
            return obj, None
        r = subprocess.run(["riscv-none-elf-gcc"] + fl + ["-c", src, "-o", obj], capture_output=True, text=True)
        return obj, (os.path.basename(src) + ":\n" + r.stdout + r.stderr) if (r.returncode or r.stderr) else None
    with ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as ex:
        res = list(ex.map(cc, jobs))
    for _, msg in res:
        if msg: print(msg)
    objs = [o for o, _ in res]
    if not all(os.path.exists(o) for o in objs):
        sys.exit("ERROR: compilation failed")
    elf = os.path.join(B, name + ".elf")
    run(["riscv-none-elf-gcc"] + arch + ["-nostartfiles", "-nostdlib"] + objs +
        ["-T" + os.path.join(HERE, "lib", "app.ld"), "-Wl,--gc-sections", "-Wl,-Map," + os.path.join(B, name + ".map"),
         "-Wl,--no-warn-rwx-segments", "-lgcc", "-o", elf])
    binf = os.path.join(B, name + ".bin")
    subprocess.check_call(["riscv-none-elf-objcopy", "-O", "binary", elf, binf])
    subprocess.check_call(["riscv-none-elf-size", elf])
    print(f"{name}.bin: {os.path.getsize(binf)} bytes")
    return binf


def build_smw():
    """apps/smw: Super Mario World (snesrev/smw cloned in apps/smw/smw, C reimplementation)
    + bltfast layer (apps/smw/port), with newlib. Needs apps/smw/smw/smw_assets.dat
    (python assets/restool.py with the USA ROM). Objects in build/smw/."""
    from concurrent.futures import ThreadPoolExecutor
    d = os.path.join(HERE, "apps", "smw")
    up, port = os.path.join(d, "smw"), os.path.join(d, "port")
    ob = os.path.join(B, "smw")
    os.makedirs(ob, exist_ok=True)
    dat = os.path.join(up, "smw_assets.dat")
    if not os.path.exists(dat):
        sys.exit("missing apps/smw/smw/smw_assets.dat: run 'python assets/restool.py' there with smw.sfc (USA)")
    with open(os.path.join(ob, "assets.S"), "w") as f:
        f.write('.section .rodata.assets,"a"\n.balign 16\n.global smw_assets_dat, smw_assets_end\n'
                'smw_assets_dat:\n.incbin "%s"\nsmw_assets_end:\n' % dat.replace("\\", "/"))
    arch = ["-march=rv32im_zicsr_zifencei", "-mabi=ilp32", "-g", "-ffunction-sections", "-fdata-sections"]
    inc = ["-I" + os.path.join(HERE, "lib"), "-I" + port, "-I" + os.path.join(port, "sdlstub"),
           "-I" + os.path.join(up, "src"), "-I" + up]
    extra = os.environ.get("SMW_CFLAGS", "").split()
    libf = arch + inc + ["-O2", "-Wall", "-Wno-unused-parameter", "-ffreestanding", "-fno-builtin",
                         "-Dprintf=lib_printf"]
    gamef = arch + inc + ["-O2", "-w", "-fno-strict-aliasing"] + extra
    jobs = [(os.path.join(HERE, "lib", f), libf) for f in
            ("crt0.S", "trap.c", "lib.c", "sd.c", "fat.c", "gfx.c", "audio.c", "font8x8.c")]
    jobs += [(f, arch + inc + ["-O2", "-Wall", "-Wno-unused-parameter", "-Wno-unknown-pragmas", "-fno-strict-aliasing"] + extra)
             for f in sorted(glob.glob(os.path.join(port, "*.c")) + glob.glob(os.path.join(port, "*.S")))]
    skip = {"main.c", "opengl.c", "glsl_shader.c", "config.c"}
    jobs += [(f, gamef) for f in sorted(glob.glob(os.path.join(up, "src", "*.c")) +
                                        glob.glob(os.path.join(up, "src", "snes", "*.c")))
             if os.path.basename(f) not in skip]
    jobs += [(os.path.join(ob, "assets.S"), arch)]
    hdrs = (glob.glob(os.path.join(HERE, "lib", "*.h")) + glob.glob(os.path.join(port, "*.h")) +
            glob.glob(os.path.join(up, "src", "*.h")) + glob.glob(os.path.join(up, "src", "snes", "*.h")))
    fl_file = os.path.join(ob, "cflags.txt")
    if not os.path.exists(fl_file) or open(fl_file).read() != " ".join(gamef):
        with open(fl_file, "w") as f:
            f.write(" ".join(gamef))
    hdrs.append(fl_file)
    hmax = max(os.path.getmtime(h) for h in hdrs)

    def cc(job):
        src, flags = job
        obj = os.path.join(ob, os.path.splitext(os.path.basename(src))[0] + ".o")
        if os.path.exists(obj) and os.path.getmtime(obj) > max(os.path.getmtime(src), hmax):
            return obj, None
        r = subprocess.run(["riscv-none-elf-gcc"] + flags + ["-c", src, "-o", obj], capture_output=True, text=True)
        return obj, (os.path.basename(src) + ":\n" + r.stdout + r.stderr) if (r.returncode or r.stderr) else None
    with ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as ex:
        res = list(ex.map(cc, jobs))
    for _, msg in res:
        if msg: print(msg)
    objs = [o for o, _ in res]
    if not all(os.path.exists(o) for o in objs):
        sys.exit("ERROR: compilation failed")
    elf = os.path.join(B, "smw.elf")
    run(["riscv-none-elf-gcc"] + arch + ["-nostartfiles", "-nostdlib"] + objs +
        ["-T" + os.path.join(HERE, "lib", "app.ld"), "-Wl,--gc-sections", "-Wl,-Map," + os.path.join(B, "smw.map"),
         "-Wl,--no-warn-rwx-segments", "-Wl,--start-group", "-lc", "-lm", "-lgcc", "-Wl,--end-group", "-o", elf])
    binf = os.path.join(B, "smw.bin")
    subprocess.check_call(["riscv-none-elf-objcopy", "-O", "binary", elf, binf])
    subprocess.check_call(["riscv-none-elf-size", elf])
    print(f"smw.bin: {os.path.getsize(binf)} bytes")
    return binf


def app_sources(name):
    return sorted(glob.glob(os.path.join(HERE, "apps", name, "*.c")) +
                  glob.glob(os.path.join(HERE, "apps", name, "*.S")))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("what", nargs="?", help="boot or the name of an app in apps/")
    ap.add_argument("--src", help="open file: its app in apps/ or a loose .c")
    ap.add_argument("--run", action="store_true", help="load over UART and open the terminal")
    ap.add_argument("--port", help="serial port (COMx)")
    ap.add_argument("--bit", action="store_true", help="boot: synthesize the bitstream")
    ap.add_argument("--prog", action="store_true", help="load the bitstream into the FPGA (SRAM)")
    ap.add_argument("--flash", action="store_true", help="write the bitstream to flash")
    a = ap.parse_args()

    binf = None
    if a.what == "boot":
        build_boot()
        if a.bit:
            run([os.path.join(GOWIN, "IDE", "bin", "gw_sh.exe"), "build.tcl"], cwd=ROOT)
    elif a.what == "bootmenu":
        binf = build_bootmenu()
    elif a.what in ("openjazz", "open_jazz") or (a.src and os.path.abspath(a.src).startswith(os.path.join(HERE, "apps", "open_jazz"))):
        binf = build_openjazz()
    elif a.what == "doom" or (a.src and os.path.abspath(a.src).startswith(os.path.join(HERE, "apps", "doom"))):
        binf = build_doom()
    elif a.what == "genesis" or (a.src and os.path.abspath(a.src).startswith(os.path.join(HERE, "apps", "genesis"))):
        binf = build_genesis()
    elif a.what == "sonic1" or (a.src and os.path.abspath(a.src).startswith(os.path.join(HERE, "apps", "sonic1"))):
        binf = build_sonic1()
    elif a.what == "sonic2" or (a.src and os.path.abspath(a.src).startswith(os.path.join(HERE, "apps", "sonic2"))):
        binf = build_sonic2()
    elif a.what == "smw" or (a.src and os.path.abspath(a.src).startswith(os.path.join(HERE, "apps", "smw"))):
        binf = build_smw()
    elif a.what == "sonic3" or (a.src and os.path.abspath(a.src).startswith(os.path.join(HERE, "apps", "sonic3"))):
        binf = build_sonic3()
    elif a.what == "sonick" or (a.src and os.path.abspath(a.src).startswith(os.path.join(HERE, "apps", "sonick"))):
        binf = build_sonick()
    elif a.src:
        src = os.path.abspath(a.src)
        if not os.path.isfile(src):
            sys.exit(f"not found: {a.src}")
        rel = os.path.relpath(src, os.path.join(HERE, "apps")).split(os.sep)
        if len(rel) > 1 and rel[0] != "..":
            binf = build_app(rel[0], app_sources(rel[0]))          # file of an app
        elif src.endswith((".c", ".S")):
            binf = build_app(os.path.splitext(os.path.basename(src))[0], [src])
        else:
            sys.exit(f"don't know how to build {a.src} (open a .c)")
    elif a.what:
        srcs = app_sources(a.what)
        if not srcs:
            sys.exit("apps/" + a.what + " does not exist")
        binf = build_app(a.what, srcs)
    elif not (a.prog or a.flash):
        print(__doc__); sys.exit(1)

    if a.prog or a.flash:
        if not os.path.exists(FS):
            sys.exit(f"{FS} does not exist (python build.py boot --bit)")
        run([os.path.join(GOWIN, "Programmer", "bin", "programmer_cli.exe"),
             "--device", "GW2AR-18C", "--operation_index", "9" if a.flash else "2", "--fsFile", FS],
            cwd=os.path.join(GOWIN, "Programmer", "bin"))
    if a.run and binf:
        cmd = [sys.executable, os.path.join(ROOT, "tools", "load.py"), binf, "--term"]
        if a.port:
            cmd += ["--port", a.port]
        sys.exit(subprocess.call(cmd))


if __name__ == "__main__":
    main()
