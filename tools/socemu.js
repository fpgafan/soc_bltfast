// socemu.js - functional emulator of the bltfast SoC (RV32IM + basic peripherals)
// usage: node socemu.js prog.bin sd.img [--frames N] [--shots 100,200] [--keys "t:code,..."] [--out dir]
//      [--oplwav f.wav]  records the OPL2 output (FM music) into a mono WAV
'use strict';
const fs = require('fs');
const zlib = require('zlib');
const path = require('path');

const args = process.argv.slice(2);
const opt = { frames: 600, shots: [], keys: [], out: '.', pads: [], maxsec: 1e9 };
const binf = args[0], imgf = args[1];
for (let i = 2; i < args.length; i++) {
  const a = args[i];
  if (a === '--frames') opt.frames = +args[++i];
  else if (a === '--shots') opt.shots = args[++i].split(',').map(Number);
  else if (a === '--keys') opt.keys = args[++i].split(',').map(s => s.split(':').map(x => parseInt(x)));
  else if (a === '--pads') opt.pads = args[++i].split(',').map(s => s.split(':').map(x => parseInt(x)));
  else if (a === '--out') opt.out = args[++i];
  else if (a === '--maxsec') opt.maxsec = +args[++i];
  else if (a === '--prof') opt.prof = args[++i];
  else if (a === '--sdslow') opt.sdslow = +args[++i];
  else if (a === '--oplwav') opt.oplwav = args[++i];
}

const SDRAM = 8 << 20;
const buf = new ArrayBuffer(SDRAM);
const m8 = new Uint8Array(buf), dv = new DataView(buf);
const prog = fs.readFileSync(binf);
m8.set(prog, 0);
const disk = fs.readFileSync(imgf);
let diskDirty = false;

const x = new Int32Array(32);
let pc = 0x40000000 | 0;
let cycles = 0;           // = instructions (1 cycle each)
const CPU_HZ = 90000000, FRAME_CYC = Math.round(CPU_HZ / 60);
let misal = 0, misalPCs = new Map();

// CSR
let mstatus = 0, mie = 0, mtvec = 0, mepc = 0, mcause = 0, mtval = 0, mscratch = 0;
let mtimecmp = 0xFFFFFFFFFFFFn, mtimecmpLo = 0xFFFFFFFF, mtimecmpHi = 0xFFFFFFFF;

// peripherals
let uartOut = '', sysScratch = 0;
let vidFb = 0, vidFbShown = 0, vidPending = 0, vidCtrl = 0, vidStride = 640, frame = 0;
const pal = new Uint32Array(256);
const blt = new Uint32Array(16);
let bltCount = 0;
const ps2q = [];
let padState = 0;
let reset = false, ledEnd = false;
let slowReads = 0, audActive = 0, keyMus = 0, keySfx = 0;
// SD
let sdTout = 0, sdCs = 0, sdRx = 0xFF, sdCmd = [], sdResp = [], sdPendR = -1, sdPendW = -1, sdApp = false;
const sdBuf = new Uint8Array(512);

function sdByte(b) {
  if (sdCmd.length === 0 && (b & 0xC0) !== 0x40) return sdResp.length ? sdResp.shift() : 0xFF;
  sdCmd.push(b);
  if (sdCmd.length < 6) return 0xFF;
  const c = sdCmd[0] & 0x3F, arg = ((sdCmd[1] << 24) | (sdCmd[2] << 16) | (sdCmd[3] << 8) | sdCmd[4]) >>> 0;
  sdCmd = [];
  const app = sdApp; sdApp = false;
  if (c === 0) sdResp = [0xFF, 0x01];
  else if (c === 8) sdResp = [0xFF, 0x01, 0, 0, 1, 0xAA];
  else if (c === 55) { sdResp = [0xFF, 0x01]; sdApp = true; }
  else if (c === 41 && app) sdResp = [0xFF, 0x00];
  else if (c === 58) sdResp = [0xFF, 0x00, 0xC0, 0xFF, 0x80, 0x00];
  else if (c === 16) sdResp = [0xFF, 0x00];
  else if (c === 17) { sdResp = [0xFF, 0x00]; sdPendR = arg; }
  else if (c === 24) { sdResp = [0xFF, 0x00]; sdPendW = arg; }
  else sdResp = [0xFF, 0x04];
  return 0xFF;
}

