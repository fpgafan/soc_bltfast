// ============================================================================
// midi.c - Reproductor de MIDI estándar (SMF tipo 0/1) sobre las voces por
// hardware. Instrumentos generados al arrancar:
//   - 4 formas de onda (seno, triángulo, sierra, cuadrada) de 256 muestras por
//     ciclo, en 6 versiones de banda limitada (una por octava) sin aliasing
//   - percusión sintetizada: bombo, caja, charles y platillo (canal 10)
// Cada programa General MIDI se asigna por familias a una onda + ADSR.
// ============================================================================
#include "audio.h"
#include "lib.h"

uint32_t snd_alloc(uint32_t bytes);

#define WLEN   256
#define NLEVEL 6
enum { W_SINE, W_TRI, W_SAW, W_SQR, W_DIST, W_OVER, NWAVE };
static sample_t wave[NWAVE][NLEVEL];
static sample_t drum_kick, drum_snare, drum_hat, drum_crash, drum_ride, drum_tom;
static int      inst_ready;

// seno en punto fijo (tabla de un cuarto de onda, 64 entradas, Q15)
static const int16_t qsin[65] = {
    0, 804, 1608, 2410, 3212, 4011, 4808, 5602, 6393, 7179, 7962, 8739, 9512, 10278, 11039,
    11793, 12539, 13279, 14010, 14732, 15446, 16151, 16846, 17530, 18204, 18868, 19519, 20159,
    20787, 21403, 22005, 22594, 23170, 23731, 24279, 24811, 25329, 25832, 26319, 26790, 27245,
    27683, 28105, 28510, 28898, 29268, 29621, 29956, 30273, 30571, 30852, 31113, 31356, 31580,
    31785, 31971, 32137, 32285, 32412, 32521, 32609, 32678, 32728, 32757, 32767 };

static int32_t isin(uint32_t ph)            // ph: 0..255 = un ciclo -> Q15
{
    ph &= 255;
    uint32_t q = ph & 63;
    switch (ph >> 6) {
    case 0:  return qsin[q];
    case 1:  return qsin[64 - q];
    case 2:  return -qsin[q];
    default: return -qsin[64 - q];
    }
}

static uint32_t rnd = 0x12345678;
static int32_t noise(void) { rnd ^= rnd << 13; rnd ^= rnd >> 17; rnd ^= rnd << 5; return (int32_t)rnd >> 16; }

static void make_waves(void)
{
    for (int w = 0; w < W_DIST; w++)
        for (int lv = 0; lv < NLEVEL; lv++) {
            // armónicos permitidos: la tabla 'lv' se usa hasta ~ 130 Hz * 2^lv
            int hmax = 160 >> lv;
            if (hmax < 1) hmax = 1;
            int16_t *t = (int16_t *)snd_alloc(WLEN * 2);
            int32_t acc[WLEN];
            int32_t peak = 1;
            for (int i = 0; i < WLEN; i++) {
                int32_t v = 0;
                for (int h = 1; h <= hmax; h++) {
                    int32_t a;
                    if (w == W_SINE)      a = (h == 1) ? 32767 : 0;
                    else if (w == W_SAW)  a = 32767 / h;
                    else if (w == W_SQR)  a = (h & 1) ? 32767 / h : 0;
                    else                  a = (h & 1) ? ((h & 2) ? -32767 : 32767) / (h * h) : 0;
                    if (a) v += (a * (w == W_TRI ? isin(i * h + 64) : isin(i * h))) >> 15;
                    if (w == W_SINE) break;
                }
                acc[i] = v;
                if (v > peak) peak = v;
                if (-v > peak) peak = -v;
            }
            for (int i = 0; i < WLEN; i++) t[i] = (int16_t)(acc[i] * 30000 / peak);
            wave[w][lv] = (sample_t){ (uint32_t)t, WLEN, 0, AUD_FMT_S16, 0 };
        }
}

