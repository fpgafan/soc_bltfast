// ============================================================================
// fat.c - Minimal FAT32 (and FAT16): root directory, 8.3 names
//   sequential read (used by the ROM) + seeking, writing, creating,
//   deleting and renaming (for programs; the ROM does not link them)
// ============================================================================
#include "lib.h"

static uint8_t  sec[512] __attribute__((aligned(4)));
static uint32_t fat_lba, data_lba, root_clus, root_lba, root_ents;
static uint32_t spc;              // sectors per cluster
static int      is32;
static uint32_t cached_fat = 0xFFFFFFFF;
static uint32_t nfat, fsz, nclus, fsinfo_lba;   // for writing
static uint32_t ent_lba, ent_off;               // entry dir_walk is looking at

#define EOC 0x0FFFFFF8u           // clusters >= EOC: end of chain

static uint32_t rd16(const uint8_t *p) { return p[0] | (p[1] << 8); }
static uint32_t rd32(const uint8_t *p) { return p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24); }
static void wr16(uint8_t *p, uint32_t v) { p[0] = v; p[1] = v >> 8; }
static void wr32(uint8_t *p, uint32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }

static int is_fat_vbr(void)
{
    return (sec[0] == 0xEB || sec[0] == 0xE9) && rd16(sec + 11) == 512 && sec[13] && sec[16];
}

// errors: -1 read, -2 no 55AA signature, -3 no FAT partition,
//         -4 boot sector not FAT, -5 exFAT, -6 NTFS
int fat_mount(void)
{
    if (sd_read(0, sec)) return -1;
    uint32_t part = 0;
    if (sec[510] != 0x55 || sec[511] != 0xAA) return -2;
    // direct boot sector, MBR or GPT?
    if (!is_fat_vbr() && memcmp(sec + 3, "EXFAT", 5) && memcmp(sec + 3, "NTFS", 4)) {
        int gpt = 0;
        for (int i = 0; i < 4; i++) {          // the first FAT partition in the MBR
            const uint8_t *e = sec + 446 + 16 * i;
            uint8_t t = e[4];
            if (t == 0xEE) gpt = 1;
            if (!part && (t == 0x01 || t == 0x04 || t == 0x06 || t == 0x0B || t == 0x0C || t == 0x0E))
                part = rd32(e + 8);
        }
        if (!part) {
            for (int i = 0; i < 4 && !part; i++)  // otherwise, the first non-empty one (exFAT/NTFS: type 07)
                if (sec[446 + 16 * i + 4] && sec[446 + 16 * i + 4] != 0xEE) part = rd32(sec + 446 + 16 * i + 8);
        }
#ifndef BOOTROM                                // (the ROM has no room for GPT)
        if (!part && gpt) {                    // GPT: first non-empty entry
            if (sd_read(1, sec)) return -1;
            if (memcmp(sec, "EFI PART", 8)) return -3;
            uint32_t ent = rd32(sec + 72);
            if (sd_read(ent, sec)) return -1;
            for (int i = 0; i < 4 && !part; i++) part = rd32(sec + 128 * i + 32);
        }
#else
        (void)gpt;
#endif
        if (!part) return -3;
        if (sd_read(part, sec)) return -1;
    }
#ifndef BOOTROM
    if (!memcmp(sec + 3, "EXFAT", 5)) return -5;
    if (!memcmp(sec + 3, "NTFS", 4)) return -6;
#endif
    if (!is_fat_vbr()) return -4;
    spc = sec[13];
    uint32_t rsv = rd16(sec + 14);
    nfat = sec[16];
    root_ents = rd16(sec + 17);
    fsz = rd16(sec + 22);
    if (fsz == 0) fsz = rd32(sec + 36);
    uint32_t tot = rd16(sec + 19);
    if (tot == 0) tot = rd32(sec + 32);
    is32 = (root_ents == 0);
    fat_lba  = part + rsv;
    root_lba = fat_lba + nfat * fsz;
    data_lba = root_lba + (root_ents * 32 + 511) / 512;
    root_clus = is32 ? rd32(sec + 44) : 0;
    fsinfo_lba = is32 ? part + rd16(sec + 48) : 0;
    nclus = (part + tot - data_lba) / spc;
    cached_fat = 0xFFFFFFFF;
    return 0;
}

