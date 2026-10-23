# bltfast — SoC RISC-V con motor 2D y sonido para Tang Nano 20K

SoC escrito desde cero para la Sipeed Tang Nano 20K (Gowin GW2AR-LV18QN88C8/I7):

| Bloque | Resumen |
|---|---|
| **CPU** | RV32IM_Zicsr propia, 6 etapas (F1 F2 D E M W), **90 MHz** (restricción de timing a 99 MHz: ~10 % de margen). I-cache 8 KB, D-cache 8 KB write-through, predicción estática + JAL + pila de retornos, MUL en 4 ciclos (DSP), DIV 12–38 ciclos, interrupciones (timer, externa, software) |
| **Memoria** | SDRAM embebida de 8 MB, controlador con 4 maestros (vídeo > sonido > CPU ↔ motor 2D), ráfagas de hasta 16 palabras; latencia de captura y fase del reloj de la SDRAM programables (la ROM las calibra sola) |
| **Vídeo** | 640×480@60, 8 bpp con paleta de 256 colores RGB888, framebuffer en SDRAM con doble buffer, **scroll por hardware** con vuelta continua (wrap) horizontal y vertical, interrupciones de VBLANK y raster |
| **HDMI** | TMDS + data islands: **audio PCM 48 kHz por HDMI**, AVI/Audio InfoFrame |
| **Motor 2D (blitter)** | Cola de 32 comandos por DMA: relleno, copia con **escalado y espejo**, **transparencia** (color clave), desplazamiento de paleta, texto 1 bpp (fuentes), líneas; recorte por hardware. 4 píxeles/ciclo en copias 1:1 y ampliaciones |
| **Sonido** | **32 voces** wavetable/PCM por DMA desde la SDRAM: 8/16 bits, mono/estéreo, tono 16.16, interpolación lineal, **ADSR por hardware**, volumen L/R, bucles y eventos para streaming. Salida por HDMI y por el DAC I2S + amplificador de la placa |
| **FM (OPL2)** | Sintetizador FM compatible con el **YM3812 (AdLib / Sound Blaster)** por hardware: 9 canales × 2 operadores, 4 ondas, vibrato/trémolo, KSL/KSR, realimentación; bit a bit igual que Nuked-OPL3 en modo OPL2. Se suma a la mezcla del motor de sonido |
| **MIDI** | Reproductor de ficheros MIDI estándar (tipo 0/1) en software: sobre las voces (16 canales, instrumentos GM por familias con ondas de banda limitada generadas, percusión en el canal 10) o **sobre el OPL2** con bancos GENMIDI (el de Freedoom incluido o el de un WAD de Doom) |
| **E/S** | UART (cargador a 2 Mbaudios), microSD (SPI con bloques por hardware, FAT32/16), 2 mandos SNES/NES, teclado PS/2, 6 LEDs, 2 botones |

Ocupación (Gowin 1.9.12.04): ~73 % de la lógica, 33/46 BSRAM, 13/24 DSP, 2/2 PLL.

## Estructura

```
rtl/            Verilog (cpu/, mem/, video/, audio/, periph/, soc_top.v, clocks.v)
constraints/    pines (.cst) y relojes (.sdc)
sim/            bancos de pruebas y modelos (Icarus Verilog) + pruebas en Python
sw/             software: boot/ (ROM), lib/ (runtime, gfx, sonido, MIDI, SD/FAT), apps/
tools/          load.py (cargador UART), img2c.py, midi2c.py, img2tex.py, wav2pcm.py, mkmidi.py, mkfont.py, timing.py
build.tcl       síntesis + PnR con Gowin EDA
```

## Compilar y cargar

Requisitos: Gowin EDA 1.9.12 (con licencia), xPack `riscv-none-elf-gcc` en `C:\riscv`, Python 3 con `pyserial` y `pillow`.

```
cd sw
python build.py boot                       # ROM de arranque -> sw/build/boot.hex
cd ..
C:\Gowin\Gowin_V1.9.12.04_x64\IDE\bin\gw_sh.exe build.tcl     # bitstream: impl/pnr/bltfast.fs
openFPGALoader -b tangnano20k impl/pnr/bltfast.fs             # o Gowin Programmer (SRAM o flash)
cd sw
python build.py demo --run                 # compila la demo, la carga por UART y abre el terminal
```

