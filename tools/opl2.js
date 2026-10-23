// opl2.js - OPL2 (YM3812) bit-exacto, igual que rtl/audio/opl2.v y sim/oplmodel.py
// (traducción de Nuked-OPL3 en modo OPL2, sin modo de ritmo). Para tools/socemu.js.
// Licencia: LGPL 2.1 (como Nuked-OPL3, ver rtl/audio/LICENSE.nuked-opl3).
'use strict';
const LOGSIN = [2137, 1731, 1543, 1419, 1326, 1252, 1190, 1137, 1091, 1050, 1013, 979, 949, 920, 894, 869, 846, 825, 804, 785, 767, 749, 732, 717, 701, 687, 672, 659, 646, 633, 621, 609, 598, 587, 576, 566, 556, 546, 536, 527, 518, 509, 501, 492, 484, 476, 468, 461, 453, 446, 439, 432, 425, 418, 411, 405, 399, 392, 386, 380, 375, 369, 363, 358, 352, 347, 341, 336, 331, 326, 321, 316, 311, 307, 302, 297, 293, 289, 284, 280, 276, 271, 267, 263, 259, 255, 251, 248, 244, 240, 236, 233, 229, 226, 222, 219, 215, 212, 209, 205, 202, 199, 196, 193, 190, 187, 184, 181, 178, 175, 172, 169, 167, 164, 161, 159, 156, 153, 151, 148, 146, 143, 141, 138, 136, 134, 131, 129, 127, 125, 122, 120, 118, 116, 114, 112, 110, 108, 106, 104, 102, 100, 98, 96, 94, 92, 91, 89, 87, 85, 83, 82, 80, 78, 77, 75, 74, 72, 70, 69, 67, 66, 64, 63, 62, 60, 59, 57, 56, 55, 53, 52, 51, 49, 48, 47, 46, 45, 43, 42, 41, 40, 39, 38, 37, 36, 35, 34, 33, 32, 31, 30, 29, 28, 27, 26, 25, 24, 23, 23, 22, 21, 20, 20, 19, 18, 17, 17, 16, 15, 15, 14, 13, 13, 12, 12, 11, 10, 10, 9, 9, 8, 8, 7, 7, 7, 6, 6, 5, 5, 5, 4, 4, 4, 3, 3, 3, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0];
const EXP = [2042, 2037, 2031, 2026, 2020, 2015, 2010, 2004, 1999, 1993, 1988, 1983, 1977, 1972, 1966, 1961, 1956, 1951, 1945, 1940, 1935, 1930, 1924, 1919, 1914, 1909, 1904, 1898, 1893, 1888, 1883, 1878, 1873, 1868, 1863, 1858, 1853, 1848, 1843, 1838, 1833, 1828, 1823, 1818, 1813, 1808, 1803, 1798, 1794, 1789, 1784, 1779, 1774, 1769, 1765, 1760, 1755, 1750, 1746, 1741, 1736, 1732, 1727, 1722, 1717, 1713, 1708, 1704, 1699, 1694, 1690, 1685, 1681, 1676, 1672, 1667, 1663, 1658, 1654, 1649, 1645, 1640, 1636, 1631, 1627, 1623, 1618, 1614, 1609, 1605, 1601, 1596, 1592, 1588, 1584, 1579, 1575, 1571, 1566, 1562, 1558, 1554, 1550, 1545, 1541, 1537, 1533, 1529, 1525, 1520, 1516, 1512, 1508, 1504, 1500, 1496, 1492, 1488, 1484, 1480, 1476, 1472, 1468, 1464, 1460, 1456, 1452, 1448, 1444, 1440, 1436, 1433, 1429, 1425, 1421, 1417, 1413, 1409, 1406, 1402, 1398, 1394, 1391, 1387, 1383, 1379, 1376, 1372, 1368, 1364, 1361, 1357, 1353, 1350, 1346, 1342, 1339, 1335, 1332, 1328, 1324, 1321, 1317, 1314, 1310, 1307, 1303, 1300, 1296, 1292, 1289, 1286, 1282, 1279, 1275, 1272, 1268, 1265, 1261, 1258, 1255, 1251, 1248, 1244, 1241, 1238, 1234, 1231, 1228, 1224, 1221, 1218, 1214, 1211, 1208, 1205, 1201, 1198, 1195, 1192, 1188, 1185, 1182, 1179, 1176, 1172, 1169, 1166, 1163, 1160, 1157, 1154, 1150, 1147, 1144, 1141, 1138, 1135, 1132, 1129, 1126, 1123, 1120, 1117, 1114, 1111, 1108, 1105, 1102, 1099, 1096, 1093, 1090, 1087, 1084, 1081, 1078, 1075, 1072, 1069, 1066, 1064, 1061, 1058, 1055, 1052, 1049, 1046, 1044, 1041, 1038, 1035, 1032, 1030, 1027, 1024];
const MT = [1, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 20, 24, 24, 30, 30];
const KSLROM = [0, 32, 40, 45, 48, 51, 53, 55, 56, 58, 59, 60, 61, 62, 63, 64];
const KSLSHIFT = [8, 1, 2, 0];
const INCSTEP = [[0, 0, 0, 0], [1, 0, 0, 0], [1, 0, 1, 0], [1, 1, 1, 0]];