function blitExec(cmd) {
  bltCount++;
  const op = cmd & 15, key = cmd & 16, bgt = cmd & 32, poff = cmd & 64;
  const dst = blt[1] & 0x7FFFFF, dstr = blt[2];
  const cx0 = blt[3] << 16 >> 16, cy0 = blt[3] >> 16, cx1 = blt[4] << 16 >> 16, cy1 = blt[4] >> 16;
  const src = blt[5] & 0x7FFFFF, sstr = blt[6];
  const X = blt[7] << 16 >> 16, Y = blt[7] >> 16;
  const W = blt[8] & 0xFFFF, H = blt[8] >>> 16;
  const col = blt[9], fg = col & 255, bg = (col >> 8) & 255, kc = (col >> 16) & 255, po = (col >>> 24) & 255;
  const u0 = blt[10] | 0, v0 = blt[11] | 0, du = blt[12] | 0, dvv = blt[13] | 0;
  if (op === 3) return;      // LINE: not used
  for (let j = 0; j < H; j++) {
    const dy = Y + j;
    if (dy < cy0 || dy >= cy1) continue;
    const v = (v0 + j * dvv) | 0, ty = v >> 16;
    for (let i = 0; i < W; i++) {
      const dx = X + i;
      if (dx < cx0 || dx >= cx1) continue;
      let c;
      if (op === 0) c = fg;
      else {
        const u = (u0 + i * du) | 0, tx = u >> 16;
        if (op === 1) {
          c = m8[(src + ty * sstr + tx) & 0x7FFFFF];
          if (key && c === kc) continue;
          if (poff) c = (c + po) & 255;
        } else {
          const bit = (m8[(src + ty * sstr + (tx >> 3)) & 0x7FFFFF] >> (7 - (tx & 7))) & 1;
          if (!bit && bgt) continue;
          c = bit ? fg : bg;
        }
      }
      m8[(dst + dy * dstr + dx) & 0x7FFFFF] = c;
    }
  }
}

function mtime() { return BigInt(cycles); }

// OPL2: writes are stored with their cycle and the music is computed at the end
const OPL_DIV = Math.round(CPU_HZ / 49716);
let oplGain = 0x80, oplWrites = 0;
const oplLog = [];
function oplRender(file) {
  const { OPL2 } = require('./opl2.js');
  const chip = new OPL2();
  const n = Math.floor(cycles / OPL_DIV);
  const pcm = Buffer.alloc(44 + n * 2);
  let w = 0, peak = 0;
  for (let k = 0; k < n; k++) {
    while (w < oplLog.length && Math.floor(oplLog[w] / OPL_DIV) <= k) { chip.write(oplLog[w + 1], oplLog[w + 2]); w += 3; }
    let y = (chip.sample() * oplGain) >> 6;
    y = y > 32767 ? 32767 : y < -32768 ? -32768 : y;
    if (Math.abs(y) > peak) peak = Math.abs(y);
    pcm.writeInt16LE(y, 44 + k * 2);
  }
  const rate = Math.round(CPU_HZ / OPL_DIV);
  pcm.write('RIFF', 0); pcm.writeUInt32LE(36 + n * 2, 4); pcm.write('WAVEfmt ', 8);
  pcm.writeUInt32LE(16, 16); pcm.writeUInt16LE(1, 20); pcm.writeUInt16LE(1, 22);
  pcm.writeUInt32LE(rate, 24); pcm.writeUInt32LE(rate * 2, 28); pcm.writeUInt16LE(2, 32); pcm.writeUInt16LE(16, 34);
  pcm.write('data', 36); pcm.writeUInt32LE(n * 2, 40);
  fs.writeFileSync(file, pcm);
  console.error(`OPL2: ${(n / rate).toFixed(1)} s in ${file}, peak ${peak}`);
}

