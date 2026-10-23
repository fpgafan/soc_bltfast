// ============================================================================
// menu.c - Boot menu of the bltfast SoC (BOOT.BIN on the microSD)
//
//  The ROM boots BOOT.BIN from the card; with this menu as BOOT.BIN, it lists
//  the other .BIN files of the root directory and loads the chosen one at
//  0x4000_0000 just like the ROM would, so any program built with build.py
//  works unchanged. The menu itself runs from 0x4078_0000 (see menu.ld).
//
//  Controls: pads (Up/Down, Left/Right = page, A/B/Start = boot, Select =
//  re-read the card), PS/2 keyboard (arrows, PgUp/PgDn, Home/End, Enter,
//  R = re-read) or the UART terminal (w/s or arrows, Enter, r; a number +
//  Enter boots that entry directly).
// ============================================================================
#include "lib.h"
#include "gfx.h"

void app_jump(uint32_t addr) __attribute__((noreturn));

#define MAX_FILES  128
#define LOAD_MAX   (6u << 20)            // same limit as the ROM: below the stack/framebuffers
#define ROWS       16                    // visible lines of the list
#define ROW_H      20
#define LIST_X     40
#define LIST_Y     88

// colors (indices redefined over the default palette)
#define C_BG       200
#define C_PANEL    201
#define C_SEL      202
#define C_TEXT     203
#define C_DIM      204
#define C_TITLE    205
#define C_ERR      206
#define C_BAR      207

typedef struct {
    char     n83[11];                    // name as stored in the directory
    char     name[13];                   // "NAME.BIN"
    uint32_t size;
} entry;

static entry files[MAX_FILES];
static int   nfiles, sel, top;
static char  status[64];                 // message line (errors)

// ---------------------------------------------------------------- strings
static void scopy(char *d, const char *s, int max)
{
    int i = 0;
    while (s[i] && i < max - 1) { d[i] = s[i]; i++; }
    d[i] = 0;
}

static char *put_dec(char *p, uint32_t v)
{
    char t[12];
    int n = 0;
    do { t[n++] = (char)('0' + v % 10); v /= 10; } while (v);
    while (n) *p++ = t[--n];
    *p = 0;
    return p;
}

// "DOOM    BIN" -> "DOOM.BIN"
static void name_83(char *d, const char *n83)
{
    int k = 0;
    for (int i = 0; i < 8 && n83[i] != ' '; i++) d[k++] = n83[i];
    d[k++] = '.';
    for (int i = 8; i < 11 && n83[i] != ' '; i++) d[k++] = n83[i];
    d[k] = 0;
}

// size in KB right-aligned in 8 characters ("   1234 KB" without the unit)
static void size_str(char *d, uint32_t size)
{
    char t[12];
    put_dec(t, (size + 1023) / 1024);
    int n = (int)strlen(t), pad = 7 - n;
    for (int i = 0; i < pad; i++) *d++ = ' ';
    scopy(d, t, 12);
    d += strlen(d);
    scopy(d, " KB", 4);
}

// ---------------------------------------------------------------- card
static void add_file(const char *n83, uint32_t size)
{
    if (nfiles >= MAX_FILES) return;
    if (memcmp(n83 + 8, "BIN", 3) || !memcmp(n83, "BOOT    BIN", 11)) return;
    if (n83[0] == '.') return;
    entry *e = &files[nfiles++];
    memcpy(e->n83, n83, 11);
    name_83(e->name, n83);
    e->size = size;
}

static void scan(void)
{
    nfiles = 0; sel = 0; top = 0;
    status[0] = 0;
    int r = sd_init();
    if (r) { scopy(status, "No SD card (press R / Select to retry)", sizeof(status)); return; }
    if (fat_mount() || fat_list(add_file) < 0) {
        scopy(status, "Cannot read the FAT file system", sizeof(status));
        return;
    }
    // alphabetical order (insertion sort: few entries)
    for (int i = 1; i < nfiles; i++) {
        entry t = files[i];
        int j = i - 1;
        while (j >= 0 && memcmp(files[j].n83, t.n83, 11) > 0) { files[j + 1] = files[j]; j--; }
        files[j + 1] = t;
    }
    if (!nfiles) scopy(status, "No .BIN files in the root directory", sizeof(status));
}

static void print_list(void)
{
    printf("\nbootmenu: %d program(s) on the SD\n", nfiles);
    for (int i = 0; i < nfiles; i++) printf("  %d  %s  %u bytes\n", i + 1, files[i].name, files[i].size);
    if (status[0]) printf("  %s\n", status);
    printf("w/s or arrows + Enter, a number + Enter, r = re-read the card\n");
}

// ---------------------------------------------------------------- screen
static void palette(void)
{
    gfx_palette(C_BG,    0x101828);
    gfx_palette(C_PANEL, 0x1C2840);
    gfx_palette(C_SEL,   0x3060C0);
    gfx_palette(C_TEXT,  0xE8ECF4);
    gfx_palette(C_DIM,   0x8090A8);
    gfx_palette(C_TITLE, 0xFFC040);
    gfx_palette(C_ERR,   0xFF6060);
    gfx_palette(C_BAR,   0x40C080);
}

