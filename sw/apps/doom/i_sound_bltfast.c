// ============================================================================
// i_sound_bltfast.c - Doom sound with the 32-voice engine
//
//  Effects: the DMX lumps (unsigned 8-bit PCM, usually 11025 Hz) are
//    converted to signed 8 bits in the sample area the first time they
//    play; each Doom channel (8) uses a fixed voice, 24 to 31.
//  Music: MUS -> MIDI (mus2mid.c) and the library MIDI player on
//    voices 0..23, updated from the timer interrupt
//    (irq_timer in doomgeneric_bltfast.c).
// ============================================================================
#include <stdlib.h>
#include <string.h>
#include "src/doomtype.h"
#include "src/i_sound.h"
#include "src/w_wad.h"
#include "src/z_zone.h"
#include "src/m_misc.h"
#include "src/deh_str.h"
#include "src/memio.h"
#include "src/mus2mid.h"
#define printf lib_printf
#include "lib.h"
#include "audio.h"
#undef printf

// configuration variables that i_sdlsound.c used to define
int use_libsamplerate = 0;
float libsamplerate_scale = 0.65f;

#define NCH        (AUD_VOICES - MIDI_VOICES)   // 8 effect channels
#define POOL_START 0x40740000u                  // after the MIDI instruments (~160 KB)
#define POOL_END   0x40800000u
#define MAXSFX     160

static snddevice_t sound_devices[] = {
    SNDDEVICE_SB, SNDDEVICE_PAS, SNDDEVICE_GUS, SNDDEVICE_WAVEBLASTER,
    SNDDEVICE_SOUNDCANVAS, SNDDEVICE_AWE32,
};

static boolean use_prefix;
static uint32_t pool_top = POOL_START;
static sample_t smp[MAXSFX];
static sfxinfo_t *smp_owner[MAXSFX];
static int nsmp;

// ---------------------------------------------------------------- effects
static void flush_cache(void)
{
    AUD_STOP = ((1u << NCH) - 1) << MIDI_VOICES;
    for (int i = 0; i < nsmp; i++) smp_owner[i]->driver_data = NULL;
    nsmp = 0;
    pool_top = POOL_START;
}

static int lump_of(sfxinfo_t *sfx)
{
    char name[9];
    if (use_prefix) M_snprintf(name, sizeof(name), "ds%s", DEH_String(sfx->name));
    else M_StringCopy(name, DEH_String(sfx->name), sizeof(name));
    return W_CheckNumForName(name);
}

static const sample_t *cache_sfx(sfxinfo_t *sfx)
{
    if (sfx->driver_data) return sfx->driver_data;
    int lump = sfx->lumpnum >= 0 ? sfx->lumpnum : lump_of(sfx);
    if (lump < 0) return NULL;
    int len = W_LumpLength(lump);
    const byte *d = W_CacheLumpNum(lump, PU_STATIC);
    uint32_t rate = d[2] | (d[3] << 8);
    uint32_t n = d[4] | (d[5] << 8) | (d[6] << 16) | ((uint32_t)d[7] << 24);
    // DMX format: 8-byte header; DMX skips 16 samples at the start and at the end
    if (len < 8 || d[0] != 3 || d[1] != 0 || n > (uint32_t)len - 8 || n <= 48) {
        W_ReleaseLumpNum(lump);
        return NULL;
    }
    n -= 32;
    if (nsmp == MAXSFX || pool_top + n > POOL_END) flush_cache();
    int8_t *dst = (int8_t *)pool_top;
    const byte *src = d + 8 + 16;
    for (uint32_t i = 0; i < n; i++) dst[i] = (int8_t)(src[i] ^ 0x80);
    W_ReleaseLumpNum(lump);
    smp[nsmp] = (sample_t){ pool_top, n, n, AUD_FMT_S8, rate };
    smp_owner[nsmp] = sfx;
    sfx->driver_data = &smp[nsmp];
    pool_top = (pool_top + n + 31) & ~31u;
    return &smp[nsmp++];
}

static void set_vol(int v, int vol, int sep)
{
    // vol 0..127, sep 0 (left) .. 254 (right); 128 = gain 1
    int l = vol * (254 - sep) / 127, r = vol * sep / 127;
    if (l > 255) l = 255;
    if (r > 255) r = 255;
    AUD_V(v, AUD_V_VOL) = (uint32_t)l | ((uint32_t)r << 8);
}

static boolean Snd_Init(boolean prefix)
{
    use_prefix = prefix;
    snd_init();
    return true;
}

static void Snd_Shutdown(void) { AUD_STOP = 0xFFFFFFFFu; }

