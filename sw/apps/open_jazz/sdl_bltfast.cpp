// ============================================================================
// sdl_bltfast.cpp - Minimal SDL 1.2 implementation for OpenJazz on soc_tang
// ============================================================================
#include "include/SDL.h"
#include <stdio.h>
#include <stdlib.h>
#include <malloc.h>
#include <string.h>

extern "C" {
#define printf lib_printf
#include "lib.h"
#include "gfx.h"
#include "audio.h"
#undef printf
}

// ============================================================================
// Video state
// ============================================================================
static SDL_Surface *main_screen = NULL;
// Triple buffering: SDL_Flip scales the frame into a buffer that is neither on
// screen nor waiting to be shown, and queues it without waiting for the
// vblank, so the CPU starts the next frame right away. FB0/FB1 are the
// gfx.c buffers; the third goes in the sample area, after the audio ring.
static const uint32_t fb_addr[3] = { FB0, FB1, 0x40780000u };
static int fb_cur = 0;      // last one queued (on screen once VID_PENDING clears)
static int fb_prev = 1;     // on screen while fb_cur is still pending

// Blitter (DMA) drawing: SDL_FillRect and SDL_BlitSurface only queue commands.
// Before the CPU touches pixels again (SDL_LockSurface, creating or freeing a
// surface) blt_sync() waits for the queue and invalidates the dcache, which
// may hold stale copies of what the blitter wrote.
static bool blt_pending;
static const SDL_Surface *blt_dst;  // destination programmed in the blitter
static bool use_blitter = true;     // JAZZ.TXT "draw=cpu" draws with the CPU instead

// JAZZ.TXT in the root of the microSD: "draw=blitter" (default) or "draw=cpu"
static void read_config(void)
{
    fat_file f;
    char buf[256];
    if (fat_open(&f, "JAZZ    TXT")) return;
    int n = fat_read(&f, buf, sizeof(buf) - 1);
    if (n <= 0) return;
    buf[n] = 0;
    for (char *p = buf; *p; p++) if (*p >= 'A' && *p <= 'Z') *p += 32;
    const char *d = strstr(buf, "draw=");
    if (d && !strncmp(d + 5, "cpu", 3)) use_blitter = false;
    if (d && !strncmp(d + 5, "blitter", 7)) use_blitter = true;
}

static void blt_sync(void)
{
    if (!blt_pending) return;
    gfx_wait();
    fence();
    blt_pending = false;
}

static inline uint32_t blt_xy(int x, int y) { return ((uint32_t)x & 0xFFFF) | ((uint32_t)y << 16); }

static void blt_target(const SDL_Surface *s)
{
    if (s == blt_dst) return;
    blt_dst = s;
    BLT_DST     = PHYS(s->pixels);
    BLT_DSTRIDE = s->pitch;
    BLT_CLIP0   = 0;
    BLT_CLIP1   = blt_xy(s->w, s->h);
}

int SDL_LockSurface(SDL_Surface *surface)
{
    (void)surface;
    blt_sync();
    return 0;
}
static uint32_t last_hw_palette[256];

static void video_init_hw(void)
{
    gfx_init();
    // gfx_init() loads the default palette: force the first SDL_SetPalette to
    // write every entry (also the black ones)
    memset(last_hw_palette, 0xFF, sizeof(last_hw_palette));
}

// ============================================================================
// Audio state
// ============================================================================
// 22050 Hz output (the sound engine resamples the ring to 48 kHz): OpenJazz
// keeps every effect converted to the output format, so at 48 kHz stereo the
// 11 kHz 8-bit effects took ~17 times their size (MBs of heap)
#define AUDIO_RATE        22050
#define AUDIO_RING_FRAMES 4096                       // ~186 ms at 22050 Hz
#define AUDIO_CHUNK_FRAMES 512
static int16_t *audio_ring = (int16_t *)0x40700000u; // SDRAM sample area
static void (*audio_cb)(void *userdata, Uint8 *stream, int len) = NULL;
static void *audio_udata = NULL;
static bool audio_opened = false;
static bool audio_paused = true;
static int  audio_locked = 0;
static bool audio_in_feed = false;