static void draw_frame(void)
{
    gfx_clear(C_BG);
    gfx_text_scaled(LIST_X, 24, "bltfast", C_TITLE, -1, 3);
    gfx_text_scaled(LIST_X + 7 * 24 + 16, 32, "boot menu", C_TEXT, -1, 2);
    gfx_fill(LIST_X - 8, LIST_Y - 8, SCR_W - 2 * (LIST_X - 8), ROWS * ROW_H + 16, C_PANEL);
}

static void draw_menu(void)
{
    draw_frame();
    for (int r = 0; r < ROWS && top + r < nfiles; r++) {
        int i = top + r, y = LIST_Y + r * ROW_H;
        if (i == sel) gfx_fill(LIST_X - 4, y - 2, SCR_W - 2 * (LIST_X - 4), ROW_H, C_SEL);
        gfx_text_scaled(LIST_X + 4, y + 2, files[i].name, C_TEXT, -1, 2);
        char s[16];
        size_str(s, files[i].size);
        gfx_text_scaled(SCR_W - LIST_X - 10 * 16 - 4, y + 2, s, i == sel ? C_TEXT : C_DIM, -1, 2);
    }
    // scroll indicator
    if (nfiles > ROWS) {
        int h = ROWS * ROW_H, bh = h * ROWS / nfiles, by = h * top / nfiles;
        gfx_fill(SCR_W - LIST_X + 2, LIST_Y + by, 4, bh, C_DIM);
    }
    int fy = LIST_Y + ROWS * ROW_H + 18;
    if (status[0])
        gfx_text_scaled(LIST_X, fy, status, C_ERR, -1, (int)strlen(status) * 16 <= SCR_W - 2 * LIST_X ? 2 : 1);
    else {
        char t[48] = "Program ";
        char *p = put_dec(t + 8, (uint32_t)sel + 1);
        scopy(p, " of ", 5);
        put_dec(p + 4, (uint32_t)nfiles);
        gfx_text_scaled(LIST_X, fy, t, C_DIM, -1, 2);
    }
    gfx_text(LIST_X, SCR_H - 28, "Up/Down: choose   Left/Right: page   A / Start / Enter: boot", C_DIM, -1);
    gfx_text(LIST_X, SCR_H - 16, "Select / R: re-read the card", C_DIM, -1);
    gfx_flip();
}

static void draw_loading(const entry *e, uint32_t done)
{
    draw_frame();
    char t[40] = "Loading ";
    scopy(t + 8, e->name, 13);
    gfx_text_scaled(LIST_X + 16, LIST_Y + 100, t, C_TEXT, -1, 2);
    int w = SCR_W - 2 * (LIST_X + 16);
    gfx_rect(LIST_X + 16, LIST_Y + 140, w, 24, C_DIM);
    int fill = e->size ? (int)((uint64_t)(w - 4) * done / e->size) : w - 4;
    gfx_fill(LIST_X + 18, LIST_Y + 142, fill, 20, C_BAR);
    gfx_flip();
}

// ---------------------------------------------------------------- boot
// leaves the hardware as the ROM leaves it (video at its reset values,
// interrupts off) and jumps to the program
static void start(void)
{
    gfx_target(&gfx_screen);
    gfx_clear(0);
    gfx_flip();
    gfx_clear(0);
    gfx_wait();
    irq_disable();
    SYS_IRQ_EN = 0;
    VID_FB_BASE = PHYS(FB0);
    VID_STRIDE = SCR_W;
    VID_SCROLL_X = 0; VID_SCROLL_Y = 0; VID_WRAP_W = 0; VID_WRAP_H = 0;
    VID_CTRL = VID_EN | VID_HDMI;
    while (!(UART_STAT & UART_TXIDLE)) ;
    app_jump(SDRAM_BASE);
}

static void boot(int i)
{
    const entry *e = &files[i];
    fat_file f;
    status[0] = 0;
    if (e->size == 0 || e->size > LOAD_MAX) { scopy(status, "Too big (6 MB max) or empty", sizeof(status)); return; }
    if (fat_open(&f, e->n83)) { scopy(status, "Cannot open the file", sizeof(status)); return; }
    printf("bootmenu: loading %s (%u bytes)\n", e->name, e->size);
    uint8_t *dst = (uint8_t *)SDRAM_BASE;
    uint32_t done = 0;
    while (done < e->size) {
        draw_loading(e, done);
        uint32_t n = e->size - done;
        if (n > (128u << 10)) n = 128u << 10;
        if (fat_read(&f, dst + done, n) != (int)n) {
            printf("bootmenu: read error at %u\n", done);
            scopy(status, "SD read error", sizeof(status));
            return;
        }
        done += n;
    }
    draw_loading(e, done);
    printf("bootmenu: starting %s\n", e->name);
    start();
}

