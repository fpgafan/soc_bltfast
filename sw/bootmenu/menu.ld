OUTPUT_ARCH(riscv)
ENTRY(_start)
/* bootmenu: the image is loaded at 0x4000_0000 (LOAD), but everything except
   the startup stub runs from 0x4078_0000 (HI, the top 512 KB of the SDRAM,
   stack included) so that programs of up to 6 MB can be loaded at
   0x4000_0000 without overwriting the menu. The framebuffers
   (0x4060_0000-0x406F_FFFF) stay where gfx.c expects them.
   Code and data go in a single output section so that the copy made by
   start.S is one contiguous block (same padding at the LMA and the VMA). */
MEMORY {
  LOAD (rwx) : ORIGIN = 0x40000000, LENGTH = 512K
  HI   (rwx) : ORIGIN = 0x40780000, LENGTH = 512K
}
SECTIONS {
  .stub : { *(.text.start) . = ALIGN(64); } > LOAD
  .image : {
    _img_start = .;
    *(.text*) *(.rodata*) *(.srodata*) *(.data*)
    __global_pointer$ = . + 0x800;
    *(.sdata*)
    . = ALIGN(4);
    _img_end = .;
  } > HI AT> LOAD
  _img_lma = LOADADDR(.image);
  .bss (NOLOAD) : { _bss_start = .; *(.sbss*) *(.bss*) *(COMMON) . = ALIGN(4); _bss_end = .; } > HI
  _end = .;
  ASSERT(_end <= 0x407F0000, "bootmenu: less than 64 KB left for the stack")
}