function ioLoad(a) {
  a >>>= 0;
  if (a >= 0x80000000 && a < 0x80001000) {
    switch (a & 0xFFF) {
      case 0x00: return 0xB17F0001;
      case 0x08: return 0;
      case 0x0C: return CPU_HZ;
      case 0x34: return sysScratch;
      case 0x10: return cycles >>> 0;
      case 0x14: return Math.floor(cycles / 4294967296);
      case 0x18: return mtimecmpLo; case 0x1C: return mtimecmpHi;
      default: return 0;
    }
  }
  if (a >= 0x80001000 && a < 0x80002000) {
    if ((a & 0xFF) === 0x04) return 2;   // TX free and idle
    return 0;                            // no received data
  }
  if (a >= 0x80002000 && a < 0x80003000) {
    switch (a & 0xFF) {
      case 0x00: return vidCtrl; case 0x04: return vidFb; case 0x08: return vidStride;
      case 0x24: return (frame << 20) >>> 0;
      case 0x28: return vidPending;
      default: return 0;
    }
  }
  if (a >= 0x80003000 && a < 0x80004000) return pal[(a >> 2) & 255];
  if (a >= 0x80004000 && a < 0x80005000) {
    if ((a & 0xFF) === 0) return (bltCount << 16) >>> 0;
    return blt[(a >> 2) & 15];
  }
  if (a >= 0x80005000 && a < 0x80006000) {
    if ((a & 0xFFF) === 0x80C) return audActive;
    return 0;
  }
  if (a >= 0x80006000 && a < 0x80007000) {
    const o = a & 0xFFF;
    if (o === 0x004) return sdRx;
    if (o === 0x008) return sdTout ? 2 : 0;
    if (o >= 0x200) return sdBuf[o - 0x200] | (sdBuf[o - 0x1FF] << 8) | (sdBuf[o - 0x1FE] << 16) | (sdBuf[o - 0x1FD] << 24);
    return 0;
  }
  if (a >= 0x80007000 && a < 0x80008000) return (a & 0xFF) === 0 ? padState : 0;
  if (a >= 0x80009000 && a < 0x8000A000) {
    const o = a & 0xFFF;
    if (o === 0x400) return oplGain;
    if (o === 0x404) return Math.floor(cycles / OPL_DIV) >>> 0;
    return 0;
  }
  if (a >= 0x80008000 && a < 0x80009000) {
    if ((a & 0xFF) === 4) return ps2q.length ? 1 : 0;
    if ((a & 0xFF) === 0) return ps2q.length ? (0x100 | ps2q.shift()) : 0;
    return 0;
  }
  throw new Error('I/O read ' + a.toString(16) + ' pc=' + (pc >>> 0).toString(16));
}

