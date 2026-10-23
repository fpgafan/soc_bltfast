// opl_bltfast.c (GPL v2, like Chocolate Doom) - OPL driver (Chocolate Doom's opl/opl.h API) for
// the SoC's hardware OPL2.
//   - OPL_WriteRegister writes straight to the chip (no delays)
//   - scheduled callbacks (OPL_SetCallback) are run by OPL_Tick(),
//     called from irq_timer (500 Hz); the music clock stops while paused
//   - OPL_Lock/Unlock = critical section with interrupts disabled
#include "src/doomtype.h"
#include "src/opl.h"
#include "src/opl_queue.h"
#define printf lib_printf
#include "lib.h"
#undef printf

void OPL_Tick(void);

static opl_callback_queue_t *queue;
static uint64_t cur_us;                 // music time in microseconds
static uint64_t last_cyc;
static uint32_t cyc_acc;
static int paused, running, lock_depth;
static uint32_t lock_mstatus;

boolean DG_HaveOPL(void)
{
    // with a bitstream without OPL2 the gain register reads as 0
    OPL_GAIN = 0x80;
    return (OPL_GAIN & 0xFF) == 0x80;
}

opl_init_result_t OPL_Init(unsigned int port_base)
{
    (void)port_base;
    if (!DG_HaveOPL()) return OPL_INIT_NONE;
    OPL_GAIN = 0xC0;                    // x3: on par with the effects (measured with socemu --oplwav)
    lib_printf("OPL2: hardware FM music (GENMIDI)\n");
    if (!queue) queue = OPL_Queue_Create();
    OPL_Lock();
    OPL_Queue_Clear(queue);
    cur_us = 0; cyc_acc = 0; last_cyc = time_cycles();
    paused = 0; running = 1;
    OPL_Unlock();
    return OPL_INIT_OPL2;
}

void OPL_Shutdown(void)
{
    OPL_Lock();
    running = 0;
    if (queue) OPL_Queue_Clear(queue);
    for (int ch = 0; ch < 9; ch++) OPL_REG(0xB0 + ch) = 0;     // release all notes
    OPL_Unlock();
}

void OPL_SetSampleRate(unsigned int rate) { (void)rate; }

void OPL_WriteRegister(int reg, int value)
{
    if (reg >= 0 && reg < 0x100) OPL_REG(reg) = (uint32_t)value & 0xFF;   // OPL3 (0x1xx) does not exist
}

void OPL_InitRegisters(int opl3)
{
    int r;
    (void)opl3;
    // like Chocolate Doom's OPL_InitRegisters (what DMX does)
    for (r = OPL_REGS_LEVEL; r <= OPL_REGS_LEVEL + OPL_NUM_OPERATORS; ++r) OPL_WriteRegister(r, 0x3f);
    for (r = OPL_REGS_ATTACK; r <= OPL_REGS_WAVEFORM + OPL_NUM_OPERATORS; ++r) OPL_WriteRegister(r, 0x00);
    for (r = 1; r < OPL_REGS_LEVEL; ++r) OPL_WriteRegister(r, 0x00);
    OPL_WriteRegister(OPL_REG_TIMER_CTRL, 0x60);
    OPL_WriteRegister(OPL_REG_TIMER_CTRL, 0x80);
    OPL_WriteRegister(OPL_REG_WAVEFORM_ENABLE, 0x20);
    OPL_WriteRegister(OPL_REG_FM_MODE, 0x40);
}

void OPL_SetCallback(uint64_t us, opl_callback_t callback, void *data)
{
    OPL_Lock();
    OPL_Queue_Push(queue, callback, data, cur_us + us);
    OPL_Unlock();
}

void OPL_ClearCallbacks(void)
{
    OPL_Lock();
    OPL_Queue_Clear(queue);
    OPL_Unlock();
}

void OPL_AdjustCallbacks(float factor)
{
    OPL_Lock();
    OPL_Queue_AdjustCallbacks(queue, cur_us, factor);
    OPL_Unlock();
}

void OPL_Lock(void)
{
    uint32_t s;
    __asm__ volatile ("csrrci %0, mstatus, 8" : "=r"(s) :: "memory");
    if (lock_depth++ == 0) lock_mstatus = s;
}

void OPL_Unlock(void)
{
    if (--lock_depth == 0 && (lock_mstatus & 8)) irq_enable();
}

void OPL_Delay(uint64_t us) { delay_us((uint32_t)us); }

void OPL_SetPaused(int p) { paused = p; }

// from irq_timer (with interrupts disabled)
void OPL_Tick(void)
{
    uint64_t now = time_cycles();
    uint32_t d = (uint32_t)(now - last_cyc);
    last_cyc = now;
    if (!running || paused || lock_depth) return;
    cyc_acc += d;
    uint32_t us = cyc_acc / (CPU_HZ / 1000000u);
    cyc_acc -= us * (CPU_HZ / 1000000u);
    cur_us += us;
    while (!OPL_Queue_IsEmpty(queue) && OPL_Queue_Peek(queue) <= cur_us) {
        opl_callback_t cb;
        void *data;
        if (!OPL_Queue_Pop(queue, &cb, &data)) break;
        cb(data);
    }
}
