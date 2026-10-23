OUTPUT_ARCH(riscv)
ENTRY(_start)
/* Programas: código y datos en la SDRAM desde 0x4000_0000 (6 MB, la pila
   crece desde 0x4060_0000; los framebuffers van en 0x4060_0000-0x406F_FFFF y
   0x4070_0000-0x407F_FFFF queda para texturas/samples a elección del programa) */
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
