// keyboard.S - USB Keyboard driver
// Target: Raspberry Pi 1, works with hid.S

#include "usb_constants.h"

// USB keyboard boot protocol report (8 bytes)
// Byte 0: Modifier keys (bitmap)
// Byte 1: Reserved
// Byte 2-7: Key codes (6 keys max)

// Modifier bit positions
.equ MOD_LCTRL,    0
.equ MOD_LSHIFT,   1
.equ MOD_LALT,     2
.equ MOD_LGUI,     3
.equ MOD_RCTRL,    4
.equ MOD_RSHIFT,   5
.equ MOD_RALT,     6
.equ MOD_RGUI,     7

// Keyboard state structure
.equ KBD_HID,           0    // HID instance pointer
.equ KBD_MODS,          4    // Current modifiers
.equ KBD_KEYS,          8    // Current keys (6 bytes)
.equ KBD_LEDS,          14   // LED state
.equ KBD_SIZE,          32

// Keymap tables
.section ".rodata"

// US keymap (simplified)
keymap_us:
    // 0x00-0x0F
    .byte 0, 0, 0, 0, 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l'
    // 0x10-0x1F
    .byte 'm', 'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z', '1', '2'
    // 0x20-0x2F
    .byte '3', '4', '5', '6', '7', '8', '9', '0', 10, 27, 8, 9, ' ', '-', '=', '['
    // 0x30-0x3F
    .byte ']', '\\', '#', ';', '\'', '`', ',', '.', '/', 0, 0, 0, 0, 0, 0, 0

// Shifted keymap
keymap_us_shifted:
    // 0x00-0x0F
    .byte 0, 0, 0, 0, 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L'
    // 0x10-0x1F
    .byte 'M', 'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', '!', '@'
    // 0x20-0x2F
    .byte '#', '$', '%', '^', '&', '*', '(', ')', 10, 27, 8, 9, ' ', '_', '+', '{'
    // 0x30-0x3F
    .byte '|', '~', ':', '"', '~', '<', '>', '?', 0, 0, 0, 0, 0, 0, 0, 0

.section ".text"

// ========== KEYBOARD PROBE ==========
// Called by HID driver for HID devices that might be keyboards
.globl kbd_probe
kbd_probe:
    push {r4-r11, lr}
    
    mov r4, r0                          // r4 = HID instance
    
    // Allocate keyboard state
    mov r0, #KBD_SIZE
    bl buddy_alloc
    cmp r0, #0
    beq kbd_probe_fail
    mov r5, r0                          // r5 = keyboard state
    
    // Store HID instance
    str r4, [r5, #KBD_HID]
    
    // Initialize state
    mov r0, #0
    str r0, [r5, #KBD_MODS]
    
    // Register callback with HID driver
    mov r0, r4
    ldr r1, =kbd_input_callback
    mov r2, r5
    bl hid_register_callback
    
    // Set boot protocol (simpler report format)
    ldr r6, [r4, #HID_DEVICE]
    mov r0, r6
    mov r1, #0x21
    mov r2, #HID_REQ_SET_PROTOCOL
    mov r3, #0                          // 0 = boot protocol
    mov r4, #0
    mov r5, #0
    mov r6, #0
    bl usb_control_transfer
    
    mov r0, #0
    pop {r4-r11, pc}

kbd_probe_fail:
    mov r0, #-1
    pop {r4-r11, pc}

// ========== INPUT CALLBACK ==========
// Called by HID driver when new report arrives
// r0 = HID instance, r1 = report buffer, r2 = length
.globl kbd_input_callback
kbd_input_callback:
    push {r4-r11, lr}
    
    mov r4, r0                          // r4 = HID instance
    mov r5, r1                          // r5 = report buffer
    mov r6, r2                          // r6 = length
    ldr r7, [r4, #HID_PRIVATE]          // r7 = keyboard state
    
    // Boot protocol keyboard report is 8 bytes
    cmp r6, #8
    blt kbd_callback_done
    
    // Get modifiers (byte 0)
    ldrb r8, [r5]
    ldr r9, [r7, #KBD_MODS]
    
    // Check for modifier changes
    eor r10, r8, r9
    str r8, [r7, #KBD_MODS]
    
    // Process keys (bytes 2-7)
    add r11, r5, #2
    mov r12, #0
    
key_loop:
    cmp r12, #6
    bge key_loop_done
    
    ldrb r14, [r11, r12]
    cmp r14, #0
    beq next_key
    
    // Translate keycode to ASCII
    mov r0, r14
    ldr r1, [r7, #KBD_MODS]
    bl kbd_translate
    
    // Push to terminal if valid
    cmp r0, #0
    beq next_key
    
    // Echo to terminal
    push {r0}
    mov r0, #1                          // stdout
    mov r1, sp
    mov r2, #1
    mov r7, #0                          // sys_write
    svc 0
    add sp, #4
    
next_key:
    add r12, #1
    b key_loop

key_loop_done:
    // Handle LED updates if needed
    // (Num Lock, Caps Lock, etc.)

kbd_callback_done:
    pop {r4-r11, pc}

// ========== KEY TRANSLATION ==========
// r0 = keycode, r1 = modifiers
// Returns ASCII character or 0
kbd_translate:
    push {lr}
    
    // Check for valid keycode range
    cmp r0, #0x3F
    bhi translate_none
    
    // Check shift modifier
    tst r1, #(1 << MOD_LSHIFT) | (1 << MOD_RSHIFT)
    bne shifted
    
    // Unshifted
    ldr r2, =keymap_us
    ldrb r0, [r2, r0]
    pop {pc}

shifted:
    ldr r2, =keymap_us_shifted
    ldrb r0, [r2, r0]
    pop {pc}

translate_none:
    mov r0, #0
    pop {pc}
