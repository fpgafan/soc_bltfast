// ============================================================================
// sys_bltfast.c - newlib system calls for OpenJazz on the bltfast SoC:
// stdout/stderr over the UART, files in the root directory of the microSD
// (FAT, 8.3 names) and heap (malloc/new) between the end of the program
// and the stack.
// ============================================================================
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <stdlib.h>
#include <unistd.h>
#define printf lib_printf
#include "lib.h"
#undef printf

#define STACK_SIZE (256u << 10)
#define HEAP_LIMIT (0x40600000u - STACK_SIZE)    // the stack grows down from 0x4060_0000

// ---------------------------------------------------------------- heap
extern char _end[];
static char *brk_ptr = _end;

void *_sbrk(ptrdiff_t incr)
{
    char *old = brk_ptr;
    if ((uint32_t)(brk_ptr + incr) > HEAP_LIMIT) {
        lib_printf("\n_sbrk: out of memory (asked %d bytes, heap %u KB of %u KB)\n", (int)incr,
                   (unsigned)((brk_ptr - _end) >> 10), (unsigned)((HEAP_LIMIT - (uint32_t)_end) >> 10));
        errno = ENOMEM;
        return (void *)-1;
    }
    brk_ptr += incr;
    return old;
}

// ---------------------------------------------------------------- console
char sys_errbuf[512];
static int errlen;

static void errlog(char c)
{
    if (errlen == (int)sizeof(sys_errbuf) - 1) {
        memmove(sys_errbuf, sys_errbuf + 128, sizeof(sys_errbuf) - 129);
        errlen -= 128;
    }
    sys_errbuf[errlen++] = c;
    sys_errbuf[errlen] = 0;
}

// ---------------------------------------------------------------- files
#define MAXF 16
#define FD0  3
static struct { int used, wr; fat_file f; uint32_t *map; } fd_tab[MAXF];

// path -> 8.3 name ("NAME    EXT"); -1 if there is no name
static int name83(const char *path, char out[11])
{
    const char *b = path;
    for (const char *p = path; *p; p++) if (*p == '/' || *p == '\\' || *p == ':') b = p + 1;
    while (*b == '.') b++;
    const char *dot = strrchr(b, '.');
    if (!*b) return -1;
    memset(out, ' ', 11);
    int n = 0;
    for (const char *p = b; *p && p != dot && n < 8; p++) {
        char c = *p;
        if (c >= 'a' && c <= 'z') c -= 32;
        if (c == ' ' || c == '.') continue;
        out[n++] = c;
    }
    if (dot) {
        n = 0;
        for (const char *p = dot + 1; *p && n < 3; p++) {
            char c = *p;
            if (c >= 'a' && c <= 'z') c -= 32;
            out[8 + n++] = c;
        }
    }
    return 0;
}

static int getf(int fd)
{
    fd -= FD0;
    if (fd < 0 || fd >= MAXF || !fd_tab[fd].used) { errno = EBADF; return -1; }
    return fd;
}

int _open(const char *path, int flags, int mode)
{
    char n[11];
    int i;
    (void)mode;
    if (name83(path, n)) { errno = ENOENT; return -1; }
    for (i = 0; i < MAXF && fd_tab[i].used; i++) ;
    if (i == MAXF) { errno = EMFILE; return -1; }
    fat_file *f = &fd_tab[i].f;
    int acc = flags & O_ACCMODE;
    int exists = fat_open(f, n) == 0;
    if (acc == O_RDONLY) {
        if (!exists) { errno = ENOENT; return -1; }
    } else if ((flags & O_TRUNC) || (!exists && (flags & O_CREAT))) {
        if (fat_create(f, n)) { errno = EIO; return -1; }
    } else if (!exists) {
        errno = ENOENT; return -1;
    }
    fd_tab[i].used = 1;
    fd_tab[i].wr = acc != O_RDONLY;
    fd_tab[i].map = 0;
    // fast seek cache for files > 64KB
    if (acc == O_RDONLY && f->size > 65536) {
        uint32_t nc = f->size / fat_cluster_bytes() + 1;
        fd_tab[i].map = (uint32_t *)malloc(nc * 4);
        if (fd_tab[i].map) fat_map(f, fd_tab[i].map, nc);
    }
    if (flags & O_APPEND) fat_seek(f, f->size);
    return FD0 + i;
}

int _close(int fd)
{
    if (fd < FD0) return 0;
    if ((fd = getf(fd)) < 0) return -1;
    int r = 0;
    if (fd_tab[fd].wr && fat_close(&fd_tab[fd].f)) { errno = EIO; r = -1; }
    if (fd_tab[fd].map) free(fd_tab[fd].map);
    fd_tab[fd].used = 0;
    return r;
}