La ROM de arranque:
1. Calibra la SDRAM (8 latencias × 16 fases; imprime la tabla y la elección).
2. Anuncia `RVBOOT` y acepta programas por la UART (`tools/load.py`, que primero
   envía `RVRST!` para reiniciar la placa y luego sube a 2 Mbaudios).
3. Si en 1,5 s no llega nada, arranca `BOOT.BIN` de la microSD (FAT32/FAT16,
   directorio raíz). Para arrancar sin PC: copia `sw/build/demo.bin` como `BOOT.BIN`.

## Mapa de memoria

| Dirección | Contenido |
|---|---|
| `0x0000_0000` | ROM de arranque, 8 KB (cacheable) |
| `0x1000_0000` | RAM interna, 4 KB (sin caché; pila de la ROM) |
| `0x4000_0000` | SDRAM 8 MB (cacheable). Programas desde `0x4000_0000`, pila hacia abajo desde `0x4060_0000`; `0x4060_0000`/`0x4068_0000` framebuffers; `0x4070_0000-0x407F_FFFF` muestras/texturas |
| `0x5000_0000` | la misma SDRAM sin caché (para leer lo que escribieron el blitter o el sonido) |
| `0x8000_0000` | periféricos (abajo) |

**Coherencia**: la dcache es write-through; los stores pasan por dos buffers de
combinación que se vacían solos (y siempre antes de cualquier acceso a E/S, así
que al escribir un registro del blitter todo lo anterior ya está en la SDRAM).
Si un periférico **escribe** en la SDRAM (blitter) y la CPU quiere leerlo, usar
el alias `0x5xxx_xxxx` o ejecutar `fence` (invalida la dcache). Tras escribir
código, `fence.i`.

## Registros

Todos los nombres están en `sw/lib/soc.h`. Resumen:

- **sysctl `0x8000_0000`**: ID, LED, BTN (nivel de los pines S1/S2), CLK_HZ,
  MTIME/MTIMECMP (64 bits, ciclos), MSIP, IRQ_PEND/IRQ_EN (0 UART, 1 VBLANK,
  2 RASTER, 3 blitter, 4 sonido, 5 PS/2), SDRAM (latencia/fase), RESET
  (`0x5EB007`), SCRATCH, MISC (bit 0 amplificador).
- **UART `0x8000_1000`**: DATA, STAT, DIV (ciclos por bit), IE. Recibir `RVRST!` reinicia el SoC.
- **Vídeo `0x8000_2000`**: CTRL (EN, LIVE, HDMI), FB_BASE, STRIDE, SCROLL_X/Y,
  WRAP_W (anillo de 2^n·256 bytes), WRAP_H (filas), BORDER, RASTER, STATUS,
  PENDING. Los cambios se aplican al empezar el cuadro (o por línea con LIVE).
  Paleta en `0x8000_3000` (256 × `0x00RRGGBB`).
- **Blitter `0x8000_4000`**: DST/DSTRIDE/CLIP0/CLIP1 (superficie destino),
  SRC/SSTRIDE, XY, SIZE, COLOR (fg, bg, key, paloff), U0/V0/DU/DV (16.16),
  CMD (encola: FILL, BLIT, EXPAND, LINE + flags), STATUS, IRQ. Ver `rtl/video/blitter.v`.
- **Sonido `0x8000_5000`**: 32 voces × {CTRL, START, LEN, LOOP, PITCH, VOL, ADSR};
  globales CTRL (volumen), KEYON, KEYOFF, STOP, ACTIVE, EVENT, IRQ_EN, COUNT,
  LAST, MON_*. Ver `rtl/audio/audio.v`.
- **SD `0x8000_6000`**, **mandos `0x8000_7000`**, **PS/2 `0x8000_8000`**.
- **FM OPL2 `0x8000_9000`**: registro n del YM3812 en `OPL_REG(n)` (+n·4, como
  escribir n en 0x388 y el dato en 0x389, sin esperas); GAIN (+0x400, 0x40 = 1.0)
  y COUNT (+0x404, muestras a ~49716 Hz). Sin modo de ritmo ni temporizadores.
  Ver `rtl/audio/opl2.v`.

## Pines