// guitarra saturada: sierra con recorte suave (como un amplificador) y, para
// que no haya aliasing, se vuelve a construir con banda limitada por octava a
// partir de sus armónicos (DFT de un ciclo de WLEN muestras)
#define DHARM 100
static void make_dist(int w, int drive)
{
    static int32_t cyc[WLEN];
    static int64_t ca[DHARM + 1], cb[DHARM + 1];
    // sierra rica (64 armónicos)
    int32_t peak = 1;
    for (int i = 0; i < WLEN; i++) {
        int32_t v = 0;
        for (int h = 1; h <= 64; h++) v += isin((uint32_t)(i * h)) / h;
        cyc[i] = v;
        if (v > peak) peak = v;
        if (-v > peak) peak = -v;
    }
    // ganancia + recorte suave: y = x (27 + x^2) / (27 + 9 x^2) (aprox. de tanh), x en Q12
    for (int i = 0; i < WLEN; i++) {
        int64_t x = (int64_t)cyc[i] * drive * 4096 / peak;
        if (x > 3 * 4096) x = 3 * 4096;
        if (x < -3 * 4096) x = -3 * 4096;
        int64_t x2 = x * x >> 12;
        cyc[i] = (int32_t)((x * (27 * 4096 + x2) / (27 * 4096 + 9 * x2)) * 32767 >> 12);
    }
    // armónicos del ciclo saturado
    for (int h = 1; h <= DHARM; h++) {
        int64_t a = 0, b = 0;
        for (int i = 0; i < WLEN; i++) {
            a += (int64_t)cyc[i] * isin((uint32_t)(h * i + 64));
            b += (int64_t)cyc[i] * isin((uint32_t)(h * i));
        }
        ca[h] = a >> 15;
        cb[h] = b >> 15;
    }
    for (int lv = 0; lv < NLEVEL; lv++) {
        int hmax = 160 >> lv;
        if (hmax > DHARM) hmax = DHARM;
        int16_t *t = (int16_t *)snd_alloc(WLEN * 2);
        int32_t acc[WLEN];
        int32_t pk = 1;
        for (int i = 0; i < WLEN; i++) {
            int64_t v = 0;
            for (int h = 1; h <= hmax; h++)
                v += ca[h] * isin((uint32_t)(h * i + 64)) + cb[h] * isin((uint32_t)(h * i));
            acc[i] = (int32_t)(v >> 15);
            if (acc[i] > pk) pk = acc[i];
            if (-acc[i] > pk) pk = -acc[i];
        }
        for (int i = 0; i < WLEN; i++) t[i] = (int16_t)((int64_t)acc[i] * 30000 / pk);
        wave[w][lv] = (sample_t){ (uint32_t)t, WLEN, 0, AUD_FMT_S16, 0 };
    }
}

