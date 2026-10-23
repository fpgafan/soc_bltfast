# bltfast — RISC-V SoC with 2D engine and sound for the Tang Nano 20K

A SoC written from scratch for the Sipeed Tang Nano 20K (Gowin GW2AR-LV18QN88C8/I7):

| Block | Summary |
|---|---|
| **CPU** | Custom RV32IM_Zicsr, 6 stages (F1 F2 D E M W), **90 MHz** (timing constrained at 99 MHz: ~10 % margin). 8 KB I-cache, 8 KB write-through D-cache, static prediction + JAL + return address stack, 4-cycle MUL (DSP), 12–38 cycle DIV, interrupts (timer, external, software) |
| **Memory** | 8 MB embedded SDRAM, controller with 4 masters (video > sound > CPU ↔ 2D engine), bursts of up to 16 words; programmable capture latency and SDRAM clock phase (the boot ROM calibrates them automatically) |
| **Video** | 640×480@60, 8 bpp with a 256-color RGB888 palette, double-buffered framebuffer in SDRAM, **hardware scrolling** with continuous horizontal and vertical wrap-around, VBLANK and raster interrupts |
| **HDMI** | TMDS + data islands: **48 kHz PCM audio over HDMI**, AVI/Audio InfoFrames |
| **2D engine (blitter)** | 32-command DMA queue: fill, copy with **scaling and mirroring**, **transparency** (color key), palette offset, 1 bpp text (fonts), lines; hardware clipping. 4 pixels/cycle for 1:1 copies and upscaling |
| **Sound** | **32 wavetable/PCM voices** with DMA from SDRAM: 8/16 bits, mono/stereo, 16.16 pitch, linear interpolation, **hardware ADSR**, L/R volume, loops and events for streaming. Output over HDMI and through the board's I2S DAC + amplifier |
| **FM (OPL2)** | Hardware FM synthesizer compatible with the **YM3812 (AdLib / Sound Blaster)**: 9 channels × 2 operators, 4 waveforms, vibrato/tremolo, KSL/KSR, feedback; bit-exact with Nuked-OPL3 in OPL2 mode. Mixed into the sound engine output |
| **MIDI** | Software player for standard MIDI files (type 0/1): on the sample voices (16 channels, GM instruments by family with generated band-limited waveforms, percussion on channel 10) or **on the OPL2** with GENMIDI banks (the bundled Freedoom one or the one from a Doom WAD) |
| **I/O** | UART (2 Mbaud loader), microSD (SPI with hardware block transfers, FAT32/16), 2 SNES/NES pads, PS/2 keyboard, 6 LEDs, 2 buttons |

Utilization (Gowin 1.9.12.04): ~73 % of the logic, 33/46 BSRAM, 13/24 DSP, 2/2 PLL.

## Layout

```
rtl/            Verilog (cpu/, mem/, video/, audio/, periph/, soc_top.v, clocks.v)
constraints/    pins (.cst) and clocks (.sdc)
sim/            testbenches and models (Icarus Verilog) + Python tests
sw/             software: boot/ (ROM), lib/ (runtime, gfx, sound, MIDI, SD/FAT), apps/doom
tools/          load.py (UART loader), img2c.py, midi2c.py, img2tex.py, wav2pcm.py, mkmidi.py, mkfont.py, timing.py
build.tcl       synthesis + PnR with Gowin EDA
```

Of the applications in `sw/apps`, only Doom is published in this repository.

## Building and loading

Requirements: Gowin EDA 1.9.12 (licensed), xPack `riscv-none-elf-gcc` in `C:\riscv`, Python 3 with `pyserial` and `pillow`.

```
cd sw
python build.py boot                       # boot ROM -> sw/build/boot.hex
cd ..
C:\Gowin\Gowin_V1.9.12.04_x64\IDE\bin\gw_sh.exe build.tcl     # bitstream: impl/pnr/bltfast.fs
openFPGALoader -b tangnano20k impl/pnr/bltfast.fs             # or Gowin Programmer (SRAM or flash)
cd sw
python build.py doom --run                 # builds Doom, loads it over UART and opens the terminal
```

The boot ROM:
1. Calibrates the SDRAM (8 latencies × 16 phases; prints the table and the choice).
2. Announces `RVBOOT` and accepts programs over the UART (`tools/load.py`, which first
   sends `RVRST!` to reset the board and then switches to 2 Mbaud).
