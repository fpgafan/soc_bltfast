// ============================================================================
// boot.c - ROM de arranque del SoC bltfast
//
//  1. Calibra la SDRAM: para cada latencia de captura (0..7) y fase del reloj
//     de la SDRAM (16 pasos de 22,5°) escribe y relee patrones (palabras sueltas
//     sin caché y ráfagas de 8 por la dcache). Elige la latencia con la ventana
//     de fases buena más ancha y la fase central.
//  2. Cargador por UART (115200 8N1):
//       PC -> "RVSP" div(4)            cambia el divisor de la UART (responde "OK")
//       PC -> "RVLD" addr len crc data carga en la SDRAM; responde "OK" y salta
//                                     a addr (o "ER" si el CRC32 no coincide)
//     La placa anuncia "RVBOOT\n" al empezar.
//  3. Sin nada por la UART en ~1,5 s: busca BOOT.BIN en la SD (FAT32/16),
//     lo carga en 0x4000_0000 y salta. Si falla, sigue esperando por la UART.
// ============================================================================
#include "lib.h"

void boot_jump(uint32_t addr) __attribute__((noreturn));

void boot_trap(uint32_t cause, uint32_t epc)
{
    printf("\nTRAP mcause=%x mepc=%08x\n", cause, epc);
    for (;;) ;
}

// ---------------------------------------------------------------- calibración
static int mem_test(uint32_t seed)
{
    volatile uint32_t *uc = (volatile uint32_t *)SDRAM_UC;
    static const uint32_t offs[8] = { 0x000000, 0x0007F8, 0x001000, 0x0A5A50,
                                      0x1FFFE0, 0x3C3C30, 0x555550, 0x7FFFC0 };
    // palabras sueltas sin caché (escritura + lectura)
    for (int k = 0; k < 8; k++)
        for (int i = 0; i < 8; i++)
            uc[(offs[k] >> 2) + i] = (seed * 0x9E3779B1u) ^ (k * 0x01010101u) ^ (i << 24) ^ ~(i << 3);
    for (int k = 0; k < 8; k++)
        for (int i = 0; i < 8; i++)
            if (uc[(offs[k] >> 2) + i] != ((seed * 0x9E3779B1u) ^ (k * 0x01010101u) ^ (i << 24) ^ ~(i << 3)))
                return 0;
    // ráfagas: invalidar la dcache y leer por la vista cacheable
    fence();
    volatile uint32_t *c = (volatile uint32_t *)SDRAM_BASE;
    for (int k = 0; k < 8; k++)
        for (int i = 0; i < 8; i++)
            if (c[(offs[k] >> 2) + i] != ((seed * 0x9E3779B1u) ^ (k * 0x01010101u) ^ (i << 24) ^ ~(i << 3)))
                return 0;
    return 1;
}

static void sdram_calibrate(void)
{
    while (!(SYS_SDRAM & 0x100)) ;
    uint16_t ok[8];
    uint32_t prev = SYS_SDRAM & 0xFF;
    for (int lat = 0; lat < 8; lat++) {
        ok[lat] = 0;
        for (int ph = 0; ph < 16; ph++) {
            SYS_SDRAM = (uint32_t)(ph << 4) | (uint32_t)lat;
            delay_us(50);
            if (mem_test(lat * 16 + ph + 1) && mem_test(lat * 16 + ph + 77)) ok[lat] |= 1u << ph;
        }
    }
    // la mejor ventana (circular) de fases buenas
    int best_lat = -1, best_len = 0, best_ph = 0;
    for (int lat = 0; lat < 8; lat++) {
        if (ok[lat] == 0xFFFF) { if (16 > best_len) { best_len = 16; best_lat = lat; best_ph = 0; } continue; }
        for (int st = 0; st < 16; st++) {
            if (!(ok[lat] >> st & 1) || (ok[lat] >> ((st + 15) & 15) & 1)) continue;   // inicio de ventana
            int len = 0;
            while (len < 16 && (ok[lat] >> ((st + len) & 15) & 1)) len++;
            if (len > best_len) { best_len = len; best_lat = lat; best_ph = (st + len / 2) & 15; }
        }
    }
    printf("SDRAM: fases buenas por latencia:");
    for (int lat = 0; lat < 8; lat++) printf(" %d:%04x", lat, ok[lat]);
    if (best_lat < 0) {
        printf("\nSDRAM: NINGUNA configuración funciona (se deja %x)\n", prev);
        SYS_SDRAM = prev;
        return;
    }
    SYS_SDRAM = (uint32_t)(best_ph << 4) | (uint32_t)best_lat;
    delay_us(50);
    printf("\nSDRAM: latencia %d, fase %d (%d pasos buenos)\n", best_lat, best_ph, best_len);
    SYS_SCRATCH = 0xCA1B0000u | (uint32_t)(best_ph << 4) | (uint32_t)best_lat;
}

