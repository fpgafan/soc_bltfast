// ============================================================================
// gfx.h - Gráficos 640x480 8 bpp con el motor 2D por hardware
//
//  Los comandos del blitter se encolan (32 en hardware) y la CPU sigue: hay
//  que llamar a gfx_wait() antes de leer con la CPU lo que dibujó el motor, y
//  gfx_flip() espera sola. Las texturas viven en la SDRAM en formato 8 bpp
//  (índices de paleta); el color 'key' de cada blit es transparente.
// ============================================================================
#ifndef GFX_H
#define GFX_H
#include <stdint.h>
#include "soc.h"

#define SCR_W 640
#define SCR_H 480

typedef struct {
    uint32_t addr;          // dirección de la SDRAM (cualquier vista)
    uint16_t w, h;          // tamaño en píxeles
    uint16_t stride;        // bytes por fila
} surface;

extern surface gfx_screen;  // buffer donde se dibuja (el oculto)

void gfx_init(void);                         // vídeo + doble buffer + paleta por defecto
void gfx_flip(void);                         // muestra lo dibujado (al empezar el cuadro)
void gfx_vsync(void);                        // espera al siguiente vblank
void gfx_wait(void);                         // espera a que el blitter termine
void gfx_target(const surface *s);           // superficie destino de los comandos
void gfx_clip(int x0, int y0, int x1, int y1);
void gfx_palette(int i, uint32_t rgb);
void gfx_palette_default(void);              // 16 EGA + cubo 6x7x6 + grises

void gfx_fill(int x, int y, int w, int h, uint8_t c);
void gfx_clear(uint8_t c);
void gfx_line(int x0, int y0, int x1, int y1, uint8_t c);
void gfx_rect(int x, int y, int w, int h, uint8_t c);
// copia de 'src' (x, y, w, h) a (dx, dy); flags: GFX_KEY (transparencia con key),
// GFX_FLIPX, GFX_FLIPY
#define GFX_KEY   1u
#define GFX_FLIPX 2u
#define GFX_FLIPY 4u
void gfx_blit(const surface *src, int sx, int sy, int w, int h, int dx, int dy,
              uint32_t flags, uint8_t key);
// escalado: el rectángulo origen (sx,sy,sw,sh) se dibuja en (dx,dy,dw,dh)
void gfx_blit_scaled(const surface *src, int sx, int sy, int sw, int sh,
                     int dx, int dy, int dw, int dh, uint32_t flags, uint8_t key);
// texto con la fuente 8x8 (página 850); bg < 0 = fondo transparente
void gfx_text(int x, int y, const char *s, uint8_t fg, int bg);
void gfx_text_scaled(int x, int y, const char *s, uint8_t fg, int bg, int scale);

// scroll por hardware del buffer visible: lienzo (dirección, ancho en bytes)
void gfx_scroll(uint32_t canvas, uint32_t stride, int sx, int sy, int wrap_w_log, int wrap_h);

uint32_t gfx_frame(void);                    // cuadros desde el arranque
#endif