| Señal | Pin | Notas |
|---|---|---|
| HDMI | 33–40 | conector de la placa |
| I2S BCLK / LRCK / DATA, PA_EN | 56 / 55 / 54, 51 | DAC + amplificador de la placa |
| microSD CLK / CMD / DAT0 / DAT3 | 83 / 82 / 84 / 81 | ranura de la placa |
| Mando 1 LATCH / CLK / DATA | 28 / 27 / 25 | como nestang |
| Mando 2 LATCH / CLK / DATA | 29 / 26 / 30 | |
| PS/2 CLK / DATA | 41 / 42 | **5 V**: usar adaptación de nivel |
| UART TX / RX | 69 / 70 | USB del BL616 |
| LEDs, S1/S2 | 15–20, 88/87 | |

## Programar

```c
#include "lib.h"
#include "gfx.h"
#include "audio.h"

int main(void) {
    gfx_init();                                  // vídeo + doble buffer
    snd_init();
    midi_use_opl(0);                // opcional: FM por el OPL2 (banco de Freedoom)
    midi_load(mi_cancion, len); midi_play(1);
    for (;;) {
        gfx_clear(0);
        gfx_blit(&sprites, 0, 0, 32, 32, x, y, GFX_KEY, 0);   // con transparencia
        gfx_blit_scaled(&sprites, 0, 0, 32, 32, 100, 100, 64, 64, GFX_FLIPX, 0);
        gfx_text(8, 8, "Hola", 15, -1);
        midi_update();
        gfx_flip();                              // espera al blitter y cambia en el vblank
    }
}
```

**MIDI con el OPL2** (`sw/lib/oplsynth.c`): `midi_use_opl(0)` manda las notas al
OPL2 con el banco GENMIDI de Freedoom (incluido); `midi_use_opl(banco)` usa otro
banco GENMIDI en memoria y `midi_use_opl_wad("DOOM    WAD")` lee el original de
un WAD de la SD. `midi_load_file("CANCION MID", buf, max)` carga un `.MID` de la
raíz de la tarjeta; `midi_use_samples()` vuelve a las voces. Como DMX (el driver
de Doom): 9 voces, instrumentos de 1 o 2 voces, percusión con las notas 35-81
del canal 10 y todo una octava por encima de la nota MIDI (así están afinados
los bancos GENMIDI). `sw/apps/midiplay` reproduce todos los `.MID` de la SD
(mando: derecha/izquierda, A pausa; S1/S2). Los ficheros tienen que estar en
la raíz con nombre 8.3 (p. ej. `CANCION.MID`, los nombres largos no se ven) y
ocupar como mucho 512 KB; si la SD tiene `DOOM2.WAD` o `DOOM.WAD` usa sus
instrumentos y si no, los de Freedoom.

Herramientas (`python tools/<herramienta> -h` para ver las opciones):

- `tools/img2c.py imagen.png sw/apps/x/imagen.h [--transparente] [--ancho W] [--pixelado] [--paleta propia --base B --colores N]`:
  imagen a cabecera C con la textura de 8 bpp, su tamaño, el índice transparente
  y una `surface` lista para `gfx_blit` (`IMAGEN_SURF`). Con la paleta por defecto
  no hay que cargar nada; con `--paleta propia`, `imagen_pal_load()`.
- `tools/midi2c.py cancion.mid sw/apps/x/cancion.h [--transponer S] [--sin-bateria] [--canales 1,2] [--tempo F] [--max-seg S] [--vol V]`:
  MIDI a cabecera C para `midi_load(cancion, CANCION_LEN)`; comprueba el fichero e
  informa de canales, instrumentos y polifonía.
- `tools/wav2pcm.py` (WAV a PCM), `tools/img2tex.py` (imagen a .bin/.c), `tools/mkmidi.py` (canción de la demo).

## Verificación (simulación)

