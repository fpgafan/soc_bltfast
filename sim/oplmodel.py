"""
oplmodel.py - Bit-exact model of the OPL2 (YM3812) in rtl/audio/opl2.v

Port of the OPL2 part of Nuked-OPL3 (nukeykt, LGPL 2.1), which reproduces
the chip cycle by cycle: 9 two-operator channels, waveforms 0-3 (with WSE),
vibrato/tremolo, KSL/KSR, feedback, NTS, DAM/DVB.
License: LGPL 2.1 (like Nuked-OPL3, see rtl/audio/LICENSE.nuked-opl3).
It does not include rhythm mode (bit 5 of 0xBD) or the timers: Doom does not
use them.
"""

LOGSIN = [0] * 256
EXP = [0] * 256
_logsin_hex = """
859 6c3 607 58b 52e 4e4 4a6 471 443 41a 3f5 3d3 3b5 398 37e 365
34e 339 324 311 2ff 2ed 2dc 2cd 2bd 2af 2a0 293 286 279 26d 261
256 24b 240 236 22c 222 218 20f 206 1fd 1f5 1ec 1e4 1dc 1d4 1cd
1c5 1be 1b7 1b0 1a9 1a2 19b 195 18f 188 182 17c 177 171 16b 166
160 15b 155 150 14b 146 141 13c 137 133 12e 129 125 121 11c 118
114 10f 10b 107 103 0ff 0fb 0f8 0f4 0f0 0ec 0e9 0e5 0e2 0de 0db
0d7 0d4 0d1 0cd 0ca 0c7 0c4 0c1 0be 0bb 0b8 0b5 0b2 0af 0ac 0a9
0a7 0a4 0a1 09f 09c 099 097 094 092 08f 08d 08a 088 086 083 081
07f 07d 07a 078 076 074 072 070 06e 06c 06a 068 066 064 062 060
05e 05c 05b 059 057 055 053 052 050 04e 04d 04b 04a 048 046 045
043 042 040 03f 03e 03c 03b 039 038 037 035 034 033 031 030 02f
02e 02d 02b 02a 029 028 027 026 025 024 023 022 021 020 01f 01e
01d 01c 01b 01a 019 018 017 017 016 015 014 014 013 012 011 011
010 00f 00f 00e 00d 00d 00c 00c 00b 00a 00a 009 009 008 008 007
007 007 006 006 005 005 005 004 004 004 003 003 003 002 002 002
002 001 001 001 001 001 001 001 000 000 000 000 000 000 000 000
"""
_exp_hex = """
7fa 7f5 7ef 7ea 7e4 7df 7da 7d4 7cf 7c9 7c4 7bf 7b9 7b4 7ae 7a9
7a4 79f 799 794 78f 78a 784 77f 77a 775 770 76a 765 760 75b 756
751 74c 747 742 73d 738 733 72e 729 724 71f 71a 715 710 70b 706
702 6fd 6f8 6f3 6ee 6e9 6e5 6e0 6db 6d6 6d2 6cd 6c8 6c4 6bf 6ba
6b5 6b1 6ac 6a8 6a3 69e 69a 695 691 68c 688 683 67f 67a 676 671
66d 668 664 65f 65b 657 652 64e 649 645 641 63c 638 634 630 62b
627 623 61e 61a 616 612 60e 609 605 601 5fd 5f9 5f5 5f0 5ec 5e8
5e4 5e0 5dc 5d8 5d4 5d0 5cc 5c8 5c4 5c0 5bc 5b8 5b4 5b0 5ac 5a8
5a4 5a0 59c 599 595 591 58d 589 585 581 57e 57a 576 572 56f 56b
567 563 560 55c 558 554 551 54d 549 546 542 53e 53b 537 534 530
52c 529 525 522 51e 51b 517 514 510 50c 509 506 502 4ff 4fb 4f8
4f4 4f1 4ed 4ea 4e7 4e3 4e0 4dc 4d9 4d6 4d2 4cf 4cc 4c8 4c5 4c2
4be 4bb 4b8 4b5 4b1 4ae 4ab 4a8 4a4 4a1 49e 49b 498 494 491 48e
48b 488 485 482 47e 47b 478 475 472 46f 46c 469 466 463 460 45d
45a 457 454 451 44e 44b 448 445 442 43f 43c 439 436 433 430 42d
42a 428 425 422 41f 41c 419 416 414 411 40e 40b 408 406 403 400
"""
LOGSIN = [int(x, 16) for x in _logsin_hex.split()]
EXP = [int(x, 16) for x in _exp_hex.split()]
MT = [1, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 20, 24, 24, 30, 30]
KSLROM = [0, 32, 40, 45, 48, 51, 53, 55, 56, 58, 59, 60, 61, 62, 63, 64]
KSLSHIFT = [8, 1, 2, 0]
INCSTEP = [[0, 0, 0, 0], [1, 0, 0, 0], [1, 0, 1, 0], [1, 1, 1, 0]]


