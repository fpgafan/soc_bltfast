// ============================================================================
// oplsynth.c - Instrumentos MIDI sobre el OPL2 por hardware (rtl/audio/opl2.v)
//
//  Recibe las notas del secuenciador de midi.c (midi_use_opl) y las reparte
//  entre los 9 canales del chip con un banco de instrumentos en formato
//  GENMIDI de DMX (el de Doom): 128 programas GM + 47 percusiones (notas
//  35-81 del canal 10), cada uno con 1 o 2 voces de 2 operadores.
//  Por defecto, el banco libre de Freedoom (genmidi_fd.c); oplsyn_load_wad()
//  carga el de un WAD de la SD (p. ej. el original de DOOM.WAD).
// ============================================================================
#include "lib.h"
#include "audio.h"

extern const uint8_t genmidi_freedoom[175 * 36];

// instrumento GENMIDI: 36 bytes
//   +0 flags (1 = tono fijo, 4 = dos voces), +2 afinación de la 2a voz
//   (128 = nada), +3 nota fija, +4 voz 0, +20 voz 1
// voz (16 bytes): modulador (+0 0x20, +1 0x60, +2 0x80, +3 0xE0, +4 KSL,
//   +5 nivel), +6 realimentación/conexión, portadora (+7..+12), +13 -,
//   +14 desplazamiento de nota (int16)
#define INSTR(i) (bank + (i) * 36)

static const uint8_t *bank = genmidi_freedoom;
static uint8_t wad_bank[175 * 36];

// F-number de las notas 0..11 en pasos de 1/32 de semitono (bloque = octava - 1)
static const uint16_t fnum_tab[12 * 32] = {
    345, 345, 346, 347, 347, 348, 349, 349, 350, 351, 351, 352, 352, 353, 354, 354,
    355, 356, 356, 357, 358, 358, 359, 359, 360, 361, 361, 362, 363, 363, 364, 365,
    365, 366, 367, 367, 368, 369, 369, 370, 371, 371, 372, 373, 373, 374, 375, 375,
    376, 377, 377, 378, 379, 380, 380, 381, 382, 382, 383, 384, 384, 385, 386, 386,
    387, 388, 389, 389, 390, 391, 391, 392, 393, 393, 394, 395, 396, 396, 397, 398,
    398, 399, 400, 401, 401, 402, 403, 404, 404, 405, 406, 406, 407, 408, 409, 409,
    410, 411, 412, 412, 413, 414, 415, 415, 416, 417, 418, 418, 419, 420, 421, 421,
    422, 423, 424, 424, 425, 426, 427, 428, 428, 429, 430, 431, 431, 432, 433, 434,
    435, 435, 436, 437, 438, 438, 439, 440, 441, 442, 442, 443, 444, 445, 446, 446,
    447, 448, 449, 450, 450, 451, 452, 453, 454, 455, 455, 456, 457, 458, 459, 460,
    460, 461, 462, 463, 464, 465, 465, 466, 467, 468, 469, 470, 470, 471, 472, 473,
    474, 475, 476, 476, 477, 478, 479, 480, 481, 482, 482, 483, 484, 485, 486, 487,
    488, 489, 489, 490, 491, 492, 493, 494, 495, 496, 497, 498, 498, 499, 500, 501,
    502, 503, 504, 505, 506, 507, 507, 508, 509, 510, 511, 512, 513, 514, 515, 516,
    517, 518, 519, 520, 520, 521, 522, 523, 524, 525, 526, 527, 528, 529, 530, 531,
    532, 533, 534, 535, 536, 537, 538, 539, 540, 541, 542, 543, 544, 545, 545, 546,
    547, 548, 549, 550, 551, 552, 553, 554, 555, 556, 557, 558, 559, 560, 561, 562,
    563, 565, 566, 567, 568, 569, 570, 571, 572, 573, 574, 575, 576, 577, 578, 579,
    580, 581, 582, 583, 584, 585, 586, 587, 588, 590, 591, 592, 593, 594, 595, 596,
    597, 598, 599, 600, 601, 602, 604, 605, 606, 607, 608, 609, 610, 611, 612, 613,
    615, 616, 617, 618, 619, 620, 621, 622, 623, 625, 626, 627, 628, 629, 630, 631,
    633, 634, 635, 636, 637, 638, 639, 641, 642, 643, 644, 645, 646, 648, 649, 650,
    651, 652, 653, 655, 656, 657, 658, 659, 661, 662, 663, 664, 665, 666, 668, 669,
    670, 671, 673, 674, 675, 676, 677, 679, 680, 681, 682, 684, 685, 686, 687, 689,
};
// atenuación (pasos de 0,75 dB) para un volumen MIDI 0..127 (curva GM: 40 log)
static const uint8_t vol_tl[128] = {
    63, 63, 63, 63, 63, 63, 63, 63, 63, 61, 59, 57, 55, 53, 51, 49,
    48, 47, 45, 44, 43, 42, 41, 40, 39, 38, 37, 36, 35, 34, 33, 33,
    32, 31, 31, 30, 29, 29, 28, 27, 27, 26, 26, 25, 25, 24, 24, 23,
    23, 22, 22, 21, 21, 20, 20, 19, 19, 19, 18, 18, 17, 17, 17, 16,
    16, 16, 15, 15, 14, 14, 14, 13, 13, 13, 13, 12, 12, 12, 11, 11,
    11, 10, 10, 10, 10, 9, 9, 9, 8, 8, 8, 8, 7, 7, 7, 7,
    6, 6, 6, 6, 6, 5, 5, 5, 5, 4, 4, 4, 4, 4, 3, 3,
    3, 3, 3, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 0, 0, 0,
};

