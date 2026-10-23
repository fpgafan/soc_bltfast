// ============================================================================
// sd.c - Tarjeta SD en modo SPI (SDSC y SDHC/SDXC)
// ============================================================================
#include "lib.h"

static int sd_hc;                 // 1 = direccionamiento por bloques

static uint8_t spi(uint8_t b)
{
    SD_DATA = b;
    while (SD_STAT & 1) ;
    return (uint8_t)SD_DATA;
}

static void cs(int on, int div) { SD_CTRL = (uint32_t)(div << 8) | (on ? 1u : 0u); }

static int sd_div = 123;          // 400 kHz al iniciar

static uint8_t cmd(uint8_t c, uint32_t arg, uint8_t crc)
{
    spi(0xFF);
    spi(0x40 | c);
    spi(arg >> 24); spi(arg >> 16); spi(arg >> 8); spi(arg);
    spi(crc);
    uint8_t r;
    for (int i = 0; i < 16; i++) {
        r = spi(0xFF);
        if (!(r & 0x80)) return r;
    }
    return 0xFF;
}

int sd_init(void)
{
    sd_div = 123;
    cs(0, sd_div);
    for (int i = 0; i < 10; i++) spi(0xFF);           // 80 relojes con CS alto
    // si la placa se reinició a mitad de una lectura la tarjeta (que no se ha
    // apagado) sigue con el bloque pendiente y no responde al primer CMD0:
    // vaciarlo con relojes con CS bajo y reintentar
    int r0 = 0xFF;
    for (int t = 0; t < 8 && r0 != 0x01; t++) {
        cs(1, sd_div);
        if (t) for (int i = 0; i < 600; i++) spi(0xFF);
        r0 = cmd(0, 0, 0x95);
        if (r0 != 0x01) { cs(0, sd_div); spi(0xFF); }
    }
    if (r0 != 0x01) return -1;
    int v2 = 0;
    if (cmd(8, 0x1AA, 0x87) == 0x01) {
        uint8_t r[4];
        for (int i = 0; i < 4; i++) r[i] = spi(0xFF);
        if (r[2] != 0x01 || r[3] != 0xAA) { cs(0, sd_div); return -2; }
        v2 = 1;
    }
    uint32_t t0 = time_us();
    for (;;) {
        cmd(55, 0, 0x65);
        uint8_t r = cmd(41, v2 ? 0x40000000u : 0, 0x77);
        if (r == 0x00) break;
        if (time_us() - t0 > 1000000u) { cs(0, sd_div); return -3; }
    }
    sd_hc = 0;
    if (v2 && cmd(58, 0, 0xFD) == 0x00) {
        uint8_t ocr = spi(0xFF);
        spi(0xFF); spi(0xFF); spi(0xFF);
        sd_hc = (ocr & 0x40) != 0;
    }
    if (!sd_hc) cmd(16, 512, 0x15);
    // 90 / 10 = 9 MHz. Con DIV = 2 (16,5 MHz a 99 MHz de sistema) MISO se
    // muestrea demasiado pronto tras el flanco de bajada (sincronizador de 2
    // ciclos + retardo de la tarjeta) y se lee el bit anterior: con una SD de
    // 16 GB fallaba todo a DIV = 2 y DIV = 3..8 iba bien (apps/sdtest)
    sd_div = 4;
    cs(1, sd_div);
    return 0;
}

uint32_t sd_err;                  // último error: código | R1 << 8 | token << 16

int sd_read(uint32_t lba, void *dst)
{
    uint8_t r = cmd(17, sd_hc ? lba : lba * 512u, 0x01);
    if (r != 0x00) { sd_err = 1u | (uint32_t)r << 8; return -1; }
    SD_BLOCK = 1;
    while (SD_STAT & 1) ;
    if (SD_STAT & 2) { sd_err = 2; return -2; }
    uint32_t *d = dst;
    if (((uint32_t)dst & 3) == 0) {
        for (int i = 0; i < 128; i++) d[i] = SD_BUF[i];
    } else {
        uint8_t *b = dst;
        for (int i = 0; i < 128; i++) {
            uint32_t w = SD_BUF[i];
            b[4 * i] = w; b[4 * i + 1] = w >> 8; b[4 * i + 2] = w >> 16; b[4 * i + 3] = w >> 24;
        }
    }
    return 0;
}

int sd_write(uint32_t lba, const void *src)
{
    const uint8_t *b = src;
    for (int i = 0; i < 128; i++)
        SD_BUF[i] = b[4 * i] | (b[4 * i + 1] << 8) | (b[4 * i + 2] << 16) | ((uint32_t)b[4 * i + 3] << 24);
    if (cmd(24, sd_hc ? lba : lba * 512u, 0x01) != 0x00) return -1;
    SD_BLOCK = 2;
    while (SD_STAT & 1) ;
    uint8_t r = spi(0xFF);                             // respuesta de datos
    if ((r & 0x1F) != 0x05) return -2;
    uint32_t t0 = time_us();
    while (spi(0xFF) == 0x00)                          // ocupada
        if (time_us() - t0 > 500000u) return -3;
    return 0;
}
