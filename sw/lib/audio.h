// ============================================================================
// audio.h - Motor de sonido (32 voces por hardware) y reproductor MIDI
// ============================================================================
#ifndef AUDIO_H
#define AUDIO_H
#include <stdint.h>
#include "soc.h"

typedef struct {
    uint32_t addr;          // dirección de la SDRAM de la muestra 0
    uint32_t len;           // muestras (tramas)
    uint32_t loop;          // inicio del bucle (= len: sin bucle)
    uint8_t  fmt;           // AUD_FMT_*
    uint32_t rate;          // muestras por segundo a tono original (o ciclo*N para ondas)
} sample_t;

void     snd_init(void);
void     snd_volume(int master);                            // 0..255 (128 = 1.0)
// reproduce 'smp' en la voz v: pitch 16.16 respecto a 48 kHz, vol/pan 0..255
void     snd_voice(int v, const sample_t *smp, uint32_t pitch, int vol, int pan, uint32_t adsr);
void     snd_release(int v);
void     snd_stop(int v);
int      snd_free_voice(void);                              // -1 si no hay
// efecto de sonido simple (muestra PCM a su frecuencia); devuelve la voz
int      snd_sfx(const sample_t *smp, int vol, int pan);
// PCM en streaming (estéreo 16 bits intercalado) con buffer circular de
// 'frames' tramas en la voz v; snd_stream_free() dice cuántas tramas se pueden
// escribir y snd_stream_write() las copia.
void     snd_stream_start(int v, int16_t *ring, uint32_t frames, uint32_t rate);
uint32_t snd_stream_free(void);
void     snd_stream_write(const int16_t *lr, uint32_t frames);

#define ADSR(a, d, s, r) ((uint32_t)(a) | ((uint32_t)(d) << 8) | ((uint32_t)(s) << 16) | ((uint32_t)(r) << 24))

// ---------------------------------------------------------------- MIDI
// Reproduce un fichero MIDI estándar (tipo 0 o 1) cargado en memoria.
// Las voces 0..(MIDI_VOICES-1) quedan para la música.
#define MIDI_VOICES 24
int      midi_load(const uint8_t *smf, uint32_t len);       // 0 = bien
void     midi_play(int loop);
void     midi_stop(void);
void     midi_update(void);                                 // llamar a menudo (>= 200 Hz)
int      midi_playing(void);
void     midi_note_on(int ch, int note, int vel);           // también para tocar en directo
void     midi_note_off(int ch, int note);
void     midi_program(int ch, int prog);
void     midi_pause(int on);                                // 1 = pausa (suelta las notas)
void     midi_volume(int vol);                              // 0..255 (255 = normal)
// salida por el OPL2 (FM como la AdLib/Sound Blaster) en vez de las voces:
// genmidi = banco GENMIDI de DMX (con o sin la cabecera "#OPL_II#") o 0 para
// el de Freedoom incluido; _wad lo lee de un WAD de la SD ("DOOM    WAD").
// Devuelven < 0 si el bitstream no tiene OPL2 (o el WAD no sirve).
int      midi_use_opl(const void *genmidi);
int      midi_use_opl_wad(const char *wad83);
void     midi_use_samples(void);
// carga un .MID de la raíz de la SD ("CANCION MID") en buf y llama a midi_load
int      midi_load_file(const char *name83, void *buf, uint32_t max);
#endif
