// ============================================================================
// soc.h - Registers of the bltfast SoC (Tang Nano 20K)
// ============================================================================
#ifndef SOC_H
#define SOC_H
#include <stdint.h>

#define REG32(a)  (*(volatile uint32_t *)(a))
#define CPU_HZ    90000000u

// ---------------------------------------------------------------- memory
#define SDRAM_BASE     0x40000000u          // cacheable
#define SDRAM_UC       0x50000000u          // uncached alias
#define SDRAM_SIZE     (8u << 20)
#define UNCACHED(p)    ((void *)(((uint32_t)(p) & 0x00FFFFFFu) | SDRAM_UC))
#define CACHED(p)      ((void *)(((uint32_t)(p) & 0x00FFFFFFu) | SDRAM_BASE))
#define PHYS(p)        ((uint32_t)(p) & 0x007FFFFFu)   // address for DMA (blitter/sound/video)
#define FB0            0x40600000u
#define FB1            0x40680000u
#define BRAM_BASE      0x10000000u          // 4 KB internal

// ---------------------------------------------------------------- system
#define SYS_BASE       0x80000000u
#define SYS_ID         REG32(SYS_BASE + 0x00)
#define SYS_LED        REG32(SYS_BASE + 0x04)
#define SYS_BTN        REG32(SYS_BASE + 0x08)
#define SYS_CLK_HZ     REG32(SYS_BASE + 0x0C)
#define SYS_MTIME      REG32(SYS_BASE + 0x10)
#define SYS_MTIMEH     REG32(SYS_BASE + 0x14)
#define SYS_MTIMECMP   REG32(SYS_BASE + 0x18)
#define SYS_MTIMECMPH  REG32(SYS_BASE + 0x1C)
#define SYS_MSIP       REG32(SYS_BASE + 0x20)
#define SYS_IRQ_PEND   REG32(SYS_BASE + 0x24)
#define SYS_IRQ_EN     REG32(SYS_BASE + 0x28)
#define SYS_SDRAM      REG32(SYS_BASE + 0x2C)
#define SYS_RESET      REG32(SYS_BASE + 0x30)
#define SYS_SCRATCH    REG32(SYS_BASE + 0x34)
#define SYS_MISC       REG32(SYS_BASE + 0x38)
#define IRQ_UART       (1u << 0)
#define IRQ_VBLANK     (1u << 1)
#define IRQ_RASTER     (1u << 2)
#define IRQ_BLIT       (1u << 3)
#define IRQ_AUDIO      (1u << 4)
#define IRQ_PS2        (1u << 5)

// ---------------------------------------------------------------- UART
#define UART_BASE      0x80001000u
#define UART_DATA      REG32(UART_BASE + 0x00)
#define UART_STAT      REG32(UART_BASE + 0x04)
#define UART_DIV       REG32(UART_BASE + 0x08)
#define UART_IE        REG32(UART_BASE + 0x0C)
#define UART_TXFULL    (1u << 0)
#define UART_TXIDLE    (1u << 1)
#define UART_RXAVAIL   (1u << 2)

// ---------------------------------------------------------------- video
#define VID_BASE       0x80002000u
#define VID_CTRL       REG32(VID_BASE + 0x00)
#define VID_FB_BASE    REG32(VID_BASE + 0x04)
#define VID_STRIDE     REG32(VID_BASE + 0x08)
#define VID_SCROLL_X   REG32(VID_BASE + 0x0C)
#define VID_SCROLL_Y   REG32(VID_BASE + 0x10)
#define VID_WRAP_W     REG32(VID_BASE + 0x14)
#define VID_WRAP_H     REG32(VID_BASE + 0x18)
#define VID_BORDER     REG32(VID_BASE + 0x1C)
#define VID_RASTER     REG32(VID_BASE + 0x20)
#define VID_STATUS     REG32(VID_BASE + 0x24)
#define VID_PENDING    REG32(VID_BASE + 0x28)
#define VID_EN         (1u << 0)
#define VID_LIVE       (1u << 1)
#define VID_HDMI       (1u << 2)
#define PALETTE        ((volatile uint32_t *)0x80003000u)   // 256 x 0x00RRGGBB

