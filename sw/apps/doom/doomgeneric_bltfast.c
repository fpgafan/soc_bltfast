// ============================================================================
// doomgeneric_bltfast.c - Doom en el SoC bltfast
//
//  Vídeo: Doom dibuja en I_VideoBuffer (320x200, 8 bpp); el blitter lo escala
//         a 640x480 (relación 4:3 original) en el buffer oculto y se cambia
//         al empezar el cuadro. La paleta de Doom va directa a la del vídeo.
//  Entrada: teclado PS/2 (set 2) y mandos SNES/NES (ver tabla abajo);
//         S1 = Esc, S2 = Enter.
//  Ficheros: directorio raíz de la microSD (sys_bltfast.c). Argumentos
//         opcionales en DOOMARGS.TXT (p. ej. "-iwad doom2.wad -warp 1").
// ============================================================================
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "src/doomgeneric.h"
#include "src/doomkeys.h"
#include "src/doomtype.h"
#include "src/i_video.h"
#include "src/d_loop.h"
#define printf lib_printf
#include "lib.h"
#include "gfx.h"
#include "audio.h"
#undef printf

extern byte *I_VideoBuffer;
extern boolean menuactive;
extern int messageToPrint;
extern boolean messageNeedsInput;
extern char sys_errbuf[];

// ---------------------------------------------------------------- vídeo
static surface shown, back;        // buffer visible y buffer donde se escala
static int text_y;

static void say(const char *s, uint8_t color)
{
    gfx_target(&shown);
    gfx_text(16, 16 + text_y, s, color, -1);
    gfx_wait();
    text_y += 10;
}

static void video_init(void)
{
    gfx_init();                                  // FB0/FB1, paleta por defecto
    back = gfx_screen;
    shown = back;
    shown.addr = back.addr == FB0 ? FB1 : FB0;
    gfx_target(&shown);
    gfx_clear(0);
    gfx_wait();
}

// temporizador a 500 Hz: muestrea los mandos (para no perder pulsaciones
// cortas mientras Doom no lee la entrada) y mueve el reproductor MIDI
#define TIMER_HZ 500
static volatile uint32_t pad_now, pad_down, pad_up;

static void pad_sample(void)
{
    uint32_t cur = (PAD0 | PAD1) & 0xFFFu;
    pad_down |= cur & ~pad_now;
    pad_up   |= pad_now & ~cur;
    pad_now = cur;
}

void OPL_Tick(void);

void irq_timer(void)
{
    uint64_t t = time_cycles() + CPU_HZ / TIMER_HZ;
    SYS_MTIMECMPH = 0xFFFFFFFFu;
    SYS_MTIMECMP  = (uint32_t)t;
    SYS_MTIMECMPH = (uint32_t)(t >> 32);
    pad_sample();
    midi_update();
    OPL_Tick();                                  // música FM (opl_bltfast.c)
}

static inline uint32_t irq_save(void)
{
    uint32_t s;
    __asm__ volatile ("csrrci %0, mstatus, 8" : "=r"(s) :: "memory");
    return s;
}
static inline void irq_restore(uint32_t s) { if (s & 8) irq_enable(); }

void DG_Init(void)
{
    irq_timer();
    __asm__ volatile ("csrs mie, %0" :: "r"(1u << 7));
    irq_enable();
}

void DG_DrawFrame(void)
{
    static surface src;
    src =(surface){ (uint32_t)I_VideoBuffer, SCREENWIDTH, SCREENHEIGHT, SCREENWIDTH };
    while (VID_PENDING & 1) ;                    // el cambio anterior ya se ve: 'back' está libre
    gfx_target(&back);
    gfx_blit_scaled(&src, 0, 0, SCREENWIDTH, SCREENHEIGHT, 0, 0, SCR_W, SCR_H, 0, 0);
    gfx_wait();
    VID_FB_BASE = PHYS(back.addr);
    VID_STRIDE  = SCR_W;
    surface t = shown; shown = back; back = t;

    // FPS por la UART cada 5 s (solo cuadros con un tic nuevo): media y el más lento
    static uint64_t t0, tlast;
    static uint32_t frames, worst;
    static int last_tic = -1;
    if (gametic == last_tic) return;
    last_tic = gametic;
    uint64_t now = time_cycles();
    if (!t0) t0 = tlast = now;
    uint32_t dt = (uint32_t)(now - tlast);
    if (dt > worst) worst = dt;
    tlast = now;
    frames++;
    if (now - t0 >= 5ull * CPU_HZ) {
        uint32_t f10 = (uint32_t)((uint64_t)frames * 10u * CPU_HZ / (now - t0));
        lib_printf("fps: %u.%u  (cuadro mas lento: %u ms)\n", f10 / 10, f10 % 10, worst / (CPU_HZ / 1000u));
        t0 = now; frames = 0; worst = 0;
    }
}

