# crt0.S - arranque de los programas (cargados en 0x4000_0000)
    .section .text.start
    .globl _start
_start:
    li   sp, 0x40600000          # pila bajo los framebuffers
    la   gp, __global_pointer$
    la   t1, _bss_start
    la   t2, _bss_end
1:  bgeu t1, t2, 2f
    sw   zero, 0(t1)
    addi t1, t1, 4
    j    1b
2:  la   t0, trap_entry
    csrw mtvec, t0
    call main
    li   a0, 0x80000004          # LEDs = 101010: fin (lo usa la simulación)
    li   a1, 0x2A
    sw   a1, 0(a0)
3:  j    3b

# Entrada de interrupciones/excepciones: guarda los registros temporales y
# llama a irq_handler(mcause, mepc) (definible por el programa; débil aquí).
    .align 4
trap_entry:
    addi sp, sp, -64
    sw   ra, 0(sp)
    sw   t0, 4(sp)
    sw   t1, 8(sp)
    sw   t2, 12(sp)
    sw   a0, 16(sp)
    sw   a1, 20(sp)
    sw   a2, 24(sp)
    sw   a3, 28(sp)
    sw   a4, 32(sp)
    sw   a5, 36(sp)
    sw   a6, 40(sp)
    sw   a7, 44(sp)
    sw   t3, 48(sp)
    sw   t4, 52(sp)
    sw   t5, 56(sp)
    sw   t6, 60(sp)
    csrr a0, mcause
    csrr a1, mepc
    call trap_handler
    lw   ra, 0(sp)
    lw   t0, 4(sp)
    lw   t1, 8(sp)
    lw   t2, 12(sp)
    lw   a0, 16(sp)
    lw   a1, 20(sp)
    lw   a2, 24(sp)
    lw   a3, 28(sp)
    lw   a4, 32(sp)
    lw   a5, 36(sp)
    lw   a6, 40(sp)
    lw   a7, 44(sp)
    lw   t3, 48(sp)
    lw   t4, 52(sp)
    lw   t5, 56(sp)
    lw   t6, 60(sp)
    addi sp, sp, 64
    mret