// ---------------------------------------------------------------- UART
static uint32_t get32(void)
{
    uint32_t v = 0;
    for (int i = 0; i < 4; i++) {
        int c = uart_getc_wait(2000000);
        if (c < 0) return 0xFFFFFFFFu;
        v |= (uint32_t)c << (8 * i);
    }
    return v;
}

static int uart_cmd(void)
{
    // busca "RV" seguido de "LD" o "SP"
    static uint8_t w[4];
    int c = uart_getc();
    if (c < 0) return 0;
    w[0] = w[1]; w[1] = w[2]; w[2] = w[3]; w[3] = (uint8_t)c;
    if (w[0] != 'R' || w[1] != 'V') return 0;
    if (w[2] == 'S' && w[3] == 'P') {
        uint32_t div = get32();
        if (div < 8 || div > 0xFFFF) return 1;
        uart_puts("OK");
        while (!(UART_STAT & UART_TXIDLE)) ;
        UART_DIV = div;
        return 1;
    }
    if (w[2] == 'L' && w[3] == 'D') {
        uint32_t addr = get32(), len = get32(), crc = get32();
        if ((addr >> 28) != 4 || len > (6u << 20)) { uart_puts("ER"); return 1; }
        uint8_t *p = (uint8_t *)addr;
        for (uint32_t i = 0; i < len; i++) {
            int b = uart_getc_wait(2000000);
            if (b < 0) { uart_puts("ER"); return 1; }
            p[i] = (uint8_t)b;
        }
        uint32_t got = crc32(0, (const void *)addr, len);
        if (got != crc) { uart_puts("ER"); printf(" crc %08x != %08x\n", got, crc); return 1; }
        uart_puts("OK");
        while (!(UART_STAT & UART_TXIDLE)) ;
        boot_jump(addr);
    }
    return 0;
}

// ---------------------------------------------------------------- SD
static int sd_boot(void)
{
    int r = sd_init();
    if (r) { printf("SD: sin tarjeta (%d)\n", r); return -1; }
    if (fat_mount()) { printf("SD: sin FAT\n"); return -1; }
    fat_file f;
    if (fat_open(&f, "BOOT    BIN")) { printf("SD: no hay BOOT.BIN\n"); return -1; }
    printf("SD: BOOT.BIN %u bytes\n", f.size);
    if (f.size > (6u << 20)) return -1;
    if (fat_read(&f, (void *)SDRAM_BASE, f.size) != (int)f.size) { printf("SD: error de lectura\n"); return -1; }
    printf("SD: arrancando\n");
    boot_jump(SDRAM_BASE);
}

int main(void)
{
    SYS_LED = 1;
    uart_puts("\nbltfast boot\n");
    sdram_calibrate();
    SYS_LED = 3;
    uart_puts("RVBOOT\n");
    uint32_t t0 = time_us();
    int tried_sd = 0;
    for (;;) {
        uart_cmd();
        if (!tried_sd && time_us() - t0 > 1500000u) {
            tried_sd = 1;
            SYS_LED = 7;
            sd_boot();
            uart_puts("RVBOOT\n");
        }
        SYS_LED = (time_us() >> 18) & 1 ? 0x21 : 0x01;
    }
}