// ---------------------------------------------------------------- input
enum { K_NONE, K_UP, K_DOWN, K_PGUP, K_PGDN, K_HOME, K_END, K_OK, K_RESCAN, K_NUM };

static int ps2_key(void)
{
    static int ext, rel;
    while (PS2_STAT & 1) {
        uint8_t c = (uint8_t)PS2_DATA;
        if (c == 0xE0) { ext = 1; continue; }
        if (c == 0xF0) { rel = 1; continue; }
        int k = K_NONE;
        if (!rel) {
            if (ext) switch (c) {
                case 0x75: k = K_UP; break;   case 0x72: k = K_DOWN; break;
                case 0x6B: case 0x7D: k = K_PGUP; break;
                case 0x74: case 0x7A: k = K_PGDN; break;
                case 0x6C: k = K_HOME; break; case 0x69: k = K_END; break;
                case 0x5A: k = K_OK; break;
            } else switch (c) {
                case 0x1D: k = K_UP; break;   case 0x1B: k = K_DOWN; break;   // W / S
                case 0x5A: case 0x29: k = K_OK; break;                        // Enter / space
                case 0x2D: k = K_RESCAN; break;                               // R
            }
        }
        ext = rel = 0;
        if (k) return k;
    }
    return K_NONE;
}

// pads: pressed edges, with auto-repeat on the D-pad
static int pad_key(void)
{
    static uint32_t prev, next_rep;
    uint32_t cur = (PAD0 | PAD1) & 0xFFFu;
    if (cur == 0xFFFu) cur = 0;                       // no pad / floating line
    uint32_t now = time_us(), dirs = PAD_UP | PAD_DOWN | PAD_LEFT | PAD_RIGHT;
    uint32_t hit = cur & ~prev;
    if (hit) next_rep = now + 400000;
    else if ((cur & dirs) && (int32_t)(now - next_rep) >= 0) { hit = cur & dirs; next_rep = now + 80000; }
    prev = cur;
    if (hit & PAD_UP)    return K_UP;
    if (hit & PAD_DOWN)  return K_DOWN;
    if (hit & PAD_LEFT)  return K_PGUP;
    if (hit & PAD_RIGHT) return K_PGDN;
    if (hit & (PAD_A | PAD_B | PAD_START)) return K_OK;
    if (hit & PAD_SELECT) return K_RESCAN;
    return K_NONE;
}

// UART: w/s/k/j, ESC [ A / B, Enter, r, digits
static int num_buf;
static int uart_key(void)
{
    static int esc;
    int c;
    while ((c = uart_getc()) >= 0) {
        if (esc == 1) { esc = c == '[' ? 2 : 0; continue; }
        if (esc == 2) {
            esc = 0;
            if (c == 'A') return K_UP;
            if (c == 'B') return K_DOWN;
            if (c == '5') return K_PGUP;
            if (c == '6') return K_PGDN;
            continue;
        }
        if (c == 27) { esc = 1; continue; }
        if (c >= '0' && c <= '9') { num_buf = num_buf * 10 + (c - '0'); uart_putc(c); continue; }
        if (c == '\r' || c == '\n') return num_buf ? K_NUM : K_OK;
        if (c == 'w' || c == 'k') return K_UP;
        if (c == 's' || c == 'j') return K_DOWN;
        if (c == 'r') return K_RESCAN;
    }
    return K_NONE;
}

static void move(int to)
{
    if (to >= nfiles) to = nfiles - 1;
    if (to < 0) to = 0;
    sel = to;
    if (sel < top) top = sel;
    if (sel >= top + ROWS) top = sel - ROWS + 1;
}

int main(void)
{
    printf("\nbltfast boot menu\n");
    while (PS2_STAT & 1) (void)PS2_DATA;          // whatever was typed before
    gfx_init();
    palette();
    scan();
    print_list();
    for (;;) {
        draw_menu();                                  // gfx_flip: one frame per pass
        int k = ps2_key();
        if (!k) k = pad_key();
        if (!k) k = uart_key();
        switch (k) {
        case K_UP:   move(sel - 1); break;
        case K_DOWN: move(sel + 1); break;
        case K_PGUP: move(sel - ROWS); break;
        case K_PGDN: move(sel + ROWS); break;
        case K_HOME: move(0); break;
        case K_END:  move(nfiles - 1); break;
        case K_RESCAN: scan(); print_list(); break;
        case K_NUM:
            uart_puts("\n");
            if (num_buf <= nfiles) { move(num_buf - 1); boot(sel); }
            num_buf = 0;
            break;
        case K_OK:
            if (nfiles) boot(sel);
            else { scan(); print_list(); }
            break;
        }
        if (k == K_OK || k == K_NUM) {
            if (status[0]) printf("bootmenu: %s\n", status);
        }
    }
}