static void make_drums(void)
{
    // bombo: seno con caída rápida de 160 a 45 Hz, clic de ataque y algo de
    // saturación, 0,35 s
    int n = 16800;
    int16_t *k = (int16_t *)snd_alloc(n * 2);
    uint32_t ph = 0;
    for (int i = 0; i < n; i++) {
        uint32_t f = 45 + (uint32_t)(115 * 2400 / (i + 2400));   // caída casi exponencial
        ph += f * 256 * 65536 / 48000;
        int32_t env = 32767 - (int32_t)((int64_t)i * 32767 / n);
        int32_t v = (isin(ph >> 16) * 3) >> 1;                     // x1,5 y recorte
        if (v > 32767) v = 32767;
        if (v < -32767) v = -32767;
        if (i < 240) v += (noise() * (240 - i)) / 480;            // clic (5 ms)
        k[i] = (int16_t)((v * env) >> 15);
    }
    drum_kick = (sample_t){ (uint32_t)k, (uint32_t)n, (uint32_t)n, AUD_FMT_S16, 48000 };
    // caja: ruido + tono de 190 Hz, 0,2 s
    n = 9600;
    int16_t *s = (int16_t *)snd_alloc(n * 2);
    ph = 0;
    for (int i = 0; i < n; i++) {
        ph += 190u * 256 * 65536 / 48000;
        int32_t env = 32767 - (int32_t)((int64_t)i * 32767 / n);
        env = (env * env) >> 15;
        s[i] = (int16_t)((((noise() * 3) >> 2) + (isin(ph >> 16) >> 2)) * env >> 15);
    }
    drum_snare = (sample_t){ (uint32_t)s, (uint32_t)n, (uint32_t)n, AUD_FMT_S16, 48000 };
    // charles: ruido agudo (diferencias), 0,08 s ; platillo: 1 s
    for (int c = 0; c < 2; c++) {
        n = c ? 48000 : 4000;
        int16_t *h = (int16_t *)snd_alloc(n * 2);
        int32_t prev = 0;
        for (int i = 0; i < n; i++) {
            int32_t x = noise(), y = x - prev;
            prev = x;
            int32_t env = 32767 - (int32_t)((int64_t)i * 32767 / n);
            env = (env * env) >> 15;
            h[i] = (int16_t)((y >> 1) * env >> 15);
        }
        if (c) drum_crash = (sample_t){ (uint32_t)h, (uint32_t)n, (uint32_t)n, AUD_FMT_S16, 48000 };
        else   drum_hat   = (sample_t){ (uint32_t)h, (uint32_t)n, (uint32_t)n, AUD_FMT_S16, 48000 };
    }
    // ride: parciales metálicos inarmónicos + ruido agudo, 0,6 s
    n = 28800;
    int16_t *r = (int16_t *)snd_alloc(n * 2);
    static const uint16_t rf[4] = { 2810, 3560, 4870, 6230 };   // Hz
    uint32_t rph[4] = { 0, 0, 0, 0 };
    int32_t prevn = 0;
    for (int i = 0; i < n; i++) {
        int32_t v = 0;
        for (int j = 0; j < 4; j++) {
            rph[j] += rf[j] * (uint32_t)(65536 * 256 / 48000);
            v += isin(rph[j] >> 16) >> 3;
        }
        int32_t x = noise(), y = x - prevn;
        prevn = x;
        v += y >> 3;
        int32_t env = 32767 - (int32_t)((int64_t)i * 32767 / n);
        env = (env * env) >> 15;
        r[i] = (int16_t)(v * env >> 15);
    }
    drum_ride = (sample_t){ (uint32_t)r, (uint32_t)n, (uint32_t)n, AUD_FMT_S16, 48000 };
    // tom: seno de 140 a 90 Hz, 0,3 s (se afina según la nota)
    n = 14400;
    int16_t *tm = (int16_t *)snd_alloc(n * 2);
    ph = 0;
    for (int i = 0; i < n; i++) {
        uint32_t f = 90 + 50 * (uint32_t)(n - i) / (uint32_t)n;
        ph += f * 256 * 65536 / 48000;
        int32_t env = 32767 - (int32_t)((int64_t)i * 32767 / n);
        tm[i] = (int16_t)((isin(ph >> 16) * env) >> 15);
    }
    drum_tom = (sample_t){ (uint32_t)tm, (uint32_t)n, (uint32_t)n, AUD_FMT_S16, 48000 };
    fence();
}

static void inst_init(void)
{
    if (inst_ready) return;
    make_waves();
    make_dist(W_DIST, 7);                // distorsión: mucha ganancia
    make_dist(W_OVER, 3);                // overdrive: saturación suave
    make_drums();
    fence();
    inst_ready = 1;
}

// ---------------------------------------------------------------- notas -> tono
// incremento 16.16 para una tabla de WLEN muestras por ciclo:
// f * WLEN / 48000 * 65536 = f * 349.525...
static const uint32_t semi[12] = {            // 2^(i/12) en Q16
    65536, 69433, 73562, 77936, 82570, 87480, 92682, 98193, 104032, 110218, 116772, 123715 };
static uint32_t note_pitch(int note, int bend)  // bend en centésimas de semitono (-200..200)
{
    // C-1 (nota 0) = 8.1758 Hz -> incremento = 8.1758 * 349.525 = 2857.6 (16.16)
    int n = note * 100 + bend;
    if (n < 0) n = 0;
    int oct = n / 1200, rem = n % 1200;
    // fracción de semitono: interpolación lineal entre semitonos
    uint64_t p;
    uint32_t nx = (rem / 100 == 11) ? 131072 : semi[rem / 100 + 1];
    p = (uint64_t)2858 * (semi[rem / 100] + (uint64_t)(nx - semi[rem / 100]) * (rem % 100) / 100);
    return (uint32_t)((p << oct) >> 16);
}