def slot_off(s):
    """register offset (0x20+off...) of operator s (0..17)"""
    return s + 2 * (s // 6)


def slot_ch(s):
    return (s // 6) * 3 + (s % 3)


def slot_op(s):
    return 1 if (s % 6) >= 3 else 0


def s16(x):
    x &= 0xFFFF
    return x - 0x10000 if x & 0x8000 else x


def calc_exp(level):
    if level > 0x1FFF:
        level = 0x1FFF
    return (EXP[level & 0xFF] << 1) >> (level >> 8)


def wave(wf, phase, env):
    phase &= 0x3FF
    neg = 0
    if wf == 0:
        if phase & 0x200:
            neg = 0xFFFF
        out = LOGSIN[(phase & 0xFF) ^ 0xFF] if phase & 0x100 else LOGSIN[phase & 0xFF]
    elif wf == 1:
        if phase & 0x200:
            out = 0x1000
        else:
            out = LOGSIN[(phase & 0xFF) ^ 0xFF] if phase & 0x100 else LOGSIN[phase & 0xFF]
    elif wf == 2:
        out = LOGSIN[(phase & 0xFF) ^ 0xFF] if phase & 0x100 else LOGSIN[phase & 0xFF]
    else:
        out = 0x1000 if phase & 0x100 else LOGSIN[phase & 0xFF]
    return s16(calc_exp(out + (env << 3)) ^ neg)


class OPL2:
    def __init__(self):
        self.regs = [0] * 256
        self.pg_phase = [0] * 18
        self.eg_rout = [0x1FF] * 18
        self.eg_gen = [3] * 18
        self.out = [0] * 18
        self.prout = [0] * 18
        self.timer = 0
        self.tremolopos = 0
        self.tremolo = 0
        self.vibpos = 0
        self.eg_timer = 0
        self.eg_state = 0
        self.eg_add = 0
        self.eg_timer_lo = 0

    def write(self, reg, val):
        self.regs[reg & 0xFF] = val & 0xFF

    # ---------------------------------------------------------------- operator
    def process(self, s):
        R = self.regs
        o, ch, op = slot_off(s), slot_ch(s), slot_op(s)
        r20, r40, r60, r80, rE0 = R[0x20 + o], R[0x40 + o], R[0x60 + o], R[0x80 + o], R[0xE0 + o]
        rA0, rB0, rC0 = R[0xA0 + ch], R[0xB0 + ch], R[0xC0 + ch]
        nts = (R[0x08] >> 6) & 1
        wse = (R[0x01] >> 5) & 1
        dvb = (R[0xBD] >> 6) & 1
        f_num = ((rB0 & 3) << 8) | rA0
        block = (rB0 >> 2) & 7
        key = (rB0 >> 5) & 1
        fb = (rC0 >> 1) & 7
        con = rC0 & 1
        am, vib, egt, ksr, mult = (r20 >> 7) & 1, (r20 >> 6) & 1, (r20 >> 5) & 1, (r20 >> 4) & 1, r20 & 15
        kslv, tl = (r40 >> 6) & 3, r40 & 0x3F
        ar, dr = (r60 >> 4) & 15, r60 & 15
        sl, rr = (r80 >> 4) & 15, r80 & 15
        if sl == 15:
            sl = 0x1F
        wf = (rE0 & 3) if wse else 0

        # feedback
        if fb:
            fbmod = (self.prout[s] + self.out[s]) >> (9 - fb)
        else:
            fbmod = 0
        self.prout[s] = self.out[s]

        # envelope
        ksl = (KSLROM[f_num >> 6] << 2) - ((8 - block) << 5)
        if ksl < 0:
            ksl = 0
        eg_ksl = ksl & 0xFF
        ksv = (block << 1) | ((f_num >> (9 - nts)) & 1)
        trem = self.tremolo if am else 0
        rout0 = self.eg_rout[s]
        gen = self.eg_gen[s]
        eg_out = rout0 + (tl << 2) + (eg_ksl >> KSLSHIFT[kslv]) + trem
        reset = 0
        if key and gen == 3:
            reset = 1
            reg_rate = ar
        else:
            reg_rate = [ar, dr, 0 if egt else rr, rr][gen]
        ks = ksv >> ((ksr ^ 1) << 1)
        rate = ks + (reg_rate << 2)
        rate_hi, rate_lo = rate >> 2, rate & 3
        if rate_hi & 0x10:
            rate_hi = 0x0F
        eg_shift = rate_hi + self.eg_add
        shift = 0
        if reg_rate != 0:
            if rate_hi < 12:
                if self.eg_state:
                    if eg_shift == 12:
                        shift = 1
                    elif eg_shift == 13:
                        shift = (rate_lo >> 1) & 1
                    elif eg_shift == 14:
                        shift = rate_lo & 1
            else:
                shift = (rate_hi & 3) + INCSTEP[rate_lo][self.eg_timer_lo]
                if shift & 4:
                    shift = 3
                if not shift:
                    shift = self.eg_state
        eg_rout = rout0
        eg_inc = 0
        if reset and rate_hi == 0x0F:
            eg_rout = 0
        eg_off = (rout0 & 0x1F8) == 0x1F8
        if gen != 0 and not reset and eg_off:
            eg_rout = 0x1FF
        if gen == 0:
            if rout0 == 0:
                gen = 1
            elif key and shift > 0 and rate_hi != 0x0F:
                eg_inc = (~rout0) >> (4 - shift)
        elif gen == 1:
            if (rout0 >> 4) == sl:
                gen = 2
            elif not eg_off and not reset and shift > 0:
                eg_inc = 1 << (shift - 1)
        else:
            if not eg_off and not reset and shift > 0:
                eg_inc = 1 << (shift - 1)
        self.eg_rout[s] = (eg_rout + eg_inc) & 0x1FF
        if reset:
            gen = 0
        if not key:
            gen = 3
        self.eg_gen[s] = gen

        # phase
        if vib:
            rng = (f_num >> 7) & 7
            vp = self.vibpos
            if not (vp & 3):
                rng = 0
            elif vp & 1:
                rng >>= 1
            rng >>= (dvb ^ 1)
            if vp & 4:
                rng = -rng
            f_vib = f_num + rng
        else:
            f_vib = f_num
        basefreq = (f_vib << block) >> 1
        phase_out = (self.pg_phase[s] >> 9) & 0x3FF
        if reset:
            self.pg_phase[s] = 0
        self.pg_phase[s] = (self.pg_phase[s] + ((basefreq * MT[mult]) >> 1)) & 0x7FFFF

        # output
        if op == 0:
            mod = fbmod
        else:
            mod = 0 if con else self.out[s - 3]
        self.out[s] = wave(wf, phase_out + mod, eg_out)

    # ---------------------------------------------------------------- sample
    def sample(self):
        for s in range(18):
            self.process(s)
        mix = 0
        for ch in range(9):
            s = (ch // 3) * 6 + (ch % 3)
            con = self.regs[0xC0 + ch] & 1
            accm = self.out[s + 3] + (self.out[s] if con else 0)
            mix += s16(accm)
        mix = max(-32768, min(32767, mix))

        bd = self.regs[0xBD]
        tshift = 2 if (bd >> 7) & 1 else 4
        if (self.timer & 0x3F) == 0x3F:
            self.tremolopos = (self.tremolopos + 1) % 210
        if self.tremolopos < 105:
            self.tremolo = self.tremolopos >> tshift
        else:
            self.tremolo = (210 - self.tremolopos) >> tshift
        if (self.timer & 0x3FF) == 0x3FF:
            self.vibpos = (self.vibpos + 1) & 7
        self.timer = (self.timer + 1) & 0xFFFF
        if self.eg_state:
            sh = 0
            while sh < 13 and ((self.eg_timer >> sh) & 1) == 0:
                sh += 1
            self.eg_add = 0 if sh > 12 else sh + 1
            self.eg_timer_lo = self.eg_timer & 3
            self.eg_timer = (self.eg_timer + 1) & 0xFFFFFFFFF
        self.eg_state ^= 1
        return mix