// Called from SDL_Flip/SDL_Delay and from _read() (sys_bltfast.c), so the
// ring is also refilled while files are being loaded.
extern "C" void audio_feed(void)
{
    if (!audio_opened || audio_locked || audio_in_feed) return;
    audio_in_feed = true;

    while (snd_stream_free() >= AUDIO_CHUNK_FRAMES) {
        int16_t chunk[AUDIO_CHUNK_FRAMES * 2]; // 16-bit stereo
        memset(chunk, 0, sizeof(chunk));
        // paused: keep writing silence so the ring does not repeat old audio
        if (!audio_paused && audio_cb)
            audio_cb(audio_udata, (Uint8 *)chunk, sizeof(chunk));
        snd_stream_write(chunk, AUDIO_CHUNK_FRAMES);
    }
    audio_in_feed = false;
}

// ============================================================================
// Input & Events
// ============================================================================
#define EVENT_QUEUE_SIZE 64
static SDL_Event event_queue[EVENT_QUEUE_SIZE];
static unsigned eq_head = 0;
static unsigned eq_tail = 0;

static void queue_event(const SDL_Event *ev)
{
    unsigned next = (eq_head + 1) % EVENT_QUEUE_SIZE;
    if (next != eq_tail) {
        event_queue[eq_head] = *ev;
        eq_head = next;
    }
}

static void queue_key(SDLKey sym, bool pressed)
{
    SDL_Event ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = pressed ? SDL_KEYDOWN : SDL_KEYUP;
    ev.key.type = ev.type;
    ev.key.state = pressed ? SDL_PRESSED : SDL_RELEASED;
    ev.key.keysym.sym = sym;
    queue_event(&ev);
}

static SDLKey ps2_to_key(uint8_t c)
{
    switch (c) {
    case 0x1C: return SDLK_a; case 0x32: return SDLK_b; case 0x21: return SDLK_c; case 0x23: return SDLK_d;
    case 0x24: return SDLK_e; case 0x2B: return SDLK_f; case 0x34: return SDLK_g; case 0x33: return SDLK_h;
    case 0x43: return SDLK_i; case 0x3B: return SDLK_j; case 0x42: return SDLK_k; case 0x4B: return SDLK_l;
    case 0x3A: return SDLK_m; case 0x31: return SDLK_n; case 0x44: return SDLK_o; case 0x4D: return SDLK_p;
    case 0x15: return SDLK_q; case 0x2D: return SDLK_r; case 0x1B: return SDLK_s; case 0x2C: return SDLK_t;
    case 0x3C: return SDLK_u; case 0x2A: return SDLK_v; case 0x1D: return SDLK_w; case 0x22: return SDLK_x;
    case 0x35: return SDLK_y; case 0x1A: return SDLK_z;
    case 0x45: return SDLK_0; case 0x16: return SDLK_1; case 0x1E: return SDLK_2; case 0x26: return SDLK_3;
    case 0x25: return SDLK_4; case 0x2E: return SDLK_5; case 0x36: return SDLK_6; case 0x3D: return SDLK_7;
    case 0x3E: return SDLK_8; case 0x46: return SDLK_9;
    case 0x0E: return SDLK_BACKQUOTE; case 0x4E: return SDLK_MINUS; case 0x55: return SDLK_EQUALS;
    case 0x66: return SDLK_BACKSPACE; case 0x0D: return SDLK_TAB;
    case 0x54: return SDLK_LEFTBRACKET; case 0x5B: return SDLK_RIGHTBRACKET; case 0x5D: return SDLK_BACKSLASH;
    case 0x4C: return SDLK_SEMICOLON; case 0x52: return SDLK_QUOTE; case 0x5A: return SDLK_RETURN;
    case 0x41: return SDLK_COMMA; case 0x49: return SDLK_PERIOD; case 0x4A: return SDLK_SLASH;
    case 0x29: return SDLK_SPACE; case 0x76: return SDLK_ESCAPE;
    case 0x12: return SDLK_LSHIFT; case 0x59: return SDLK_RSHIFT; case 0x14: return SDLK_LCTRL; case 0x11: return SDLK_LALT;
    case 0x58: return SDLK_CAPSLOCK;
    case 0x05: return SDLK_F1; case 0x06: return SDLK_F2; case 0x04: return SDLK_F3; case 0x0C: return SDLK_F4;
    case 0x03: return SDLK_F5; case 0x0B: return SDLK_F6; case 0x83: return SDLK_F7; case 0x0A: return SDLK_F8;
    case 0x01: return SDLK_F9; case 0x09: return SDLK_F10; case 0x78: return SDLK_F11; case 0x07: return SDLK_F12;
    case 0x75: return SDLK_UP; case 0x72: return SDLK_DOWN; case 0x6B: return SDLK_LEFT; case 0x74: return SDLK_RIGHT;
    default:   return SDLK_UNKNOWN;
    }
}