static uint32_t next_clus(uint32_t c)
{
    uint32_t off = is32 ? c * 4 : c * 2;
    uint32_t lba = fat_lba + off / 512;
    if (lba != cached_fat) { if (sd_read(lba, sec)) return 0x0FFFFFFF; cached_fat = lba; }
    uint32_t v = is32 ? (rd32(sec + off % 512) & 0x0FFFFFFF) : rd16(sec + off % 512);
    if (!is32 && v >= 0xFFF8) v = 0x0FFFFFFF;
    return v;
}

static uint32_t clus_lba(uint32_t c) { return data_lba + (c - 2) * spc; }

// walks the root directory; cb returns 1 to stop (ent_lba/ent_off = the entry)
static int dir_walk(int (*cb)(const uint8_t *e, void *ctx), void *ctx)
{
    uint32_t c = root_clus, lba, n;
    if (is32) { lba = clus_lba(c); n = spc; } else { lba = root_lba; n = (root_ents * 32 + 511) / 512; }
    for (;;) {
        for (uint32_t s = 0; s < n; s++) {
            if (sd_read(lba + s, sec)) return -1;
            cached_fat = 0xFFFFFFFF;
            for (int i = 0; i < 512; i += 32) {
                const uint8_t *e = sec + i;
                if (e[0] == 0x00) return 0;
                if (e[0] == 0xE5 || (e[11] & 0x0F) == 0x0F || (e[11] & 0x08)) continue;
                ent_lba = lba + s; ent_off = (uint32_t)i;
                if (cb(e, ctx)) return 1;
            }
        }
        if (!is32) return 0;
        c = next_clus(c);
        if (c >= EOC) return 0;
        lba = clus_lba(c); n = spc;
    }
}

struct find_ctx { const char *name; fat_file *f; };
static int find_cb(const uint8_t *e, void *ctx)
{
    struct find_ctx *fc = ctx;
    if (memcmp(e, fc->name, 11)) return 0;
    fc->f->clus = (rd16(e + 20) << 16) | rd16(e + 26);
    fc->f->size = rd32(e + 28);
    return 1;
}

int fat_open(fat_file *f, const char *name83)
{
    struct find_ctx fc = { name83, f };
    if (dir_walk(find_cb, &fc) != 1) return -1;
    f->pos = 0; f->cur = f->clus; f->lba_in_clus = 0;
    f->prev = 0; f->dir_lba = ent_lba; f->dir_off = ent_off;
    f->map = 0; f->nmap = 0;
    return 0;
}

static void (*list_fn)(const char *, uint32_t);
static int list_cb(const uint8_t *e, void *ctx)
{
    (void)ctx;
    char n[12];
    memcpy(n, e, 11); n[11] = 0;
    list_fn(n, rd32(e + 28));
    return 0;
}

int fat_list(void (*cb)(const char *name83, uint32_t size))
{
    list_fn = cb;
    return dir_walk(list_cb, 0);
}

// moves to the next cluster when crossing the end of one (pos already updated)
static void step(fat_file *f)
{
    if (++f->lba_in_clus < spc) return;
    f->lba_in_clus = 0;
    f->prev = f->cur;
    uint32_t ci = f->pos / (spc * 512);
    if (f->map && ci < f->nmap) f->cur = f->map[ci];
    else f->cur = next_clus(f->cur);
}

// sequential read (any dst; with an aligned dst and whole blocks it goes direct)
int fat_read(fat_file *f, void *dst, uint32_t len)
{
    uint8_t *d = dst;
    uint32_t done = 0;
    if (len > f->size - f->pos) len = f->size - f->pos;
    while (done < len) {
        uint32_t off = f->pos % 512;
        uint32_t lba = clus_lba(f->cur) + f->lba_in_clus;
        uint32_t chunk = 512 - off;
        if (chunk > len - done) chunk = len - done;
        if (off == 0 && chunk == 512 && (((uint32_t)(d + done)) & 3) == 0) {
            if (sd_read(lba, d + done)) return -1;
        } else {
            if (sd_read(lba, sec)) return -1;
            memcpy(d + done, sec + off, chunk);
        }
        cached_fat = 0xFFFFFFFF;
        done += chunk;
        f->pos += chunk;
        if (f->pos % 512 == 0) step(f);
    }
    return (int)done;
}

// ---------------------------------------------------------------- seeking

