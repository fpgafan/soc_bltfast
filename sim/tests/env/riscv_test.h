// Minimal environment for riscv-tests on the SoC (simulation):
//   tohost = 0x8000_0F00 (1 = PASS, (n<<1)|1 = FAIL in test n)
#ifndef _ENV_SOC_H
#define _ENV_SOC_H
#define TESTNUM gp
#define RVTEST_RV32U .macro init; .endm
#define RVTEST_RV64U RVTEST_RV32U
#define RVTEST_RV32M .macro init; .endm
#define RVTEST_RV64M RVTEST_RV32M
#define TOHOST 0x80000F00
#define RVTEST_CODE_BEGIN \
        .section .text.init; .align 6; .globl _start; \
_start: la t0, trap_vector; csrw mtvec, t0; li TESTNUM, 0; j 1f; \
trap_vector: li a0, 0xBAD; li t0, TOHOST; sw a0, 4(t0); csrr a0, mcause; sw a0, 8(t0); \
        li a0, 3; sw a0, 0(t0); 9: j 9b; \
1:      init;
#define RVTEST_CODE_END unimp
#define RVTEST_PASS fence; li a0, 1; li t0, TOHOST; sw a0, 0(t0); 8: j 8b;
#define RVTEST_FAIL fence; slli a0, TESTNUM, 1; ori a0, a0, 1; li t0, TOHOST; sw a0, 0(t0); 7: j 7b;
#define EXTRA_DATA
#define RVTEST_DATA_BEGIN EXTRA_DATA .pushsection .tohost,"aw",@progbits; .align 6; .global tohost; tohost: .dword 0; .popsection; .align 4; .global begin_signature; begin_signature:
#define RVTEST_DATA_END .align 4; .global end_signature; end_signature:
#endif