static SDLKey ps2_ext_map(uint8_t c)
{
    switch (c) {
    case 0x75: return SDLK_UP;
    case 0x72: return SDLK_DOWN;
    case 0x6B: return SDLK_LEFT;
    case 0x74: return SDLK_RIGHT;
    case 0x70: return SDLK_INSERT;
    case 0x71: return SDLK_DELETE;
    case 0x6C: return SDLK_HOME;
    case 0x69: return SDLK_END;
    case 0x7D: return SDLK_PAGEUP;
    case 0x7A: return SDLK_PAGEDOWN;
    case 0x14: return SDLK_RCTRL;
    case 0x11: return SDLK_RALT;
    case 0x5A: return SDLK_RETURN;
    case 0x4A: return SDLK_SLASH;
    default:   return SDLK_UNKNOWN;
    }
}

static void poll_ps2(void)
{
    static int ext = 0, rel = 0, skip = 0;
    while (PS2_STAT & 1) {
        uint8_t c = (uint8_t)PS2_DATA;
        if (skip) { skip--; continue; }
        if (c == 0xE1) {
            skip = 7;
            queue_key(SDLK_p, true);
            queue_key(SDLK_p, false);
            continue;
        }
        if (c == 0xE0) { ext = 1; continue; }
        if (c == 0xF0) { rel = 1; continue; }
        SDLKey k = ext ? ps2_ext_map(c) : ps2_to_key(c);
        if (k != SDLK_UNKNOWN) {
            queue_key(k, !rel);
        }
        ext = rel = 0;
    }
}

// Gamepad polling
static uint32_t pad_now = 0, pad_down = 0, pad_up = 0;

static void pad_sample(void)
{
    uint32_t cur = (PAD0 | PAD1) & 0xFFFu;
    pad_down |= cur & ~pad_now;
    pad_up   |= pad_now & ~cur;
    pad_now = cur;
}

static SDLKey pad_to_key(uint32_t bit)
{
    switch (bit) {
    case PAD_UP:     return SDLK_UP;
    case PAD_DOWN:   return SDLK_DOWN;
    case PAD_LEFT:   return SDLK_LEFT;
    case PAD_RIGHT:  return SDLK_RIGHT;
    case PAD_A:      return SDLK_SPACE;    // Jump
    case PAD_B:      return SDLK_LALT;     // Fire
    case PAD_Y:      return SDLK_LALT;     // Fire (alternate)
    case PAD_X:      return SDLK_RCTRL;    // Change weapon
    case PAD_START:  return SDLK_RETURN;   // Enter / Pause
    case PAD_SELECT: return SDLK_ESCAPE;   // Escape / Menu
    default:         return SDLK_UNKNOWN;
    }
}

static void poll_pads(void)
{
    static uint32_t btn_idle = 0xFFFFFFFFu, prev_btn = 0;
    static SDLKey sent_key[12] = { SDLK_UNKNOWN };

    pad_sample();
    uint32_t cur = pad_now, dn = pad_down, up = pad_up;
    pad_down = pad_up = 0;

    for (int b = 0; b < 12; b++) {
        uint32_t m = 1u << b;
        if ((cur & m) && (up & m)) {
            if (sent_key[b] != SDLK_UNKNOWN) queue_key(sent_key[b], false);
        }
        if (dn & m) {
            sent_key[b] = pad_to_key(m);
            if (sent_key[b] != SDLK_UNKNOWN) queue_key(sent_key[b], true);
        }
        if (!(cur & m) && (up & m)) {
            if (sent_key[b] != SDLK_UNKNOWN) queue_key(sent_key[b], false);
        }
    }

    // Board buttons S1 (Esc) and S2 (Enter)
    if (btn_idle == 0xFFFFFFFFu) btn_idle = SYS_BTN;
    uint32_t bt = SYS_BTN ^ btn_idle;
    if ((bt ^ prev_btn) & 1) queue_key(SDLK_ESCAPE, (bt & 1) != 0);
    if ((bt ^ prev_btn) & 2) queue_key(SDLK_RETURN, ((bt >> 1) & 1) != 0);
    prev_btn = bt;
}