// table of the file's clusters in 'map' (n entries): fat_seek becomes O(1)
int fat_map(fat_file *f, uint32_t *map, uint32_t n)
{
    uint32_t c = f->clus, i = 0;
    while (c >= 2 && c < EOC && i < n) { map[i++] = c; c = next_clus(c); }
    f->map = map; f->nmap = i;
    return (int)i;
}

uint32_t fat_cluster_bytes(void) { return spc * 512; }

// card sector holding the current file position
uint32_t fat_file_lba(const fat_file *f) { return clus_lba(f->cur) + f->lba_in_clus; }

int fat_seek(fat_file *f, uint32_t pos)
{
    if (pos > f->size) pos = f->size;
    uint32_t cb = spc * 512, ci = pos / cb;
    f->pos = pos;
    f->lba_in_clus = (pos % cb) / 512;
    if (f->map && ci < f->nmap) {
        f->cur = f->map[ci];
        f->prev = ci ? f->map[ci - 1] : 0;
        return 0;
    }
    if (f->map && f->nmap && ci == f->nmap) {   // right at the end of the chain
        f->prev = f->map[ci - 1];
        f->cur = 0x0FFFFFFF;
        return 0;
    }
    uint32_t c = f->clus, p = 0;
    for (uint32_t i = 0; i < ci && c >= 2 && c < EOC; i++) { p = c; c = next_clus(c); }
    f->cur = c; f->prev = p;
    return 0;
}

// ---------------------------------------------------------------- writing
static uint32_t free_hint = 2;

// writes entry c of every copy of the FAT (the last one, copy 0,
// stays in 'sec' as a cache)
static int set_fat(uint32_t c, uint32_t v)
{
    uint32_t off = is32 ? c * 4 : c * 2;
    for (int k = (int)nfat - 1; k >= 0; k--) {
        uint32_t lba = fat_lba + (uint32_t)k * fsz + off / 512;
        if (lba != cached_fat && sd_read(lba, sec)) { cached_fat = 0xFFFFFFFF; return -1; }
        if (is32) wr32(sec + off % 512, (rd32(sec + off % 512) & 0xF0000000u) | (v & 0x0FFFFFFF));
        else      wr16(sec + off % 512, v >= EOC ? 0xFFFF : v);
        cached_fat = lba;
        if (sd_write(lba, sec)) { cached_fat = 0xFFFFFFFF; return -1; }
    }
    return 0;
}

static void fsinfo_unknown(void)
{
    static int done;
    if (done || !fsinfo_lba) return;
    done = 1;
    if (sd_read(fsinfo_lba, sec)) { cached_fat = 0xFFFFFFFF; return; }
    cached_fat = 0xFFFFFFFF;
    if (rd32(sec) != 0x41615252u) return;
    uint32_t hint = rd32(sec + 492);                 // hint for the first free cluster
    if (hint >= 2 && hint < nclus + 2) free_hint = hint;
    wr32(sec + 488, 0xFFFFFFFFu);                    // free count: unknown
    wr32(sec + 492, 0xFFFFFFFFu);
    sd_write(fsinfo_lba, sec);
}

// finds a free cluster, marks it as end of chain and links it after 'prev'
static uint32_t alloc_clus(uint32_t prev)
{
    fsinfo_unknown();
    for (uint32_t n = 0; n < nclus; n++) {
        uint32_t c = free_hint + n;
        if (c >= nclus + 2) c -= nclus;
        if (next_clus(c) != 0) continue;
        if (set_fat(c, 0x0FFFFFFF)) return 0;
        if (prev && set_fat(prev, c)) return 0;
        free_hint = c + 1;
        return c;
    }
    return 0;                                        // disk full
}

static int free_chain(uint32_t c)
{
    while (c >= 2 && c < EOC) {
        uint32_t n = next_clus(c);
        if (set_fat(c, 0)) return -1;
        c = n;
    }
    return 0;
}

