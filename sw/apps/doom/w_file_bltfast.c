// ============================================================================
// w_file_bltfast.c - WAD access without the stdio buffer: open/lseek/read
// go straight to the FAT (with the cluster table, seeking to a lump is O(1)).
// Replaces w_file_stdc.c (same class name, used by w_file.c).
// ============================================================================
#include <fcntl.h>
#include <unistd.h>
#include "src/w_file.h"
#include "src/z_zone.h"

typedef struct { wad_file_t wad; int fd; } blt_wad_file_t;

extern wad_file_class_t stdc_wad_file;

static wad_file_t *W_Blt_OpenFile(char *path)
{
    int fd = open(path, O_RDONLY);
    if (fd < 0) return NULL;
    blt_wad_file_t *w = Z_Malloc(sizeof(*w), PU_STATIC, 0);
    w->wad.file_class = &stdc_wad_file;
    w->wad.mapped = NULL;
    w->wad.length = (unsigned int)lseek(fd, 0, SEEK_END);
    w->fd = fd;
    return &w->wad;
}

static void W_Blt_CloseFile(wad_file_t *wad)
{
    blt_wad_file_t *w = (blt_wad_file_t *)wad;
    close(w->fd);
    Z_Free(w);
}

static size_t W_Blt_Read(wad_file_t *wad, unsigned int offset, void *buffer, size_t len)
{
    blt_wad_file_t *w = (blt_wad_file_t *)wad;
    lseek(w->fd, (off_t)offset, SEEK_SET);
    int r = read(w->fd, buffer, len);
    return r < 0 ? 0 : (size_t)r;
}

wad_file_class_t stdc_wad_file = { W_Blt_OpenFile, W_Blt_CloseFile, W_Blt_Read };
