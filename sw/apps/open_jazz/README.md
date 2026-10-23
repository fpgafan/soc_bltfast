# OpenJazz for the bltfast SoC (Tang Nano 20K)

Port of **OpenJazz** (open source reimplementation of *Jazz Jackrabbit*, 1994,
Epic MegaGames) to the **bltfast** RISC-V SoC on the Sipeed Tang Nano 20K.
OpenJazz is GPL v2 (see `COPYING`); the libraries in `ext/` keep their own
licenses. No game data is included.

## What the port does

- **Video** (`sdl_bltfast.cpp`, a minimal SDL 1.2):
  - The game draws at 320×200, 8 bpp. `SDL_FillRect` and `SDL_BlitSurface`
    are done by the hardware **blitter** (DMA: fill, copy, color key); the CPU
    only queues commands. `SDL_LockSurface` waits for the blitter and
    invalidates the dcache before the CPU touches pixels directly (scaled
    sprites, bonus levels, cutscenes, menu plasma).
  - `SDL_Flip` scales the frame to **640×480@60 HDMI** with the blitter and uses
    **triple buffering** (the third framebuffer at `0x4078_0000`), so the game
    never waits for the vblank.
  - In game: ~140–170 frames per second generated (60 shown) with the blitter,
    ~60–70 drawing with the CPU.
- **Audio**: PSM music with `xmp` and the 8-bit effects of `SOUNDS.000`, mixed
  by OpenJazz at **22050 Hz** stereo into a DMA ring that the sound engine
  resamples to 48 kHz (HDMI and the I2S DAC). 22050 Hz rather than 48 kHz
  because OpenJazz keeps every effect converted to the output format: at 48 kHz
  they took over 2 MB of heap and loading the level after Diamondus 2 ran out
  of memory.
- **Input**: SNES/NES pad, PS/2 keyboard, buttons S1 (Escape) and S2 (Enter).
- **Files** (`sys_bltfast.c`): newlib system calls on the microSD (FAT16/FAT32,
  root directory, 8.3 names), heap between the program and the stack.
- **UART output**: OpenJazz's log, every 5 s `FPS: x  heap: ...` (frames per
  second and heap use), and a watchdog that prints the CPU address if no frame
  is shown for 3 s (loading a level takes 3–4 s, so a couple of messages there
  are normal).

## Controls

| Action | SNES pad | PS/2 keyboard | Board |
|---|---|---|---|
| **Move / crouch / look up** | D-pad | Arrows | |
| **Jump** | **A** | `Space` | |
| **Fire** | **B** or **Y** | `Left Alt` | |
| **Change weapon** | **X** | `Right Ctrl` | |
| **Accept / pause** | **Start** | `Enter` | **S2** |
| **Menu / quit / back** | **Select** | `Escape` | **S1** |

## microSD card

1. FAT32 (or FAT16).
2. Copy the files of the original *Jazz Jackrabbit* (shareware or registered)
   to the **root** of the card, not to a folder: `STARTUP.0SC`, `MENUSNG.PSM`,
   `SOUNDS.000`, `PANEL.000`, `BLOCKS.*`, `LEVEL*.*`, `PLANET.*`,
   `SPRITES.*`, the fonts (`*.0FN`) and the music (`*.PSM`).
3. Optional `JAZZ.TXT`: `draw=blitter` (default) or `draw=cpu` to draw with
   the CPU instead of the blitter.

## Building and running

```
cd sw
python build.py openjazz          # -> sw/build/openjazz.bin
python build.py openjazz --run    # load over UART and open the terminal
```

To boot without a PC: copy `sw/build/openjazz.bin` to the card as
`OPENJAZZ.BIN` and choose it in the boot menu (`python build.py bootmenu`,
copied as `BOOT.BIN`), or copy it directly as `BOOT.BIN`.