// ---------------------------------------------------------------- instrumentos GM
typedef struct { uint8_t wave; uint32_t adsr; int8_t oct; uint8_t gain, layer; } inst_t;   // gain/16; layer: 2a voz desafinada
static const inst_t family[16] = {
    { W_TRI,  ADSR(0xF0, 0x4C, 0x40, 0x6C), 0, 16, 0 },   // pianos
    { W_SINE, ADSR(0xF0, 0x5A, 0x00, 0x6A), 0, 16, 0 },   // percusión cromática
    { W_SQR,  ADSR(0xA0, 0x40, 0xC0, 0x7C), 0, 16, 0 },   // órganos
    { W_SAW,  ADSR(0xF0, 0x50, 0x30, 0x6A), 0, 16, 0 },   // guitarras
    { W_SAW,  ADSR(0xE0, 0x4A, 0x80, 0x7A), 0, 16, 0 },   // bajos
    { W_SAW,  ADSR(0x6C, 0x30, 0xD0, 0x5C), 0, 16, 0 },   // cuerdas
    { W_SAW,  ADSR(0x6A, 0x30, 0xC0, 0x5A), 0, 16, 0 },   // conjuntos
    { W_SQR,  ADSR(0x8C, 0x40, 0xB0, 0x6C), 0, 16, 0 },   // metales
    { W_SQR,  ADSR(0x8A, 0x40, 0xB0, 0x6C), 0, 16, 0 },   // lengüeta
    { W_SINE, ADSR(0x8A, 0x40, 0xC0, 0x6C), 0, 16, 0 },   // flautas
    { W_SAW,  ADSR(0xD0, 0x40, 0xB0, 0x6A), 0, 16, 0 },   // solista sintético
    { W_TRI,  ADSR(0x50, 0x30, 0xC0, 0x4A), 0, 16, 0 },   // pads
    { W_SQR,  ADSR(0x80, 0x40, 0x80, 0x5A), 0, 16, 0 },   // efectos sintéticos
    { W_SAW,  ADSR(0xF0, 0x58, 0x20, 0x6A), 0, 16, 0 },   // étnicos
    { W_SINE, ADSR(0xF0, 0x60, 0x00, 0x7A), 0, 16, 0 },   // percusivos
    { W_TRI,  ADSR(0xF0, 0x50, 0x40, 0x6A), 0, 16, 0 },   // efectos
};

// instrumentos concretos (los que más usa la música de Doom); el resto, por familia
static inst_t prog_inst(int p)
{
    switch (p) {
    case 29: return (inst_t){ W_OVER, ADSR(0xE0, 0x46, 0xC0, 0x88), 0, 16, 1 };   // guitarra overdrive
    case 30: return (inst_t){ W_DIST, ADSR(0xE0, 0x44, 0xD0, 0x88), 0, 16, 1 };   // guitarra distorsionada
    case 32: case 33: case 34: case 35:                                           // bajos eléctricos
             return (inst_t){ W_OVER, ADSR(0xF0, 0x50, 0xA8, 0x88), 0, 20, 0 };
    case 36: case 37: case 38: case 39:                                           // bajos slap / sintéticos
             return (inst_t){ W_SQR,  ADSR(0xF0, 0x52, 0xA0, 0x88), 0, 18, 0 };
    case 80: return (inst_t){ W_SQR,  ADSR(0xE0, 0x40, 0xC0, 0x70), 0, 16, 1 };   // solista cuadrada
    case 81: return (inst_t){ W_SAW,  ADSR(0xE0, 0x40, 0xC0, 0x70), 0, 16, 1 };   // solista sierra
    case 87: return (inst_t){ W_DIST, ADSR(0xE0, 0x44, 0xC0, 0x80), 0, 16, 0 };   // solista + bajo
    default: {
        inst_t in = family[p >> 3];
        in.gain = 16;
        in.layer = 0;
        return in;
    }
    }
}