void DG_SetPalette(const struct color *colors)
{
    const uint32_t *c = (const uint32_t *)colors;   // {b, g, r, a} = 0x00RRGGBB
    for (int i = 0; i < 256; i++) PALETTE[i] = c[i] & 0xFFFFFFu;
}

void DG_SetWindowTitle(const char *title) { lib_printf("%s\n", title); }

// ---------------------------------------------------------------- tiempo
uint32_t DG_GetTicksMs(void) { return (uint32_t)(time_cycles() / (CPU_HZ / 1000u)); }
void DG_SleepMs(uint32_t ms) { delay_ms(ms); }

// ---------------------------------------------------------------- entrada
#define QLEN 64
static uint16_t q[QLEN];
static unsigned qh, qt;

static void push(int pressed, int key)
{
    if (!key || ((qh + 1) % QLEN) == qt) return;
    q[qh] = (uint16_t)((pressed ? 0x100 : 0) | (key & 0xFF));
    qh = (qh + 1) % QLEN;
}

// teclado PS/2, códigos del set 2 sin prefijo
static const uint8_t ps2_key[0x84] = {
    [0x1C] = 'a', [0x32] = 'b', [0x21] = 'c', [0x23] = 'd', [0x24] = 'e', [0x2B] = 'f',
    [0x34] = 'g', [0x33] = 'h', [0x43] = 'i', [0x3B] = 'j', [0x42] = 'k', [0x4B] = 'l',
    [0x3A] = 'm', [0x31] = 'n', [0x44] = 'o', [0x4D] = 'p', [0x15] = 'q', [0x2D] = 'r',
    [0x1B] = 's', [0x2C] = 't', [0x3C] = 'u', [0x2A] = 'v', [0x1D] = 'w', [0x22] = 'x',
    [0x35] = 'y', [0x1A] = 'z',
    [0x45] = '0', [0x16] = '1', [0x1E] = '2', [0x26] = '3', [0x25] = '4', [0x2E] = '5',
    [0x36] = '6', [0x3D] = '7', [0x3E] = '8', [0x46] = '9',
    [0x0E] = '`', [0x4E] = '-', [0x55] = '=', [0x66] = KEY_BACKSPACE, [0x0D] = KEY_TAB,
    [0x54] = '[', [0x5B] = ']', [0x5D] = '\\', [0x4C] = ';', [0x52] = '\'', [0x5A] = KEY_ENTER,
    [0x41] = ',', [0x49] = '.', [0x4A] = '/', [0x29] = ' ', [0x76] = KEY_ESCAPE,
    [0x12] = KEY_RSHIFT, [0x59] = KEY_RSHIFT, [0x14] = KEY_RCTRL, [0x11] = KEY_RALT,
    [0x58] = KEY_CAPSLOCK, [0x77] = KEY_NUMLOCK, [0x7E] = KEY_SCRLCK,
    [0x05] = KEY_F1, [0x06] = KEY_F2, [0x04] = KEY_F3, [0x0C] = KEY_F4, [0x03] = KEY_F5,
    [0x0B] = KEY_F6, [0x83] = KEY_F7, [0x0A] = KEY_F8, [0x01] = KEY_F9, [0x09] = KEY_F10,
    [0x78] = KEY_F11, [0x07] = KEY_F12,
    // teclado numérico
    [0x75] = KEY_UPARROW, [0x72] = KEY_DOWNARROW, [0x6B] = KEY_LEFTARROW, [0x74] = KEY_RIGHTARROW,
    [0x6C] = KEY_HOME, [0x69] = KEY_END, [0x7D] = KEY_PGUP, [0x7A] = KEY_PGDN,
    [0x70] = KEY_INS, [0x71] = KEY_DEL, [0x73] = '5', [0x7C] = '*', [0x7B] = '-', [0x79] = '+',
};

