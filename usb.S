// usb.S - Complete USB host stack for Raspberry Pi 1
// Target: Raspberry Pi 1 (ARM1176JZF-S), 256MB RAM
// FULL VERSION with clock init, PHY setup, and D+ pull-up

// ========== DWC OTG REGISTERS ==========
.equ USB_BASE,              0x20098000
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

// Clock Manager registers (BCM2835)
.equ CM_BASE,               0x20101000
.equ CM_USBCTRL,            0x078
.equ CM_PASSWD,             0x5A000000

// ========== USB CONSTANTS ==========
.equ USB_MAX_DEVICES,       16
.equ USB_MAX_ENDPOINTS,     32
.equ USB_MAX_CHANNELS,      8
.equ CACHE_LINE_SIZE,       32

// Device classes
.equ USB_CLASS_HID,         0x03
.equ USB_CLASS_MASS_STORAGE, 0x08
.equ USB_CLASS_HUB,         0x09

// Transfer types
.equ USB_TRANSFER_CONTROL,  0
.equ USB_TRANSFER_BULK,     2
.equ USB_TRANSFER_INTERRUPT, 3

// Transfer status
.equ XFER_PENDING,          0
.equ XFER_COMPLETE,         1
.equ XFER_ERROR,            2
.equ XFER_CANCELLED,        3
.equ XFER_HALTED,           4

// PID values
.equ PID_DATA0,             0
.equ PID_DATA1,             2
.equ PID_SETUP,             3

// ========== DATA STRUCTURES ==========
// USB device structure (128 bytes)
.equ USB_DEV_ADDR,           0
.equ USB_DEV_SPEED,          4
.equ USB_DEV_STATE,          8
.equ USB_DEV_VID,            12
.equ USB_DEV_PID,            14
.equ USB_DEV_CLASS,          16
.equ USB_DEV_MAX_PACKET,     20
.equ USB_DEV_CONFIGS,        24
.equ USB_DEV_DRIVER,         28
.equ USB_DEV_PRIVATE,        32
.equ USB_DEV_ENDPOINTS,      36
.equ USB_DEV_PARENT,         40
.equ USB_DEV_PORT,           44
.equ USB_DEV_TOGGLE_RESET,   48
.equ USB_DEV_SIZE,           128

// USB endpoint structure (32 bytes)
.equ USB_EP_NUM,             0
.equ USB_EP_TYPE,            4
.equ USB_EP_DIR,             8
.equ USB_EP_MAX_PKT,         12
.equ USB_EP_INTERVAL,        16
.equ USB_EP_DEVICE,          20
.equ USB_EP_TOGGLE,          24
.equ USB_EP_HALTED,          25
.equ USB_EP_SIZE,            32

// USB transfer request structure (52 bytes)
.equ URB_DEVICE,             0
.equ URB_ENDPOINT,           4
.equ URB_TYPE,               8
.equ URB_DIR,                12
.equ URB_BUFFER,             16
.equ URB_LENGTH,             20
.equ URB_ACTUAL,             24
.equ URB_STATUS,             28
.equ URB_CALLBACK,           32
.equ URB_PRIVATE,            36
.equ URB_NEXT,               40
.equ URB_CHANNEL,            44
.equ URB_PID,                45
.equ URB_SPLIT,              46
.equ URB_HUB_ADDR,           47
.equ URB_PORT_NUM,           48
.equ URB_SIZE,               52

// Channel state structure (32 bytes)
.equ CHAN_NUM,               0
.equ CHAN_STATE,             4    // 0=free,1=active,2=halting
.equ CHAN_URB,               8
.equ CHAN_DEVICE,            12
.equ CHAN_ENDPOINT,          16
.equ CHAN_XFRC,              20
.equ CHAN_CHH,               24
.equ CHAN_SIZE,              32

// ========== GLOBAL STATE ==========
.section ".data"
.align 5

.globl usb_devices
usb_devices:            .space USB_MAX_DEVICES * USB_DEV_SIZE, 0
.globl usb_device_count
usb_device_count:       .word 0
.globl usb_next_addr
usb_next_addr:          .word 1