static int Snd_GetSfxLumpNum(sfxinfo_t *sfx)
{
    if (sfx->link) sfx = sfx->link;
    return lump_of(sfx);
}

static void Snd_Update(void) { }

static void Snd_UpdateSoundParams(int ch, int vol, int sep)
{
    if (ch < 0) return;
    set_vol(MIDI_VOICES + ch % NCH, vol, sep);
}

static int Snd_StartSound(sfxinfo_t *sfx, int ch, int vol, int sep)
{
    if (ch < 0) return -1;
    if (sfx->link) sfx = sfx->link;
    const sample_t *s = cache_sfx(sfx);
    if (!s) return -1;
    int v = MIDI_VOICES + ch % NCH;
    snd_stop(v);
    snd_voice(v, s, (uint32_t)(((uint64_t)s->rate << 16) / 48000u), 0, 128, ADSR(0xFF, 0, 0xFF, 0xC0));
    set_vol(v, vol, sep);
    return ch;
}

static void Snd_StopSound(int ch)
{
    if (ch >= 0) snd_stop(MIDI_VOICES + ch % NCH);
}

static boolean Snd_SoundIsPlaying(int ch)
{
    if (ch < 0) return false;
    return (AUD_ACTIVE >> (MIDI_VOICES + ch % NCH)) & 1;
}

static void Snd_CacheSounds(sfxinfo_t *sounds, int num) { (void)sounds; (void)num; }

sound_module_t DG_sound_module = {
    sound_devices, arrlen(sound_devices),
    Snd_Init, Snd_Shutdown, Snd_GetSfxLumpNum, Snd_Update, Snd_UpdateSoundParams,
    Snd_StartSound, Snd_StopSound, Snd_SoundIsPlaying, Snd_CacheSounds,
};

// ---------------------------------------------------------------- music
// midi_update() is called from irq_timer (doomgeneric_bltfast.c, 500 Hz)

typedef struct { uint8_t *data; uint32_t len; } song_t;
static song_t *current;

static boolean Mus_Init(void) { return true; }

static void Mus_Shutdown(void)
{
    irq_disable();
    midi_stop();
    irq_enable();
}

static void Mus_SetVolume(int vol)                 // 0..127
{
    irq_disable();
    midi_volume(vol * 2);
    irq_enable();
}

static void Mus_Pause(void)  { irq_disable(); midi_pause(1); irq_enable(); }
static void Mus_Resume(void) { irq_disable(); midi_pause(0); irq_enable(); }

static void *Mus_RegisterSong(void *data, int len)
{
    song_t *s = malloc(sizeof(*s));
    if (!s) return NULL;
    if (len >= 4 && !memcmp(data, "MUS\x1a", 4)) {
        MEMFILE *in = mem_fopen_read(data, (size_t)len);
        MEMFILE *out = mem_fopen_write();
        void *buf;
        size_t n;
        if (mus2mid(in, out)) {                    // true = error
            mem_fclose(in); mem_fclose(out); free(s);
            return NULL;
        }
        mem_get_buf(out, &buf, &n);
        s->data = malloc(n);
        if (s->data) memcpy(s->data, buf, n);
        s->len = (uint32_t)n;
        mem_fclose(in); mem_fclose(out);
    } else {                                       // plain MIDI (modern PWADs)
        s->data = malloc((size_t)len);
        if (s->data) memcpy(s->data, data, (size_t)len);
        s->len = (uint32_t)len;
    }
    if (!s->data) { free(s); return NULL; }
    return s;
}

static void Mus_StopSong(void)
{
    irq_disable();
    midi_stop();
    current = NULL;
    irq_enable();
}

static void Mus_UnRegisterSong(void *handle)
{
    song_t *s = handle;
    if (!s) return;
    if (s == current) Mus_StopSong();
    free(s->data);
    free(s);
}

static void Mus_PlaySong(void *handle, boolean looping)
{
    song_t *s = handle;
    if (!s) return;
    irq_disable();
    midi_stop();
    midi_pause(0);
    if (midi_load(s->data, s->len) == 0) { midi_play(looping); current = s; }
    irq_enable();
}

static boolean Mus_IsPlaying(void) { return midi_playing() != 0; }

music_module_t DG_music_module = {
    sound_devices, arrlen(sound_devices),
    Mus_Init, Mus_Shutdown, Mus_SetVolume, Mus_Pause, Mus_Resume,
    Mus_RegisterSong, Mus_UnRegisterSong, Mus_PlaySong, Mus_StopSong, Mus_IsPlaying,
    NULL,
};
