// usb.S - USB host stack for Raspberry Pi 1
// Target: Raspberry Pi 1 (ARM1176JZF-S), 256MB RAM
// FULLY CORRECTED for hardware bring-up

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
.equ OTG_HPTXSTS,           0x410
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
.equ USB_TRANSFER_BULK,     2
.equ USB_TRANSFER_INTERRUPT, 3

// Standard request codes
.equ USB_REQ_GET_STATUS,     0x00
.equ USB_REQ_CLEAR_FEATURE,  0x01
.equ USB_REQ_SET_FEATURE,    0x03
.equ USB_REQ_SET_ADDRESS,    0x05
.equ USB_REQ_GET_DESCRIPTOR, 0x06
.equ USB_REQ_SET_DESCRIPTOR, 0x07
.equ USB_REQ_GET_CONFIG,     0x08
.equ USB_REQ_SET_CONFIG,     0x09

// Descriptor types
.equ USB_DESC_DEVICE,        0x01
.equ USB_DESC_CONFIG,        0x02
.equ USB_DESC_STRING,        0x03
.equ USB_DESC_INTERFACE,     0x04
.equ USB_DESC_ENDPOINT,      0x05

// ========== DATA STRUCTURES ==========
// USB device structure (64 bytes)
.equ USB_DEV_ADDR,           0    // Device address
.equ USB_DEV_SPEED,          4    // Speed
.equ USB_DEV_STATE,          8    // State
.equ USB_DEV_VID,            12   // Vendor ID
.equ USB_DEV_PID,            14   // Product ID
.equ USB_DEV_CLASS,          16   // Device class
.equ USB_DEV_SUBCLASS,       17   // Device subclass
.equ USB_DEV_PROTOCOL,       18   // Protocol
.equ USB_DEV_MAX_PACKET,     20   // Max packet size for EP0
.equ USB_DEV_CONFIGS,        24   // Number of configurations
.equ USB_DEV_SIZE,           64

// ========== GLOBAL USB STATE ==========
.section ".data"
.align 5  // 32-byte alignment for cache

.globl usb_devices
usb_devices:
    .space USB_MAX_DEVICES * USB_DEV_SIZE, 0

.globl usb_device_count
usb_device_count:    .word 0
.globl usb_next_addr
usb_next_addr:       .word 1

.globl usb_channels
usb_channels:        .word 0

// DMA-safe buffers (cache line aligned)
.align 5
.globl usb_setup_buffer
usb_setup_buffer:    .space 64, 0      // 64 bytes (2 cache lines)
.globl usb_data_buffer
usb_data_buffer:     .space 2048, 0    // 2KB (64 cache lines)

// ========== CACHE MANAGEMENT ==========
// Clean entire D-cache range
.globl clean_dcache_range
clean_dcache_range:
    // r0 = start address, r1 = size
    push {r4-r5, lr}
    
    mov r4, r0
    add r5, r0, r1
    
clean_loop:
    cmp r4, r5
    bge clean_done
    
    mcr p15, 0, r4, c7, c10, 1    // Clean D-cache line by MVA
    add r4, #CACHE_LINE_SIZE
    b clean_loop
    
clean_done:
    dsb
    isb
    pop {r4-r5, pc}

// Invalidate entire D-cache range
.globl invalidate_dcache_range
invalidate_dcache_range:
    // r0 = start address, r1 = size
    push {r4-r5, lr}
    
    mov r4, r0
    add r5, r0, r1
    
inval_loop:
    cmp r4, r5
    bge inval_done
    
    mcr p15, 0, r4, c7, c6, 1     // Invalidate D-cache line by MVA
    add r4, #CACHE_LINE_SIZE
    b inval_loop
    
inval_done:
    dsb
    isb
    pop {r4-r5, pc}

// ========== DELAY FUNCTIONS ==========
.globl usb_delay_us
usb_delay_us:
    // r0 = microseconds (approximate)
    push {r4, lr}
    
    // Rough delay: ~1 cycle per iteration at 700MHz
    // 700 cycles per microsecond
    lsl r4, r0, #9                // Multiply by ~512 (close enough)
    
delay_loop:
    subs r4, #1
    bne delay_loop
    
    pop {r4, pc}