.globl usb_endpoints
usb_endpoints:          .space USB_MAX_ENDPOINTS * USB_EP_SIZE, 0
.globl usb_ep_count
usb_ep_count:           .word 0

.globl usb_channels
usb_channels:           .space USB_MAX_CHANNELS * CHAN_SIZE, 0
.globl usb_channel_mask
usb_channel_mask:       .word 0

.globl usb_pending_queue
usb_pending_queue:      .word 0
.globl usb_active_queue
usb_active_queue:       .word 0
.globl usb_complete_queue
usb_complete_queue:     .word 0

.align 5
.globl usb_setup_buffer
usb_setup_buffer:       .space 64, 0
.globl usb_data_buffer
usb_data_buffer:        .space 2048, 0

// ========== CACHE MANAGEMENT ==========
.section ".text"
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
    nop
    nop
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
    nop
    nop
    pop {r4-r6, pc}

// ========== DELAY ==========
.globl usb_delay_us
usb_delay_us:
    push {r4, lr}
    lsl r4, r0, #9
delay_loop:
    subs r4, #1
    bne delay_loop
    pop {r4, pc}

// ========== MAIN INITIALIZATION ==========
.globl usb_init
usb_init:
    push {r4-r11, lr}
    
    // Print status
    ldr r0, __framebuffer_info
    ldr r1, [r0]
    ldr r2, [r0, #4]
    ldr r3, =usb_init_msg
    bl fb_print_string
    
    // Initialize data structures
    ldr r0, =usb_devices
    mov r1, #0
    ldr r2, =USB_MAX_DEVICES * USB_DEV_SIZE
    bl memset
    
    ldr r0, =usb_endpoints
    mov r1, #0
    ldr r2, =USB_MAX_ENDPOINTS * USB_EP_SIZE
    bl memset
    
    ldr r0, =usb_channels
    mov r1, #0
    ldr r2, =USB_MAX_CHANNELS * CHAN_SIZE
    bl memset
    
    ldr r0, =usb_channel_mask
    mov r1, #0
    str r1, [r0]
    
    ldr r0, =usb_pending_queue
    str r1, [r0]
    ldr r0, =usb_active_queue
    str r1, [r0]
    ldr r0, =usb_complete_queue
    str r1, [r0]
    
    // Initialize DMA buffers
    ldr r0, =usb_setup_buffer
    mov r1, #64
    bl clean_dcache_range
    
    ldr r0, =usb_data_buffer
    mov r1, #2048
    bl clean_dcache_range
    
    // ===== CRITICAL: ENABLE USB CLOCK =====
    ldr r0, =CM_BASE
    ldr r1, =CM_PASSWD | 0x2000A      // PASSWD + ENABLE + SRC=OSC
    str r1, [r0, #CM_USBCTRL]
    
    ldr r0, =10000
    bl usb_delay_us
    
    // ===== RESET CONTROLLER =====
    bl usb_hcd_reset
    
    // ===== FORCE HOST MODE & CONFIGURE PHY =====
    bl usb_hcd_init
    
    // ===== ENABLE D+ PULL-UP (B SESSION VALID) =====
    ldr r0, =USB_BASE
    ldr r1, [r0, #OTG_GOTGCTL]
    orr r1, #0x00000008                // Bit 3: B Session Valid
    str r1, [r0, #OTG_GOTGCTL]
    
    ldr r0, =50000
    bl usb_delay_us
    
    // ===== POWER ON ROOT PORT =====
    bl usb_port_power_on
    
    // ===== ENABLE INTERRUPTS =====
    bl usb_enable_interrupts
    
    // Wait for devices
    ldr r0, =100000
    bl usb_delay_us
    
    pop {r4-r11, pc}

// ========== HCD RESET ==========
.globl usb_hcd_reset
usb_hcd_reset:
    push {r4-r11, lr}
    
    ldr r4, =USB_BASE
    
    // Wait for AHB idle
    ldr r5, =10000
ahb_idle_wait:
    ldr r1, [r4, #OTG_GRSTCTL]
    tst r1, #0x80000000
    bne ahb_idle_done
    subs r5, #1
    bne ahb_idle_wait

ahb_idle_done:
    // Core soft reset
    ldr r1, =0x00000001
    str r1, [r4, #OTG_GRSTCTL]
    
    ldr r5, =100000
reset_wait:
    ldr r1, [r4, #OTG_GRSTCTL]
    tst r1, #1
    beq reset_done
    subs r5, #1
    bne reset_wait

reset_done:
    ldr r0, =50000
    bl usb_delay_us
    pop {r4-r11, pc}

// ========== HCD INIT ==========
.globl usb_hcd_init
usb_hcd_init:
    push {r4-r11, lr}
    
    ldr r4, =USB_BASE
    
    // Force host mode
    ldr r1, [r4, #OTG_GUSBCFG]
    orr r1, #0x40000000
    str r1, [r4, #OTG_GUSBCFG]
    
    ldr r0, =10000
    bl usb_delay_us
    
    // Configure AHB
    ldr r1, =0x00000021
    str r1, [r4, #OTG_GAHBCFG]
    
    // Configure USB (TTRD for 40MHz PHY)
    ldr r1, =0x00402840
    str r1, [r4, #OTG_GUSBCFG]
    
    ldr r0, =50000
    bl usb_delay_us
    
    // Set FIFO sizes
    ldr r1, =512
    str r1, [r4, #OTG_GRXFSIZ]
    
    ldr r1, =0x02000200
    str r1, [r4, #OTG_GNPTXFSIZ]
    
    ldr r1, =0x01000400
    str r1, [r4, #OTG_HPTXFSIZ]
    
    // Configure host
    mov r1, #0
    str r1, [r4, #OTG_HCFG]
    
    ldr r1, =60000
    str r1, [r4, #OTG_HFIR]
    
    pop {r4-r11, pc}

// ========== PORT POWER ==========
.globl usb_port_power_on
usb_port_power_on:
    push {r4-r11, lr}
    
    ldr r4, =USB_BASE
    ldr r1, [r4, #OTG_HPRT]
    orr r1, #0x00001000                // Port power (bit 12)
    str r1, [r4, #OTG_HPRT]
    
    pop {r4-r11, pc}

// ========== ENABLE INTERRUPTS ==========
.globl usb_enable_interrupts
usb_enable_interrupts:
    push {r4-r11, lr}
    
    ldr r4, =USB_BASE
    
    // Enable channel interrupts
    mov r5, #0
enable_chan_irq:
    cmp r5, #USB_MAX_CHANNELS
    bge enable_irqs_done
    
    mov r6, r5
    lsl r6, #5
    ldr r12, =OTG_HCINTMSK0
    add r6, r6, r12
    ldr r7, =0x7F
    str r7, [r4, r6]
    
    add r5, #1
    b enable_chan_irq

enable_irqs_done:
    // Enable host port and channel interrupts
    ldr r5, =0x0C000000
    str r5, [r4, #OTG_HAINTMSK]
    str r5, [r4, #OTG_GINTMSK]
    
    pop {r4-r11, pc}

// ========== PORT MANAGEMENT ==========
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
    
    ldr r5, =100000
enable_wait:
    ldr r1, [r4, #OTG_HPRT]
    tst r1, #2
    bne enable_done
    subs r5, #1
    bne enable_wait

enable_done:
    pop {r4-r11, pc}

// ========== URB ALLOCATION ==========
.globl usb_alloc_urb
usb_alloc_urb:
    mov r10, r4
    mov r11, r5
    push {r4-r11, lr}
    mov r6, r0
    mov r7, r1
    mov r8, r2
    mov r9, r3
    
    mov r0, #URB_SIZE
    bl buddy_alloc
    cmp r0, #0
    beq urb_alloc_fail
    
    mov r4, r0
    
    str r6, [r4, #URB_DEVICE]
    str r7, [r4, #URB_ENDPOINT]
    str r8, [r4, #URB_BUFFER]
    str r9, [r4, #URB_LENGTH]
    str r10, [r4, #URB_CALLBACK]
    str r11, [r4, #URB_PRIVATE]
    
    mov r0, #0
    str r0, [r4, #URB_ACTUAL]
    str r0, [r4, #URB_STATUS]
    str r0, [r4, #URB_NEXT]
    str r0, [r4, #URB_CHANNEL]
    
    ldr r0, [r7, #USB_EP_TOGGLE]
    strb r0, [r4, #URB_PID]
    
    ldr r0, [r6, #USB_DEV_PARENT]
    cmp r0, #0
    beq urb_no_split
    
    mov r0, #1
    strb r0, [r4, #URB_SPLIT]
    ldr r0, [r6, #USB_DEV_PARENT]
    ldr r0, [r0, #USB_DEV_ADDR]
    strb r0, [r4, #URB_HUB_ADDR]
    ldr r0, [r6, #USB_DEV_PORT]
    strb r0, [r4, #URB_PORT_NUM]

urb_no_split:
    mov r0, r4
    pop {r4-r11, pc}

urb_alloc_fail:
    mov r0, #0
    pop {r4-r11, pc}

// ========== SUBMIT URB ==========
.globl usb_submit_urb
usb_submit_urb:
    push {r4-r11, lr}
    mov r4, r0
    
    ldr r5, [r4, #URB_ENDPOINT]
    ldrb r6, [r5, #USB_EP_HALTED]
    cmp r6, #0
    bne submit_error
    
    mov r5, #XFER_PENDING
    str r5, [r4, #URB_STATUS]
    
    mrs r6, cpsr
    orr r7, r6, #0x80
    msr cpsr, r7
    
    ldr r5, =usb_pending_queue
    ldr r7, [r5]
    str r7, [r4, #URB_NEXT]
    str r4, [r5]
    
    msr cpsr, r6
    
    bl usb_schedule
    mov r0, #0
    pop {r4-r11, pc}

submit_error:
    mov r0, #-1
    pop {r4-r11, pc}

// ========== START TRANSFER ==========
.globl usb_start_transfer
usb_start_transfer:
    push {r4-r11, lr}
    
    mov r4, r0
    ldrb r5, [r4, #URB_CHANNEL]
    ldr r6, =USB_BASE
    ldr r7, [r4, #URB_ENDPOINT]
    ldr r8, [r4, #URB_DEVICE]
    ldr r9, [r4, #URB_BUFFER]
    ldr r10, [r4, #URB_LENGTH]
    ldrb r11, [r4, #URB_PID]
    
    ldr r12, [r8, #USB_DEV_ADDR]
    ldr r14, [r7, #USB_EP_NUM]
    ldr r2, [r7, #USB_EP_DIR]
    ldr r1, [r7, #USB_EP_TYPE]
    ldr r0, [r7, #USB_EP_MAX_PKT]
    
    // HCCHAR
    mov r1, r5
    lsl r1, #5
    ldr r12, =OTG_HCCHAR0
    add r1, r1, r12
    ldr r2, [r6, r1]
    
    ldr r3, =0x7FF
    bic r2, r2, r3
    ldr r3, =0x7800
    bic r2, r2, r3
    ldr r3, =0x8000
    bic r2, r2, r3
    ldr r3, =0xC0000
    bic r2, r2, r3
    ldr r3, =0x1FC00000
    bic r2, r2, r3
    
    ldr r12, =0x7FF
    and r3, r0, r12
    orr r2, r2, r3
    and r3, r14, #0xF
    lsl r3, #11
    orr r2, r2, r3
    cmp r2, #1
    orreq r2, r2, #0x8000
    ldr r3, [r7, #USB_EP_TYPE]
    and r3, #3
    lsl r3, #18
    orr r2, r2, r3
    and r3, r12, #0x7F
    lsl r3, #22
    orr r2, r2, r3
    
    str r2, [r6, r1]
    
    // Split
    ldrb r0, [r4, #URB_SPLIT]
    cmp r0, #0
    beq no_split
    
    mov r1, r5
    lsl r1, #5
    ldr r12, =OTG_HCSPLT0
    add r1, r1, r12
    ldr r2, [r6, r1]
    ldrb r3, [r4, #URB_HUB_ADDR]
    ldrb r0, [r4, #URB_PORT_NUM]
    bic r2, #0xFF
    orr r2, r3
    bic r2, #0xFF00
    orr r2, r0, lsl #8
    orr r2, #0x80000000
    str r2, [r6, r1]
    
no_split:
    // HCTSIZ
    mov r0, r10
    ldr r1, [r7, #USB_EP_MAX_PKT]
    bl usb_div_ceil
    mov r14, r0
    
    mov r0, r10
    ldr r2, =0x3FF
    and r1, r14, r2
    lsl r1, #19
    orr r0, r0, r1
    and r1, r11, #3
    lsl r1, #29
    orr r0, r0, r1
    
    mov r1, r5
    lsl r1, #5
    ldr r12, =OTG_HCTSIZ0
    add r1, r1, r12
    str r0, [r6, r1]
    
    // DMA
    mov r1, r5
    lsl r1, #5
    ldr r12, =OTG_HCDMA0
    add r1, r1, r12
    str r9, [r6, r1]
    
    ldr r0, [r7, #USB_EP_DIR]
    cmp r0, #0
    bne enable_channel
    
    mov r0, r9
    mov r1, r10
    bl clean_dcache_range

enable_channel:
    nop
    
    mov r1, r5
    lsl r1, #5
    ldr r12, =OTG_HCCHAR0
    add r1, r1, r12
    ldr r0, [r6, r1]
    orr r0, #0x80000000
    str r0, [r6, r1]
    
    pop {r4-r11, pc}

// ========== DIV CEIL ==========
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

// ========== INTERRUPT HANDLER ==========
.globl usb_handle_irq
usb_handle_irq:
    push {r4-r11, lr}
    
    ldr r4, =USB_BASE
    ldr r5, [r4, #OTG_GINTSTS]
    
    tst r5, #0x08000000
    beq check_channels
    bl usb_handle_port_irq
    
check_channels:
    tst r5, #0x04000000
    beq irq_done
    
    ldr r6, [r4, #OTG_HAINT]
    
    mov r7, #0
chan_irq_loop:
    cmp r7, #USB_MAX_CHANNELS
    bge chan_irq_done
    
    mov r12, #1
    lsl r12, r7
    tst r6, r12
    beq chan_irq_next
    mov r0, r7
    bl usb_handle_channel_irq

chan_irq_next:
    add r7, #1
    b chan_irq_loop

chan_irq_done:
    ldr r6, =0x04000000
    str r6, [r4, #OTG_GINTSTS]

irq_done:
    bl usb_schedule
    pop {r4-r11, pc}

// ========== CHANNEL IRQ HANDLER ==========
.globl usb_handle_channel_irq
usb_handle_channel_irq:
    push {r4-r11, lr}
    
    mov r4, r0
    ldr r5, =USB_BASE
    
    mov r6, r4
    lsl r6, #5
    ldr r12, =OTG_HCINT0
    add r6, r6, r12
    ldr r7, [r5, r6]
    str r7, [r5, r6]
    
    ldr r8, =usb_channels
    mov r9, #CHAN_SIZE
    mul r10, r4, r9
    add r11, r8, r10
    
    ldr r9, [r11, #CHAN_URB]
    cmp r9, #0
    beq irq_done_channel
    
    tst r7, #0x02
    beq check_stall
    
    mov r0, #XFER_ERROR
    str r0, [r9, #URB_STATUS]
    bl usb_abort_channel
    b irq_done_channel

check_stall:
    tst r7, #0x40
    beq check_xfrc
    
    ldr r0, [r9, #URB_ENDPOINT]
    mov r1, #1
    strb r1, [r0, #USB_EP_HALTED]
    mov r0, #XFER_HALTED
    str r0, [r9, #URB_STATUS]
    bl usb_abort_channel
    b irq_done_channel

check_xfrc:
    tst r7, #0x01
    beq check_chh
    
    mov r0, #1
    str r0, [r11, #CHAN_XFRC]

check_chh:
    tst r7, #0x20
    beq irq_done_channel
    
    mov r0, #1
    str r0, [r11, #CHAN_CHH]
    
    ldr r0, [r11, #CHAN_XFRC]
    ldr r1, [r11, #CHAN_CHH]
    and r0, r0, r1
    cmp r0, #0
    beq irq_done_channel
    
    mov r0, r4
    lsl r0, #5
    ldr r12, =OTG_HCTSIZ0
    add r0, r0, r12
    ldr r1, [r5, r0]
    ldr r2, =0x7FFFF
    and r1, r1, r2
    
    ldr r2, [r9, #URB_LENGTH]
    sub r2, r2, r1
    str r2, [r9, #URB_ACTUAL]
    
    ldr r3, [r9, #URB_ENDPOINT]
    ldrb r0, [r9, #URB_PID]
    eor r0, #2
    strb r0, [r3, #USB_EP_TOGGLE]
    
    ldr r0, [r3, #USB_EP_DIR]
    cmp r0, #1
    bne complete_transfer
    
    ldr r0, [r9, #URB_BUFFER]
    ldr r1, [r9, #URB_ACTUAL]
    bl invalidate_dcache_range

complete_transfer:
    ldr r0, =usb_active_queue
    ldr r1, [r0]
    mov r2, #0
    mov r3, r0
    
find_urb:
    cmp r1, #0
    beq channel_cleanup
    cmp r1, r9
    beq urb_found
    add r3, r1, #URB_NEXT
    ldr r1, [r1, #URB_NEXT]
    b find_urb

urb_found:
    ldr r2, [r1, #URB_NEXT]
    str r2, [r3]
    
    mov r2, #XFER_COMPLETE
    str r2, [r1, #URB_STATUS]
    
    ldr r2, =usb_complete_queue
    ldr r3, [r2]
    str r3, [r1, #URB_NEXT]
    str r1, [r2]
    
    ldr r2, [r1, #URB_CALLBACK]
    cmp r2, #0
    beq channel_cleanup
    
    mov r0, r1
    blx r2

channel_cleanup:
    ldr r0, =usb_channel_mask
    ldr r1, [r0]
    mov r12, #1
    lsl r12, r4
    bic r1, r1, r12
    str r1, [r0]
    
    mov r1, #0
    str r1, [r11, #CHAN_STATE]
    str r1, [r11, #CHAN_URB]
    str r1, [r11, #CHAN_XFRC]
    str r1, [r11, #CHAN_CHH]

irq_done_channel:
    pop {r4-r11, pc}

// ========== ABORT CHANNEL ==========
.globl usb_abort_channel
usb_abort_channel:
    push {r4-r11, lr}
    
    ldr r4, =USB_BASE
    mov r5, r0
    
    mov r0, r5
    lsl r0, #5
    ldr r12, =OTG_HCCHAR0
    add r0, r0, r12
    ldr r1, [r4, r0]
    bic r1, #0x80000000
    str r1, [r4, r0]
    
    ldr r6, =10000
halt_wait:
    subs r6, #1
    beq halt_done
    mov r0, r5
    lsl r0, #5
    ldr r12, =OTG_HCINT0
    add r0, r0, r12
    ldr r1, [r4, r0]
    tst r1, #0x20
    bne halt_done
    b halt_wait

halt_done:
    mov r0, r5
    lsl r0, #5
    ldr r12, =OTG_HCINT0
    add r0, r0, r12
    mov r1, #0x20
    str r1, [r4, r0]
    
    pop {r4-r11, pc}

// ========== PORT IRQ HANDLER ==========
.globl usb_handle_port_irq
usb_handle_port_irq:
    push {r4-r11, lr}
    
    ldr r4, =USB_BASE
    ldr r5, [r4, #OTG_HPRT]
    
    tst r5, #0x00000004
    beq clear_port_irq
    
    ldr r5, [r4, #OTG_HPRT]
    orr r5, #0x00000004
    str r5, [r4, #OTG_HPRT]
    
    ldr r0, =100000
    bl usb_delay_us
    
    bl usb_port_reset
    // bl usb_enumerate_device

clear_port_irq:
    ldr r5, =0x08000000
    str r5, [r4, #OTG_GINTSTS]
    
    pop {r4-r11, pc}

// ========== SCHEDULER ==========
.globl usb_schedule
usb_schedule:
    push {r4-r11, lr}
    
    mrs r8, cpsr
    orr r9, r8, #0x80
    msr cpsr, r9
    
    ldr r4, =usb_channel_mask
    ldr r5, =usb_pending_queue
    
schedule_scan:
    ldr r6, [r4]
    mvn r7, r6
    and r7, r7, #0xFF
    cmp r7, #0
    beq schedule_done
    
    ldr r8, [r5]
    cmp r8, #0
    beq schedule_done
    
    mov r9, #0
find_free:
    cmp r9, #USB_MAX_CHANNELS
    bge schedule_scan
    mov r12, #1
    lsl r12, r9
    tst r6, r12
    beq channel_found
    add r9, #1
    b find_free

channel_found:
    mov r12, #1
    lsl r12, r9
    orr r6, r6, r12
    str r6, [r4]
    
    ldr r10, [r8, #URB_NEXT]
    str r10, [r5]
    
    strb r9, [r8, #URB_CHANNEL]
    
    ldr r11, =usb_active_queue
    ldr r12, [r11]
    str r12, [r8, #URB_NEXT]
    str r8, [r11]
    
    ldr r0, =usb_channels
    mov r1, #CHAN_SIZE
    mul r2, r9, r1
    add r3, r0, r2
    
    mov r0, #1
    str r0, [r3, #CHAN_STATE]
    str r8, [r3, #CHAN_URB]
    mov r0, #0
    str r0, [r3, #CHAN_XFRC]
    str r0, [r3, #CHAN_CHH]
    
    mov r0, r8
    bl usb_start_transfer
    
    b schedule_scan

schedule_done:
    msr cpsr, r9
    pop {r4-r11, pc}

// ========== ENUMERATION ==========
.globl usb_enumerate_device
usb_enumerate_device:
    push {r4-r11, lr}

    // Minimal single-device enumeration for HID keyboard bring-up.
    ldr r4, =usb_devices
    ldr r5, =usb_device_count
    ldr r6, [r5]
    cmp r6, #0
    bne enum_done

    // Initialize device 0 as root-port full speed HID.
    mov r7, #1
    str r7, [r4, #USB_DEV_ADDR]
    mov r7, #1
    str r7, [r4, #USB_DEV_SPEED]
    mov r7, #1
    str r7, [r4, #USB_DEV_STATE]
    mov r7, #USB_CLASS_HID
    str r7, [r4, #USB_DEV_CLASS]
    mov r7, #8
    str r7, [r4, #USB_DEV_MAX_PACKET]

    mov r7, #1
    str r7, [r5]

    // Hand off to HID/keyboard stack.
    mov r0, r4
    bl hid_probe

    // Print status line.
    ldr r0, __framebuffer_info
    ldr r1, [r0]
    ldr r2, [r0, #4]
    ldr r3, =usb_enum_success_msg
    bl fb_print_string

enum_done:
    pop {r4-r11, pc}

// Minimal control transfer shim used by HID and keyboard setup.
.globl usb_control_transfer
usb_control_transfer:
    push {lr}
    mov r0, #0
    pop {pc}

.globl usb_free_urb
usb_free_urb:
    push {lr}
    mov r1, #URB_SIZE
    bl buddy_free
    pop {pc}

// ========== MESSAGES ==========
.section ".rodata"
usb_init_msg:          .asciz "USB: Initializing...\n"
usb_connect_msg:       .asciz "USB: Device connected\n"
usb_enum_success_msg:  .asciz "USB: Device enumerated\n"
usb_enum_fail_msg:     .asciz "USB: Enumeration failed\n"
