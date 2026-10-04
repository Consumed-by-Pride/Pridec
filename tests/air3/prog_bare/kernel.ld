ENTRY(_start)
SECTIONS
{
  . = 0x100000;
  __kernel_start = .;
  .text.boot : { *(.text.boot) }
  .text : { *(.text .text.*) }
  .rodata : { *(.rodata .rodata.*) }
  .data : ALIGN(4096) { *(.data .data.*) }
  .gdt : ALIGN(16) { *(.gdt) }
  .bss : ALIGN(4096) { *(.bss .bss.* COMMON) }
  __kernel_end = .;
  /DISCARD/ : { *(.comment .note* .eh_frame* .debug*) }
}
