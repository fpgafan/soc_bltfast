// trap.c - default (weak) interrupt handler: the program may
// define irq_ext(), irq_timer() or its own trap_handler()
#include "lib.h"

__attribute__((weak)) void irq_ext(uint32_t pend) { (void)pend; }
__attribute__((weak)) void irq_timer(void) { SYS_MTIMECMPH = 0xFFFFFFFFu; }

__attribute__((weak)) void trap_handler(uint32_t cause, uint32_t epc)
{
    if (cause == 0x8000000Bu) {                 // external
        uint32_t p = SYS_IRQ_PEND & SYS_IRQ_EN;
        irq_ext(p);
        SYS_IRQ_PEND = p;                       // clears the serviced edge interrupts
        return;
    }
    if (cause == 0x80000007u) { irq_timer(); return; }
    printf("\n*** exception mcause=%x mepc=%08x\n", cause, epc);
    for (;;) ;
}
