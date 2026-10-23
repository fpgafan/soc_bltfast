// ============================================================================
// gfx.h - 640x480 8 bpp graphics using the hardware 2D engine
//
//  Blitter commands are queued (32 in hardware) and the CPU continues: you
//  must call gfx_wait() before reading with the CPU what the engine drew, and
//  gfx_flip() waits by itself. Textures live in SDRAM in 8 bpp format
//  (palette indices); the 'key' color of each blit is transparent.
// ============================================================================
#ifndef GFX_H
#define GFX_H
#include <stdint.h>
#include "soc.h"

#define SCR_W 640
#define SCR_H 480

typedef struct {
    uint32_t addr;          // SDRAM address (any view)
    uint16_t w, h;          // size in pixels
    uint16_t stride;        // bytes per row
} surface;

extern surface gfx_screen;  // buffer being drawn into (the hidden one)

void gfx_init(void);                         // video + double buffer + default palette
void gfx_flip(void);                         // shows what was drawn (at frame start)
void gfx_vsync(void);                        // waits for the next vblank
void gfx_wait(void);                         // waits for the blitter to finish
void gfx_target(const surface *s);           // destination surface for commands
void gfx_clip(int x0, int y0, int x1, int y1);
void gfx_palette(int i, uint32_t rgb);
void gfx_palette_default(void);              // 16 EGA + 6x7x6 cube + grays

void gfx_fill(int x, int y, int w, int h, uint8_t c);
void gfx_clear(uint8_t c);
void gfx_line(int x0, int y0, int x1, int y1, uint8_t c);
void gfx_rect(int x, int y, int w, int h, uint8_t c);
// copies 'src' (x, y, w, h) to (dx, dy); flags: GFX_KEY (transparency with key),
// GFX_FLIPX, GFX_FLIPY
#define GFX_KEY   1u
#define GFX_FLIPX 2u
#define GFX_FLIPY 4u
void gfx_blit(const surface *src, int sx, int sy, int w, int h, int dx, int dy,
              uint32_t flags, uint8_t key);
// scaling: the source rectangle (sx,sy,sw,sh) is drawn at (dx,dy,dw,dh)
void gfx_blit_scaled(const surface *src, int sx, int sy, int sw, int sh,
                     int dx, int dy, int dw, int dh, uint32_t flags, uint8_t key);
// text with the 8x8 font (code page 850); bg < 0 = transparent background
void gfx_text(int x, int y, const char *s, uint8_t fg, int bg);
void gfx_text_scaled(int x, int y, const char *s, uint8_t fg, int bg, int scale);

// hardware scrolling of the visible buffer: canvas (address, width in bytes)
void gfx_scroll(uint32_t canvas, uint32_t stride, int sx, int sy, int wrap_w_log, int wrap_h);

uint32_t gfx_frame(void);                    // frames since boot
#endif
