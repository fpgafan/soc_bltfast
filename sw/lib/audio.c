// ============================================================================
// audio.c - Generated instruments, voices, effects and PCM streaming
// ============================================================================
#include "audio.h"
#include "lib.h"

// sample area: 0x4070_0000 - 0x407F_FFFF (1 MB, see app.ld)
#define SAMPLE_AREA 0x40700000u
static uint32_t sample_top = SAMPLE_AREA;

uint32_t snd_alloc(uint32_t bytes)
{
    uint32_t a = sample_top;
    sample_top = (sample_top + bytes + 31) & ~31u;
    return a;
}

void snd_volume(int master) { AUD_CTRL = 0x100 | (uint32_t)(master & 255); }

void snd_init(void)
{
    AUD_STOP = 0xFFFFFFFFu;
    AUD_CTRL = 0x100 | 0x80;
    SYS_MISC = 1;                          // on-board amplifier
}

void snd_voice(int v, const sample_t *s, uint32_t pitch, int vol, int pan, uint32_t adsr)
{
    if (v < 0 || v >= AUD_VOICES) return;
    int l = vol * (255 - pan) / 128, r = vol * pan / 128;
    if (l > 255) l = 255;
    if (r > 255) r = 255;
    uint32_t loop = s->loop < s->len;
    AUD_V(v, AUD_V_CTRL)  = s->fmt | (loop ? AUD_LOOP : 0) | AUD_INTERP;
    AUD_V(v, AUD_V_START) = PHYS(s->addr);
    AUD_V(v, AUD_V_LEN)   = s->len;
    AUD_V(v, AUD_V_LOOP)  = loop ? s->loop : 0;
    AUD_V(v, AUD_V_PITCH) = pitch;
    AUD_V(v, AUD_V_VOL)   = (uint32_t)l | ((uint32_t)r << 8);
    AUD_V(v, AUD_V_ADSR)  = adsr;
    AUD_KEYON = 1u << v;
}

void snd_release(int v) { AUD_KEYOFF = 1u << v; }
void snd_stop(int v)    { AUD_STOP = 1u << v; }

int snd_free_voice(void)
{
    uint32_t act = AUD_ACTIVE;
    for (int v = AUD_VOICES - 1; v >= MIDI_VOICES; v--)
        if (!(act >> v & 1)) return v;
    return -1;
}

int snd_sfx(const sample_t *s, int vol, int pan)
{
    int v = snd_free_voice();
    if (v < 0) return -1;
    uint32_t pitch = (uint32_t)(((uint64_t)s->rate << 16) / 48000u);
    snd_voice(v, s, pitch, vol, pan, ADSR(0xFF, 0, 0xFF, 0xC0));
    return v;
}

// ---------------------------------------------------------------- streaming
static int16_t *st_ring;
static uint32_t st_frames, st_wr;
static int st_vl;

void snd_stream_start(int v, int16_t *ring, uint32_t frames, uint32_t rate)
{
    st_ring = UNCACHED(ring); st_frames = frames; st_wr = 0; st_vl = v;
    memset(st_ring, 0, frames * 4);
    sample_t s = { (uint32_t)ring, frames, 0, AUD_FMT_S16ST, rate };
    uint32_t pitch = (uint32_t)(((uint64_t)rate << 16) / 48000u);
    // stereo format: VOL[7:0] scales L and VOL[15:8] scales R (128 + pan 128 = 1.0)
    snd_voice(v, &s, pitch, 128, 128, ADSR(0xFF, 0, 0xFF, 0xFF));
    AUD_MON_V = (uint32_t)v;
}

uint32_t snd_stream_free(void)
{
    uint32_t rd = AUD_MON_POS;             // read position of the left voice
    return (rd + st_frames - st_wr - 1) % st_frames;
}

void snd_stream_write(const int16_t *lr, uint32_t frames)
{
    while (frames--) {
        st_ring[2 * st_wr]     = *lr++;
        st_ring[2 * st_wr + 1] = *lr++;
        if (++st_wr == st_frames) st_wr = 0;
    }
}