| Prueba | Qué comprueba |
|---|---|
| `sim/run_isa.py` | 49 riscv-tests oficiales (rv32ui + rv32um) sobre CPU + SDRAM |
| `sim/run_rand.py N` | programas RV32IM aleatorios (ALU, mul/div, loads/stores cacheados y sin caché, E/S, fence, saltos, bucles, llamadas) contra un ISS en Python: registros y memoria |
| `sim/run_blit.py N` | comandos aleatorios del blitter (todas las operaciones, recorte, escalado, espejo, transparencia) contra un modelo, byte a byte; con `--vid` compite con tráfico de vídeo |
| `sim/run_audio.py N` | 32 voces con parámetros y eventos aleatorios contra un modelo bit-exacto |
| `sim/run_opl.py S N [--musical]` | OPL2: registros al azar o notas con instrumentos, muestra a muestra contra `sim/oplmodel.py` (traducción de Nuked-OPL3, validada contra el original compilado para RISC-V) |
| `sim/run_vid.py` | un cuadro TMDS completo decodificado: píxeles = paleta[framebuffer] con scroll/wrap, sincronismos, data islands con ECC BCH, ACR, InfoFrames y muestras de audio |
| `sim/tb/tb_soc.v` | SoC completo: arranque de la ROM, calibración y carga de un programa por la UART |

Notas de diseño para Fmax: ninguna señal tardía (acierto de caché) llega a las
habilitaciones de todo el pipeline — los fallos de la dcache hacen *replay*;
las escrituras pasan por una FIFO registrada; los caminos de los periféricos
están segmentados. `tools/timing.py` resume el informe de Gowin.

## Doom