// ---------------------------------------------------------------- estado de canales y voces
typedef struct { uint8_t prog, vol, pan, expr; int16_t bend; uint8_t sustain; } chan_t;
static chan_t ch[16];
typedef struct { int8_t ch, note; uint32_t age; uint8_t held, sus; } vstate_t;
static int music_vol = 255;
static vstate_t vs[MIDI_VOICES];
static uint32_t vage;

static void chan_reset(void)
{
    for (int c = 0; c < 16; c++) ch[c] = (chan_t){ 0, 100, 64, 127, 0, 0 };
    for (int v = 0; v < MIDI_VOICES; v++) vs[v] = (vstate_t){ -1, -1, 0, 0, 0 };
}

static int alloc_voice(void)
{
    uint32_t act = AUD_ACTIVE;
    int best = -1;
    uint32_t oldest = 0xFFFFFFFF;
    for (int v = 0; v < MIDI_VOICES; v++)              // libre
        if (!(act >> v & 1)) return v;
    for (int v = 0; v < MIDI_VOICES; v++)              // en relajación, la más antigua
        if (!vs[v].held && vs[v].age < oldest) { oldest = vs[v].age; best = v; }
    if (best >= 0) return best;
    for (int v = 0; v < MIDI_VOICES; v++)
        if (vs[v].age < oldest) { oldest = vs[v].age; best = v; }
    return best;
}

// salida por el OPL2 (oplsynth.c) en lugar de las voces de muestras
static int use_opl;
void oplsyn_reset(void);
void oplsyn_note_on(int ch, int note, int vel, int prog);
void oplsyn_note_off(int ch, int note);
void oplsyn_all_off(void);
void oplsyn_controller(int ch, int cc, int val);
void oplsyn_bend(int ch, int cents);
void oplsyn_master(int vol);
void oplsyn_bank(const void *genmidi);
int  oplsyn_load_wad(const char *wad83);

void midi_program(int c, int p) { ch[c & 15].prog = (uint8_t)p; }

void midi_note_on(int c, int note, int vel)
{
    c &= 15;
    if (vel == 0) { midi_note_off(c, note); return; }
    if (use_opl) { oplsyn_note_on(c, note, vel, ch[c].prog); return; }
    int v = alloc_voice();
    if (v < 0) return;
    int vol = vel * ch[c].vol / 127 * ch[c].expr / 127 * 2 * music_vol / 255;  // 0..254
    int pan = ch[c].pan * 2;
    if (c == 9) {                                              // percusión GM
        const sample_t *s;
        uint32_t pitch = 0x10000;
        if (note == 35 || note == 36) { s = &drum_kick; vol = vol * 3 / 2; }
        else if (note == 38 || note == 40 || note == 37 || note == 39) { s = &drum_snare; vol = vol * 5 / 4; }
        else if (note == 42 || note == 44) s = &drum_hat;
        else if (note == 46) { s = &drum_hat; pitch = 0xC000; }
        else if (note == 51 || note == 53 || note == 59) { s = &drum_ride; if (note == 53) pitch = 0x12000; }
        else if (note == 49 || note == 52 || note == 55 || note == 57) s = &drum_crash;
        else if (note == 41 || note == 43 || note == 45 || note == 47 || note == 48 || note == 50) {
            s = &drum_tom;
            pitch = 0xA000 + (uint32_t)(note - 41) * 0x1400;     // toms de grave a agudo
        } else s = &drum_hat;
        if (vol > 255) vol = 255;
        snd_voice(v, s, pitch, vol, pan, ADSR(0xFF, 0, 0xFF, 0x90));
    } else {
        inst_t in = prog_inst(ch[c].prog);
        int n = note + in.oct * 12;
        int lv = (n - 36) / 12;                                // tabla según la octava
        if (lv < 0) lv = 0;
        if (lv >= NLEVEL) lv = NLEVEL - 1;
        vol = vol * in.gain / 16;
        if (in.layer) vol = vol * 3 / 4;                       // dos voces: algo menos cada una
        if (vol > 255) vol = 255;
        snd_voice(v, &wave[in.wave][lv], note_pitch(n, ch[c].bend), vol, pan, in.adsr);
        if (in.layer) {                                        // 2a voz +10 centésimas: más gruesa
            vs[v] = (vstate_t){ (int8_t)c, (int8_t)note, ++vage, 1, 0 };
            int v2 = alloc_voice();
            if (v2 >= 0 && v2 != v) {
                snd_voice(v2, &wave[in.wave][lv], note_pitch(n, ch[c].bend + 10), vol, pan, in.adsr);
                vs[v2] = (vstate_t){ (int8_t)c, (int8_t)note, ++vage, 1, 0 };
            }
            return;
        }
    }
    vs[v] = (vstate_t){ (int8_t)c, (int8_t)note, ++vage, 1, 0 };
}