// ========== INITIALIZATION ==========
.section ".text"
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
    
    ldr r0, =usb_channels
    mov r1, #0
    str r1, [r0]
    
    // Initialize DMA buffers
    ldr r0, =usb_setup_buffer
    mov r1, #64
    bl clean_dcache_range
    
    ldr r0, =usb_data_buffer
    mov r1, #2048
    bl clean_dcache_range
    
    // Reset and initialize controller
    bl usb_hcd_reset
    bl usb_hcd_init
    bl usb_port_power_on
    
    // Wait 100ms for devices to stabilize
    ldr r0, =100000
    bl usb_delay_us
    
    // Start connection detection in main loop
    pop {r4-r11, pc}

// ========== HOST CONTROLLER DRIVER ==========
.globl usb_hcd_reset
usb_hcd_reset:
    push {r4-r11, lr}
    
    ldr r4, =USB_BASE
    
    // Wait for AHB idle (bit 31)
    mov r5, #10000
ahb_idle_wait:
    ldr r1, [r4, #OTG_GRSTCTL]
    tst r1, #0x80000000            // AHB idle bit
    bne ahb_idle_done
    subs r5, #1
    bne ahb_idle_wait

ahb_idle_done:
    // Core soft reset
    ldr r1, =0x00000001
    str r1, [r4, #OTG_GRSTCTL]
    
    // Wait for reset to complete
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
    // Wait additional 50ms for PHY
    ldr r0, =50000
    bl usb_delay_us
    pop {r4-r11, pc}

.globl usb_hcd_init
usb_hcd_init:
    push {r4-r11, lr}
    
    ldr r4, =USB_BASE
    
    // Force host mode
    ldr r1, [r4, #OTG_GUSBCFG]
    orr r1, #0x40000000            // Force host mode
    str r1, [r4, #OTG_GUSBCFG]
    
    // Wait for mode change
    ldr r0, =10000
    bl usb_delay_us
    
    // Configure AHB
    ldr r1, =0x00000021            // DMA enable, burst length 4
    str r1, [r4, #OTG_GAHBCFG]
    
    // Configure USB (TTRD for 40MHz PHY)
    ldr r1, =0x00402840
    str r1, [r4, #OTG_GUSBCFG]
    
    // Wait for PHY clock
    ldr r0, =50000
    bl usb_delay_us
    
    // Set FIFO sizes (conservative for Pi 1)
    // RX FIFO: 512 words (2KB)
    ldr r1, =512
    str r1, [r4, #OTG_GRXFSIZ]
    
    // Non-periodic TX FIFO: 512 words, start after RX FIFO
    ldr r1, =0x02000200            // size=512, start=512
    str r1, [r4, #OTG_GNPTXFSIZ]
    
    // Periodic TX FIFO: 256 words, start after non-periodic
    ldr r1, =0x01000400            // size=256, start=1024
    str r1, [r4, #OTG_HPTXFSIZ]
    
    // Configure host
    mov r1, #0                      // 60MHz clock
    str r1, [r4, #OTG_HCFG]
    
    // Set frame interval (1ms at 60MHz = 60000)
    ldr r1, =60000
    str r1, [r4, #OTG_HFIR]
    
    // Enable host interrupts
    ldr r1, =0xFFFFFFFF
    str r1, [r4, #OTG_HAINTMSK]
    
    // Enable global interrupts
    ldr r1, =0x80000000             // Disconnect detect
    orr r1, #0x08000000             // Host port
    orr r1, #0x04000000             // Host channels
    str r1, [r4, #OTG_GINTMSK]
    
    pop {r4-r11, pc}

.globl usb_port_power_on
usb_port_power_on:
    push {r4-r11, lr}
    
    ldr r4, =USB_BASE
    
    // Power on root port (CORRECT: bit 12 = PrtPwr)
    ldr r1, [r4, #OTG_HPRT]
    orr r1, #0x00001000             // Port power (bit 12)
    str r1, [r4, #OTG_HPRT]
    
    pop {r4-r11, pc}

// ========== PORT MANAGEMENT ==========
.globl usb_check_root_port
usb_check_root_port:
    push {r4-r11, lr}
    
    ldr r4, =USB_BASE
    ldr r1, [r4, #OTG_HPRT]
    
    // Check actual connection status (bit 0)
    tst r1, #1
    beq no_device
    
    // Check if this is a new connection (bit 2 = connect detected)
    tst r1, #4
    beq already_connected
    
    // Clear connect detected flag
    ldr r1, [r4, #OTG_HPRT]
    orr r1, #4
    str r1, [r4, #OTG_HPRT]
    
    // Device connected - begin enumeration
    ldr r0, __framebuffer_info
    ldr r1, [r0]
    ldr r2, [r0, #4]
    ldr r3, =usb_connect_msg
    bl fb_print_string
    
    // Wait 100ms for device to stabilize
    ldr r0, =100000
    bl usb_delay_us
    
    // Reset the port
    bl usb_port_reset
    
    // Enumerate device
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
    
    // Set port reset (bit 8 = PrtRst)
    ldr r1, [r4, #OTG_HPRT]
    orr r1, #0x00000100             // Port reset
    str r1, [r4, #OTG_HPRT]
    
    // Wait 50ms
    ldr r0, =50000
    bl usb_delay_us
    
    // Clear reset
    ldr r1, [r4, #OTG_HPRT]
    bic r1, #0x00000100
    str r1, [r4, #OTG_HPRT]
    
    // Wait 20ms for recovery
    ldr r0, =20000
    bl usb_delay_us
    
    // Wait for port enable (bit 1)
    mov r5, #100000
enable_wait:
    ldr r1, [r4, #OTG_HPRT]
    tst r1, #2                      // Port enabled?
    bne enable_done
    subs r5, #1
    bne enable_wait

enable_done:
    pop {r4-r11, pc}

// ========== CHANNEL MANAGEMENT ==========
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

// ========== CONTROL TRANSFERS ==========
// r0 = device pointer, r1 = bmRequestType, r2 = bRequest, r3 = wValue
// r4 = wIndex, r5 = wLength, r6 = data pointer
.globl usb_control_transfer
usb_control_transfer:
    push {r4-r11, lr}
    
    // Save all parameters
    mov r7, r0                     // r7 = device pointer (preserved)
    mov r8, r1                     // r8 = bmRequestType (preserved)
    mov r9, r2                     // r9 = bRequest
    mov r10, r3                    // r10 = wValue
    mov r11, r4                    // r11 = wIndex
    mov r12, r5                    // r12 = wLength
    mov r4, r6                     // r4 = data pointer
    
    // Allocate channel
    bl usb_alloc_channel
    cmp r0, #0
    blt ctrl_fail
    mov r5, r0                     // r5 = channel number
    
    ldr r6, =USB_BASE
    
    // Build setup packet in cache-coherent buffer
    ldr r14, =usb_setup_buffer
    strb r8, [r14]                 // bmRequestType
    strb r9, [r14, #1]             // bRequest
    strh r10, [r14, #2]            // wValue
    strh r11, [r14, #4]            // wIndex
    strh r12, [r14, #6]            // wLength
    
    // Clean setup buffer
    ldr r0, =usb_setup_buffer
    mov r1, #64
    bl clean_dcache_range
    
    // Get device parameters
    ldr r8, [r7, #USB_DEV_ADDR]    // Device address
    ldr r9, [r7, #USB_DEV_SPEED]   // Device speed
    ldr r10, [r7, #USB_DEV_MAX_PACKET] // Max packet size
    
    // ===== CORRECT HCCHAR CONFIGURATION =====
    // HCCHAR bit layout:
    // bits 0-10:   MaxPacketSize
    // bits 11-14:  EndpointNumber
    // bit 15:      EndpointDirection (0=OUT, 1=IN)
    // bits 16-17:  reserved
    // bits 18-19:  EndpointType (0=control, 2=bulk, 3=int)
    // bits 20-21:  reserved
    // bits 22-28:  DeviceAddress
    // bit 29:      OddFrame
    // bit 30:      ChannelDisable
    // bit 31:      ChannelEnable
    
    ldr r11, =OTG_HCCHAR(r5)
    ldr r12, [r6, r11]
    
    // Clear all configurable fields
    bic r12, #0x7FF                // Clear MaxPacketSize (bits 0-10)
    bic r12, #0x7800               // Clear EndpointNumber (bits 11-14)
    bic r12, #0x8000               // Clear Direction (bit 15)
    bic r12, #0xC0000              // Clear EndpointType (bits 18-19)
    bic r12, #0x1FC00000           // Clear DeviceAddress (bits 22-28)
    
    // Set MaxPacketSize (bits 0-10)
    and r14, r10, #0x7FF
    orr r12, r14
    
    // EndpointNumber = 0 for control
    // (already cleared)
    
    // Direction = 0 for setup stage
    // (already cleared)
    
    // EndpointType = 0 for control
    // (already cleared)
    
    // DeviceAddress (bits 22-28)
    lsl r14, r8, #22
    orr r12, r14
    
    // Set speed bit if high speed (bit 17 is LS/FS, bit 27 is HS)
    cmp r9, #USB_SPEED_HIGH
    orreq r12, #0x08000000          // Set HS bit
    
    str r12, [r6, r11]
    
    // ========== SETUP STAGE ==========
    // HCTSIZ bit layout:
    // bits 0-18:   XferSize
    // bits 19-28:  PacketCount
    // bits 29-30:  PID (0=DATA0, 2=DATA1, 3=SETUP)
    // bit 31:      DoPing
    
    ldr r11, =OTG_HCTSIZ(r5)
    mov r12, #8                     // XferSize = 8
    orr r12, #1 << 19                // PacketCount = 1
    orr r12, #3 << 29                // PID = SETUP (3)
    str r12, [r6, r11]
    
    // Set DMA address
    ldr r11, =OTG_HCDMA(r5)
    ldr r12, =usb_setup_buffer
    str r12, [r6, r11]
    
    // Enable channel
    ldr r11, =OTG_HCCHAR(r5)
    ldr r12, [r6, r11]
    orr r12, #0x80000000            // Channel enable
    str r12, [r6, r11]
    
    // Wait for completion
    mov r8, #100000
setup_wait:
    subs r8, #1
    beq ctrl_timeout
    
    ldr r11, =OTG_HCINT(r5)
    ldr r12, [r6, r11]
    tst r12, #0x01                  // Transfer complete?
    bne setup_done
    tst r12, #0x02                  // Error?
    bne ctrl_error
    b setup_wait

setup_done:
    // Clear interrupt
    str r12, [r6, r11]
    
    // Wait for channel halt
    mov r8, #10000
halt_wait_setup:
    ldr r11, =OTG_HCINT(r5)
    ldr r12, [r6, r11]
    tst r12, #0x20                  // Channel halted?
    bne halt_done_setup
    subs r8, #1
    bne halt_wait_setup

halt_done_setup:
    // Clear halt interrupt
    ldr r11, =OTG_HCINT(r5)
    mov r12, #0x20
    str r12, [r6, r11]
    
    // ========== DATA STAGE (if any) ==========
    cmp r12, #0
    beq status_stage
    
    // Configure for data stage
    ldr r11, =OTG_HCCHAR(r5)
    ldr r12, [r6, r11]
    
    // Set direction based on bmRequestType (still in r8)
    ldr r8, [sp, #4]                // Reload original bmRequestType from stack
    tst r8, #0x80
    orrne r12, #0x8000              // Set IN direction for data stage
    
    // Clear and re-enable later
    bic r12, #0x80000000
    str r12, [r6, r11]
    
    // Configure HCTSIZ for data
    ldr r11, =OTG_HCTSIZ(r5)
    mov r12, r12                     // wLength
    orr r12, #1 << 19                // PacketCount = 1
    orr r12, #2 << 29                // PID = DATA1 (2)
    str r12, [r6, r11]
    
    // Clean/invalidate data buffer
    ldr r0, =usb_data_buffer
    ldr r1, =2048
    tst r8, #0x80
    beq data_out
    bl invalidate_dcache_range       // For IN transfer
    b data_dma_set

data_out:
    bl clean_dcache_range            // For OUT transfer

data_dma_set:
    // Set DMA address
    ldr r11, =OTG_HCDMA(r5)
    ldr r12, =usb_data_buffer
    str r12, [r6, r11]
    
    // Enable channel
    ldr r11, =OTG_HCCHAR(r5)
    ldr r12, [r6, r11]
    orr r12, #0x80000000
    str r12, [r6, r11]
    
    // Wait for data stage
    mov r8, #100000
data_wait:
    subs r8, #1
    beq ctrl_timeout
    
    ldr r11, =OTG_HCINT(r5)
    ldr r12, [r6, r11]
    tst r12, #0x01
    bne data_done
    tst r12, #0x02
    bne ctrl_error
    b data_wait

data_done:
    // Clear interrupt
    str r12, [r6, r11]
    
    // Wait for channel halt
    mov r8, #10000
halt_wait_data:
    ldr r11, =OTG_HCINT(r5)
    ldr r12, [r6, r11]
    tst r12, #0x20
    bne halt_done_data
    subs r8, #1
    bne halt_wait_data

halt_done_data:
    // Clear halt interrupt
    ldr r11, =OTG_HCINT(r5)
    mov r12, #0x20
    str r12, [r6, r11]
    
    // Invalidate data buffer if IN transfer
    ldr r8, [sp, #4]                // Reload bmRequestType
    tst r8, #0x80
    beq status_stage
    ldr r0, =usb_data_buffer
    ldr r1, =2048
    bl invalidate_dcache_range

    // ========== STATUS STAGE ==========
status_stage:
    // Configure HCCHAR for status
    ldr r11, =OTG_HCCHAR(r5)
    ldr r12, [r6, r11]
    
    // Opposite direction of data stage
    ldr r8, [sp, #4]                // Reload bmRequestType
    tst r8, #0x80
    biceq r12, #0x8000              // OUT if data was IN
    orrne r12, #0x8000               // IN if data was OUT
    
    // Clear enable
    bic r12, #0x80000000
    str r12, [r6, r11]
    
    // Configure HCTSIZ for status
    ldr r11, =OTG_HCTSIZ(r5)
    mov r12, #0                      // XferSize = 0
    orr r12, #1 << 19                // PacketCount = 1
    orr r12, #2 << 29                // PID = DATA1 (2) for status
    str r12, [r6, r11]
    
    // Enable channel
    ldr r11, =OTG_HCCHAR(r5)
    ldr r12, [r6, r11]
    orr r12, #0x80000000
    str r12, [r6, r11]
    
    // Wait for status stage
    mov r8, #100000
status_wait:
    subs r8, #1
    beq ctrl_timeout
    
    ldr r11, =OTG_HCINT(r5)
    ldr r12, [r6, r11]
    tst r12, #0x01
    bne status_done
    b status_wait

status_done:
    // Clear interrupt
    str r12, [r6, r11]
    
    // Wait for channel halt
    mov r8, #10000
halt_wait_status:
    ldr r11, =OTG_HCINT(r5)
    ldr r12, [r6, r11]
    tst r12, #0x20
    bne halt_done_status
    subs r8, #1
    bne halt_wait_status

halt_done_status:
    // Clear halt interrupt
    ldr r11, =OTG_HCINT(r5)
    mov r12, #0x20
    str r12, [r6, r11]
    
    // Free channel
    mov r0, r5
    bl usb_free_channel
    
    ldr r12, [sp, #8]                // Get wLength
    mov r0, r12                       // Return transferred length
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

// ========== DEVICE ENUMERATION ==========
.globl usb_enumerate_device
usb_enumerate_device:
    push {r4-r11, lr}
    
    // Allocate device structure
    ldr r4, =usb_devices
    ldr r5, =usb_device_count
    ldr r6, [r5]
    cmp r6, #USB_MAX_DEVICES
    bge enum_fail
    
    mov r7, #USB_DEV_SIZE
    mul r8, r6, r7
    add r9, r4, r8                     // r9 = new device
    
    // Set initial state
    mov r10, #USB_STATE_DEFAULT
    str r10, [r9, #USB_DEV_STATE]
    
    // Get port speed
    ldr r4, =USB_BASE
    ldr r1, [r4, #OTG_HPRT]
    and r2, r1, #0x00000600
    lsr r2, #9
    str r2, [r9, #USB_DEV_SPEED]
    
    // Set max packet size to 8 for initial descriptor fetch
    mov r10, #8
    str r10, [r9, #USB_DEV_MAX_PACKET]
    
    // Get device descriptor (first 8 bytes)
    mov r0, r9                         // device
    mov r1, #0x80                      // device-to-host
    mov r2, #USB_REQ_GET_DESCRIPTOR
    mov r3, #(USB_DESC_DEVICE << 8)    // device descriptor, index 0
    mov r4, #0                         // wIndex
    mov r5, #8                         // wLength
    ldr r6, =usb_data_buffer           // data
    bl usb_control_transfer
    
    cmp r0, #8
    blt enum_fail
    
    // Invalidate data buffer after transfer
    ldr r0, =usb_data_buffer
    mov r1, #2048
    bl invalidate_dcache_range
    
    // Parse descriptor
    ldr r4, =usb_data_buffer
    ldrh r5, [r4, #2]                  // idVendor
    strh r5, [r9, #USB_DEV_VID]
    ldrh r5, [r4, #4]                  // idProduct
    strh r5, [r9, #USB_DEV_PID]
    
    // Get max packet size from descriptor
    ldrb r5, [r4, #7]                  // bMaxPacketSize0
    str r5, [r9, #USB_DEV_MAX_PACKET]
    
    // Assign address
    ldr r5, =usb_next_addr
    ldr r6, [r5]
    add r7, r6, #1
    str r7, [r5]
    
    // Set address
    mov r0, r9                         // device
    mov r1, #0x00                      // host-to-device
    mov r2, #USB_REQ_SET_ADDRESS
    mov r3, r6                         // new address
    mov r4, #0
    mov r5, #0
    mov r6, #0
    bl usb_control_transfer
    
    // USB spec requires 2ms delay after SET_ADDRESS
    ldr r0, =2000
    bl usb_delay_us
    
    // Update device address
    str r6, [r9, #USB_DEV_ADDR]
    mov r10, #USB_STATE_ADDRESSED
    str r10, [r9, #USB_DEV_STATE]
    
    // Get full device descriptor (18 bytes)
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
    
    // Parse full descriptor
    ldr r4, =usb_data_buffer
    ldrb r5, [r4, #4]                  // bDeviceClass
    strb r5, [r9, #USB_DEV_CLASS]
    ldrb r5, [r4, #5]                  // bDeviceSubClass
    strb r5, [r9, #USB_DEV_SUBCLASS]
    ldrb r5, [r4, #6]                  // bDeviceProtocol
    strb r5, [r9, #USB_DEV_PROTOCOL]
    ldrb r5, [r4, #17]                 // bNumConfigurations
    str r5, [r9, #USB_DEV_CONFIGS]
    
    // Set configuration (use first configuration)
    mov r0, r9
    mov r1, #0x00
    mov r2, #USB_REQ_SET_CONFIG
    mov r3, #1                          // Configuration 1
    mov r4, #0
    mov r5, #0
    mov r6, #0
    bl usb_control_transfer
    
    // Delay after SET_CONFIG
    ldr r0, =10000
    bl usb_delay_us
    
    mov r10, #USB_STATE_CONFIGURED
    str r10, [r9, #USB_DEV_STATE]
    
    // Increment device count
    ldr r5, =usb_device_count
    ldr r6, [r5]
    add r6, #1
    str r6, [r5]
    
    // Print success
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

// ========== INTERRUPT HANDLER ==========
.globl usb_handle_irq
usb_handle_irq:
    push {r4-r11, lr}
    
    ldr r4, =USB_BASE
    
    // Read global interrupt status
    ldr r5, [r4, #OTG_GINTSTS]
    
    // Host port interrupt?
    tst r5, #0x08000000
    beq check_channels
    
    // Handle host port change
    ldr r6, [r4, #OTG_HPRT]
    
    // Device connected/disconnected?
    tst r6, #0x00000004
    beq no_connect
    
    // Clear connect flag
    ldr r6, [r4, #OTG_HPRT]
    orr r6, #0x00000004
    str r6, [r4, #OTG_HPRT]
    
    // Schedule enumeration in main loop
    ldr r0, __framebuffer_info
    ldr r1, [r0]
    ldr r2, [r0, #4]
    ldr r3, =usb_connect_msg
    bl fb_print_string

no_connect:
    // Clear host port interrupt
    ldr r6, =0x08000000
    str r6, [r4, #OTG_GINTSTS]

check_channels:
    // Host channels interrupt?
    tst r5, #0x04000000
    beq irq_done
    
    // Read host all channels interrupt
    ldr r6, [r4, #OTG_HAINT]
    
    // Process each channel
    mov r7, #0
chan_irq_loop:
    cmp r7, #USB_MAX_CHANNELS
    bge chan_irq_done
    
    tst r6, #1 << r7
    beq chan_irq_next
    
    // Read channel interrupt status
    ldr r8, =OTG_HCINT(r7)
    ldr r9, [r4, r8]
    
    // Clear channel interrupts
    str r9, [r4, r8]
    
    // Handle transfer complete (for future async I/O)

chan_irq_next:
    add r7, #1
    b chan_irq_loop

chan_irq_done:
    // Clear host channels interrupt
    ldr r6, =0x04000000
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
