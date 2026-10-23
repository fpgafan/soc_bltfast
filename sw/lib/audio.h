// ============================================================================
// audio.h - Sound engine (32 hardware voices) and MIDI player
// ============================================================================
#ifndef AUDIO_H
#define AUDIO_H
#include <stdint.h>
#include "soc.h"

typedef struct {
    uint32_t addr;          // SDRAM address of sample 0
    uint32_t len;           // samples (frames)
    uint32_t loop;          // loop start (= len: no loop)
    uint8_t  fmt;           // AUD_FMT_*
    uint32_t rate;          // samples per second at original pitch (or cycle*N for waveforms)
} sample_t;

void     snd_init(void);
void     snd_volume(int master);                            // 0..255 (128 = 1.0)
// plays 'smp' on voice v: 16.16 pitch relative to 48 kHz, vol/pan 0..255
void     snd_voice(int v, const sample_t *smp, uint32_t pitch, int vol, int pan, uint32_t adsr);
void     snd_release(int v);
void     snd_stop(int v);
int      snd_free_voice(void);                              // -1 if none
// simple sound effect (PCM sample at its own rate); returns the voice
int      snd_sfx(const sample_t *smp, int vol, int pan);
// streaming PCM (interleaved 16-bit stereo) with a ring buffer of
// 'frames' frames on voice v; snd_stream_free() tells how many frames can be
// written and snd_stream_write() copies them.
void     snd_stream_start(int v, int16_t *ring, uint32_t frames, uint32_t rate);
uint32_t snd_stream_free(void);
void     snd_stream_write(const int16_t *lr, uint32_t frames);

#define ADSR(a, d, s, r) ((uint32_t)(a) | ((uint32_t)(d) << 8) | ((uint32_t)(s) << 16) | ((uint32_t)(r) << 24))

// ---------------------------------------------------------------- MIDI
// Plays a standard MIDI file (type 0 or 1) loaded in memory.
// Voices 0..(MIDI_VOICES-1) are reserved for the music.
#define MIDI_VOICES 24
int      midi_load(const uint8_t *smf, uint32_t len);       // 0 = ok
void     midi_play(int loop);
void     midi_stop(void);
void     midi_update(void);                                 // call often (>= 200 Hz)
int      midi_playing(void);
void     midi_note_on(int ch, int note, int vel);           // also for live playing
void     midi_note_off(int ch, int note);
void     midi_program(int ch, int prog);
void     midi_pause(int on);                                // 1 = pause (releases the notes)
void     midi_volume(int vol);                              // 0..255 (255 = normal)
// output through the OPL2 (FM like the AdLib/Sound Blaster) instead of the voices:
// genmidi = DMX GENMIDI bank (with or without the "#OPL_II#" header) or 0 for
// the bundled Freedoom one; _wad reads it from a WAD on the SD ("DOOM    WAD").
// They return < 0 if the bitstream has no OPL2 (or the WAD is unusable).
int      midi_use_opl(const void *genmidi);
int      midi_use_opl_wad(const char *wad83);
void     midi_use_samples(void);
// loads a .MID from the SD root ("SONG    MID") into buf and calls midi_load
int      midi_load_file(const char *name83, void *buf, uint32_t max);
#endif