void midi_note_off(int c, int note)
{
    if (use_opl) { oplsyn_note_off(c & 15, note); return; }
    for (int v = 0; v < MIDI_VOICES; v++)
        if (vs[v].held && vs[v].ch == c && vs[v].note == note) {
            vs[v].held = 0;
            if (ch[c & 15].sustain) vs[v].sus = 1;
            else if (c != 9) snd_release(v);
        }
}

static void all_off(void)
{
    if (use_opl) { oplsyn_all_off(); return; }
    AUD_KEYOFF = (1u << MIDI_VOICES) - 1;
    for (int v = 0; v < MIDI_VOICES; v++) vs[v].held = 0;
}

static void controller(int c, int cc, int val)
{
    if (use_opl) oplsyn_controller(c, cc, val);
    switch (cc) {
    case 7:  ch[c].vol = (uint8_t)val; break;
    case 10: ch[c].pan = (uint8_t)val; break;
    case 11: ch[c].expr = (uint8_t)val; break;
    case 64:
        ch[c].sustain = val >= 64;
        if (!ch[c].sustain && !use_opl)
            for (int v = 0; v < MIDI_VOICES; v++)
                if (vs[v].sus && vs[v].ch == c) { vs[v].sus = 0; snd_release(v); }
        break;
    case 120: case 123: all_off(); break;
    case 121: ch[c] = (chan_t){ ch[c].prog, 100, 64, 127, 0, 0 }; break;
    default: break;
    }
}

// ---------------------------------------------------------------- secuenciador SMF
#define MAXTRK 32
typedef struct { const uint8_t *p, *end; uint32_t next; uint8_t run; uint8_t done; } trk_t;
static trk_t trk[MAXTRK];
static int ntrk, division, playing, looping;
static const uint8_t *smf_data;
static uint32_t smf_len;
static uint32_t us_per_tick_q8;           // microsegundos por tick (Q8)
static uint32_t now_tick, last_us, frac_us;

static uint32_t be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]; }
static uint32_t varlen(const uint8_t **pp, const uint8_t *end)
{
    uint32_t v = 0;
    while (*pp < end) { uint8_t b = *(*pp)++; v = (v << 7) | (b & 0x7F); if (!(b & 0x80)) break; }
    return v;
}

static void set_tempo(uint32_t us_per_quarter)
{
    us_per_tick_q8 = (uint32_t)(((uint64_t)us_per_quarter << 8) / (uint32_t)division);
}

static int parse(void)
{
    const uint8_t *p = smf_data, *end = smf_data + smf_len;
    if (smf_len < 14 || memcmp(p, "MThd", 4)) return -1;
    uint32_t hl = be32(p + 4);
    division = (p[12] << 8) | p[13];
    if (division & 0x8000) return -2;              // SMPTE: no soportado
    p += 8 + hl;
    ntrk = 0;
    while (p + 8 <= end && ntrk < MAXTRK) {
        uint32_t l = be32(p + 4);
        if (!memcmp(p, "MTrk", 4)) {
            trk[ntrk].p = p + 8;
            trk[ntrk].end = (p + 8 + l <= end) ? p + 8 + l : end;
            trk[ntrk].run = 0;
            trk[ntrk].done = 0;
            trk[ntrk].next = varlen(&trk[ntrk].p, trk[ntrk].end);
            ntrk++;
        }
        p += 8 + l;
    }
    set_tempo(500000);
    now_tick = 0;
    return ntrk ? 0 : -3;
}