function ioStore(a, v) {
  a >>>= 0; v >>>= 0;
  if (a >= 0x80000000 && a < 0x80001000) {
    switch (a & 0xFFF) {
      case 0x04: if (v === 0x2A) ledEnd = true; return;
      case 0x18: mtimecmpLo = v; return;
      case 0x1C: mtimecmpHi = v; return;
      case 0x30: if (v === 0x5EB007) reset = true; return;
      case 0x34: sysScratch = v; return;
      default: return;
    }
  }
  if (a >= 0x80001000 && a < 0x80002000) { if ((a & 0xFF) === 0) { const c = String.fromCharCode(v & 255); if (c !== '\r') process.stdout.write(c); } return; }
  if (a >= 0x80002000 && a < 0x80003000) {
    switch (a & 0xFF) {
      case 0x00: vidCtrl = v; return;
      case 0x04: vidFb = v; vidPending = 1; return;
      case 0x08: vidStride = v; return;
      default: return;
    }
  }
  if (a >= 0x80003000 && a < 0x80004000) { pal[(a >> 2) & 255] = v; return; }
  if (a >= 0x80004000 && a < 0x80005000) {
    const r = (a >> 2) & 15;
    if (r === 14) blitExec(v); else blt[r] = v;
    return;
  }
  if (a >= 0x80009000 && a < 0x8000A000) {
    const o = a & 0xFFF;
    if (o < 0x400) { oplWrites++; if (opt.oplwav) oplLog.push(cycles, o >> 2, v & 255); }
    else if (o === 0x400) oplGain = v & 255;
    return;
  }
  if (a >= 0x80005000 && a < 0x80006000) { if ((a & 0xFFF) === 0x804) { for (let b = 0; b < 32; b++) if ((v >>> b) & 1) { if (b < 24) keyMus++; else keySfx++; } } return; }
  if (a >= 0x80006000 && a < 0x80007000) {
    const o = a & 0xFFF;
    if (o === 0x000) sdCs = v & 1;
    else if (o === 0x004) sdRx = sdByte(v & 255);
    else if (o === 0x00C) {
      if (v === 1) {
        if (sdPendR < 0) throw new Error('BLOCK without CMD17');
        sdTout = 0;
        if (opt.sdslow) {   // slow card: the token arrives after opt.sdslow bytes (> 65536: hardware timeout)
          const wait = opt.sdslow - 65536;
          if (wait > 0) { sdTout = 1; sdResp = new Array(wait).fill(0xFF).concat([0xFE], [...disk.subarray(sdPendR * 512, sdPendR * 512 + 512)], [0x12, 0x34]); sdPendR = -1; slowReads++; return; }
        }
        sdBuf.set(disk.subarray(sdPendR * 512, sdPendR * 512 + 512)); sdPendR = -1;
      }
      else if (v === 2) { if (sdPendW < 0) throw new Error('BLOCK without CMD24'); disk.set(sdBuf, sdPendW * 512); diskDirty = true; sdPendW = -1; sdResp = [0x05, 0x00, 0xFF]; }
    } else if (o >= 0x200) { sdBuf[o - 0x200] = v; sdBuf[o - 0x1FF] = v >> 8; sdBuf[o - 0x1FE] = v >> 16; sdBuf[o - 0x1FD] = v >> 24; }
    return;
  }
  if (a >= 0x80007000 && a < 0x80009000) return;
  throw new Error('I/O write ' + a.toString(16) + ' pc=' + (pc >>> 0).toString(16));
}

function memIdx(a) {
  const h = a >>> 24;
  if (h === 0x40 || h === 0x50) return a & 0x7FFFFF;
  return -1;
}
function noteMisal(a) {
  misal++;
  const k = (pc >>> 0).toString(16);
  misalPCs.set(k, (misalPCs.get(k) || 0) + 1);
}
function ld(a, n, sgn) {
  const i = memIdx(a);
  if (i < 0) {
    if ((a >>> 0) >= 0x80000000) { const v = ioLoad(a); return n === 4 ? v | 0 : n === 2 ? (sgn ? v << 16 >> 16 : v & 0xFFFF) : (sgn ? v << 24 >> 24 : v & 255); }
    throw new Error('read ' + (a >>> 0).toString(16) + ' pc=' + (pc >>> 0).toString(16));
  }
  if (a & (n - 1)) noteMisal(a);
  if (n === 4) return dv.getInt32(i, true);
  if (n === 2) return sgn ? dv.getInt16(i, true) : dv.getUint16(i, true);
  return sgn ? (m8[i] << 24 >> 24) : m8[i];
}
function st(a, v, n) {
  const i = memIdx(a);
  if (i < 0) {
    if ((a >>> 0) >= 0x80000000) return ioStore(a, n === 4 ? v : n === 2 ? v & 0xFFFF : v & 255);
    throw new Error('write ' + (a >>> 0).toString(16) + ' pc=' + (pc >>> 0).toString(16));
  }
  if (a & (n - 1)) noteMisal(a);
  if (n === 4) dv.setInt32(i, v, true);
  else if (n === 2) dv.setInt16(i, v, true);
  else m8[i] = v;
}

