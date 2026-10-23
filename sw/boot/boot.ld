OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY {
  ROM  (rx)  : ORIGIN = 0x00000000, LENGTH = 8K
  BRAM (rw)  : ORIGIN = 0x10000000, LENGTH = 3K      /* el último KB es pila */
}
SECTIONS {
  .text : { *(.text.start) *(.text*) *(.rodata*) *(.srodata*) } > ROM
  . = ALIGN(4);
  _data_lma = .;
  .data : AT(_data_lma) {
    _data_start = .;
    *(.data*) *(.sdata*)
    . = ALIGN(4);
    _data_end = .;
  } > BRAM
  .bss (NOLOAD) : {
    _bss_start = .;
    *(.bss*) *(.sbss*) *(COMMON)
    . = ALIGN(4);
    _bss_end = .;
  } > BRAM
  __global_pointer$ = _data_start + 0x800;
}