typedef struct {
    int8_t   ch, note;                  // canal y nota MIDI (-1 = libre)
    uint8_t  held, sus;                 // tecla pulsada / sostenida por el pedal
    uint8_t  vol;                       // volumen de la nota (velocidad)
    uint8_t  second;                    // 2a voz de un instrumento doble
    const uint8_t *in, *v;              // instrumento y voz GENMIDI
    uint16_t fb;                        // valor de 0xB0 sin la tecla (bloque, F-number alto)
    uint32_t age;
} ovoice_t;

static ovoice_t ov[9];
static uint32_t oage;
static uint8_t  cvol[16], cexpr[16], csus[16];
static int16_t  cbend[16];              // 1/32 de semitono (-64..64)
static uint8_t  master = 255;

static int slot_off(int c) { return (c / 3) * 8 + c % 3; }   // modulador; portadora +3

static void key(int c, int on) { OPL_REG(0xB0 + c) = ov[c].fb | (on ? 0x20u : 0u); }

static void set_freq(int c)
{
    const ovoice_t *o = &ov[c];
    int n;
    if (o->in[0] & 1) n = o->in[3];                       // tono fijo (percusión)
    else n = o->note + (int16_t)(o->v[14] | o->v[15] << 8);
    while (n < 0) n += 12;
    while (n > 95) n -= 12;
    // +1 octava: DMX (el driver de Doom) toca todo una octava por encima de
    // la nota MIDI y los bancos GENMIDI están afinados contando con ello
    int idx = (n + 12) * 32 + (o->ch == 9 ? 0 : cbend[o->ch]);
    if (o->second) idx += (o->in[2] - 128) / 2;           // 2a voz algo desafinada: más gruesa
    if (idx < 0) idx = 0;
    int blk = idx / (12 * 32) - 1;
    uint32_t f = fnum_tab[idx % (12 * 32)];
    while (blk < 0) { f >>= 1; blk++; }
    while (blk > 7) { f <<= 1; blk--; }
    if (f > 1023) f = 1023;
    ov[c].fb = (uint16_t)((f >> 8) | (uint32_t)blk << 2);
    OPL_REG(0xA0 + c) = f & 0xFF;
}

static void set_level(int c)
{
    const ovoice_t *o = &ov[c];
    int v = o->vol * cvol[o->ch] / 127 * cexpr[o->ch] / 127 * master / 255;
    int att = vol_tl[v > 127 ? 127 : v];
    int m = slot_off(c);
    int car = (o->v[12] & 0x3F) + att;                    // nivel de la portadora
    OPL_REG(0x40 + m + 3) = (o->v[11] & 0xC0) | (uint32_t)(car > 63 ? 63 : car);
    int mod = o->v[5] & 0x3F;
    if (o->v[6] & 1) mod += att;                          // síntesis aditiva: el modulador también suena
    OPL_REG(0x40 + m) = (o->v[4] & 0xC0) | (uint32_t)(mod > 63 ? 63 : mod);
}

static void program(int c)
{
    const uint8_t *v = ov[c].v;
    int m = slot_off(c);
    OPL_REG(0x20 + m) = v[0];  OPL_REG(0x60 + m) = v[1];
    OPL_REG(0x80 + m) = v[2];  OPL_REG(0xE0 + m) = v[3];
    OPL_REG(0x20 + m + 3) = v[7];  OPL_REG(0x60 + m + 3) = v[8];
    OPL_REG(0x80 + m + 3) = v[9];  OPL_REG(0xE0 + m + 3) = v[10];
    OPL_REG(0xC0 + c) = v[6] & 0x0F;
}

static int alloc(void)
{
    int best = -1;
    uint32_t oldest = 0xFFFFFFFFu;
    for (int c = 0; c < 9; c++)                           // libre o ya soltada, la más antigua
        if (!ov[c].held && !ov[c].sus && ov[c].age < oldest) { oldest = ov[c].age; best = c; }
    if (best >= 0) return best;
    for (int c = 0; c < 9; c++)                           // si no, se roba la más antigua
        if (ov[c].age < oldest) { oldest = ov[c].age; best = c; }
    return best;
}