`sw/apps/doom`: Doom (base [doomgeneric](https://github.com/ozkl/doomgeneric),
derivado de Chocolate Doom, GPL v2 — ver `src/LICENSE`) con una capa propia:

| Fichero | Qué hace |
|---|---|
| `doomgeneric_bltfast.c` | arranque, vídeo (el blitter escala 320×200 → 640×480, 4:3 como en DOS), paleta por hardware, teclado PS/2, mandos, ENDOOM y pantalla de error |
| `i_sound_bltfast.c` | efectos en las voces 24–31 (PCM DMX convertido a 8 bits con signo en `0x4074_0000`); música con el reproductor MIDI de `lib/midi.c` (voces 0–23) si se pide `-synth` o el bitstream no tiene OPL2 |
| `src/i_oplmusic.c` | música como en DOS con Sound Blaster: el reproductor OPL de Chocolate Doom con los instrumentos `GENMIDI` del WAD, sobre el OPL2 por hardware |
| `opl_bltfast.c` | controlador de la API `opl.h` de Chocolate Doom: escribe los registros del OPL2 y ejecuta las llamadas programadas desde la interrupción de 500 Hz |
| `midi_stream.c` | API de `midifile.h` leyendo los eventos sobre la marcha (la versión original ocupa ~400 KB con las canciones largas de Doom 2) |
| `sys_bltfast.c` | llamadas al sistema de newlib: stdout/stderr por la UART, ficheros en el raíz de la SD, `malloc` |
| `w_file_bltfast.c` | lectura de los WAD sin búfer, con tabla de clusters (`fat_map`) para saltar a cualquier lump |
| `src/` | código de doomgeneric; los cambios van bajo `#ifdef BLTFAST` |

```
cd sw
python build.py doom          # -> build/doom.bin (~570 KB)
python build.py doom --run    # cargar por UART
```

**microSD** (FAT32/FAT16, directorio raíz, nombres 8.3): copia el IWAD
(`DOOM1.WAD`, `DOOM.WAD`, `DOOM2.WAD`, `PLUTONIA.WAD` o `TNT.WAD`; si hay
varios se usa el primero de doom2, plutonia, tnt, doom, doom1, salvo que se
indique `-iwad`) y, para arrancar sin PC, `build/doom.bin`
como `BOOT.BIN`. Opcional: `DOOMARGS.TXT` con argumentos, p. ej.
`-iwad doom.wad -warp 1 3 -skill 4` o `-file mimod.wad`. Doom guarda en la SD
`DEFAULT.CFG`, `DOOMGENE.CFG` y las partidas `DOOMSAVn.DSG`.

**Música**: con el OPL2 suena como en DOS con una Sound Blaster (mismos
instrumentos FM, los del lump `GENMIDI`). `-synth` en `DOOMARGS.TXT` usa en su
lugar el sintetizador de `lib/midi.c`.

**Controles**: teclado como en DOS (flechas, Ctrl dispara, espacio abre,
Mayús corre, Alt + flechas de lado, `,` `.` de lado, `[` `]` cambian de arma,
1–7 armas, Tab mapa, Esc menú, F2/F3 guardar/cargar). Mando SNES: cruceta =
moverse, B = disparar, A = abrir, Y = correr, X = siguiente arma, L/R = de
lado, Start = menú, Select = mapa; en los menús A = aceptar y B = volver, en
las preguntas A = sí y B = no. S1 = Esc, S2 = Enter.

Memoria: programa ~0,8 MB desde `0x4000_0000`, zona de Doom ~4,4 MB, 512 KB
para `malloc` y 256 KB de pila bajo `0x4060_0000`. El temporizador interrumpe a
500 Hz (MIDI y muestreo de los mandos). Si Doom termina con error, el mensaje
sale en pantalla (y por la UART) y una tecla reinicia el SoC.

**Doom 2**: el mismo `doom.bin` sirve para Doom 1 y Doom 2 (probado en placa y
en el emulador con las demos, MAP15 y MAP29). Si en la SD están `DOOM2.WAD` y
`DOOM.WAD`, gana Doom 2; para jugar a Doom 1, `-iwad doom.wad` en `DOOMARGS.TXT`.

**FPS**: cada 5 s Doom imprime por la UART los cuadros por segundo (solo cuenta
los cuadros con un tic nuevo del juego). En placa: 33–35 FPS en las demos.

**microSD tras un reinicio**: si la placa se reinicia en mitad de una lectura,
la tarjeta puede quedarse enviando el bloque pendiente y no responder a CMD0.
`sd_init` (`sw/lib/sd.c`) lo reintenta hasta 8 veces vaciando antes 600 bytes
con CS activo, así que ya no sale "no hay tarjeta microSD" al reiniciar.

## Herramientas de prueba

| Herramienta | Uso |
|---|---|
| `sim/rvtorture.py` + `sim/torture.sh` | programas RV32IM aleatorios (ALU, MUL/DIV, cargas/stores, saltos, llamadas, E/S, vídeo) ejecutados en la placa y en el emulador; compara la firma final |
| `tools/socemu.js` | emulador funcional del SoC en Node.js (CPU, SD, blitter, vídeo, PS/2, mandos, OPL2): ejecuta `.bin`, guarda capturas PNG (`--shots`), simula teclas/mandos (`--keys`, `--pads`) y graba la música FM en un WAV (`--oplwav`, con `tools/opl2.js`) |
| `sw/apps/padtest` | estado de los dos mandos en pantalla y por la UART |
| `sw/apps/sdtest` | fiabilidad de la lectura de la microSD a varias velocidades de SPI |
| `sw/apps/sddump` + `tools/sddump.py` | copia un fichero de la microSD al PC por la UART (con control de flujo y CRC) |

## Historial

| Fecha | Commit | Cambios |
|---|---|---|
| 2026-10-21 | `2dd113c` | Primera versión: SoC completo (CPU RV32IM a 90 MHz, SDRAM, vídeo + HDMI con audio, blitter, 32 voces, microSD, mandos, PS/2), biblioteca, demo, pruebas de simulación y port de Doom |
| 2026-10-21 | `0714eee` (etiqueta `antes-opl2`) | Doom 2 probado; contador de FPS de Doom por la UART; `sd_init` recuperable tras un reinicio a mitad de lectura; bitstream de 90 MHz grabado en la flash; planes futuros (wavetable, rendimiento) |
| 2026-10-21 | `c3d2044` | **OPL2 (YM3812) por hardware** en `0x8000_9000` (`rtl/audio/opl2.v`), sumado a la mezcla de `audio.v`; verificado bit a bit con `sim/run_opl.py` contra `sim/oplmodel.py` (Nuked-OPL3); emulador con OPL2 (`tools/opl2.js`, `--oplwav`). **Doom con música FM como en DOS**: `i_oplmusic.c` de Chocolate Doom con el `GENMIDI` del WAD, `opl_bltfast.c` y `midi_stream.c`. Ocupación ~73 % de la lógica, Fmax 99,75 MHz; grabado en la flash |
| 2026-10-21 | `fd8a8d6` | **MIDI sobre el OPL2 para programas propios** (`sw/lib/oplsynth.c`, banco de Freedoom `genmidi_fd.c`, API `midi_use_opl*`, `midi_load_file`) y la aplicación `sw/apps/midiplay` |
| 2026-10-22 | — | `midiplay` probado en placa: lee los instrumentos de `DOOM2.WAD` y reproduce los `.MID` de la SD (`LEVEL1.MID`) |

Para volver al estado anterior al OPL2: `git switch --detach antes-opl2` (solo
mirar), `git restore --source antes-opl2 <fichero>` (recuperar un fichero) o
`git reset --hard antes-opl2` (descartar todo lo posterior).

**Pendiente**: subir el repositorio a GitHub (sin los WAD: `.gitignore`
excluye `*.wad`); decidir si `.vscode/` (rutas locales) se queda en el repo.

## Planes futuros

### Música de Doom con instrumentos muestreados (wavetable)

Ahora `lib/midi.c` sintetiza cada instrumento con ondas simples + ADSR, y por
eso la música suena "a chip". Con muestras reales (como una Sound Canvas o un
SoundFont General MIDI) sonaría mucho más natural. El hardware ya reproduce
PCM desde SDRAM con pitch, volumen y envolvente (así van los efectos), así que
es sobre todo software:

1. Herramienta `tools/sf2bank.py`: extraer de un SoundFont libre (p. ej.
   GeneralUser GS) solo los programas GM y percusiones que usan las músicas de
   `DOOM.WAD` y `DOOM2.WAD` (~30–40 programas + batería), a 8 bits y ~22 kHz
   con bucles cortos y zonas por tesitura → `INSTR.DAT` (objetivo 1–1,5 MB).
2. Doom carga `INSTR.DAT` de la SD al arrancar; si no existe, se usa la
   síntesis actual.
3. `midi.c`: modo muestras (elegir zona por nota, pitch respecto a la nota
   raíz, bucle, envolvente del SoundFont); el resto del reproductor no cambia.
4. Memoria: el banco sale de la zona de Doom (4,4 MB → ~3 MB). Comprobar en
   el emulador que los mapas grandes de Doom 2 (MAP15, MAP29) y los PWAD
   habituales no dan `Z_Malloc failed`; si no caben, banco más pequeño
   (11 kHz o menos programas).

### Rendimiento de Doom

Medido en placa (timedemo demo1 de Doom 1): **33,2 FPS**, ~30 ms por cuadro,
de los que el blitter (escalado) ocupa 2,9 ms y el resto es CPU
(`R_DrawColumn`/`R_DrawSpan`, limitados por los accesos a SDRAM). Ideas, de
menos a más trabajo:

1. Escalar con el blitter el cuadro anterior mientras la CPU dibuja el
   siguiente (doble búfer de `I_VideoBuffer`): ~3 ms por cuadro.
2. Perfilar con `tools/socemu.js --prof` y pasar los bucles de columnas y
   spans a ensamblador.
3. Caché de datos mayor (8 KB → 16–32 KB, quedan BSRAM libres) y/o el colormap
   en una BSRAM propia.
4. Modo del blitter que dibuje columnas/spans texturizados con colormap.

Una FPU no ayudaría: Doom usa coma fija. 60 FPS requeriría además
interpolación entre tics (el motor corre a 35 Hz).

## Licencia

El SoC (RTL, biblioteca, aplicaciones y herramientas) se publica bajo licencia
**MIT** (ver `LICENSE`), salvo:

- `sw/apps/doom/src/`: doomgeneric / Chocolate Doom, **GPL v2**. Los binarios
  que incluyan Doom se distribuyen bajo GPL v2.
- `sim/tests/`: riscv-tests, licencia BSD.
- `sw/lib/genmidi_fd.c`: instrumentos FM de [Freedoom](https://freedoom.github.io/), licencia BSD (incluida en el fichero).
- `rtl/audio/opl2.v`, `sim/oplmodel.py`, `tools/opl2.js`: siguen el algoritmo
  y las tablas de [Nuked-OPL3](https://github.com/nukeykt/Nuked-OPL3) (nukeykt),
  **LGPL 2.1** (ver `rtl/audio/LICENSE.nuked-opl3`).
- `sw/apps/doom/midi_stream.c` y `opl_bltfast.c` implementan APIs de Chocolate
  Doom y van con Doom: **GPL v2**.

Los WAD de Doom **no** se incluyen: hay que usar los propios (`DOOM.WAD`,
`DOOM2.WAD`…), el shareware `DOOM1.WAD` o [Freedoom](https://freedoom.github.io/).