static int ps2_ext_key(uint8_t c)                // tras E0
{
    switch (c) {
    case 0x75: return KEY_UPARROW;   case 0x72: return KEY_DOWNARROW;
    case 0x6B: return KEY_LEFTARROW; case 0x74: return KEY_RIGHTARROW;
    case 0x70: return KEY_INS;  case 0x71: return KEY_DEL;
    case 0x6C: return KEY_HOME; case 0x69: return KEY_END;
    case 0x7D: return KEY_PGUP; case 0x7A: return KEY_PGDN;
    case 0x14: return KEY_RCTRL; case 0x11: return KEY_RALT;
    case 0x5A: return KEY_ENTER; case 0x4A: return '/';
    default:   return 0;                         // E0 12 / E0 59 (mayúsculas falsas), etc.
    }
}

static void poll_ps2(void)
{
    static int ext, rel, skip;
    while (PS2_STAT & 1) {
        uint8_t c = (uint8_t)PS2_DATA;
        if (skip) { skip--; continue; }
        if (c == 0xE1) { skip = 7; push(1, KEY_PAUSE); push(0, KEY_PAUSE); continue; }
        if (c == 0xE0) { ext = 1; continue; }
        if (c == 0xF0) { rel = 1; continue; }
        int k = ext ? ps2_ext_key(c) : (c < sizeof(ps2_key) ? ps2_key[c] : 0);
        push(!rel, k);
        ext = rel = 0;
    }
}

// mandos: cruceta = flechas; en juego B dispara, A abre/usa, Y corre,
// X cambia de arma, L/R se desplazan de lado, Start = menú, Select = mapa.
// En los menús A = aceptar, B = volver; en las preguntas A = sí, B = no.
static int pad_key(uint32_t bit)
{
    if (bit == PAD_UP)    return KEY_UPARROW;
    if (bit == PAD_DOWN)  return KEY_DOWNARROW;
    if (bit == PAD_LEFT)  return KEY_LEFTARROW;
    if (bit == PAD_RIGHT) return KEY_RIGHTARROW;
    if (bit == PAD_START) return KEY_ESCAPE;
    if (messageToPrint && messageNeedsInput) {
        if (bit == PAD_A) return 'y';
        if (bit == PAD_B) return 'n';
    } else if (menuactive) {
        if (bit == PAD_A) return KEY_ENTER;
        if (bit == PAD_B) return KEY_BACKSPACE;
    }
    switch (bit) {
    case PAD_B:      return KEY_RCTRL;
    case PAD_A:      return ' ';
    case PAD_Y:      return KEY_RSHIFT;
    case PAD_X:      return ']';
    case PAD_L:      return ',';
    case PAD_R:      return '.';
    case PAD_SELECT: return KEY_TAB;
    default:         return 0;
    }
}

static void poll_pads(void)
{
    static uint32_t btn_idle = 0xFFFFFFFFu, prev_btn;
    static uint8_t sent[12];
    uint32_t s = irq_save();
    pad_sample();                                // también con las interrupciones apagadas
    uint32_t cur = pad_now, dn = pad_down, up = pad_up;
    pad_down = pad_up = 0;
    irq_restore(s);
    for (int b = 0; b < 12; b++) {
        uint32_t m = 1u << b;
        // una pulsación entera entre dos lecturas también cuenta (en orden)
        if ((cur & m) && (up & m)) push(0, sent[b]);
        if (dn & m) { sent[b] = (uint8_t)pad_key(m); push(1, sent[b]); }
        if (!(cur & m) && (up & m)) push(0, sent[b]);
    }
    if (btn_idle == 0xFFFFFFFFu) btn_idle = SYS_BTN;
    uint32_t bt = SYS_BTN ^ btn_idle;            // polaridad: la del arranque
    if ((bt ^ prev_btn) & 1) push(bt & 1, KEY_ESCAPE);
    if ((bt ^ prev_btn) & 2) push((bt >> 1) & 1, KEY_ENTER);
    prev_btn = bt;
}

int DG_GetKey(int *pressed, unsigned char *key)
{
    if (qh == qt) { poll_ps2(); poll_pads(); }
    if (qh == qt) return 0;
    *pressed = q[qt] >> 8;
    *key = (unsigned char)q[qt];
    qt = (qt + 1) % QLEN;
    return 1;
}

static int any_input(void)
{
    int p; unsigned char k;
    while (DG_GetKey(&p, &k)) if (p) return 1;
    return 0;
}

// ---------------------------------------------------------------- salida
// pantalla ENDOOM: 80x25 caracteres (código, atributo) en celdas de 8x16
#define FONT_ADDR 0x406F8000u                    // gfx_init copia ahí la fuente 8x8