function s16(x) { x &= 0xFFFF; return x & 0x8000 ? x - 0x10000 : x; }
function calcExp(l) { if (l > 0x1FFF) l = 0x1FFF; return (EXP[l & 0xFF] << 1) >> (l >> 8); }
function wave(wf, phase, env) {
  phase &= 0x3FF;
  let neg = 0, out;
  const ls = phase & 0x100 ? LOGSIN[(phase & 0xFF) ^ 0xFF] : LOGSIN[phase & 0xFF];
  if (wf === 0) { if (phase & 0x200) neg = 0xFFFF; out = ls; }
  else if (wf === 1) out = phase & 0x200 ? 0x1000 : ls;
  else if (wf === 2) out = ls;
  else out = phase & 0x100 ? 0x1000 : LOGSIN[phase & 0xFF];
  return s16(calcExp(out + (env << 3)) ^ neg);
}

class OPL2 {
  constructor() {
    this.regs = new Uint8Array(256);
    this.ph = new Int32Array(18); this.rout = new Int32Array(18).fill(0x1FF);
    this.gen = new Int32Array(18).fill(3); this.out = new Int32Array(18); this.prout = new Int32Array(18);
    this.timer = 0; this.tpos = 0; this.trem = 0; this.vibpos = 0;
    this.egTimer = 0; this.egState = 0; this.egAdd = 0; this.egLo = 0;
  }
  write(r, v) { this.regs[r & 0xFF] = v & 0xFF; }
  process(s) {
    const R = this.regs, o = s + 2 * Math.floor(s / 6), ch = Math.floor(s / 6) * 3 + (s % 3), op = (s % 6) >= 3;
    const r20 = R[0x20 + o], r40 = R[0x40 + o], r60 = R[0x60 + o], r80 = R[0x80 + o], rE0 = R[0xE0 + o];
    const rA0 = R[0xA0 + ch], rB0 = R[0xB0 + ch], rC0 = R[0xC0 + ch];
    const nts = (R[8] >> 6) & 1, wse = (R[1] >> 5) & 1, dvb = (R[0xBD] >> 6) & 1;
    const fnum = ((rB0 & 3) << 8) | rA0, block = (rB0 >> 2) & 7, key = (rB0 >> 5) & 1;
    const fb = (rC0 >> 1) & 7, con = rC0 & 1;
    const am = r20 >> 7, vib = (r20 >> 6) & 1, egt = (r20 >> 5) & 1, ksr = (r20 >> 4) & 1, mult = r20 & 15;
    const kslv = r40 >> 6, tl = r40 & 0x3F, ar = r60 >> 4, dr = r60 & 15, rr = r80 & 15;
    let sl = r80 >> 4; if (sl === 15) sl = 0x1F;
    const wf = wse ? rE0 & 3 : 0;
    const fbmod = fb ? (this.prout[s] + this.out[s]) >> (9 - fb) : 0;
    this.prout[s] = this.out[s];
    let ksl = (KSLROM[fnum >> 6] << 2) - ((8 - block) << 5); if (ksl < 0) ksl = 0;
    const egKsl = ksl & 0xFF, ksv = (block << 1) | ((fnum >> (9 - nts)) & 1);
    const rout0 = this.rout[s]; let gen = this.gen[s];
    const egOut = rout0 + (tl << 2) + (egKsl >> KSLSHIFT[kslv]) + (am ? this.trem : 0);
    let reset = 0, regRate;
    if (key && gen === 3) { reset = 1; regRate = ar; }
    else regRate = [ar, dr, egt ? 0 : rr, rr][gen];
    const ks = ksv >> ((ksr ^ 1) << 1), rate = ks + (regRate << 2);
    let rateHi = rate >> 2; const rateLo = rate & 3; if (rateHi & 0x10) rateHi = 0x0F;
    const egShift = rateHi + this.egAdd;
    let shift = 0;
    if (regRate) {
      if (rateHi < 12) {
        if (this.egState) shift = egShift === 12 ? 1 : egShift === 13 ? (rateLo >> 1) & 1 : egShift === 14 ? rateLo & 1 : 0;
      } else {
        shift = (rateHi & 3) + INCSTEP[rateLo][this.egLo];
        if (shift & 4) shift = 3;
        if (!shift) shift = this.egState;
      }
    }
    let er = rout0, inc = 0;
    if (reset && rateHi === 0x0F) er = 0;
    const off = (rout0 & 0x1F8) === 0x1F8;
    if (gen !== 0 && !reset && off) er = 0x1FF;
    if (gen === 0) { if (rout0 === 0) gen = 1; else if (key && shift > 0 && rateHi !== 0x0F) inc = (~rout0) >> (4 - shift); }
    else if (gen === 1) { if ((rout0 >> 4) === sl) gen = 2; else if (!off && !reset && shift > 0) inc = 1 << (shift - 1); }
    else if (!off && !reset && shift > 0) inc = 1 << (shift - 1);
    this.rout[s] = (er + inc) & 0x1FF;
    if (reset) gen = 0;
    if (!key) gen = 3;
    this.gen[s] = gen;
    let fv = fnum;
    if (vib) {
      let rng = (fnum >> 7) & 7; const vp = this.vibpos;
      if (!(vp & 3)) rng = 0; else if (vp & 1) rng >>= 1;
      rng >>= (dvb ^ 1);
      fv = vp & 4 ? fnum - rng : fnum + rng;
    }
    const base = (fv << block) >> 1;
    const phaseOut = (this.ph[s] >> 9) & 0x3FF;
    if (reset) this.ph[s] = 0;
    this.ph[s] = (this.ph[s] + ((base * MT[mult]) >> 1)) & 0x7FFFF;
    const mod = !op ? fbmod : con ? 0 : this.out[s - 3];
    this.out[s] = wave(wf, phaseOut + mod, egOut);
  }
  sample() {
    for (let s = 0; s < 18; s++) this.process(s);
    let mix = 0;
    for (let ch = 0; ch < 9; ch++) {
      const s = Math.floor(ch / 3) * 6 + ch % 3;
      mix += s16(this.out[s + 3] + (this.regs[0xC0 + ch] & 1 ? this.out[s] : 0));
    }
    if (mix > 32767) mix = 32767; else if (mix < -32768) mix = -32768;
    const tsh = (this.regs[0xBD] >> 7) & 1 ? 2 : 4;
    if ((this.timer & 0x3F) === 0x3F) this.tpos = (this.tpos + 1) % 210;
    this.trem = (this.tpos < 105 ? this.tpos : 210 - this.tpos) >> tsh;
    if ((this.timer & 0x3FF) === 0x3FF) this.vibpos = (this.vibpos + 1) & 7;
    this.timer = (this.timer + 1) & 0xFFFF;
    if (this.egState) {
      let sh = 0;
      while (sh < 13 && ((this.egTimer >> sh) & 1) === 0) sh++;
      this.egAdd = sh > 12 ? 0 : sh + 1;
      this.egLo = this.egTimer & 3;
      this.egTimer = (this.egTimer + 1) & 0x1FFF;
    }
    this.egState ^= 1;
    return mix;
  }
}
module.exports = { OPL2 };