// ---------------------------------------------------------------- blitter
#define BLT_BASE       0x80004000u
#define BLT_STATUS     REG32(BLT_BASE + 0x00)
#define BLT_DST        REG32(BLT_BASE + 0x04)
#define BLT_DSTRIDE    REG32(BLT_BASE + 0x08)
#define BLT_CLIP0      REG32(BLT_BASE + 0x0C)
#define BLT_CLIP1      REG32(BLT_BASE + 0x10)
#define BLT_SRC        REG32(BLT_BASE + 0x14)
#define BLT_SSTRIDE    REG32(BLT_BASE + 0x18)
#define BLT_XY         REG32(BLT_BASE + 0x1C)
#define BLT_SIZE       REG32(BLT_BASE + 0x20)
#define BLT_COLOR      REG32(BLT_BASE + 0x24)
#define BLT_U0         REG32(BLT_BASE + 0x28)
#define BLT_V0         REG32(BLT_BASE + 0x2C)
#define BLT_DU         REG32(BLT_BASE + 0x30)
#define BLT_DV         REG32(BLT_BASE + 0x34)
#define BLT_CMD        REG32(BLT_BASE + 0x38)
#define BLT_IRQ        REG32(BLT_BASE + 0x3C)
#define BLT_OP_FILL    0u
#define BLT_OP_BLIT    1u
#define BLT_OP_EXPAND  2u
#define BLT_OP_LINE    3u
#define BLT_F_KEY      (1u << 4)
#define BLT_F_BGTRANS  (1u << 5)
#define BLT_F_PALOFF   (1u << 6)
#define BLT_BUSY       (1u << 0)

// ---------------------------------------------------------------- sound
#define AUD_BASE       0x80005000u
#define AUD_V(v, r)    REG32(AUD_BASE + (v) * 0x20 + (r))
#define AUD_V_CTRL     0x00
#define AUD_V_START    0x04
#define AUD_V_LEN      0x08
#define AUD_V_LOOP     0x0C
#define AUD_V_PITCH    0x10
#define AUD_V_VOL      0x14
#define AUD_V_ADSR     0x18
#define AUD_CTRL       REG32(AUD_BASE + 0x800)
#define AUD_KEYON      REG32(AUD_BASE + 0x804)
#define AUD_KEYOFF     REG32(AUD_BASE + 0x808)
#define AUD_ACTIVE     REG32(AUD_BASE + 0x80C)
#define AUD_EVENT      REG32(AUD_BASE + 0x810)
#define AUD_IRQ_EN     REG32(AUD_BASE + 0x814)
#define AUD_COUNT      REG32(AUD_BASE + 0x818)
#define AUD_STOP       REG32(AUD_BASE + 0x81C)
#define AUD_LAST       REG32(AUD_BASE + 0x820)
#define AUD_MON_V      REG32(AUD_BASE + 0x824)
#define AUD_MON_POS    REG32(AUD_BASE + 0x828)
#define AUD_MON_ENV    REG32(AUD_BASE + 0x82C)
#define AUD_FMT_S8     0u
#define AUD_FMT_S16    1u
#define AUD_FMT_S16ST  2u
#define AUD_FMT_S8ST   3u
#define AUD_LOOP       (1u << 2)
#define AUD_INTERP     (1u << 3)
#define AUD_EVENT_EN   (1u << 4)
#define AUD_VOICES     32

// ---------------------------------------------------------------- SD, pads, PS/2
#define SD_BASE        0x80006000u
#define SD_CTRL        REG32(SD_BASE + 0x000)
#define SD_DATA        REG32(SD_BASE + 0x004)
#define SD_STAT        REG32(SD_BASE + 0x008)
#define SD_BLOCK       REG32(SD_BASE + 0x00C)
#define SD_BUF         ((volatile uint32_t *)(SD_BASE + 0x200))
#define PAD_BASE       0x80007000u
#define PAD0           REG32(PAD_BASE + 0x00)
#define PAD1           REG32(PAD_BASE + 0x04)
#define PAD_B      (1u << 0)
#define PAD_Y      (1u << 1)
#define PAD_SELECT (1u << 2)
#define PAD_START  (1u << 3)
#define PAD_UP     (1u << 4)
#define PAD_DOWN   (1u << 5)
#define PAD_LEFT   (1u << 6)
#define PAD_RIGHT  (1u << 7)
#define PAD_A      (1u << 8)
#define PAD_X      (1u << 9)
#define PAD_L      (1u << 10)
#define PAD_R      (1u << 11)
#define PS2_BASE       0x80008000u
#define PS2_DATA       REG32(PS2_BASE + 0x00)
#define PS2_STAT       REG32(PS2_BASE + 0x04)

// FM OPL2 (YM3812): chip register n at OPL_REG(n); the output is added to the
// sound engine mix
#define OPL_BASE       0x80009000u
#define OPL_REG(n)     REG32(OPL_BASE + (n) * 4)
#define OPL_GAIN       REG32(OPL_BASE + 0x400)    // 0x40 = 1.0 (default 0x80)
#define OPL_COUNT      REG32(OPL_BASE + 0x404)    // samples generated (~49716/s)

#endif