int fat_write(fat_file *f, const void *src, uint32_t len)
{
    const uint8_t *s = src;
    uint32_t done = 0;
    while (done < len) {
        if (f->cur < 2 || f->cur >= EOC) {          // no cluster: add one
            uint32_t c = alloc_clus(f->prev);
            if (!c) break;
            if (!f->prev) f->clus = c;
            f->cur = c;
            f->map = 0;
        }
        uint32_t off = f->pos % 512;
        uint32_t lba = clus_lba(f->cur) + f->lba_in_clus;
        uint32_t chunk = 512 - off;
        if (chunk > len - done) chunk = len - done;
        if (chunk == 512) {
            if (sd_write(lba, s + done)) return -1;
        } else {
            if (f->pos - off < f->size) { if (sd_read(lba, sec)) { cached_fat = 0xFFFFFFFF; return -1; } }
            else memset(sec, 0, 512);
            memcpy(sec + off, s + done, chunk);
            if (sd_write(lba, sec)) { cached_fat = 0xFFFFFFFF; return -1; }
        }
        cached_fat = 0xFFFFFFFF;
        done += chunk;
        f->pos += chunk;
        if (f->pos > f->size) f->size = f->pos;
        if (f->pos % 512 == 0) step(f);
    }
    return (int)done;
}

// updates the directory entry (first cluster and size)
int fat_close(fat_file *f)
{
    if (sd_read(f->dir_lba, sec)) return -1;
    cached_fat = 0xFFFFFFFF;
    uint8_t *e = sec + f->dir_off;
    wr16(e + 20, f->clus >> 16);
    wr16(e + 26, f->clus);
    wr32(e + 28, f->size);
    e[11] |= 0x20;                                   // file modified
    return sd_write(f->dir_lba, sec);
}

// finds a free root entry (on FAT32 it grows the root if full)
static int dir_slot(void)
{
    uint32_t c = root_clus, lba, n;
    if (is32) { lba = clus_lba(c); n = spc; } else { lba = root_lba; n = (root_ents * 32 + 511) / 512; }
    for (;;) {
        for (uint32_t s = 0; s < n; s++) {
            if (sd_read(lba + s, sec)) return -1;
            cached_fat = 0xFFFFFFFF;
            for (int i = 0; i < 512; i += 32)
                if (sec[i] == 0x00 || sec[i] == 0xE5) { ent_lba = lba + s; ent_off = (uint32_t)i; return 0; }
        }
        if (!is32) return -1;                        // FAT16: fixed-size root
        uint32_t nx = next_clus(c);
        if (nx >= EOC) {
            nx = alloc_clus(c);
            if (!nx) return -1;
            memset(sec, 0, 512);
            for (uint32_t k = 0; k < spc; k++)
                if (sd_write(clus_lba(nx) + k, sec)) return -1;
            cached_fat = 0xFFFFFFFF;
        }
        c = nx; lba = clus_lba(c); n = spc;
    }
}

// creates the file (or truncates it if it exists) and leaves it open for writing
int fat_create(fat_file *f, const char *name83)
{
    if (fat_open(f, name83) == 0) {
        if (free_chain(f->clus)) return -1;
        f->clus = 0; f->size = 0; f->cur = 0;
        return fat_close(f);
    }
    if (dir_slot()) return -2;
    // dir_slot leaves the entry's sector in 'sec'
    uint8_t *e = sec + ent_off;
    memset(e, 0, 32);
    memcpy(e, name83, 11);
    e[11] = 0x20;
    wr16(e + 16, (46u << 9) | (10u << 5) | 21u);     // date: 21/10/2026
    wr16(e + 18, (46u << 9) | (10u << 5) | 21u);
    wr16(e + 24, (46u << 9) | (10u << 5) | 21u);
    if (sd_write(ent_lba, sec)) return -3;
    f->clus = 0; f->size = 0; f->pos = 0; f->cur = 0; f->lba_in_clus = 0; f->prev = 0;
    f->dir_lba = ent_lba; f->dir_off = ent_off;
    f->map = 0; f->nmap = 0;
    return 0;
}

int fat_remove(const char *name83)
{
    fat_file f;
    if (fat_open(&f, name83)) return -1;
    if (free_chain(f.clus)) return -2;
    if (sd_read(f.dir_lba, sec)) return -3;
    cached_fat = 0xFFFFFFFF;
    sec[f.dir_off] = 0xE5;
    return sd_write(f.dir_lba, sec);
}

int fat_rename(const char *from83, const char *to83)
{
    fat_file f;
    if (fat_open(&f, from83)) return -1;
    if (!memcmp(from83, to83, 11)) return 0;
    fat_remove(to83);
    if (sd_read(f.dir_lba, sec)) return -2;
    cached_fat = 0xFFFFFFFF;
    memcpy(sec + f.dir_off, to83, 11);
    return sd_write(f.dir_lba, sec);
}