3. If nothing arrives within 1.5 s, it boots `BOOT.BIN` from the microSD (FAT32/FAT16,
   root directory). To boot without a PC: copy e.g. `sw/build/doom.bin` as `BOOT.BIN`.

## Memory map

| Address | Contents |
|---|---|
| `0x0000_0000` | boot ROM, 8 KB (cacheable) |
| `0x1000_0000` | internal RAM, 4 KB (uncached; ROM stack) |
| `0x4000_0000` | 8 MB SDRAM (cacheable). Programs from `0x4000_0000`, stack growing down from `0x4060_0000`; `0x4060_0000`/`0x4068_0000` framebuffers; `0x4070_0000-0x407F_FFFF` samples/textures |
| `0x5000_0000` | the same SDRAM, uncached (to read what the blitter or the sound engine wrote) |
| `0x8000_0000` | peripherals (below) |

**Coherency**: the dcache is write-through; stores go through two write-combining
buffers that flush themselves (and always before any I/O access, so by the time a
blitter register is written everything before it is already in SDRAM).
If a peripheral **writes** to SDRAM (blitter) and the CPU wants to read it, use
the `0x5xxx_xxxx` alias or execute `fence` (invalidates the dcache). After writing
code, `fence.i`.

## Registers

All the names are in `sw/lib/soc.h`. Summary:

- **sysctl `0x8000_0000`**: ID, LED, BTN (level of the S1/S2 pins), CLK_HZ,
  MTIME/MTIMECMP (64 bits, cycles), MSIP, IRQ_PEND/IRQ_EN (0 UART, 1 VBLANK,
  2 RASTER, 3 blitter, 4 sound, 5 PS/2), SDRAM (latency/phase), RESET
  (`0x5EB007`), SCRATCH, MISC (bit 0 amplifier).
- **UART `0x8000_1000`**: DATA, STAT, DIV (cycles per bit), IE. Receiving `RVRST!` resets the SoC.
- **Video `0x8000_2000`**: CTRL (EN, LIVE, HDMI), FB_BASE, STRIDE, SCROLL_X/Y,
  WRAP_W (ring of 2^n·256 bytes), WRAP_H (rows), BORDER, RASTER, STATUS,
  PENDING. Changes are applied at the start of the frame (or per line with LIVE).
  Palette at `0x8000_3000` (256 × `0x00RRGGBB`).
- **Blitter `0x8000_4000`**: DST/DSTRIDE/CLIP0/CLIP1 (destination surface),
  SRC/SSTRIDE, XY, SIZE, COLOR (fg, bg, key, paloff), U0/V0/DU/DV (16.16),
  CMD (queues: FILL, BLIT, EXPAND, LINE + flags), STATUS, IRQ. See `rtl/video/blitter.v`.
- **Sound `0x8000_5000`**: 32 voices × {CTRL, START, LEN, LOOP, PITCH, VOL, ADSR};
  globals CTRL (volume), KEYON, KEYOFF, STOP, ACTIVE, EVENT, IRQ_EN, COUNT,
  LAST, MON_*. See `rtl/audio/audio.v`.
- **SD `0x8000_6000`**, **pads `0x8000_7000`**, **PS/2 `0x8000_8000`**.
- **FM OPL2 `0x8000_9000`**: YM3812 register n at `OPL_REG(n)` (+n·4, like
  writing n to 0x388 and the data to 0x389, with no delays); GAIN (+0x400, 0x40 = 1.0)
  and COUNT (+0x404, samples at ~49716 Hz). No rhythm mode and no timers.
  See `rtl/audio/opl2.v`.

## Pins

| Signal | Pin | Notes |
|---|---|---|
| HDMI | 33–40 | on-board connector |
| I2S BCLK / LRCK / DATA, PA_EN | 56 / 55 / 54, 51 | on-board DAC + amplifier |
| microSD CLK / CMD / DAT0 / DAT3 | 83 / 82 / 84 / 81 | on-board slot |
| Pad 1 LATCH / CLK / DATA | 28 / 27 / 25 | as in nestang |
| Pad 2 LATCH / CLK / DATA | 29 / 26 / 30 | |
| PS/2 CLK / DATA | 41 / 42 | **5 V**: use level shifting |
| UART TX / RX | 69 / 70 | BL616 USB |
| LEDs, S1/S2 | 15–20, 88/87 | |

## Programming