function csrRead(c) {
  switch (c) {
    case 0x300: return mstatus; case 0x304: return mie; case 0x305: return mtvec;
    case 0x340: return mscratch; case 0x341: return mepc; case 0x342: return mcause; case 0x343: return mtval;
    case 0x344: return timerPending() ? 0x80 : 0;
    case 0xB00: case 0xC00: case 0xC01: case 0xB02: case 0xC02: return cycles | 0;
    case 0xB80: case 0xC80: case 0xC81: case 0xB82: case 0xC82: return Math.floor(cycles / 4294967296) | 0;
    case 0x301: return 0x40001100;
    default: return 0;
  }
}
function csrWrite(c, v) {
  switch (c) {
    case 0x300: mstatus = v & 0x88; break; case 0x304: mie = v & 0x888; break; case 0x305: mtvec = v; break;
    case 0x340: mscratch = v; break; case 0x341: mepc = v & ~3; break; case 0x342: mcause = v; break; case 0x343: mtval = v; break;
  }
}
function timerPending() {
  const cmp = mtimecmpHi * 4294967296 + mtimecmpLo;
  return cycles >= cmp;
}
function trap(cause, epc) {
  mepc = epc; mcause = cause;
  mstatus = (mstatus & ~0x88) | ((mstatus & 8) ? 0x80 : 0);
  pc = mtvec & ~3;
}

// ---------------------------------------------------------------- PNG
function crc32(b) { let c, crc = 0xFFFFFFFF; for (let n = 0; n < b.length; n++) { c = (crc ^ b[n]) & 255; for (let k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1; crc = (crc >>> 8) ^ c; } return (crc ^ 0xFFFFFFFF) >>> 0; }
function chunk(t, d) { const l = Buffer.alloc(4); l.writeUInt32BE(d.length); const td = Buffer.concat([Buffer.from(t), d]); const c = Buffer.alloc(4); c.writeUInt32BE(crc32(td)); return Buffer.concat([l, td, c]); }
function shot(name) {
  const W = 640, H = 480, raw = Buffer.alloc((W * 3 + 1) * H);
  const base = vidFbShown & 0x7FFFFF;
  for (let y = 0; y < H; y++) {
    raw[y * (W * 3 + 1)] = 0;
    for (let xx = 0; xx < W; xx++) {
      const c = pal[m8[(base + y * vidStride + xx) & 0x7FFFFF]], o = y * (W * 3 + 1) + 1 + xx * 3;
      raw[o] = (c >> 16) & 255; raw[o + 1] = (c >> 8) & 255; raw[o + 2] = c & 255;
    }
  }
  const ih = Buffer.alloc(13); ih.writeUInt32BE(W, 0); ih.writeUInt32BE(H, 4); ih[8] = 8; ih[9] = 2;
  const png = Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ih), chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]);
  fs.writeFileSync(path.join(opt.out, name), png);
}

