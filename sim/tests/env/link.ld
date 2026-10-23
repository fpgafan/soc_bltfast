OUTPUT_ARCH(riscv)
ENTRY(_start)
SECTIONS {
  . = 0x40000000;
  .text : { *(.text.init) *(.text*) }
  . = ALIGN(0x100);
  .data : { *(.data*) *(.sdata*) *(.rodata*) *(.tohost) }
  .bss : { *(.bss*) *(.sbss*) }
  _end = .;
}
