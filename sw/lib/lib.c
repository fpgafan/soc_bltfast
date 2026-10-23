// ============================================================================
// lib.c - UART, printf mínimo, tiempo, CRC32, memoria
// ============================================================================
#include <stdarg.h>
#include "lib.h"

void uart_putc(int c)
{
    if (c == '\n') uart_putc('\r');
    while (UART_STAT & UART_TXFULL) ;
    UART_DATA = (uint32_t)c & 0xFF;
}

void uart_puts(const char *s) { while (*s) uart_putc(*s++); }

int uart_getc(void)
{
    uint32_t d = UART_DATA;
    return (d & 0x100) ? (int)(d & 0xFF) : -1;
}

int uart_getc_wait(uint32_t timeout_us)
{
    uint32_t t0 = time_us();
    for (;;) {
        int c = uart_getc();
        if (c >= 0) return c;
        if (timeout_us && (time_us() - t0) >= timeout_us) return -1;
    }
}

void uart_setbaud(uint32_t baud)
{
    while (!(UART_STAT & UART_TXIDLE)) ;
    UART_DIV = (CPU_HZ + baud / 2) / baud;
}

static void put_u(uint32_t v, int base, int width, char pad)
{
    char b[12];
    int n = 0;
    do { int d = v % base; b[n++] = d < 10 ? '0' + d : 'a' + d - 10; v /= base; } while (v);
    while (n < width) b[n++] = pad;
    while (n) uart_putc(b[--n]);
}

// %d %u %x %s %c %%, con ancho y relleno con 0 (p. ej. %08x)
void printf(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    for (; *fmt; fmt++) {
        if (*fmt != '%') { uart_putc(*fmt); continue; }
        fmt++;
        char pad = ' ';
        int width = 0;
        if (*fmt == '0') { pad = '0'; fmt++; }
        while (*fmt >= '0' && *fmt <= '9') width = width * 10 + (*fmt++ - '0');
        switch (*fmt) {
        case 'd': { int v = va_arg(ap, int);
                    if (v < 0) { uart_putc('-'); v = -v; width--; }
                    put_u((uint32_t)v, 10, width, pad); break; }
        case 'u': put_u(va_arg(ap, uint32_t), 10, width, pad); break;
        case 'x': put_u(va_arg(ap, uint32_t), 16, width, pad); break;
        case 's': uart_puts(va_arg(ap, const char *)); break;
        case 'c': uart_putc(va_arg(ap, int)); break;
        default:  uart_putc(*fmt); break;
        }
    }
    va_end(ap);
}

uint64_t time_cycles(void)
{
    uint32_t h, l;
    do { h = SYS_MTIMEH; l = SYS_MTIME; } while (h != SYS_MTIMEH);
    return ((uint64_t)h << 32) | l;
}

uint32_t time_us(void) { return (uint32_t)(time_cycles() / (CPU_HZ / 1000000u)); }

void delay_us(uint32_t us)
{
    uint64_t end = time_cycles() + (uint64_t)us * (CPU_HZ / 1000000u);
    while (time_cycles() < end) ;
}

void delay_ms(uint32_t ms) { delay_us(ms * 1000u); }

uint32_t crc32(uint32_t crc, const void *data, uint32_t len)
{
    const uint8_t *p = data;
    crc = ~crc;
    while (len--) {
        crc ^= *p++;
        for (int k = 0; k < 8; k++) crc = (crc >> 1) ^ (0xEDB88320u & -(crc & 1));
    }
    return ~crc;
}

void *memcpy(void *d, const void *s, size_t n)
{
    uint8_t *dp = d;
    const uint8_t *sp = s;
    if ((((uint32_t)dp | (uint32_t)sp) & 3) == 0) {
        while (n >= 4) { *(uint32_t *)dp = *(const uint32_t *)sp; dp += 4; sp += 4; n -= 4; }
    }
    while (n--) *dp++ = *sp++;
    return d;
}

void *memset(void *d, int c, size_t n)
{
    uint8_t *dp = d;
    uint32_t w = (uint8_t)c * 0x01010101u;
    while (n && ((uint32_t)dp & 3)) { *dp++ = (uint8_t)c; n--; }
    while (n >= 4) { *(uint32_t *)dp = w; dp += 4; n -= 4; }
    while (n--) *dp++ = (uint8_t)c;
    return d;
}

int memcmp(const void *a, const void *b, size_t n)
{
    const uint8_t *x = a, *y = b;
    for (; n; n--, x++, y++) if (*x != *y) return *x - *y;
    return 0;
}

size_t strlen(const char *s) { size_t n = 0; while (s[n]) n++; return n; }
