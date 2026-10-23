# ROM startup: stack and data in the internal RAM (0x1000_0000, 4 KB),
# because the SDRAM is not calibrated yet.
    .section .text.start
    .globl _start
_start:
    li   sp, 0x10001000
    la   gp, __global_pointer$
    # .data: copy from the ROM to the internal RAM
    la   t0, _data_lma
    la   t1, _data_start
    la   t2, _data_end
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
4:  la   t0, trap
    csrw mtvec, t0
    call main
5:  j    5b

# any exception in the ROM: report over the UART and restart the loop
trap:
    csrr a0, mcause
    csrr a1, mepc
    call boot_trap
6:  j    6b

# jump to a loaded program: a0 = address
    .globl boot_jump
boot_jump:
    fence
    fence.i
    li   sp, 0x40600000
    jr   a0
