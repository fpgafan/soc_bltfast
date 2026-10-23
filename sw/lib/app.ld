OUTPUT_ARCH(riscv)
ENTRY(_start)
/* Programs: code and data in SDRAM from 0x4000_0000 (6 MB, the stack
   grows down from 0x4060_0000; the framebuffers go at 0x4060_0000-0x406F_FFFF and
   0x4070_0000-0x407F_FFFF is left for textures/samples as the program chooses) */
MEMORY { RAM (rwx) : ORIGIN = 0x40000000, LENGTH = 6M }
SECTIONS {
  .text : { *(.text.start) *(.text*) } > RAM
  .rodata : { *(.rodata*) *(.srodata*) } > RAM
  .data : { *(.data*) *(.sdata*) } > RAM
  . = ALIGN(4);
  .bss (NOLOAD) : { _bss_start = .; *(.bss*) *(.sbss*) *(COMMON) . = ALIGN(4); _bss_end = .; } > RAM
  _end = .;
  __global_pointer$ = ADDR(.data) + 0x800;
}