```c
#include "lib.h"
#include "gfx.h"
#include "audio.h"

int main(void) {
    gfx_init();                                  // video + double buffer
    snd_init();
    midi_use_opl(0);                // optional: FM on the OPL2 (Freedoom bank)
    midi_load(my_song, len); midi_play(1);
    for (;;) {
        gfx_clear(0);
        gfx_blit(&sprites, 0, 0, 32, 32, x, y, GFX_KEY, 0);   // with transparency
        gfx_blit_scaled(&sprites, 0, 0, 32, 32, 100, 100, 64, 64, GFX_FLIPX, 0);
        gfx_text(8, 8, "Hello", 15, -1);
        midi_update();
        gfx_flip();                              // waits for the blitter and flips on vblank
    }
}
```

**MIDI on the OPL2** (`sw/lib/oplsynth.c`): `midi_use_opl(0)` sends the notes to the
OPL2 with Freedoom's GENMIDI bank (bundled); `midi_use_opl(bank)` uses another
GENMIDI bank in memory and `midi_use_opl_wad("DOOM    WAD")` reads the original one
from a WAD on the SD. `midi_load_file("SONG    MID", buf, max)` loads a `.MID` from
the card's root; `midi_use_samples()` goes back to the sample voices. Like DMX (Doom's
driver): 9 voices, 1- or 2-voice instruments, percussion on notes 35-81
of channel 10 and everything one octave above the MIDI note (that is how the
GENMIDI banks are tuned). Files must be in the root with an 8.3 name
(e.g. `SONG.MID`; long names are not seen) and be at most 512 KB.

Tools (`python tools/<tool> -h` shows the options):

- `tools/img2c.py image.png sw/apps/x/image.h [--transparent] [--width W] [--pixelated] [--palette custom --base B --colors N]`:
  image to a C header with the 8 bpp texture, its size, the transparent index
  and a `surface` ready for `gfx_blit` (`IMAGE_SURF`). With the default palette
  nothing has to be loaded; with `--palette custom`, call `image_pal_load()`.
- `tools/midi2c.py song.mid sw/apps/x/song.h [--transpose S] [--no-drums] [--channels 1,2] [--tempo F] [--max-sec S] [--vol V]`:
  MIDI to a C header for `midi_load(song, SONG_LEN)`; checks the file and
  reports channels, instruments and polyphony.
- `tools/wav2pcm.py` (WAV to PCM), `tools/img2tex.py` (image to .bin/.c), `tools/mkmidi.py` (demo song).

## Verification (simulation)

| Test | What it checks |
|---|---|
| `sim/run_isa.py` | 49 official riscv-tests (rv32ui + rv32um) on CPU + SDRAM |
| `sim/run_rand.py N` | random RV32IM programs (ALU, mul/div, cached and uncached loads/stores, I/O, fence, branches, loops, calls) against a Python ISS: registers and memory |
| `sim/run_blit.py N` | random blitter commands (every operation, clipping, scaling, mirroring, transparency) against a model, byte by byte; with `--vid` it competes with video traffic |
| `sim/run_audio.py N` | 32 voices with random parameters and events against a bit-exact model |
| `sim/run_opl.py S N [--musical]` | OPL2: random registers or notes with instruments, sample by sample against `sim/oplmodel.py` (port of Nuked-OPL3, validated against the original compiled for RISC-V) |
| `sim/run_vid.py` | a full decoded TMDS frame: pixels = palette[framebuffer] with scroll/wrap, syncs, data islands with BCH ECC, ACR, InfoFrames and audio samples |
| `sim/tb/tb_soc.v` | full SoC: ROM boot, calibration and loading a program over the UART |

Design notes for Fmax: no late signal (cache hit) reaches the enables of the
whole pipeline — dcache misses cause a *replay*; writes go through a registered
FIFO; peripheral paths are pipelined. `tools/timing.py` summarizes the Gowin report.

## Doom

