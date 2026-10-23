# bootmenu startup. The ROM (or tools/load.py) loads BOOT.BIN at 0x4000_0000
# and jumps here, but that is exactly where the chosen program has to go, so
# the first thing this stub does is copy the menu (linked at 0x4078_0000,
# see menu.ld) up there and continue from that copy.
    .section .text.start
    .globl _start
_start:
    la   t0, _img_lma            # absolute addresses: the stub runs where it was linked
    la   t1, _img_start
    la   t2, _img_end
1:  bgeu t1, t2, 2f
    lw   t3, 0(t0)
    sw   t3, 0(t1)
    addi t0, t0, 4
    addi t1, t1, 4
    j    1b
2:  la   t1, _bss_start
    la   t2, _bss_end
3:  bgeu t1, t2, 4f
    sw   zero, 0(t1)
    addi t1, t1, 4
    j    3b
4:  fence
    fence.i
    li   sp, 0x40800000          # stack at the top of the SDRAM, above the menu
    la   gp, __global_pointer$
    la   t0, main
    jr   t0

# starts a loaded program the same way the ROM does: a0 = address
    .text
    .globl app_jump
app_jump:
    fence
    fence.i
    li   sp, 0x40600000
    jr   a0