int midi_load(const uint8_t *smf, uint32_t len)
{
    inst_init();
    smf_data = smf; smf_len = len;
    chan_reset();
    return parse();
}

void midi_play(int loop)
{
    looping = loop;
    chan_reset();
    if (use_opl) oplsyn_reset();
    if (parse()) return;
    last_us = time_us(); frac_us = 0;
    playing = 1;
}

void midi_stop(void) { playing = 0; all_off(); }
static int paused;
void midi_pause(int on) { paused = on; if (on) all_off(); }
void midi_volume(int vol) { music_vol = vol < 0 ? 0 : vol > 255 ? 255 : vol; oplsyn_master(music_vol); }

int midi_use_opl(const void *genmidi)
{
    OPL_GAIN = 0x60;                               // x1,5: margen para 9 voces (sin OPL2 se lee 0)
    if ((OPL_GAIN & 0xFF) != 0x60) return -1;
    all_off();
    oplsyn_bank(genmidi);
    oplsyn_reset();
    use_opl = 1;
    return 0;
}

int midi_use_opl_wad(const char *wad83)
{
    if (midi_use_opl(0)) return -1;
    return oplsyn_load_wad(wad83);
}

void midi_use_samples(void)
{
    if (use_opl) oplsyn_all_off();
    use_opl = 0;
}

int midi_load_file(const char *name83, void *buf, uint32_t max)
{
    fat_file f;
    if (fat_open(&f, name83)) return -10;
    if (f.size > max) return -11;
    if (fat_read(&f, buf, f.size) != (int)f.size) return -12;
    return midi_load(buf, f.size);
}
int  midi_playing(void) { return playing; }

static void track_event(trk_t *t)
{
    const uint8_t *p = t->p;
    uint8_t st = *p;
    if (st & 0x80) { p++; if (st < 0xF0) t->run = st; } else st = t->run;
    if (st == 0xFF) {                              // meta
        uint8_t type = *p++;
        uint32_t l = varlen(&p, t->end);
        if (type == 0x51 && l == 3) set_tempo((uint32_t)p[0] << 16 | p[1] << 8 | p[2]);
        if (type == 0x2F) t->done = 1;
        p += l;
    } else if (st == 0xF0 || st == 0xF7) {         // sysex
        uint32_t l = varlen(&p, t->end);
        p += l;
    } else {
        int c = st & 15, a = p[0], b = p[1];
        switch (st & 0xF0) {
        case 0x80: midi_note_off(c, a); p += 2; break;
        case 0x90: midi_note_on(c, a, b); p += 2; break;
        case 0xA0: p += 2; break;
        case 0xB0: controller(c, a, b); p += 2; break;
        case 0xC0: midi_program(c, a); p += 1; break;
        case 0xD0: p += 1; break;
        case 0xE0:
            ch[c].bend = (int16_t)((((b << 7) | a) - 8192) * 200 / 8192);
            if (use_opl) oplsyn_bend(c, ch[c].bend);
            p += 2;
            break;
        default: p += 1; break;
        }
    }
    t->p = p;
    if (t->p >= t->end) t->done = 1;
    if (!t->done) t->next += varlen(&t->p, t->end);
}

void midi_update(void)
{
    if (!playing) return;
    uint32_t now = time_us();
    if (paused) { last_us = now; return; }
    frac_us += (now - last_us) << 8;
    last_us = now;
    while (frac_us >= us_per_tick_q8) { frac_us -= us_per_tick_q8; now_tick++; }
    int alive = 0;
    for (int i = 0; i < ntrk; i++) {
        trk_t *t = &trk[i];
        while (!t->done && t->next <= now_tick) track_event(t);
        if (!t->done) alive = 1;
    }
    if (!alive) {
        all_off();
        if (looping) midi_play(1); else playing = 0;
    }
}