void DG_Endoom(byte *data)
{
    gfx_palette_default();                       // los 16 primeros son los de EGA
    while (VID_PENDING & 1) ;
    gfx_target(&shown);
    gfx_clear(0);
    BLT_SSTRIDE = 1;
    BLT_U0 = 0; BLT_V0 = 0;
    BLT_DU = 0x10000; BLT_DV = 0x8000;           // 8x8 -> 8x16
    BLT_SIZE = 8u | (16u << 16);
    for (int i = 0; i < 80 * 25; i++) {
        uint8_t ch = data[2 * i], at = data[2 * i + 1];
        BLT_COLOR = (at & 15u) | ((uint32_t)((at >> 4) & 7) << 8);
        BLT_SRC = PHYS(FONT_ADDR) + ch * 8u;
        BLT_XY = (uint32_t)(i % 80 * 8) | ((uint32_t)(40 + i / 80 * 16) << 16);
        BLT_CMD = BLT_OP_EXPAND;
    }
    gfx_wait();
    BLT_DV = 0x10000;
    irq_disable();
    midi_stop();
    AUD_STOP = 0xFFFFFFFFu;
    delay_ms(300);
    while (any_input()) ;
    while (!any_input()) ;
}

// exit(): con error, muestra los últimos mensajes y espera una tecla; luego
// reinicia el SoC (vuelve a la ROM de arranque)
void _exit(int code)
{
    irq_disable();
    midi_stop();
    AUD_STOP = 0xFFFFFFFFu;
    if (code != 0) {
        gfx_palette_default();
        while (VID_PENDING & 1) ;
        text_y = 0;
        gfx_target(&shown);
        gfx_clear(1);
        say("DOOM: error", 14);
        char line[81];
        const char *p = sys_errbuf;
        while (*p && text_y < 440) {
            int n = 0;
            while (*p && *p != '\n' && n < 78) line[n++] = *p++;
            if (*p == '\n') p++;
            line[n] = 0;
            if (n) say(line, 15);
        }
        say("", 15);
        say("pulsa una tecla o un boton para reiniciar", 11);
        delay_ms(500);
        while (any_input()) ;
        while (!any_input()) ;
    }
    lib_printf("\nreinicio\n");
    delay_ms(10);
    SYS_RESET = 0x5EB007u;
    for (;;) ;
}

static void fatal(const char *msg)
{
    say(msg, 12);
    lib_printf("%s\n", msg);
    for (;;) ;
}

// ---------------------------------------------------------------- arranque
#define MAXARG 32

static int read_args(char **argv)
{
    static char buf[1024];
    int argc = 1;
    argv[0] = "doom";
    FILE *f = fopen("DOOMARGS.TXT", "r");
    if (!f) return argc;
    size_t n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    buf[n] = 0;
    char *p = buf;
    while (*p && argc < MAXARG - 1) {
        while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') *p++ = 0;
        if (!*p) break;
        argv[argc++] = p;
        while (*p && *p != ' ' && *p != '\t' && *p != '\r' && *p != '\n') p++;
    }
    argv[argc] = 0;
    return argc;
}

int main(void)
{
    static char *argv[MAXARG];
    lib_printf("\nDOOM para bltfast\n");
    video_init();
    say("DOOM para bltfast", 14);
    if (sd_init()) fatal("no hay tarjeta microSD");
    int r = fat_mount();
    if (r) {
        char l[80];
        snprintf(l, sizeof(l), "no se pudo montar la microSD (error %d)", r);
        say(l, 12);
        if (r == -1) {
            snprintf(l, sizeof(l), "sd_read: %s (R1=%02x, token=%02x)",
                     (sd_err & 255) == 1 ? "CMD17 rechazado" : "no llega el token de datos",
                     (unsigned)(sd_err >> 8) & 255, (unsigned)(sd_err >> 16) & 255);
            say(l, 12);
        }
        fatal(r == -1 ? "error de lectura de la tarjeta" :
              r == -2 ? "el sector 0 no tiene firma 55AA" :
              r == -3 ? "no hay particion FAT (MBR/GPT)" :
              r == -5 ? "esta en exFAT: formateala en FAT32" :
              r == -6 ? "esta en NTFS: formateala en FAT32" :
                        "la particion no es FAT16/FAT32");
    }
    int argc = read_args(argv);
    if (argc > 1) {
        char l[80];
        snprintf(l, sizeof(l), "argumentos (DOOMARGS.TXT): %d", argc - 1);
        say(l, 7);
    }
    say("cargando el WAD...", 7);
    doomgeneric_Create(argc, argv);
    for (;;) doomgeneric_Tick();
}