`sw/apps/doom`: Doom (based on [doomgeneric](https://github.com/ozkl/doomgeneric),
derived from Chocolate Doom, GPL v2 — see `src/LICENSE`) with a custom layer:

| File | What it does |
|---|---|
| `doomgeneric_bltfast.c` | startup, video (the blitter scales 320×200 → 640×480, 4:3 as on DOS), hardware palette, PS/2 keyboard, pads, ENDOOM and error screen |
| `i_sound_bltfast.c` | effects on voices 24–31 (DMX PCM converted to signed 8 bits at `0x4074_0000`); music with the `lib/midi.c` MIDI player (voices 0–23) if `-synth` is given or the bitstream has no OPL2 |
| `src/i_oplmusic.c` | music as on DOS with a Sound Blaster: Chocolate Doom's OPL player with the WAD's `GENMIDI` instruments, on the hardware OPL2 |
| `opl_bltfast.c` | driver for Chocolate Doom's `opl.h` API: writes the OPL2 registers and runs the scheduled callbacks from the 500 Hz interrupt |
| `midi_stream.c` | `midifile.h` API reading the events on the fly (the original version takes ~400 KB with the long Doom 2 songs) |
| `sys_bltfast.c` | newlib system calls: stdout/stderr over the UART, files in the SD root, `malloc` |
| `w_file_bltfast.c` | unbuffered WAD reading, with a cluster table (`fat_map`) to seek to any lump |
| `src/` | doomgeneric code; changes are under `#ifdef BLTFAST` |

```
cd sw
python build.py doom          # -> build/doom.bin (~590 KB)
python build.py doom --run    # load over UART
```

**microSD** (FAT32/FAT16, root directory, 8.3 names): copy the IWAD
(`DOOM1.WAD`, `DOOM.WAD`, `DOOM2.WAD`, `PLUTONIA.WAD` or `TNT.WAD`; if there are
several, the first of doom2, plutonia, tnt, doom, doom1 is used, unless
`-iwad` is given) and, to boot without a PC, `build/doom.bin`
as `BOOT.BIN`. Optional: `DOOMARGS.TXT` with arguments, e.g.
`-iwad doom.wad -warp 1 3 -skill 4` or `-file mymod.wad`. Doom stores
`DEFAULT.CFG`, `DOOMGENE.CFG` and the saved games `DOOMSAVn.DSG` on the SD.

**Music**: with the OPL2 it sounds like DOS with a Sound Blaster (same
FM instruments, the ones in the `GENMIDI` lump). `-synth` in `DOOMARGS.TXT` uses
the `lib/midi.c` synthesizer instead.

**Controls**: keyboard as on DOS (arrows, Ctrl fires, space opens,
Shift runs, Alt + arrows strafe, `,` `.` strafe, `[` `]` switch weapons,
1–7 weapons, Tab map, Esc menu, F2/F3 save/load). SNES pad: D-pad =
move, B = fire, A = open, Y = run, X = next weapon, L/R = strafe,
Start = menu, Select = map; in menus A = accept and B = back, in
prompts A = yes and B = no. S1 = Esc, S2 = Enter.

Memory: program ~0.8 MB from `0x4000_0000`, Doom zone ~4.4 MB, 512 KB
for `malloc` and 256 KB of stack below `0x4060_0000`. The timer interrupts at
500 Hz (MIDI and pad sampling). If Doom exits with an error, the message
is shown on screen (and over the UART) and a key resets the SoC.

**Doom 2**: the same `doom.bin` works for Doom 1 and Doom 2 (tested on the board and
in the emulator with the demos, MAP15 and MAP29). If both `DOOM2.WAD` and
`DOOM.WAD` are on the SD, Doom 2 wins; to play Doom 1, put `-iwad doom.wad` in `DOOMARGS.TXT`.

**FPS**: every 5 s Doom prints the frames per second over the UART (only frames
with a new game tic count). On the board: 33–35 FPS in the demos.

**microSD after a reset**: if the board is reset in the middle of a read,
the card may keep sending the pending block and not respond to CMD0.
`sd_init` (`sw/lib/sd.c`) retries up to 8 times, first draining 600 bytes
with CS active, so "no microSD card" no longer appears after a reset.

## Test tools

| Tool | Use |
|---|---|
| `sim/rvtorture.py` + `sim/torture.sh` | random RV32IM programs (ALU, MUL/DIV, loads/stores, branches, calls, I/O, video) run on the board and in the emulator; compares the final signature |
| `tools/socemu.js` | functional SoC emulator in Node.js (CPU, SD, blitter, video, PS/2, pads, OPL2): runs a `.bin`, saves PNG screenshots (`--shots`), simulates keys/pads (`--keys`, `--pads`) and records the FM music into a WAV (`--oplwav`, with `tools/opl2.js`) |

## History

| Date | Changes |
|---|---|
| 2026-10-21 | First version: full SoC (RV32IM CPU at 90 MHz, SDRAM, video + HDMI with audio, blitter, 32 voices, microSD, pads, PS/2), library, simulation tests and Doom port |
| 2026-10-21 | Doom 2 tested; Doom FPS counter over the UART; `sd_init` recovers after a reset in the middle of a read; 90 MHz bitstream written to flash |
| 2026-10-21 | **Hardware OPL2 (YM3812)** at `0x8000_9000` (`rtl/audio/opl2.v`), added to the `audio.v` mix; verified bit by bit with `sim/run_opl.py` against `sim/oplmodel.py` (Nuked-OPL3); emulator with OPL2 (`tools/opl2.js`, `--oplwav`). **Doom with FM music as on DOS**: Chocolate Doom's `i_oplmusic.c` with the WAD's `GENMIDI`, `opl_bltfast.c` and `midi_stream.c`. ~73 % logic utilization, Fmax 99.75 MHz |
| 2026-10-21 | **MIDI on the OPL2 for custom programs** (`sw/lib/oplsynth.c`, Freedoom bank `genmidi_fd.c`, `midi_use_opl*` API, `midi_load_file`) |

## Future plans

### Doom music with sampled instruments (wavetable)

Right now `lib/midi.c` synthesizes each instrument with simple waveforms + ADSR, which
is why the music sounds "chippy". With real samples (like a Sound Canvas or a
General MIDI SoundFont) it would sound much more natural. The hardware already plays
PCM from SDRAM with pitch, volume and envelope (that is how the effects work), so
it is mostly software:

1. A `tools/sf2bank.py` tool: extract from a free SoundFont (e.g.
   GeneralUser GS) only the GM programs and percussion used by the music in
   `DOOM.WAD` and `DOOM2.WAD` (~30–40 programs + drums), at 8 bits and ~22 kHz
   with short loops and key-range zones → `INSTR.DAT` (target 1–1.5 MB).
2. Doom loads `INSTR.DAT` from the SD at startup; if it does not exist, the
   current synthesis is used.
3. `midi.c`: sample mode (pick a zone per note, pitch relative to the root
   note, loop, SoundFont envelope); the rest of the player stays the same.
4. Memory: the bank comes out of the Doom zone (4.4 MB → ~3 MB). Check in
   the emulator that the large Doom 2 maps (MAP15, MAP29) and common
   PWADs do not hit `Z_Malloc failed`; if they do not fit, a smaller bank
   (11 kHz or fewer programs).

### Doom performance

Measured on the board (Doom 1 timedemo demo1): **33.2 FPS**, ~30 ms per frame,
of which the blitter (scaling) takes 2.9 ms and the rest is CPU
(`R_DrawColumn`/`R_DrawSpan`, limited by SDRAM accesses). Ideas, from
least to most work:

1. Scale the previous frame with the blitter while the CPU draws the
   next one (double-buffered `I_VideoBuffer`): ~3 ms per frame.
2. Profile with `tools/socemu.js --prof` and move the column and
   span loops to assembly.
3. A larger data cache (8 KB → 16–32 KB, there are free BSRAMs) and/or the colormap
   in its own BSRAM.
4. A blitter mode that draws textured columns/spans with a colormap.

An FPU would not help: Doom uses fixed point. 60 FPS would also require
interpolation between tics (the engine runs at 35 Hz).

## License

The SoC (RTL, library, applications and tools) is released under the
**MIT** license (see `LICENSE`), except:

- `sw/apps/doom/src/`: doomgeneric / Chocolate Doom, **GPL v2**. Binaries
  that include Doom are distributed under GPL v2.
- `sim/tests/`: riscv-tests, BSD license.
- `sw/lib/genmidi_fd.c`: FM instruments from [Freedoom](https://freedoom.github.io/), BSD license (included in the file).
- `rtl/audio/opl2.v`, `sim/oplmodel.py`, `tools/opl2.js`: follow the algorithm
  and tables of [Nuked-OPL3](https://github.com/nukeykt/Nuked-OPL3) (nukeykt),
  **LGPL 2.1** (see `rtl/audio/LICENSE.nuked-opl3`).
- `sw/apps/doom/midi_stream.c` and `opl_bltfast.c` implement Chocolate Doom APIs
  and ship with Doom: **GPL v2**.

The Doom WADs are **not** included: use your own (`DOOM.WAD`,
`DOOM2.WAD`…), the shareware `DOOM1.WAD` or [Freedoom](https://freedoom.github.io/).