// ---------------------------------------------------------------- CPU
const prof = opt.prof ? [] : null;
function run() {
  const t0 = Date.now();
  let nextFrame = FRAME_CYC;
  let flips = 0, lastFb = 0;
  const keys = opt.keys.slice(), pads = opt.pads.slice();
  for (;;) {
    // block of instructions up to the next event
    const lim = Math.min(nextFrame, cycles + 20000);
    while (cycles < lim) {
      const i = dv.getInt32((pc & 0x7FFFFF), true);
      const op = i & 0x7F, rd = (i >> 7) & 31, f3 = (i >> 12) & 7, r1 = (i >> 15) & 31, r2 = (i >> 20) & 31;
      let npc = (pc + 4) | 0;
      cycles++;
      switch (op) {
        case 0x37: if (rd) x[rd] = i & 0xFFFFF000; break;
        case 0x17: if (rd) x[rd] = (pc + (i & 0xFFFFF000)) | 0; break;
        case 0x6F: {
          const imm = ((i >> 31) << 20) | (((i >> 12) & 0xFF) << 12) | (((i >> 20) & 1) << 11) | (((i >> 21) & 0x3FF) << 1);
          if (rd) x[rd] = npc; npc = (pc + imm) | 0; break;
        }
        case 0x67: { const t = (x[r1] + (i >> 20)) & ~1; if (rd) x[rd] = npc; npc = t; break; }
        case 0x63: {
          const imm = ((i >> 31) << 12) | (((i >> 7) & 1) << 11) | (((i >> 25) & 0x3F) << 5) | (((i >> 8) & 0xF) << 1);
          const a = x[r1], b = x[r2];
          let t;
          switch (f3) {
            case 0: t = a === b; break; case 1: t = a !== b; break;
            case 4: t = a < b; break; case 5: t = a >= b; break;
            case 6: t = (a >>> 0) < (b >>> 0); break; case 7: t = (a >>> 0) >= (b >>> 0); break;
            default: throw new Error('branch');
          }
          if (t) npc = (pc + imm) | 0;
          break;
        }
        case 0x03: {
          const a = (x[r1] + (i >> 20)) | 0;
          let v;
          switch (f3) { case 0: v = ld(a, 1, 1); break; case 1: v = ld(a, 2, 1); break; case 2: v = ld(a, 4, 1); break; case 4: v = ld(a, 1, 0); break; case 5: v = ld(a, 2, 0); break; default: throw new Error('load'); }
          if (rd) x[rd] = v; break;
        }
        case 0x23: {
          const imm = ((i >> 25) << 5) | ((i >> 7) & 31);
          st((x[r1] + imm) | 0, x[r2], 1 << f3); break;
        }
        case 0x13: {
          const imm = i >> 20, a = x[r1];
          let v;
          switch (f3) {
            case 0: v = (a + imm) | 0; break; case 1: v = a << (imm & 31); break;
            case 2: v = a < imm ? 1 : 0; break; case 3: v = (a >>> 0) < (imm >>> 0) ? 1 : 0; break;
            case 4: v = a ^ imm; break; case 5: v = (i >>> 30) & 1 ? a >> (imm & 31) : a >>> (imm & 31); break;
            case 6: v = a | imm; break; case 7: v = a & imm; break;
          }
          if (rd) x[rd] = v; break;
        }
        case 0x33: {
          const a = x[r1], b = x[r2], f7 = i >>> 25;
          let v;
          if (f7 === 1) {
            switch (f3) {
              case 0: v = Math.imul(a, b); break;
              case 1: v = Number((BigInt(a) * BigInt(b)) >> 32n) | 0; break;
              case 2: v = Number((BigInt(a) * BigInt(b >>> 0)) >> 32n) | 0; break;
              case 3: v = Number((BigInt(a >>> 0) * BigInt(b >>> 0)) >> 32n) | 0; break;
              case 4: v = b === 0 ? -1 : (a === -2147483648 && b === -1) ? a : (a / b) | 0; break;
              case 5: v = b === 0 ? -1 : ((a >>> 0) / (b >>> 0)) | 0; break;
              case 6: v = b === 0 ? a : (a === -2147483648 && b === -1) ? 0 : a % b; break;
              case 7: v = b === 0 ? a : ((a >>> 0) % (b >>> 0)) | 0; break;
            }
          } else {
            switch (f3) {
              case 0: v = f7 ? (a - b) | 0 : (a + b) | 0; break; case 1: v = a << (b & 31); break;
              case 2: v = a < b ? 1 : 0; break; case 3: v = (a >>> 0) < (b >>> 0) ? 1 : 0; break;
              case 4: v = a ^ b; break; case 5: v = f7 ? a >> (b & 31) : a >>> (b & 31); break;
              case 6: v = a | b; break; case 7: v = a & b; break;
            }
          }
          if (rd) x[rd] = v; break;
        }
        case 0x0F: break;
        case 0x73: {
          if (f3 === 0) {
            if (i === 0x30200073) { mstatus = (mstatus & ~0x88) | ((mstatus & 0x80) ? 8 : 0) | 0x80; npc = mepc; break; }
            if (i === 0x10500073) break;      // wfi
            trap(i === 0x73 ? 11 : 3, pc); npc = pc; break;
          }
          const c = i >>> 20, old = csrRead(c);
          const src = f3 & 4 ? r1 : x[r1];
          if ((f3 & 3) === 1) csrWrite(c, src);
          else if ((f3 & 3) === 2 && r1) csrWrite(c, old | src);
          else if ((f3 & 3) === 3 && r1) csrWrite(c, old & ~src);
          if (rd) x[rd] = old;
          break;
        }
        default: throw new Error('instruction ' + (i >>> 0).toString(16) + ' pc=' + (pc >>> 0).toString(16));
      }
      if (prof && (cycles & 127) === 0) prof.push(pc >>> 0);
      pc = npc;
      if ((mstatus & 8) && (mie & 0x80) && timerPending()) trap(0x80000007 | 0, pc);
    }
    if (cycles >= nextFrame) {
      nextFrame += FRAME_CYC;
      frame++;
      if (vidPending) { vidPending = 0; vidFbShown = vidFb; flips++; }
      else if (frame === 1) vidFbShown = vidFb;
      while (keys.length && keys[0][0] <= frame) ps2q.push(keys.shift()[1]);
      while (pads.length && pads[0][0] <= frame) padState = pads.shift()[1];
      if (opt.shots.includes(frame)) shot('f' + String(frame).padStart(5, '0') + '.png');
      if (frame % 60 === 0) {
        const s = (Date.now() - t0) / 1000;
        process.stderr.write(`[frame ${frame}: ${(cycles / 1e6).toFixed(0)} M instr, ${s.toFixed(0)} s, ${flips} cambios de buffer en el último segundo, desalineados=${misal}]\n`);
        flips = 0;
        if (s > opt.maxsec) break;
      }
      if (frame >= opt.frames) break;
    }
    if (reset || ledEnd) break;
  }
}

