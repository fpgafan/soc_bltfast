// ============================================================================
// lib.h - Basic functions: UART, minimal printf, time, CRC32, memory
// ============================================================================
#ifndef LIB_H
#define LIB_H
#include <stdint.h>
#include <stddef.h>
#include "soc.h"

void     uart_putc(int c);
void     uart_puts(const char *s);
int      uart_getc(void);                  // -1 if no data
int      uart_getc_wait(uint32_t timeout_us); // -1 on timeout
void     uart_setbaud(uint32_t baud);
void     printf(const char *fmt, ...);

uint64_t time_cycles(void);
uint32_t time_us(void);
void     delay_us(uint32_t us);
void     delay_ms(uint32_t ms);

uint32_t crc32(uint32_t crc, const void *data, uint32_t len);

void    *memcpy(void *d, const void *s, size_t n);
void    *memset(void *d, int c, size_t n);
int      memcmp(const void *a, const void *b, size_t n);
size_t   strlen(const char *s);

static inline void fence(void)   { __asm__ volatile ("fence" ::: "memory"); }
static inline void fence_i(void) { __asm__ volatile ("fence.i" ::: "memory"); }
static inline uint32_t rdcycle(void) { uint32_t c; __asm__ volatile ("rdcycle %0" : "=r"(c)); return c; }
static inline void irq_enable(void)  { __asm__ volatile ("csrsi mstatus, 8"); }
static inline void irq_disable(void) { __asm__ volatile ("csrci mstatus, 8"); }

// SD + FAT32 (sd.c / fat.c)
int      sd_init(void);                                  // 0 = ok
int      sd_read(uint32_t lba, void *dst);               // 512 bytes
int      sd_write(uint32_t lba, const void *src);
extern uint32_t sd_err;                                  // details of the last sd_read error
int      fat_mount(void);
typedef struct {
    uint32_t clus, size, pos, cur, lba_in_clus;
    uint32_t prev, dir_lba, dir_off;                     // previous cluster, directory entry
    uint32_t *map, nmap;                                 // optional cluster table (fat_map)
} fat_file;
int      fat_open(fat_file *f, const char *name83);      // "BOOT    BIN"
int      fat_read(fat_file *f, void *dst, uint32_t len); // bytes read
int      fat_list(void (*cb)(const char *name83, uint32_t size));
int      fat_seek(fat_file *f, uint32_t pos);
int      fat_map(fat_file *f, uint32_t *map, uint32_t n); // clusters stored (fast seek)
uint32_t fat_cluster_bytes(void);
uint32_t fat_file_lba(const fat_file *f);
// writing (root directory only): fat_close stores size and cluster in the directory
int      fat_create(fat_file *f, const char *name83);    // creates or truncates it
int      fat_write(fat_file *f, const void *src, uint32_t len);
int      fat_close(fat_file *f);
int      fat_remove(const char *name83);
int      fat_rename(const char *from83, const char *to83);

#endif