// ============================================================================
// SDL API Implementation
// ============================================================================
extern "C" {

// ============================================================================
// Watchdog (debugging): a timer interrupt every 0.5 s; if no frame has been
// shown for 3 s it prints where the CPU is (mepc) and the blitter/video state
// ============================================================================
static volatile uint32_t wd_last_flip;
extern "C" uint32_t sys_heap_top(void);
extern "C" uint32_t sys_heap_limit(void);

static void wd_arm(void)
{
    uint64_t t = time_cycles() + CPU_HZ / 2;
    SYS_MTIMECMPH = 0xFFFFFFFFu;
    SYS_MTIMECMP  = (uint32_t)t;
    SYS_MTIMECMPH = (uint32_t)(t >> 32);
}

extern "C" void trap_handler(uint32_t cause, uint32_t epc)
{
    if (cause == 0x80000007u) {
        if (time_us() - wd_last_flip > 3000000u)
            lib_printf("\nWATCHDOG: no frame for %u ms, pc=%08x blt_status=%08x vid_pending=%x\n",
                       (unsigned)((time_us() - wd_last_flip) / 1000), (unsigned)epc,
                       (unsigned)BLT_STATUS, (unsigned)VID_PENDING);
        wd_arm();
        return;
    }
    lib_printf("\n*** exception mcause=%x mepc=%08x\n", (unsigned)cause, (unsigned)epc);
    for (;;) ;
}

static void wd_start(void)
{
    wd_last_flip = time_us();
    wd_arm();
    __asm__ volatile ("csrs mie, %0" :: "r"(0x80u));     // MTIE
    irq_enable();
}

int SDL_Init(Uint32 flags)
{
    (void)flags;
    video_init_hw();
    wd_start();
    snd_init();
    if (sd_init() != 0) {
        lib_printf("WARNING: no microSD card found!\n");
    } else {
        int r = fat_mount();
        if (r != 0) {
            lib_printf("WARNING: could not mount microSD (error %d)\n", r);
        } else {
            lib_printf("microSD mounted successfully!\n");
            read_config();
        }
    }
    lib_printf("drawing with the %s (JAZZ.TXT: draw=blitter / draw=cpu)\n", use_blitter ? "blitter" : "CPU");
    return 0;
}

int SDL_InitSubSystem(Uint32 flags) { return SDL_Init(flags); }
void SDL_QuitSubSystem(Uint32 flags) { (void)flags; }

void SDL_Quit(void)
{
    if (audio_opened) {
        snd_stop(0);
        audio_opened = false;
    }
}

const char *SDL_GetError(void) { return ""; }
void SDL_ClearError(void) {}

Uint32 SDL_GetTicks(void)
{
    return (Uint32)(time_cycles() / (CPU_HZ / 1000u));
}

void SDL_Delay(Uint32 ms)
{
    uint32_t start = SDL_GetTicks();
    while (SDL_GetTicks() - start < ms) {
        audio_feed();
    }
}

SDL_Surface *SDL_CreateRGBSurface(Uint32 flags, int width, int height, int depth,
                                  Uint32 Rmask, Uint32 Gmask, Uint32 Bmask, Uint32 Amask)
{
    (void)flags; (void)depth; (void)Rmask; (void)Gmask; (void)Bmask; (void)Amask;
    blt_sync();                 // the memory may come from a surface the blitter still uses
    SDL_Surface *s = (SDL_Surface *)calloc(1, sizeof(SDL_Surface));
    if (!s) return NULL;

    s->w = width;
    s->h = height;
    s->pitch = width;
    s->pixels = malloc(width * height);
    if (!s->pixels) { free(s); return NULL; }
    memset(s->pixels, 0, width * height);

    s->format = (SDL_PixelFormat *)calloc(1, sizeof(SDL_PixelFormat));
    s->format->BitsPerPixel = 8;
    s->format->BytesPerPixel = 1;
    s->format->palette = (SDL_Palette *)calloc(1, sizeof(SDL_Palette));
    s->format->palette->ncolors = 256;
    s->format->palette->colors = (SDL_Color *)calloc(256, sizeof(SDL_Color));

    s->clip_rect.x = 0;
    s->clip_rect.y = 0;
    s->clip_rect.w = width;
    s->clip_rect.h = height;
    s->refcount = 1;

    return s;
}

SDL_Surface *SDL_SetVideoMode(int width, int height, int bpp, Uint32 flags)
{
    if (main_screen) {
        if (main_screen->w == width && main_screen->h == height) {
            main_screen->flags = flags;
            return main_screen;
        }
        SDL_FreeSurface(main_screen);
        main_screen = NULL;
    }

    main_screen = SDL_CreateRGBSurface(flags, width, height, bpp, 0, 0, 0, 0);
    if (main_screen) {
        main_screen->flags = flags;
    }
    return main_screen;
}

void SDL_FreeSurface(SDL_Surface *surface)
{
    if (!surface) return;
    blt_sync();
    if (surface == blt_dst) blt_dst = NULL;
    if (surface->pixels) free(surface->pixels);
    if (surface->format) {
        if (surface->format->palette) {
            if (surface->format->palette->colors) free(surface->format->palette->colors);
            free(surface->format->palette);
        }
        free(surface->format);
    }
    free(surface);
}

int SDL_SetPalette(SDL_Surface *surface, int flags, const SDL_Color *colors, int firstcolor, int ncolors)
{
    (void)flags;
    if (!surface || !surface->format || !surface->format->palette || !colors) return 0;
    if (firstcolor < 0 || firstcolor + ncolors > 256) return 0;

    memcpy(&surface->format->palette->colors[firstcolor], colors, ncolors * sizeof(SDL_Color));

    if (surface == main_screen) {
        for (int i = 0; i < ncolors; i++) {
            int idx = firstcolor + i;
            uint32_t c = ((uint32_t)colors[i].r << 16) | ((uint32_t)colors[i].g << 8) | colors[i].b;
            if (last_hw_palette[idx] != c) {
                last_hw_palette[idx] = c;
                PALETTE[idx] = c;
            }
        }
    }
    return 1;
}

int SDL_SetColorKey(SDL_Surface *surface, Uint32 flag, Uint32 key)
{
    if (!surface || !surface->format) return -1;
    if (flag & SDL_SRCCOLORKEY) {
        surface->flags |= SDL_SRCCOLORKEY;
        surface->format->colorkey = key;
    } else {
        surface->flags &= ~SDL_SRCCOLORKEY;
    }
    return 0;
}

int SDL_SetClipRect(SDL_Surface *surface, const SDL_Rect *rect)
{
    if (!surface) return 0;
    if (rect) {
        int x = rect->x, y = rect->y, w = rect->w, h = rect->h;
        if (x < 0) { w += x; x = 0; }
        if (y < 0) { h += y; y = 0; }
        if (x + w > surface->w) w = surface->w - x;
        if (y + h > surface->h) h = surface->h - y;
        surface->clip_rect.x = (x < 0) ? 0 : x;
        surface->clip_rect.y = (y < 0) ? 0 : y;
        surface->clip_rect.w = (w < 0) ? 0 : w;
        surface->clip_rect.h = (h < 0) ? 0 : h;
    } else {
        surface->clip_rect.x = 0;
        surface->clip_rect.y = 0;
        surface->clip_rect.w = surface->w;
        surface->clip_rect.h = surface->h;
    }
    return 1;
}

int SDL_FillRect(SDL_Surface *dst, const SDL_Rect *dstrect, Uint32 color)
{
    if (!dst || !dst->pixels) return -1;

    int dx = dstrect ? dstrect->x : 0;
    int dy = dstrect ? dstrect->y : 0;
    int dw = dstrect ? dstrect->w : dst->w;
    int dh = dstrect ? dstrect->h : dst->h;

    int cx = dst->clip_rect.x, cy = dst->clip_rect.y;
    int cw = dst->clip_rect.w, ch = dst->clip_rect.h;

    if (dx < cx) { dw -= (cx - dx); dx = cx; }
    if (dy < cy) { dh -= (cy - dy); dy = cy; }
    if (dx + dw > cx + cw) dw = (cx + cw) - dx;
    if (dy + dh > cy + ch) dh = (cy + ch) - dy;

    if (dw <= 0 || dh <= 0) return 0;

    if (use_blitter) {
        blt_target(dst);
        BLT_XY    = blt_xy(dx, dy);
        BLT_SIZE  = blt_xy(dw, dh);
        BLT_COLOR = (uint8_t)color;
        BLT_CMD   = BLT_OP_FILL;
        blt_pending = true;
        return 0;
    }

    uint8_t *dp = (uint8_t *)dst->pixels + dy * dst->pitch + dx;
    for (int r = 0; r < dh; r++) {
        memset(dp, (uint8_t)color, dw);
        dp += dst->pitch;
    }
    return 0;
}

int SDL_BlitSurface(SDL_Surface *src, const SDL_Rect *srcrect, SDL_Surface *dst, SDL_Rect *dstrect)
{
    if (!src || !dst || !src->pixels || !dst->pixels) return -1;

    int sx = srcrect ? srcrect->x : 0;
    int sy = srcrect ? srcrect->y : 0;
    int sw = srcrect ? srcrect->w : src->w;
    int sh = srcrect ? srcrect->h : src->h;

    int dx = dstrect ? dstrect->x : 0;
    int dy = dstrect ? dstrect->y : 0;

    if (sx < 0) { sw += sx; dx -= sx; sx = 0; }
    if (sy < 0) { sh += sy; dy -= sy; sy = 0; }
    if (sx + sw > src->w) sw = src->w - sx;
    if (sy + sh > src->h) sh = src->h - sy;

    int cx = dst->clip_rect.x, cy = dst->clip_rect.y;
    int cw = dst->clip_rect.w, ch = dst->clip_rect.h;

    if (dx < cx) { int diff = cx - dx; dx = cx; sx += diff; sw -= diff; }
    if (dy < cy) { int diff = cy - dy; dy = cy; sy += diff; sh -= diff; }
    if (dx + sw > cx + cw) sw = (cx + cw) - dx;
    if (dy + sh > cy + ch) sh = (cy + ch) - dy;

    if (sw <= 0 || sh <= 0) return 0;

    if (dstrect) {
        dstrect->x = dx;
        dstrect->y = dy;
        dstrect->w = sw;
        dstrect->h = sh;
    }

    if (use_blitter && src != dst) {
        blt_target(dst);
        BLT_SRC     = PHYS(src->pixels) + (uint32_t)(sy * src->pitch + sx);
        BLT_SSTRIDE = src->pitch;
        BLT_XY      = blt_xy(dx, dy);
        BLT_SIZE    = blt_xy(sw, sh);
        BLT_U0 = 0; BLT_V0 = 0; BLT_DU = 0x10000; BLT_DV = 0x10000;
        if (src->flags & SDL_SRCCOLORKEY) {
            BLT_COLOR = (uint32_t)(uint8_t)src->format->colorkey << 16;
            BLT_CMD   = BLT_OP_BLIT | BLT_F_KEY;
        } else {
            BLT_CMD   = BLT_OP_BLIT;
        }
        blt_pending = true;
        return 0;
    }

    // CPU drawing, or the same surface (overlapping areas): after the queued commands
    blt_sync();
    const uint8_t *sp = (const uint8_t *)src->pixels + sy * src->pitch + sx;
    uint8_t *dp = (uint8_t *)dst->pixels + dy * dst->pitch + dx;

    if (src->flags & SDL_SRCCOLORKEY) {
        uint8_t key = (uint8_t)src->format->colorkey;
        for (int row = 0; row < sh; row++) {
            for (int col = 0; col < sw; col++) {
                uint8_t pix = sp[col];
                if (pix != key) dp[col] = pix;
            }
            sp += src->pitch;
            dp += dst->pitch;
        }
    } else {
        for (int row = 0; row < sh; row++) {
            memcpy(dp, sp, sw);
            sp += src->pitch;
            dp += dst->pitch;
        }
    }
    return 0;
}

int SDL_SoftStretch(SDL_Surface *src, const SDL_Rect *srcrect, SDL_Surface *dst, const SDL_Rect *dstrect)
{
    return SDL_BlitSurface(src, srcrect, dst, (SDL_Rect *)dstrect);
}

int SDL_Flip(SDL_Surface *screen)
{
    if (!screen || !screen->pixels) return -1;

    wd_last_flip = time_us();
    audio_feed();

    int t = 3 - fb_cur - fb_prev;                    // the free buffer
    surface src = { (uint32_t)screen->pixels, (uint16_t)screen->w, (uint16_t)screen->h, (uint16_t)screen->pitch };
    surface dst = { fb_addr[t], 640, 480, 640 };
    gfx_target(&dst);
    blt_dst = NULL;
    gfx_blit_scaled(&src, 0, 0, screen->w, screen->h, 0, 0, 640, 480, 0, 0);
    audio_feed();
    gfx_wait();                  // the game redraws screen->pixels as soon as we return
    if (use_blitter) blt_pending = true;   // (blt_sync still has to invalidate the dcache)

    // queue it: shown at the next frame start. If the previous one was still
    // pending it is simply replaced (that frame is dropped) and fb_prev stays
    // on screen. If a frame starts while we do this we cannot tell which
    // buffer was latched, so wait for ours to be shown.
    uint32_t f0 = gfx_frame();
    uint32_t pend = VID_PENDING & 1;
    VID_FB_BASE = PHYS(fb_addr[t]);
    VID_STRIDE  = 640;
    if (gfx_frame() != f0) {
        while (VID_PENDING & 1) ;
        fb_prev = fb_cur;
    } else if (!pend) {
        fb_prev = fb_cur;
    }
    fb_cur = t;

    // frames per second over the UART every 5 s
    static uint32_t fps_t0, fps_n;
    uint32_t now = time_us();
    if (!fps_t0) fps_t0 = now;
    fps_n++;
    if (now - fps_t0 >= 5000000u) {
        uint32_t x10 = (uint32_t)((uint64_t)fps_n * 10000000u / (now - fps_t0));
        struct mallinfo mi = mallinfo();
        printf("FPS: %u.%u  heap: %u KB in use, %u KB taken, %u KB max\n",
               (unsigned)(x10 / 10), (unsigned)(x10 % 10), (unsigned)(mi.uordblks >> 10),
               (unsigned)(sys_heap_top() >> 10), (unsigned)(sys_heap_limit() >> 10));
        fps_t0 = now; fps_n = 0;
    }

    return 0;
}

Uint32 SDL_MapRGB(const SDL_PixelFormat *format, Uint8 r, Uint8 g, Uint8 b)
{
    (void)format;
    // Map to 6-bit or simple index
    return (r > 128 || g > 128 || b > 128) ? 15 : 0;
}

void SDL_WM_SetCaption(const char *title, const char *icon)
{
    (void)title; (void)icon;
}

int SDL_ShowCursor(int toggle)
{
    (void)toggle;
    return 0;
}

int SDL_PollEvent(SDL_Event *event)
{
    if (eq_head == eq_tail) {
        poll_ps2();
        poll_pads();
    }
    if (eq_head == eq_tail) return 0;

    if (event) {
        *event = event_queue[eq_tail];
    }
    eq_tail = (eq_tail + 1) % EVENT_QUEUE_SIZE;
    return 1;
}

char *SDL_GetKeyName(SDLKey key)
{
    static char buf[16];
    if (key >= SDLK_a && key <= SDLK_z) {
        buf[0] = (char)('A' + (key - SDLK_a)); buf[1] = 0; return buf;
    }
    if (key >= SDLK_0 && key <= SDLK_9) {
        buf[0] = (char)key; buf[1] = 0; return buf;
    }
    switch (key) {
    case SDLK_UP: return (char *)"Up";
    case SDLK_DOWN: return (char *)"Down";
    case SDLK_LEFT: return (char *)"Left";
    case SDLK_RIGHT: return (char *)"Right";
    case SDLK_SPACE: return (char *)"Space";
    case SDLK_RETURN: return (char *)"Return";
    case SDLK_ESCAPE: return (char *)"Esc";
    case SDLK_TAB: return (char *)"Tab";
    case SDLK_BACKSPACE: return (char *)"Backspace";
    case SDLK_LCTRL: case SDLK_RCTRL: return (char *)"Ctrl";
    case SDLK_LALT: case SDLK_RALT: return (char *)"Alt";
    case SDLK_LSHIFT: case SDLK_RSHIFT: return (char *)"Shift";
    default: return (char *)"Key";
    }
}

int SDL_NumJoysticks(void) { return 2; }
SDL_Joystick *SDL_JoystickOpen(int device_index) { (void)device_index; return (SDL_Joystick *)1; }
void SDL_JoystickClose(SDL_Joystick *joystick) { (void)joystick; }

int SDL_OpenAudio(SDL_AudioSpec *desired, SDL_AudioSpec *obtained)
{
    audio_cb = desired->callback;
    audio_udata = desired->userdata;
    audio_opened = true;
    audio_paused = true;

    if (obtained) {
        obtained->freq = AUDIO_RATE;
        obtained->format = AUDIO_S16SYS;
        obtained->channels = 2;
        obtained->samples = AUDIO_CHUNK_FRAMES;
        obtained->callback = desired->callback;
        obtained->userdata = desired->userdata;
    }

    // Start the stereo streaming DMA on voice 0 (from a silent ring)
    memset(audio_ring, 0, AUDIO_RING_FRAMES * 4);
    snd_stream_start(0, audio_ring, AUDIO_RING_FRAMES, AUDIO_RATE);
    return 0;
}

void SDL_PauseAudio(int pause_on)
{
    audio_paused = pause_on ? true : false;
}

void SDL_CloseAudio(void)
{
    if (audio_opened) {
        snd_stop(0);
        audio_opened = false;
    }
}

void SDL_LockAudio(void) { audio_locked = 1; }
void SDL_UnlockAudio(void) { audio_locked = 0; }

void SDL_MixAudio(Uint8 *dst, const Uint8 *src, Uint32 len, int volume)
{
    if (volume == 0 || !dst || !src) return;

    int16_t *d = (int16_t *)dst;
    const int16_t *s = (const int16_t *)src;
    int samples = (int)(len / 2);

    for (int i = 0; i < samples; i++) {
        int32_t val = (int32_t)d[i] + (((int32_t)s[i] * volume) / SDL_MIX_MAXVOLUME);
        if (val > 32767) val = 32767;
        else if (val < -32768) val = -32768;
        d[i] = (int16_t)val;
    }
}

int SDL_BuildAudioCVT(SDL_AudioCVT *cvt, Uint16 src_fmt, Uint8 src_ch, int src_rate,
                       Uint16 dst_fmt, Uint8 dst_ch, int dst_rate)
{
    (void)src_fmt; (void)src_ch; (void)dst_fmt; (void)dst_ch;
    if (!cvt) return -1;
    memset(cvt, 0, sizeof(*cvt));
    cvt->needed = 1;
    cvt->src_format = src_fmt;
    cvt->dst_format = dst_fmt;
    cvt->rate_incr = (double)src_rate / (double)dst_rate;
    // 8-bit mono to 16-bit stereo = 4x samples per input sample * frequency ratio
    int mult = ((dst_rate + src_rate - 1) / src_rate) * 4 + 4;
    cvt->len_mult = mult;
    cvt->len_ratio = ((double)dst_rate / (double)src_rate) * 4.0;
    return 1;
}

int SDL_ConvertAudio(SDL_AudioCVT *cvt)
{
    if (!cvt || !cvt->buf) return -1;

    // Convert 8-bit mono (unsigned or signed) into 16-bit stereo at 48 kHz
    int src_len = cvt->len;
    uint8_t *src_copy = (uint8_t *)malloc(src_len);
    if (!src_copy) return -1;
    memcpy(src_copy, cvt->buf, src_len);

    int dst_frames = (int)(src_len * (48000.0 / 11025.0));
    int16_t *dst = (int16_t *)cvt->buf;

    for (int i = 0; i < dst_frames; i++) {
        int src_idx = (int)((double)i * (11025.0 / 48000.0));
        if (src_idx >= src_len) src_idx = src_len - 1;
        uint8_t u = src_copy[src_idx];
        int16_t sample = ((int16_t)u - 128) << 8;
        dst[2 * i]     = sample;
        dst[2 * i + 1] = sample;
    }
    free(src_copy);

    cvt->len_cvt = dst_frames * 4;
    return 0;
}

static SDL_version linked_ver = { 1, 2, 15 };
const SDL_version *SDL_Linked_Version(void) { return &linked_ver; }

} // extern "C"