static void start(int ch, int note, int vel, const uint8_t *in, int second)
{
    int c = alloc();
    key(c, 0);
    ov[c] = (ovoice_t){ (int8_t)ch, (int8_t)note, 1, 0, (uint8_t)vel, (uint8_t)second,
                        in, in + 4 + 16 * second, 0, ++oage };
    program(c);
    set_level(c);
    set_freq(c);
    key(c, 1);
}

// ---------------------------------------------------------------- interfaz con midi.c
void oplsyn_reset(void)
{
    for (int c = 0; c < 9; c++) {
        ov[c] = (ovoice_t){ -1, -1, 0, 0, 0, 0, genmidi_freedoom, genmidi_freedoom + 4, 0, 0 };
        OPL_REG(0xB0 + c) = 0;
        OPL_REG(0x40 + slot_off(c)) = 0x3F;
        OPL_REG(0x40 + slot_off(c) + 3) = 0x3F;
    }
    for (int i = 0; i < 16; i++) { cvol[i] = 100; cexpr[i] = 127; csus[i] = 0; cbend[i] = 0; }
    OPL_REG(0x01) = 0x20;                                 // ondas 1-3 habilitadas
    OPL_REG(0x08) = 0x40;
    OPL_REG(0xBD) = 0x00;
}

void oplsyn_note_on(int ch, int note, int vel, int prog)
{
    const uint8_t *in;
    if (ch == 9) {
        if (note < 35 || note > 81) return;
        in = INSTR(128 + note - 35);
    } else
        in = INSTR(prog & 127);
    start(ch, note, vel, in, 0);
    if (in[0] & 4) start(ch, note, vel, in, 1);           // instrumento de dos voces
}

void oplsyn_note_off(int ch, int note)
{
    for (int c = 0; c < 9; c++)
        if (ov[c].held && ov[c].ch == ch && ov[c].note == note) {
            ov[c].held = 0;
            if (csus[ch]) ov[c].sus = 1; else key(c, 0);
        }
}

void oplsyn_all_off(void)
{
    for (int c = 0; c < 9; c++) { ov[c].held = ov[c].sus = 0; key(c, 0); }
}

void oplsyn_controller(int ch, int cc, int val)
{
    switch (cc) {
    case 7: case 11:
        if (cc == 7) cvol[ch] = (uint8_t)val; else cexpr[ch] = (uint8_t)val;
        for (int c = 0; c < 9; c++) if ((ov[c].held || ov[c].sus) && ov[c].ch == ch) set_level(c);
        break;
    case 64:
        csus[ch] = val >= 64;
        if (!csus[ch])
            for (int c = 0; c < 9; c++)
                if (ov[c].sus && ov[c].ch == ch) { ov[c].sus = 0; key(c, 0); }
        break;
    case 121: cvol[ch] = 100; cexpr[ch] = 127; cbend[ch] = 0; csus[ch] = 0; break;
    case 120: case 123: oplsyn_all_off(); break;
    default: break;
    }
}

void oplsyn_bend(int ch, int cents)                       // -200..200
{
    cbend[ch] = (int16_t)(cents * 32 / 100);
    for (int c = 0; c < 9; c++)
        if ((ov[c].held || ov[c].sus) && ov[c].ch == ch) { set_freq(c); key(c, 1); }
}

void oplsyn_master(int vol) { master = (uint8_t)vol; }

void oplsyn_bank(const void *genmidi)
{
    const uint8_t *g = genmidi;
    if (!g) bank = genmidi_freedoom;
    else bank = memcmp(g, "#OPL_II#", 8) == 0 ? g + 8 : g;
}

// lee el lump GENMIDI de un WAD de la raíz de la SD ("DOOM    WAD")
int oplsyn_load_wad(const char *wad83)
{
    fat_file f;
    uint8_t hdr[12], ent[16];
    if (fat_open(&f, wad83) || fat_read(&f, hdr, 12) != 12) return -1;
    if (memcmp(hdr + 1, "WAD", 3)) return -2;
    uint32_t n = hdr[4] | hdr[5] << 8 | hdr[6] << 16 | (uint32_t)hdr[7] << 24;
    uint32_t dir = hdr[8] | hdr[9] << 8 | hdr[10] << 16 | (uint32_t)hdr[11] << 24;
    for (uint32_t i = 0; i < n; i++) {
        if (fat_seek(&f, dir + i * 16) || fat_read(&f, ent, 16) != 16) return -3;
        if (memcmp(ent + 8, "GENMIDI", 7) || ent[15]) continue;
        uint32_t pos = ent[0] | ent[1] << 8 | ent[2] << 16 | (uint32_t)ent[3] << 24;
        if (fat_seek(&f, pos + 8) || fat_read(&f, wad_bank, sizeof wad_bank) != (int)sizeof wad_bank) return -4;
        bank = wad_bank;
        return 0;
    }
    return -5;                                            // no tiene GENMIDI
}
