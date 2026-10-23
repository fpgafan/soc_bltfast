#!/usr/bin/env python3
"""pyiss.py - RV32IM reference simulator (minimal machine mode) for differential
testing. Memory: 8 MB SDRAM visible at 0x4xxx_xxxx and 0x5xxx_xxxx
(alias), I/O writes ignored except tohost (0x8000_0F00)."""
import struct

M32 = 0xFFFFFFFF


def sx(v, b):
    v &= (1 << b) - 1
    return v - (1 << b) if v >> (b - 1) else v


class ISS:
    def __init__(self, image, base=0x40000000):
        self.mem = bytearray(8 << 20)
        self.mem[0:len(image)] = image
        self.x = [0] * 32
        self.pc = base
        self.done = None
        self.n = 0

    def phys(self, a):
        top = a >> 28
        if top in (4, 5):
            return a & 0x7FFFFF
        return None

    def ld(self, a, size):
        p = self.phys(a)
        if p is None:
            return 0
        return int.from_bytes(self.mem[p:p + size], "little")

    def st(self, a, size, v):
        p = self.phys(a)
        if p is None:
            if a == 0x80000F00:
                self.done = v
            return
        self.mem[p:p + size] = (v & ((1 << (8 * size)) - 1)).to_bytes(size, "little")

    def step(self):
        pc = self.pc
        i = self.ld(pc, 4)
        op = i & 0x7F
        rd = (i >> 7) & 31
        f3 = (i >> 12) & 7
        r1 = self.x[(i >> 15) & 31]
        r2 = self.x[(i >> 20) & 31]
        f7 = i >> 25
        immi = sx(i >> 20, 12)
        imms = sx(((i >> 25) << 5) | ((i >> 7) & 31), 12)
        immb = sx(((i >> 31) << 12) | (((i >> 7) & 1) << 11) | (((i >> 25) & 63) << 5) | (((i >> 8) & 15) << 1), 13)
        immu = i & 0xFFFFF000
        immj = sx(((i >> 31) << 20) | (((i >> 12) & 255) << 12) | (((i >> 20) & 1) << 11) | (((i >> 21) & 1023) << 1), 21)
        npc = (pc + 4) & M32
        res = None
        if op == 0x37:
            res = immu
        elif op == 0x17:
            res = (pc + immu) & M32
        elif op == 0x6F:
            res = npc; npc = (pc + immj) & M32
        elif op == 0x67:
            res = npc; npc = (r1 + immi) & M32 & ~1
        elif op == 0x63:
            s1, s2 = sx(r1, 32), sx(r2, 32)
            t = {0: r1 == r2, 1: r1 != r2, 4: s1 < s2, 5: s1 >= s2, 6: r1 < r2, 7: r1 >= r2}[f3]
            if t:
                npc = (pc + immb) & M32
        elif op == 0x03:
            a = (r1 + immi) & M32
            v = self.ld(a, {0: 1, 1: 2, 2: 4, 4: 1, 5: 2}[f3])
            res = {0: sx(v, 8), 1: sx(v, 16), 2: v, 4: v, 5: v}[f3] & M32
        elif op == 0x23:
            a = (r1 + imms) & M32
            self.st(a, {0: 1, 1: 2, 2: 4}[f3], r2)
        elif op in (0x13, 0x33):
            b = immi & M32 if op == 0x13 else r2
            if op == 0x33 and f7 == 1:
                res = self.muldiv(f3, r1, r2)
            else:
                sh = b & 31
                if f3 == 0:
                    res = (r1 - b) if (op == 0x33 and f7 == 0x20) else (r1 + b)
                elif f3 == 1:
                    res = r1 << sh
                elif f3 == 2:
                    res = int(sx(r1, 32) < sx(b, 32))
                elif f3 == 3:
                    res = int(r1 < (b & M32))
                elif f3 == 4:
                    res = r1 ^ b
                elif f3 == 5:
                    res = (sx(r1, 32) >> sh) if (f7 & 0x20) else (r1 >> sh)
                elif f3 == 6:
                    res = r1 | b
                else:
                    res = r1 & b
                res &= M32
        elif op == 0x0F:
            pass
        elif op == 0x73:
            if f3 != 0:
                res = 0          # CSR: the generator does not use them except for reads that are ignored
        else:
            raise RuntimeError(f"unsupported instruction {i:08x} at {pc:08x}")
        if res is not None and rd:
            self.x[rd] = res & M32
        self.pc = npc
        self.n += 1

    @staticmethod
    def muldiv(f3, a, b):
        sa, sb = sx(a, 32), sx(b, 32)
        if f3 == 0:
            return (a * b) & M32
        if f3 == 1:
            return ((sa * sb) >> 32) & M32
        if f3 == 2:
            return ((sa * b) >> 32) & M32
        if f3 == 3:
            return ((a * b) >> 32) & M32
        if f3 == 4:
            if b == 0:
                return M32
            if sa == -2**31 and sb == -1:
                return a
            q = abs(sa) // abs(sb)
            return (-q if (sa < 0) != (sb < 0) else q) & M32
        if f3 == 5:
            return M32 if b == 0 else a // b
        if f3 == 6:
            if b == 0:
                return a
            if sa == -2**31 and sb == -1:
                return 0
            r = abs(sa) % abs(sb)
            return (-r if sa < 0 else r) & M32
        return a if b == 0 else a % b

    def run(self, maxn=10_000_000):
        while self.done is None and self.n < maxn:
            self.step()
        return self.done
