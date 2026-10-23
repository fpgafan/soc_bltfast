// ============================================================================
// gfx.c - Graphics with the blitter (see gfx.h)
// ============================================================================
#include "gfx.h"
#include "lib.h"

extern const uint8_t font8x8[256 * 8];

surface gfx_screen;
static surface front;
static uint32_t font_addr;         // copy of the font in SDRAM (1 bpp, 8 bytes per character)
static const surface *cur_dst;

static inline uint32_t xy(int x, int y) { return ((uint32_t)x & 0xFFFF) | ((uint32_t)y << 16); }

void gfx_wait(void) { while (BLT_STATUS & BLT_BUSY) ; }

void gfx_target(const surface *s)
{
    cur_dst = s;
    BLT_DST     = PHYS(s->addr);
    BLT_DSTRIDE = s->stride;
    BLT_CLIP0   = 0;
    BLT_CLIP1   = xy(s->w, s->h);
}

void gfx_clip(int x0, int y0, int x1, int y1)
{
    BLT_CLIP0 = xy(x0, y0);
    BLT_CLIP1 = xy(x1, y1);
}

void gfx_palette(int i, uint32_t rgb) { PALETTE[i & 255] = rgb; }

void gfx_palette_default(void)
{
    static const uint32_t ega[16] = {
        0x000000, 0x0000AA, 0x00AA00, 0x00AAAA, 0xAA0000, 0xAA00AA, 0xAA5500, 0xAAAAAA,
        0x555555, 0x5555FF, 0x55FF55, 0x55FFFF, 0xFF5555, 0xFF55FF, 0xFFFF55, 0xFFFFFF };
    int i = 0;
    for (; i < 16; i++) PALETTE[i] = ega[i];
    for (int r = 0; r < 6; r++)                 // 16..267 -> 6x7x6 = 252 colors (16..267 clipped)
        for (int g = 0; g < 7; g++)
            for (int b = 0; b < 6; b++)
                if (i < 240) PALETTE[i++] = ((r * 51) << 16) | ((g * 85 / 2) << 8) | (b * 51);
    for (int k = 0; i < 256; i++, k++) {         // 16 grays
        uint32_t v = k * 17;
        PALETTE[i] = (v << 16) | (v << 8) | v;
    }
}

void gfx_init(void)
{
    front      = (surface){ FB0, SCR_W, SCR_H, SCR_W };
    gfx_screen = (surface){ FB1, SCR_W, SCR_H, SCR_W };
    gfx_palette_default();
    // font in SDRAM (the blitter only reads from there); at the end of the FB area
    font_addr = 0x406F8000u;
    memcpy((void *)font_addr, font8x8, sizeof(font8x8));
    fence();
    VID_FB_BASE = PHYS(front.addr);
    VID_STRIDE  = SCR_W;
    VID_SCROLL_X = 0; VID_SCROLL_Y = 0; VID_WRAP_W = 0; VID_WRAP_H = 0;
    VID_CTRL = VID_EN | VID_HDMI;
    BLT_DU = 0x10000; BLT_DV = 0x10000; BLT_U0 = 0; BLT_V0 = 0;
    gfx_target(&gfx_screen);
    gfx_clear(0);
    gfx_wait();
    gfx_flip();
}

uint32_t gfx_frame(void) { return VID_STATUS >> 20; }

void gfx_vsync(void)
{
    uint32_t f = gfx_frame();
    while (gfx_frame() == f) ;
}

void gfx_flip(void)
{
    gfx_wait();
    surface t = front; front = gfx_screen; gfx_screen = t;
    VID_FB_BASE = PHYS(front.addr);
    VID_STRIDE  = front.stride;
    while (VID_PENDING & 1) ;                   // applied at frame start
    if (cur_dst == &gfx_screen || cur_dst == 0) gfx_target(&gfx_screen);
}

void gfx_scroll(uint32_t canvas, uint32_t stride, int sx, int sy, int wrap_w_log, int wrap_h)
{
    VID_FB_BASE  = PHYS(canvas);
    VID_STRIDE   = stride;
    VID_SCROLL_X = (uint32_t)sx;
    VID_SCROLL_Y = (uint32_t)sy;
    VID_WRAP_W   = (uint32_t)wrap_w_log;
    VID_WRAP_H   = (uint32_t)wrap_h;
}

