// usb.S - USB host stack with strict register discipline
// Register allocation:
// r4 = URB pointer (preserved throughout)
// r5 = channel number (preserved throughout)
// r6 = USB_BASE
// r7 = endpoint
// r8 = device
// r9 = length/buffer temp
// r10-r12 = temps
// r14 = loop counter

// ========== URB ALLOCATION ==========
// r0 = device, r1 = endpoint, r2 = buffer, r3 = length
// r4 = callback, r5 = private (passed in registers)
.globl usb_alloc_urb
usb_alloc_urb:
    // Save callback and private immediately
    mov r10, r4          // callback
    mov r11, r5          // private
    
    push {r4-r11, lr}
    
    // Move parameters to safe registers
    mov r6, r0           // device
    mov r7, r1           // endpoint
    mov r8, r2           // buffer
    mov r9, r3           // length
    
    // Allocate URB
    mov r0, #URB_SIZE
    bl buddy_alloc
    cmp r0, #0
    beq urb_alloc_fail
    
    mov r4, r0           // r4 = URB pointer (preserved)
    
    // Initialize URB
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
    
    // Get initial PID from endpoint
    ldr r0, [r7, #USB_EP_TOGGLE]
    strb r0, [r4, #URB_PID]
    
    // Check if device behind hub
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

// ========== START TRANSFER ==========
// r0 = URB pointer (caller)
// Preserves: r4 = URB, r5 = channel
.globl usb_start_transfer
usb_start_transfer:
    push {r4-r11, lr}
    
    mov r4, r0                          // r4 = URB (preserved)
    ldrb r5, [r4, #URB_CHANNEL]         // r5 = channel (preserved)
    ldr r6, =USB_BASE                    // r6 = base (preserved)
    ldr r7, [r4, #URB_ENDPOINT]          // r7 = endpoint
    ldr r8, [r4, #URB_DEVICE]            // r8 = device
    ldr r9, [r4, #URB_BUFFER]            // r9 = buffer
    ldr r10, [r4, #URB_LENGTH]           // r10 = length
    ldrb r11, [r4, #URB_PID]             // r11 = PID
    
    // Get device/endpoint parameters
    ldr r12, [r8, #USB_DEV_ADDR]         // device address
    ldr r14, [r7, #USB_EP_NUM]           // endpoint number
    ldr r2, [r7, #USB_EP_DIR]            // direction
    ldr r1, [r7, #USB_EP_TYPE]           // type
    ldr r0, [r7, #USB_EP_MAX_PKT]        // max packet
    
    // ===== HCCHAR CONFIGURATION =====
    ldr r1, =OTG_HCCHAR(r5)
    ldr r2, [r6, r1]
    
    // Clear all configurable fields using safe masks
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
    
    // Set MaxPacketSize
    and r3, r0, #0x7FF
    orr r2, r2, r3
    
    // Set EndpointNumber
    and r3, r14, #0xF
    lsl r3, #11
    orr r2, r2, r3
    
    // Set Direction
    cmp r2, #1
    orreq r2, r2, #0x8000
    
    // Set EndpointType
    ldr r3, [r7, #USB_EP_TYPE]
    and r3, #3
    lsl r3, #18
    orr r2, r2, r3
    
    // Set DeviceAddress
    and r3, r12, #0x7F
    lsl r3, #22
    orr r2, r2, r3
    
    str r2, [r6, r1]
    
    // ===== SPLIT TRANSACTION =====
    ldrb r0, [r4, #URB_SPLIT]
    cmp r0, #0
    beq no_split
    
    ldr r1, =OTG_HCSPLT(r5)
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
    // ===== HCTSIZ CONFIGURATION =====
    // Calculate packet count: ceil(length / max_packet)
    mov r0, r10                          // length
    ldr r1, [r7, #USB_EP_MAX_PKT]        // max packet
    bl usb_div_ceil
    mov r14, r0                           // packet count
    
    // Build HCTSIZ: XferSize | (PacketCount << 19) | (PID << 29)
    mov r0, r10                           // XferSize = length
    and r1, r14, #0x3FF
    lsl r1, #19
    orr r0, r0, r1
    
    and r1, r11, #3
    lsl r1, #29
    orr r0, r0, r1
    
    ldr r1, =OTG_HCTSIZ(r5)
    str r0, [r6, r1]
    
    // ===== DMA ADDRESS =====
    ldr r1, =OTG_HCDMA(r5)
    str r9, [r6, r1]                      // buffer address
    
    // Clean cache for OUT transfers
    ldr r0, [r7, #USB_EP_DIR]
    cmp r0, #0
    bne enable_channel
    
    mov r0, r9
    mov r1, r10
    bl clean_dcache_range

enable_channel:
    dsb
    
    // Enable channel
    ldr r1, =OTG_HCCHAR(r5)
    ldr r0, [r6, r1]
    orr r0, #0x80000000
    str r0, [r6, r1]
    
    pop {r4-r11, pc}

// ========== INTERRUPT HANDLER ==========
// r0 = channel number (preserved)
.globl usb_handle_channel_irq
usb_handle_channel_irq:
    push {r4-r11, lr}
    
    mov r4, r0                           // r4 = channel (preserved)
    ldr r5, =USB_BASE
    
    // Read and clear HCINT immediately
    ldr r6, =OTG_HCINT(r4)
    ldr r7, [r5, r6]
    str r7, [r5, r6]                     // Clear all
    
    // Get channel state
    ldr r8, =usb_channels
    mov r9, #CHAN_SIZE
    mul r10, r4, r9
    add r11, r8, r10
    
    // Get URB
    ldr r9, [r11, #CHAN_URB]
    cmp r9, #0
    beq irq_done_channel
    
    // Process based on recorded interrupt bits
    tst r7, #0x02                        // Error?
    beq check_stall
    
    // Error occurred
    mov r0, #XFER_ERROR
    str r0, [r9, #URB_STATUS]
    bl usb_abort_channel
    b irq_done_channel

check_stall:
    tst r7, #0x40                        // STALL?
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
    
    // Check if both XFRC and CHH seen
    ldr r0, [r11, #CHAN_XFRC]
    ldr r1, [r11, #CHAN_CHH]
    and r0, r0, r1
    cmp r0, #0
    beq irq_done_channel
    
    // Transfer complete - calculate actual length
    ldr r0, =OTG_HCTSIZ(r4)
    ldr r1, [r5, r0]
    and r1, r1, #0x7FFFF                  // remaining bytes
    
    ldr r2, [r9, #URB_LENGTH]
    sub r2, r2, r1
    str r2, [r9, #URB_ACTUAL]
    
    // Update endpoint toggle
    ldr r3, [r9, #URB_ENDPOINT]
    ldrb r0, [r9, #URB_PID]
    eor r0, #2
    strb r0, [r3, #USB_EP_TOGGLE]
    
    // Invalidate cache for IN transfers
    ldr r0, [r3, #USB_EP_DIR]
    cmp r0, #1
    bne complete_transfer
    
    ldr r0, [r9, #URB_BUFFER]
    ldr r1, [r9, #URB_ACTUAL]
    bl invalidate_dcache_range

complete_transfer:
    // Remove from active queue and complete
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
    // Free channel
    ldr r0, =usb_channel_mask
    ldr r1, [r0]
    bic r1, r1, #1 << r4
    str r1, [r0]
    
    // Clear channel state
    mov r1, #0
    str r1, [r11, #CHAN_STATE]
    str r1, [r11, #CHAN_URB]
    str r1, [r11, #CHAN_XFRC]
    str r1, [r11, #CHAN_CHH]

irq_done_channel:
    pop {r4-r11, pc}

// ========== SCHEDULER ==========
.globl usb_schedule
usb_schedule:
    push {r4-r11, lr}
    
    // Disable IRQs
    mrs r8, cpsr
    orr r9, r8, #0x80
    msr cpsr, r9
    
    ldr r4, =usb_channel_mask
    ldr r5, =usb_pending_queue
    
schedule_scan:
    ldr r6, [r4]                         // current mask
    mvn r7, r6
    and r7, r7, #0xFF                     // free channels
    cmp r7, #0
    beq schedule_done
    
    ldr r8, [r5]                          // first pending
    cmp r8, #0
    beq schedule_done
    
    // Find lowest free channel
    mov r9, #0
find_free:
    cmp r9, #USB_MAX_CHANNELS
    bge schedule_scan
    
    tst r6, #1 << r9
    beq channel_found
    add r9, #1
    b find_free

channel_found:
    // Mark channel used
    orr r6, r6, #1 << r9
    str r6, [r4]
    
    // Remove from pending
    ldr r10, [r8, #URB_NEXT]
    str r10, [r5]
    
    // Store channel
    strb r9, [r8, #URB_CHANNEL]
    
    // Add to active
    ldr r11, =usb_active_queue
    ldr r12, [r11]
    str r12, [r8, #URB_NEXT]
    str r8, [r11]
    
    // Initialize channel state
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
    
    // Start transfer (r0 = URB)
    mov r0, r8
    bl usb_start_transfer
    
    // Continue scanning for more free channels
    b schedule_scan

schedule_done:
    msr cpsr, r9
    pop {r4-r11, pc}
