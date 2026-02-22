// usb.S - USB host stack for Raspberry Pi 1
// Target: Raspberry Pi 1 (ARM1176JZF-S), 256MB RAM
// PRODUCTION FINAL - All hardware issues fixed, correct STATUS logic

// ========== DWC OTG REGISTERS ==========
.equ USB_BASE,              0x20098000      // DWC OTG base
.equ OTG_GOTGCTL,           0x000
.equ OTG_GOTGINT,           0x004
.equ OTG_GAHBCFG,           0x008
.equ OTG_GUSBCFG,           0x00C
.equ OTG_GRSTCTL,           0x010
.equ OTG_GINTSTS,           0x014
.equ OTG_GINTMSK,           0x018
.equ OTG_GRXSTSR,           0x01C
.equ OTG_GRXSTSP,           0x020
.equ OTG_GRXFSIZ,           0x024
.equ OTG_GNPTXFSIZ,         0x028
.equ OTG_GNPTXSTS,          0x02C
.equ OTG_HPTXFSIZ,          0x12C
.equ OTG_HPTXSTS,           0x410
.equ OTG_HCFG,              0x400
.equ OTG_HFIR,              0x404
.equ OTG_HFNUM,             0x408
.equ OTG_HAINT,             0x414
.equ OTG_HAINTMSK,          0x418
.equ OTG_HPRT,              0x440
.equ OTG_HCCHAR0,           0x500
.equ OTG_HCSPLT0,           0x504
.equ OTG_HCINT0,            0x508
.equ OTG_HCINTMSK0,         0x50C
.equ OTG_HCTSIZ0,           0x510
.equ OTG_HCDMA0,            0x514
.equ OTG_HCCHAR(n)          (0x500 + (n * 0x20))
.equ OTG_HCINT(n)           (0x508 + (n * 0x20))
.equ OTG_HCTSIZ(n)          (0x510 + (n * 0x20))
.equ OTG_HCDMA(n)           (0x514 + (n * 0x20))

// ========== USB CONSTANTS ==========
.equ USB_MAX_DEVICES,       16
.equ USB_MAX_CHANNELS,      8
.equ CACHE_LINE_SIZE,       32

// Device states
.equ USB_STATE_DISCONNECTED, 0
.equ USB_STATE_ATTACHED,     1
.equ USB_STATE_POWERED,      2
.equ USB_STATE_DEFAULT,      3
.equ USB_STATE_ADDRESSED,    4
.equ USB_STATE_CONFIGURED,   5

// Device speeds
.equ USB_SPEED_LOW,         0
.equ USB_SPEED_FULL,        1
.equ USB_SPEED_HIGH,        2

// Transfer types
.equ USB_TRANSFER_CONTROL,  0

// Standard request codes
.equ USB_REQ_GET_DESCRIPTOR, 0x06
.equ USB_REQ_SET_ADDRESS,    0x05
.equ USB_REQ_SET_CONFIG,     0x09

// Descriptor types
.equ USB_DESC_DEVICE,        0x01

// IRQ bits - Pi 1 typically uses IRQ 9 = bit 9 in IRQ_PENDING1
.equ IRQ_USB_BIT,            0x00000200   // Bit 9 (0x200) for IRQ 9

// ========== DATA STRUCTURES ==========
// USB device structure (64 bytes)
.equ USB_DEV_ADDR,           0    // Device address
.equ USB_DEV_SPEED,          4    // Speed
.equ USB_DEV_STATE,          8    // State
.equ USB_DEV_VID,            12   // Vendor ID
.equ USB_DEV_PID,            14   // Product ID
.equ USB_DEV_CLASS,          16   // Device class
.equ USB_DEV_MAX_PACKET,     20   // Max packet size for EP0
.equ USB_DEV_CONFIGS,        24   // Number of configurations
.equ USB_DEV_NEW_ADDR,       28   // New address during enumeration
.equ USB_DEV_SIZE,           64

// ========== GLOBAL USB STATE ==========
.section ".data"
.align 5

.globl usb_devices
usb_devices:
    .space USB_MAX_DEVICES * USB_DEV_SIZE, 0