void audio_feed(void);   // sdl_bltfast.cpp

int _read(int fd, void *buf, size_t len)
{
    if (fd < FD0) return 0;
    if ((fd = getf(fd)) < 0) return -1;
    audio_feed();           // loading levels takes longer than the ring lasts
    int r = fat_read(&fd_tab[fd].f, buf, len);
    if (r < 0) errno = EIO;
    return r;
}

int _write(int fd, const void *buf, size_t len)
{
    const char *p = (const char *)buf;
    if (fd == 1 || fd == 2) {
        for (size_t i = 0; i < len; i++) {
            uart_putc(p[i]);
            if (fd == 2) errlog(p[i]);
        }
        return (int)len;
    }
    if ((fd = getf(fd)) < 0) return -1;
    if (!fd_tab[fd].wr) { errno = EBADF; return -1; }
    int r = fat_write(&fd_tab[fd].f, buf, len);
    if (r < 0 || (size_t)r < len) errno = ENOSPC;
    return r;
}

off_t _lseek(int fd, off_t off, int whence)
{
    if (fd < FD0) return 0;
    if ((fd = getf(fd)) < 0) return -1;
    fat_file *f = &fd_tab[fd].f;
    int32_t pos = whence == SEEK_SET ? (int32_t)off :
                  whence == SEEK_CUR ? (int32_t)f->pos + (int32_t)off : (int32_t)f->size + (int32_t)off;
    if (pos < 0) { errno = EINVAL; return -1; }
    fat_seek(f, (uint32_t)pos);
    return (off_t)f->pos;
}

int _fstat(int fd, struct stat *st)
{
    memset(st, 0, sizeof(*st));
    if (fd < FD0) { st->st_mode = S_IFCHR; return 0; }
    if ((fd = getf(fd)) < 0) return -1;
    st->st_mode = S_IFREG | 0666;
    st->st_size = (off_t)fd_tab[fd].f.size;
    st->st_blksize = 512;
    return 0;
}

int _stat(const char *path, struct stat *st)
{
    char n[11];
    fat_file f;
    memset(st, 0, sizeof(*st));
    // the root directory ("/", "", "."): getcwd() returns "/" and OpenJazz
    // only uses a data path if access() says it is readable
    const char *p = path;
    while (*p == '/' || *p == '\\' || *p == '.' || *p == ':') p++;
    if (!*p) { st->st_mode = S_IFDIR | 0777; return 0; }
    if (name83(path, n) || fat_open(&f, n)) { errno = ENOENT; return -1; }
    st->st_mode = S_IFREG | 0666;
    st->st_size = (off_t)f.size;
    return 0;
}

int _isatty(int fd) { return fd < FD0; }

int _unlink(const char *path)
{
    char n[11];
    if (name83(path, n) || fat_remove(n)) { errno = ENOENT; return -1; }
    return 0;
}

int rename(const char *from, const char *to)
{
    char a[11], b[11];
    if (name83(from, a) || name83(to, b) || fat_rename(a, b)) { errno = ENOENT; return -1; }
    return 0;
}

int access(const char *path, int mode)
{
    (void)mode;
    struct stat st;
    return _stat(path, &st);
}

int _link(const char *a, const char *b) { (void)a; (void)b; errno = EMLINK; return -1; }
int mkdir(const char *path, mode_t mode) { (void)path; (void)mode; return 0; }
int _getpid(void) { return 1; }
int _kill(int pid, int sig) { (void)pid; (void)sig; errno = EINVAL; return -1; }

int _gettimeofday(struct timeval *tv, void *tz)
{
    (void)tz;
    uint64_t us = time_cycles() / (CPU_HZ / 1000000u);
    tv->tv_sec = (time_t)(us / 1000000u);
    tv->tv_usec = (suseconds_t)(us % 1000000u);
    return 0;
}

// heap size reached (bytes) and maximum, for the FPS line
uint32_t sys_heap_top(void)   { return (uint32_t)(brk_ptr - _end); }
uint32_t sys_heap_limit(void) { return HEAP_LIMIT - (uint32_t)_end; }

void _exit(int status)
{
    lib_printf("\n_exit(%d): the program has finished\n", status);
    for (;;) ;
}

void *__dso_handle = 0;

char *getcwd(char *buf, size_t size)
{
    if (buf && size > 1) {
        buf[0] = '/';
        buf[1] = 0;
        return buf;
    }
    return NULL;
}