try { run(); }
catch (e) { console.error('\n*** ' + e.message); }
console.error(`slow reads: ${slowReads}`);
console.error(`music notes: ${keyMus}, effects: ${keySfx}, OPL2 writes: ${oplWrites}`);
if (opt.oplwav) oplRender(opt.oplwav);
console.error(`\nend: frame ${frame}, ${cycles} instructions, reset=${reset}, misaligned=${misal}`);
if (misal) console.error('misaligned by pc:', [...misalPCs.entries()].slice(0, 20));
if (diskDirty) fs.writeFileSync(imgf + '.out', disk);
shot('final.png');
if (prof) {
  const out = require('child_process').execSync('riscv-none-elf-nm -n -S ' + opt.prof).toString().split('\n');
  const syms = [];
  for (const l of out) { const p = l.trim().split(/\s+/); if (p.length >= 4 && /[tTwW]/.test(p[2])) syms.push([parseInt(p[0], 16), parseInt(p[1], 16), p[3]]); }
  const h = new Map();
  for (const a of prof) {
    let lo = 0, hi = syms.length - 1, f = '?';
    while (lo <= hi) { const m = (lo + hi) >> 1; if (syms[m][0] <= a) { f = syms[m][2]; lo = m + 1; } else hi = m - 1; }
    h.set(f, (h.get(f) || 0) + 1);
  }
  const tot = prof.length;
  console.error('profile (% of instructions):');
  for (const [f, n] of [...h.entries()].sort((a, b) => b[1] - a[1]).slice(0, 25)) console.error((100 * n / tot).toFixed(1).padStart(6) + '%  ' + f);
}