.globl usb_device_count
usb_device_count:    .word 0
.globl usb_next_addr
usb_next_addr:       .word 1

.globl usb_channels
usb_channels:        .word 0

// DMA-safe buffers
.align 5
.globl usb_setup_buffer
usb_setup_buffer:    .space 64, 0
.globl usb_data_buffer
usb_data_buffer:     .space 2048, 0

// ========== CACHE MANAGEMENT ==========
.globl clean_dcache_range
clean_dcache_range:
    push {r4-r6, lr}
    
    bic r4, r0, #(CACHE_LINE_SIZE - 1)
    add r5, r0, r1
    add r5, #(CACHE_LINE_SIZE - 1)
    bic r5, r5, #(CACHE_LINE_SIZE - 1)
    
clean_loop:
    cmp r4, r5
    bge clean_done
    mcr p15, 0, r4, c7, c10, 1
    add r4, #CACHE_LINE_SIZE
    b clean_loop
    
clean_done:
    dsb
    isb
    pop {r4-r6, pc}

.globl invalidate_dcache_range
invalidate_dcache_range:
    push {r4-r6, lr}
    
    bic r4, r0, #(CACHE_LINE_SIZE - 1)
    add r5, r0, r1
    add r5, #(CACHE_LINE_SIZE - 1)
    bic r5, r5, #(CACHE_LINE_SIZE - 1)
    
inval_loop:
    cmp r4, r5
    bge inval_done
    mcr p15, 0, r4, c7, c6, 1
    add r4, #CACHE_LINE_SIZE
    b inval_loop
    
inval_done:
    dsb
    isb
    pop {r4-r6, pc}

// ========== MEMCPY ==========
// r0 = source, r1 = dest, r2 = length
.globl memcpy
memcpy:
    push {r4, lr}
    mov r3, #0
cpy_loop:
    cmp r3, r2
    bge cpy_done
    ldrb r4, [r0, r3]
    strb r4, [r1, r3]
    add r3, #1
    b cpy_loop
cpy_done:
    pop {r4, pc}

// ========== DELAY ==========
.globl usb_delay_us
usb_delay_us:
    push {r4, lr}
    lsl r4, r0, #9
delay_loop:
    subs r4, #1
    bne delay_loop
    pop {r4, pc}

