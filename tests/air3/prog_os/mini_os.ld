ENTRY(_start)
SECTIONS
{
  . = 0x100000;
  .multiboot : { KEEP(*(.multiboot)) }
  .text : { *(.text .text.*) }
  .rodata : { *(.rodata .rodata.*) }
  .data : ALIGN(4096) { *(.data .data.*) }
  .bss : ALIGN(4096) { *(.bss .bss.* COMMON) }
  /DISCARD/ : { *(.comment .note* .eh_frame* .debug*) }
}
