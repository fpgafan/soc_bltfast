OUTPUT_ARCH(riscv)
ENTRY(_start)
/* Programs: code and data in SDRAM from 0x4000_0000 (6 MB, the stack
   grows down from 0x4060_0000; the framebuffers go at 0x4060_0000-0x406F_FFFF and
   0x4070_0000-0x407F_FFFF is left for textures/samples as the program chooses) */
MEMORY { RAM (rwx) : ORIGIN = 0x40000000, LENGTH = 6M }
SECTIONS {
  .text : { *(.text.start) *(.text*) } > RAM
  .rodata : { *(.rodata*) *(.srodata*) *(.gcc_except_table*) } > RAM
  /* C++ exceptions: the program registers this table with __register_frame_info
     (there is no crtbegin.o); the zero word terminates it */
  .eh_frame : { __eh_frame_start = .; KEEP(*(.eh_frame)) LONG(0) } > RAM
  .data : { *(.data*) *(.sdata*) } > RAM
  . = ALIGN(4);
  .init_array : {
    PROVIDE_HIDDEN (__init_array_start = .);
    KEEP (*(SORT_BY_INIT_PRIORITY(.init_array.*) SORT_BY_INIT_PRIORITY(.ctors.*)))
    KEEP (*(.init_array* .ctors*))
    PROVIDE_HIDDEN (__init_array_end = .);
  } > RAM
  . = ALIGN(4);
  .bss (NOLOAD) : { _bss_start = .; *(.bss*) *(.sbss*) *(COMMON) . = ALIGN(4); _bss_end = .; } > RAM
  _end = .;
  __global_pointer$ = ADDR(.data) + 0x800;
}