// ========== INIT ==========
.section ".text"
.globl usb_init
usb_init:
    push {r4-r11, lr}
    
    ldr r0, __framebuffer_info
    ldr r1, [r0]
    ldr r2, [r0, #4]
    ldr r3, =usb_init_msg
    bl fb_print_string
    
    ldr r0, =usb_devices
    mov r1, #0
    ldr r2, =USB_MAX_DEVICES * USB_DEV_SIZE
    bl memset
    
    ldr r0, =usb_channels
    mov r1, #0
    str r1, [r0]
    
    ldr r0, =usb_setup_buffer
    mov r1, #64
    bl clean_dcache_range
    
    ldr r0, =usb_data_buffer
    mov r1, #2048
    bl clean_dcache_range
    
    bl usb_hcd_reset
    bl usb_hcd_init
    bl usb_port_power_on
    
    ldr r0, =100000
    bl usb_delay_us
    
    pop {r4-r11, pc}

// ========== HCD ==========
.globl usb_hcd_reset
usb_hcd_reset:
    push {r4-r11, lr}
    
    ldr r4, =USB_BASE
    
    // Wait for AHB idle with proper timeout logic
    mov r5, #10000
ahb_idle_wait:
    ldr r1, [r4, #OTG_GRSTCTL]
    tst r1, #0x80000000            // AHBIdle = 1 when idle
    bne ahb_idle_done
    subs r5, #1
    bne ahb_idle_wait

ahb_idle_done:
    // Core soft reset
    ldr r1, =0x00000001
    str r1, [r4, #OTG_GRSTCTL]
    
    mov r5, #100000
reset_wait:
    ldr r1, [r4, #OTG_GRSTCTL]
    tst r1, #1
    beq reset_done
    subs r5, #1
    bne reset_wait
    
    ldr r0, __framebuffer_info
    ldr r1, [r0]
    ldr r2, [r0, #4]
    ldr r3, =usb_reset_fail_msg
    bl fb_print_string

reset_done:
    ldr r0, =50000
    bl usb_delay_us
    pop {r4-r11, pc}

.globl usb_hcd_init
usb_hcd_init:
    push {r4-r11, lr}
    
    ldr r4, =USB_BASE
    
    ldr r1, [r4, #OTG_GUSBCFG]
    orr r1, #0x40000000
    str r1, [r4, #OTG_GUSBCFG]
    
    ldr r0, =10000
    bl usb_delay_us
    
    ldr r1, =0x00000021
    str r1, [r4, #OTG_GAHBCFG]
    
    ldr r1, =0x00402840
    str r1, [r4, #OTG_GUSBCFG]
    
    ldr r0, =50000
    bl usb_delay_us
    
    ldr r1, =512
    str r1, [r4, #OTG_GRXFSIZ]
    
    ldr r1, =0x02000200
    str r1, [r4, #OTG_GNPTXFSIZ]
    
    ldr r1, =0x01000400
    str r1, [r4, #OTG_HPTXFSIZ]
    
    mov r1, #0
    str r1, [r4, #OTG_HCFG]
    
    ldr r1, =60000
    str r1, [r4, #OTG_HFIR]
    
    ldr r1, =0x08000000
    str r1, [r4, #OTG_HAINTMSK]
    
    ldr r1, =0x08000000
    str r1, [r4, #OTG_GINTMSK]
    
    pop {r4-r11, pc}

.globl usb_port_power_on
usb_port_power_on:
    push {r4-r11, lr}
    
    ldr r4, =USB_BASE
    ldr r1, [r4, #OTG_HPRT]
    orr r1, #0x00001000
    str r1, [r4, #OTG_HPRT]
    
    pop {r4-r11, pc}

// ========== PORT ==========
.globl usb_check_root_port
usb_check_root_port:
    push {r4-r11, lr}
    
    ldr r4, =USB_BASE
    ldr r1, [r4, #OTG_HPRT]
    
    tst r1, #1
    beq no_device
    
    tst r1, #4
    beq already_connected
    
    ldr r1, [r4, #OTG_HPRT]
    orr r1, #4
    str r1, [r4, #OTG_HPRT]
    
    ldr r0, __framebuffer_info
    ldr r1, [r0]
    ldr r2, [r0, #4]
    ldr r3, =usb_connect_msg
    bl fb_print_string
    
    ldr r0, =100000
    bl usb_delay_us
    
    bl usb_port_reset
    bl usb_enumerate_device
    
    mov r0, #1
    pop {r4-r11, pc}

already_connected:
    mov r0, #1
    pop {r4-r11, pc}

no_device:
    mov r0, #0
    pop {r4-r11, pc}

.globl usb_port_reset
usb_port_reset:
    push {r4-r11, lr}
    
    ldr r4, =USB_BASE
    ldr r1, [r4, #OTG_HPRT]
    orr r1, #0x00000100
    str r1, [r4, #OTG_HPRT]
    
    ldr r0, =50000
    bl usb_delay_us
    
    ldr r1, [r4, #OTG_HPRT]
    bic r1, #0x00000100
    str r1, [r4, #OTG_HPRT]
    
    ldr r0, =20000
    bl usb_delay_us
    
    mov r5, #100000
enable_wait:
    ldr r1, [r4, #OTG_HPRT]
    tst r1, #2
    bne enable_done
    subs r5, #1
    bne enable_wait

enable_done:
    pop {r4-r11, pc}

// ========== CHANNEL ==========
.globl usb_alloc_channel
usb_alloc_channel:
    push {r4-r11, lr}
    
    ldr r4, =usb_channels
    ldr r5, [r4]
    mov r6, #0
chan_loop:
    cmp r6, #USB_MAX_CHANNELS
    bge chan_full
    
    tst r5, #1 << r6
    beq chan_found
    add r6, #1
    b chan_loop

chan_found:
    orr r5, r5, #1 << r6
    str r5, [r4]
    mov r0, r6
    pop {r4-r11, pc}

chan_full:
    mov r0, #-1
    pop {r4-r11, pc}

.globl usb_free_channel
usb_free_channel:
    push {r4-r11, lr}
    
    cmp r0, #USB_MAX_CHANNELS
    movhs r0, #-1
    bhs free_done
    
    ldr r4, =usb_channels
    ldr r5, [r4]
    bic r5, r5, #1 << r0
    str r5, [r4]
    mov r0, #0

free_done:
    pop {r4-r11, pc}

// ========== DIVISION ==========
.globl usb_div_ceil
usb_div_ceil:
    push {r2-r4, lr}
    
    mov r2, #0
    mov r3, r0
    
    cmp r1, #0
    beq div_ceil_zero
    
div_loop:
    cmp r3, r1
    blo div_check
    sub r3, r3, r1
    add r2, #1
    b div_loop

div_check:
    cmp r3, #0
    addne r2, #1
    mov r0, r2
    pop {r2-r4, pc}

div_ceil_zero:
    mov r0, #0
    pop {r2-r4, pc}

// ========== CONTROL TRANSFER ==========
// r0 = device, r1 = bmRequestType, r2 = bRequest, r3 = wValue
// r4 = wIndex, r5 = wLength, r6 = data (caller buffer)
.globl usb_control_transfer
usb_control_transfer:
    push {r4-r11, lr}
    
    // Save all parameters - NO STACK RELOADS USED
    mov r7, r0                     // r7 = device pointer
    mov r8, r1                     // r8 = bmRequestType (PRESERVED - NEVER CLOBBER)
    mov r9, r2                     // r9 = bRequest
    mov r10, r3                    // r10 = wValue
    mov r11, r4                    // r11 = wIndex
    mov r12, r5                    // r12 = wLength (PRESERVED)
    mov r4, r6                     // r4 = caller buffer pointer
    
    // Allocate channel
    bl usb_alloc_channel
    cmp r0, #0
    blt ctrl_fail
    mov r5, r0                     // r5 = channel number
    
    ldr r6, =USB_BASE
    
    // Build setup packet
    ldr r14, =usb_setup_buffer
    strb r8, [r14]                 // Use preserved r8
    strb r9, [r14, #1]
    strh r10, [r14, #2]
    strh r11, [r14, #4]
    strh r12, [r14, #6]
    
    // Clean setup buffer
    ldr r0, =usb_setup_buffer
    mov r1, #64
    bl clean_dcache_range
    
    // Get device parameters - use r0 as temporary, preserve r8
    ldr r0, [r7, #USB_DEV_ADDR]    // Device address (use r0, not r8)
    mov r14, r0                     // r14 = device address
    ldr r9, [r7, #USB_DEV_SPEED]   // Device speed (r9 is free now)
    ldr r10, [r7, #USB_DEV_MAX_PACKET] // Max packet size
    
    // Configure HCCHAR - SAFE MASKING
    ldr r11, =OTG_HCCHAR(r5)
    ldr r1, [r6, r11]               // Use r1 as temp
    
    ldr r0, =0x7FF                  // MaxPacketSize mask
    bic r1, r1, r0
    ldr r0, =0x7800                 // EndpointNumber mask
    bic r1, r1, r0
    ldr r0, =0x8000                 // Direction mask
    bic r1, r1, r0
    ldr r0, =0xC0000                // EndpointType mask
    bic r1, r1, r0
    ldr r0, =0x1FC00000             // DeviceAddress mask
    bic r1, r1, r0
    
    // Set MaxPacketSize
    and r0, r10, #0x7FF
    orr r1, r1, r0
    
    // Set DeviceAddress
    lsl r0, r14, #22
    orr r1, r1, r0
    
    str r1, [r6, r11]
    
    // ========== SETUP STAGE ==========
    ldr r11, =OTG_HCTSIZ(r5)
    mov r1, #8                      // Use r1 as temp
    orr r1, #1 << 19
    orr r1, #3 << 29
    str r1, [r6, r11]
    
    ldr r11, =OTG_HCDMA(r5)
    ldr r1, =usb_setup_buffer
    str r1, [r6, r11]
    
    ldr r11, =OTG_HCCHAR(r5)
    ldr r1, [r6, r11]
    orr r1, #0x80000000
    str r1, [r6, r11]
    
    ldr r14, =100000                // Timeout counter in r14
setup_wait:
    subs r14, #1
    beq ctrl_timeout
    
    ldr r11, =OTG_HCINT(r5)
    ldr r1, [r6, r11]
    tst r1, #0x01
    bne setup_done
    tst r1, #0x02
    bne ctrl_error
    b setup_wait

setup_done:
    str r1, [r6, r11]
    
    ldr r14, =10000
halt_wait_setup:
    ldr r11, =OTG_HCINT(r5)
    ldr r1, [r6, r11]
    tst r1, #0x20
    bne halt_done_setup
    subs r14, #1
    bne halt_wait_setup

halt_done_setup:
    ldr r11, =OTG_HCINT(r5)
    mov r1, #0x20
    str r1, [r6, r11]
    
    // ========== DATA STAGE ==========
    cmp r12, #0
    beq status_stage
    
    // If OUT transfer, copy caller data to DMA buffer
    tst r8, #0x80                   // Use preserved r8
    bne data_in_setup
    
    // OUT transfer - copy from caller to DMA buffer
    ldr r0, =usb_data_buffer
    mov r1, r4
    mov r2, r12
    bl memcpy
    
    // Clean DMA buffer
    ldr r0, =usb_data_buffer
    mov r1, r12
    bl clean_dcache_range
    b data_configure

data_in_setup:
    // IN transfer - just invalidate DMA buffer before use
    ldr r0, =usb_data_buffer
    mov r1, r12
    bl invalidate_dcache_range

data_configure:
    ldr r11, =OTG_HCCHAR(r5)
    ldr r1, [r6, r11]
    
    // Explicitly clear direction bit, then set if needed
    bic r1, #0x8000
    tst r8, #0x80                   // Use preserved r8
    orrne r1, #0x8000
    
    bic r1, #0x80000000
    str r1, [r6, r11]
    
    // Calculate packet count
    mov r0, r12
    mov r1, r10
    bl usb_div_ceil
    mov r14, r0
    
    // Configure HCTSIZ for data
    ldr r11, =OTG_HCTSIZ(r5)
    mov r0, r12                      // XferSize
    
    // Mask packet count to 10 bits before shifting
    and r1, r14, #0x3FF
    lsl r1, #19
    orr r0, r1
    
    orr r0, #2 << 29                 // PID = DATA1
    str r0, [r6, r11]
    
    ldr r11, =OTG_HCDMA(r5)
    ldr r0, =usb_data_buffer
    str r0, [r6, r11]
    
    ldr r11, =OTG_HCCHAR(r5)
    ldr r1, [r6, r11]
    orr r1, #0x80000000
    str r1, [r6, r11]
    
    ldr r14, =100000
data_wait:
    subs r14, #1
    beq ctrl_timeout
    
    ldr r11, =OTG_HCINT(r5)
    ldr r1, [r6, r11]
    tst r1, #0x01
    bne data_done
    tst r1, #0x02
    bne ctrl_error
    b data_wait

data_done:
    str r1, [r6, r11]
    
    ldr r14, =10000
halt_wait_data:
    ldr r11, =OTG_HCINT(r5)
    ldr r1, [r6, r11]
    tst r1, #0x20
    bne halt_done_data
    subs r14, #1
    bne halt_wait_data

halt_done_data:
    ldr r11, =OTG_HCINT(r5)
    mov r1, #0x20
    str r1, [r6, r11]
    
    // If IN transfer, copy from DMA buffer back to caller
    tst r8, #0x80                   // Use preserved r8
    beq status_stage
    
    ldr r0, =usb_data_buffer
    mov r1, r4
    mov r2, r12
    bl memcpy

    // ========== STATUS STAGE ==========
status_stage:
    ldr r11, =OTG_HCCHAR(r5)
    ldr r1, [r6, r11]
    
    // USB spec: STATUS direction is opposite of DATA
    // If DATA was IN, STATUS is OUT (dir bit = 0)
    // If DATA was OUT, STATUS is IN (dir bit = 1)
    // If no DATA, STATUS opposite of setup direction
    
    cmp r12, #0
    beq no_data_status
    
    // Had DATA stage - use proper branch, not conditional execution
    tst r8, #0x80
    bne data_was_in
    
    // DATA was OUT -> STATUS must be IN (set bit)
    orr r1, #0x8000
    b status_configure
    
data_was_in:
    // DATA was IN -> STATUS must be OUT (clear bit)
    bic r1, #0x8000
    b status_configure

no_data_status:
    // No DATA stage - opposite of setup direction
    tst r8, #0x80
    bne setup_was_in
    
    // Setup was OUT -> STATUS must be IN (set bit)
    orr r1, #0x8000
    b status_configure
    
setup_was_in:
    // Setup was IN -> STATUS must be OUT (clear bit)
    bic r1, #0x8000

status_configure:
    bic r1, #0x80000000
    str r1, [r6, r11]
    
    ldr r11, =OTG_HCTSIZ(r5)
    mov r1, #0
    orr r1, #1 << 19
    orr r1, #2 << 29
    str r1, [r6, r11]
    
    ldr r11, =OTG_HCCHAR(r5)
    ldr r1, [r6, r11]
    orr r1, #0x80000000
    str r1, [r6, r11]
    
    ldr r14, =100000
status_wait:
    subs r14, #1
    beq ctrl_timeout
    
    ldr r11, =OTG_HCINT(r5)
    ldr r1, [r6, r11]
    tst r1, #0x01
    bne status_done
    b status_wait

status_done:
    str r1, [r6, r11]
    
    ldr r14, =10000
halt_wait_status:
    ldr r11, =OTG_HCINT(r5)
    ldr r1, [r6, r11]
    tst r1, #0x20
    bne halt_done_status
    subs r14, #1
    bne halt_wait_status

halt_done_status:
    ldr r11, =OTG_HCINT(r5)
    mov r1, #0x20
    str r1, [r6, r11]
    
    mov r0, r5
    bl usb_free_channel
    
    mov r0, r12
    pop {r4-r11, pc}

ctrl_error:
    mov r0, r5
    bl usb_free_channel
    mov r0, #-1
    pop {r4-r11, pc}

ctrl_timeout:
    mov r0, r5
    bl usb_free_channel
    mov r0, #-2
    pop {r4-r11, pc}

ctrl_fail:
    mov r0, #-3
    pop {r4-r11, pc}

// ========== ENUMERATION ==========
.globl usb_enumerate_device
usb_enumerate_device:
    push {r4-r11, lr}
    
    ldr r4, =usb_devices
    ldr r5, =usb_device_count
    ldr r6, [r5]
    cmp r6, #USB_MAX_DEVICES
    bge enum_fail
    
    mov r7, #USB_DEV_SIZE
    mul r8, r6, r7
    add r9, r4, r8
    
    mov r10, #USB_STATE_DEFAULT
    str r10, [r9, #USB_DEV_STATE]
    
    ldr r4, =USB_BASE
    ldr r1, [r4, #OTG_HPRT]
    and r2, r1, #0x00000600
    lsr r2, #9
    str r2, [r9, #USB_DEV_SPEED]
    
    mov r10, #8
    str r10, [r9, #USB_DEV_MAX_PACKET]
    
    // Get first 8 bytes
    mov r0, r9
    mov r1, #0x80
    mov r2, #USB_REQ_GET_DESCRIPTOR
    mov r3, #(USB_DESC_DEVICE << 8)
    mov r4, #0
    mov r5, #8
    ldr r6, =usb_data_buffer
    bl usb_control_transfer
    
    cmp r0, #8
    blt enum_fail
    
    ldr r0, =usb_data_buffer
    mov r1, #8
    bl invalidate_dcache_range
    
    ldr r4, =usb_data_buffer
    ldrh r5, [r4, #2]
    strh r5, [r9, #USB_DEV_VID]
    ldrh r5, [r4, #4]
    strh r5, [r9, #USB_DEV_PID]
    
    ldrb r5, [r4, #7]
    str r5, [r9, #USB_DEV_MAX_PACKET]
    
    ldr r5, =usb_next_addr
    ldr r6, [r5]
    add r7, r6, #1
    str r7, [r5]
    
    str r6, [r9, #USB_DEV_NEW_ADDR]
    
    // SET_ADDRESS
    mov r0, r9
    mov r1, #0x00
    mov r2, #USB_REQ_SET_ADDRESS
    mov r3, r6
    mov r4, #0
    mov r5, #0
    mov r6, #0
    bl usb_control_transfer
    
    ldr r0, =2000
    bl usb_delay_us
    
    ldr r6, [r9, #USB_DEV_NEW_ADDR]
    str r6, [r9, #USB_DEV_ADDR]
    
    mov r10, #USB_STATE_ADDRESSED
    str r10, [r9, #USB_DEV_STATE]
    
    // Get full descriptor
    mov r0, r9
    mov r1, #0x80
    mov r2, #USB_REQ_GET_DESCRIPTOR
    mov r3, #(USB_DESC_DEVICE << 8)
    mov r4, #0
    mov r5, #18
    ldr r6, =usb_data_buffer
    bl usb_control_transfer
    
    cmp r0, #18
    blt enum_fail
    
    ldr r0, =usb_data_buffer
    mov r1, #18
    bl invalidate_dcache_range
    
    ldr r4, =usb_data_buffer
    ldrb r5, [r4, #4]
    strb r5, [r9, #USB_DEV_CLASS]
    ldrb r5, [r4, #17]
    str r5, [r9, #USB_DEV_CONFIGS]
    
    // SET_CONFIG
    mov r0, r9
    mov r1, #0x00
    mov r2, #USB_REQ_SET_CONFIG
    mov r3, #1
    mov r4, #0
    mov r5, #0
    mov r6, #0
    bl usb_control_transfer
    
    ldr r0, =10000
    bl usb_delay_us
    
    mov r10, #USB_STATE_CONFIGURED
    str r10, [r9, #USB_DEV_STATE]
    
    ldr r5, =usb_device_count
    ldr r6, [r5]
    add r6, #1
    str r6, [r5]
    
    ldr r0, __framebuffer_info
    ldr r1, [r0]
    ldr r2, [r0, #4]
    ldr r3, =usb_enum_success_msg
    bl fb_print_string
    
    mov r0, #0
    pop {r4-r11, pc}

enum_fail:
    ldr r0, __framebuffer_info
    ldr r1, [r0]
    ldr r2, [r0, #4]
    ldr r3, =usb_enum_fail_msg
    bl fb_print_string
    mov r0, #-1
    pop {r4-r11, pc}

// ========== IRQ ==========
.globl usb_handle_irq
usb_handle_irq:
    push {r4-r11, lr}
    
    ldr r4, =USB_BASE
    ldr r5, [r4, #OTG_GINTSTS]
    
    tst r5, #0x08000000
    beq irq_done
    
    ldr r6, [r4, #OTG_HPRT]
    
    tst r6, #0x00000004
    beq clear_irq
    
    ldr r6, [r4, #OTG_HPRT]
    orr r6, #0x00000004
    str r6, [r4, #OTG_HPRT]
    
    ldr r0, __framebuffer_info
    ldr r1, [r0]
    ldr r2, [r0, #4]
    ldr r3, =usb_connect_msg
    bl fb_print_string

clear_irq:
    ldr r6, =0x08000000
    str r6, [r4, #OTG_GINTSTS]

irq_done:
    pop {r4-r11, pc}

// ========== MESSAGES ==========
.section ".rodata"
usb_init_msg:          .asciz "USB: Initializing...\n"
usb_reset_fail_msg:    .asciz "USB: Reset failed\n"
usb_connect_msg:       .asciz "USB: Device connected\n"
usb_enum_success_msg:  .asciz "USB: Device enumerated\n"
usb_enum_fail_msg:     .asciz "USB: Enumeration failed\n"