void gfx_fill(int x, int y, int w, int h, uint8_t c)
{
    BLT_XY = xy(x, y);
    BLT_SIZE = xy(w, h);
    BLT_COLOR = c;
    BLT_CMD = BLT_OP_FILL;
}

void gfx_clear(uint8_t c) { gfx_fill(0, 0, cur_dst->w, cur_dst->h, c); }

void gfx_line(int x0, int y0, int x1, int y1, uint8_t c)
{
    BLT_XY = xy(x0, y0);
    BLT_SIZE = xy(x1, y1);
    BLT_COLOR = c;
    BLT_CMD = BLT_OP_LINE;
}

void gfx_rect(int x, int y, int w, int h, uint8_t c)
{
    gfx_fill(x, y, w, 1, c);
    gfx_fill(x, y + h - 1, w, 1, c);
    gfx_fill(x, y, 1, h, c);
    gfx_fill(x + w - 1, y, 1, h, c);
}

void gfx_blit_scaled(const surface *src, int sx, int sy, int sw, int sh,
                     int dx, int dy, int dw, int dh, uint32_t flags, uint8_t key)
{
    if (dw <= 0 || dh <= 0) return;
    int32_t du = (int32_t)(((int64_t)sw << 16) / dw);
    int32_t dv = (int32_t)(((int64_t)sh << 16) / dh);
    int32_t u0 = (du >> 1) & ~0, v0 = (dv >> 1);     // sampling at the pixel center
    if (du == 0x10000) u0 = 0;
    if (dv == 0x10000) v0 = 0;
    if (flags & GFX_FLIPX) { u0 = ((int32_t)sw << 16) - 1 - u0; du = -du; }
    if (flags & GFX_FLIPY) { v0 = ((int32_t)sh << 16) - 1 - v0; dv = -dv; }
    if (du == -0x10000) u0 = (sw - 1) << 16;
    if (dv == -0x10000) v0 = (sh - 1) << 16;
    BLT_SRC = PHYS(src->addr) + (uint32_t)sy * src->stride + (uint32_t)sx;
    BLT_SSTRIDE = src->stride;
    BLT_XY = xy(dx, dy);
    BLT_SIZE = xy(dw, dh);
    BLT_COLOR = (uint32_t)key << 16;
    BLT_U0 = (uint32_t)u0; BLT_V0 = (uint32_t)v0;
    BLT_DU = (uint32_t)du; BLT_DV = (uint32_t)dv;
    BLT_CMD = BLT_OP_BLIT | ((flags & GFX_KEY) ? BLT_F_KEY : 0);
}

void gfx_blit(const surface *src, int sx, int sy, int w, int h, int dx, int dy,
              uint32_t flags, uint8_t key)
{
    gfx_blit_scaled(src, sx, sy, w, h, dx, dy, w, h, flags, key);
}

void gfx_text_scaled(int x, int y, const char *s, uint8_t fg, int bg, int scale)
{
    // each character is an 8x8-bit "image" with a 1-byte stride
    BLT_SSTRIDE = 1;
    BLT_COLOR = fg | ((uint32_t)(bg < 0 ? 0 : bg) << 8);
    BLT_U0 = 0; BLT_V0 = 0;
    BLT_DU = (uint32_t)(0x10000 / scale);
    BLT_DV = (uint32_t)(0x10000 / scale);
    BLT_SIZE = xy(8 * scale, 8 * scale);
    for (; *s; s++, x += 8 * scale) {
        BLT_SRC = PHYS(font_addr) + (uint32_t)(uint8_t)*s * 8u;
        BLT_XY = xy(x, y);
        BLT_CMD = BLT_OP_EXPAND | (bg < 0 ? BLT_F_BGTRANS : 0);
    }
    BLT_DU = 0x10000; BLT_DV = 0x10000;
}

void gfx_text(int x, int y, const char *s, uint8_t fg, int bg) { gfx_text_scaled(x, y, s, fg, bg, 1); }
