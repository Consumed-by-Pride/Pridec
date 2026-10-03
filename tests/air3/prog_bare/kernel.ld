ENTRY(_start)
SECTIONS
{
  . = 0x100000;
  .text.boot : { *(.text.boot) }
  .text : { *(.text .text.*) }
  .rodata : { *(.rodata .rodata.*) }
  .data : ALIGN(4096) { *(.data .data.*) }
  .gdt : ALIGN(16) { *(.gdt) }
  .bss : ALIGN(4096) { *(.bss .bss.* COMMON) }
  /DISCARD/ : { *(.comment .note* .eh_frame* .debug*) }
}
