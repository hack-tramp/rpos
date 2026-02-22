/* kernel.ld - Linker script for Raspberry Pi 1 */

ENTRY(_start)

SECTIONS
{
    /* Kernel starts at 0x8000 */
    . = 0x8000;
    
    /* Vector table first */
    .vectors : {
        *(.vectors)
    }
    
    /* Text section (code) */
    .text : {
        *(.text.boot)
        *(.text)
        *(.text.*)
    }
    
    /* Read-only data */
    .rodata : {
        *(.rodata)
        *(.rodata.*)
    }
    
    /* Read-write data */
    .data : {
        *(.data)
        *(.data.*)
    }
    
    /* Zero-initialized data */
    .bss : {
        . = ALIGN(16);
        __bss_start = .;
        *(.bss)
        *(.bss.*)
        *(COMMON)
        . = ALIGN(16);
        __bss_end = .;
    }
    
    /* End of kernel */
    . = ALIGN(4096);
    __end = .;
}
