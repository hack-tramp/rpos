// hid.S - USB HID (Human Interface Device) driver
// Target: Raspberry Pi 1, works with usb.S and kernel.S

#include "usb_constants.h"

// HID descriptor types
.equ HID_DESC_HID,          0x21
.equ HID_DESC_REPORT,       0x22
.equ HID_DESC_PHYSICAL,     0x23

// HID request types
.equ HID_REQ_GET_REPORT,    0x01
.equ HID_REQ_GET_IDLE,      0x02
.equ HID_REQ_GET_PROTOCOL,  0x03
.equ HID_REQ_SET_REPORT,    0x09
.equ HID_REQ_SET_IDLE,      0x0A
.equ HID_REQ_SET_PROTOCOL,  0x0B

// Report types
.equ HID_REPORT_INPUT,      0x01
.equ HID_REPORT_OUTPUT,     0x02
.equ HID_REPORT_FEATURE,    0x03

// HID instance structure (128 bytes)
.equ HID_DEVICE,            0    // USB device pointer
.equ HID_INTERFACE,         4    // Interface number
.equ HID_EP_IN,             8    // Interrupt IN endpoint pointer
.equ HID_REPORT_SIZE,       12   // Report size in bytes
.equ HID_REPORT_DESC,       16   // Report descriptor buffer
.equ HID_STATE,             20   // Driver state
.equ HID_BUFFER,            24   // Current report buffer
.equ HID_URB,               28   // Active URB
.equ HID_CALLBACK,          32   // Input callback
.equ HID_PRIVATE,           36   // Private data for callback
.equ HID_IDLE,              40   // Idle rate
.equ HID_PROTOCOL,          44   // Boot/Report protocol
.equ HID_SIZE,              128

// HID states
.equ HID_STATE_INIT,        0
.equ HID_STATE_IDLE,        1
.equ HID_STATE_READING,     2
.equ HID_STATE_ERROR,       3

.section ".data"
.align 4

// Registered HID devices
.globl hid_devices
hid_devices:            .space 4 * 8, 0    // Up to 8 HID devices
.globl hid_device_count
hid_device_count:       .word 0

// Global input event queue
.globl hid_event_queue
hid_event_queue:        .space 256, 0      // 64 events * 4 bytes
.globl hid_event_head
hid_event_head:         .word 0
.globl hid_event_tail
hid_event_tail:         .word 0

.section ".text"

// ========== HID PROBE ==========
// Called by USB core when HID device detected
// r0 = device pointer
.globl hid_probe
hid_probe:
    push {r4-r11, lr}
    
    mov r4, r0                          // r4 = device
    
    // Check if device class is HID
    ldr r0, [r4, #USB_DEV_CLASS]
    cmp r0, #USB_CLASS_HID
    bne hid_probe_fail
    
    // Allocate HID instance
    mov r0, #HID_SIZE
    bl buddy_alloc
    cmp r0, #0
    beq hid_probe_fail
    mov r5, r0                          // r5 = HID instance
    
    // Initialize HID instance
    str r4, [r5, #HID_DEVICE]
    mov r0, #HID_STATE_INIT
    str r0, [r5, #HID_STATE]
    
    // Set default idle rate (8ms intervals)
    mov r0, #8
    str r0, [r5, #HID_IDLE]
    
    // Set default protocol (1 = report protocol)
    mov r0, #1
    str r0, [r5, #HID_PROTOCOL]
    
    // Allocate report buffer (8 bytes for keyboard)
    mov r0, #8
    bl buddy_alloc
    cmp r0, #0
    beq hid_free_instance
    str r0, [r5, #HID_BUFFER]
    
    // Get HID descriptor and find interrupt endpoint
    mov r0, r5
    bl hid_get_descriptor
    
    // Register with HID subsystem
    ldr r6, =hid_devices
    ldr r7, =hid_device_count
    ldr r8, [r7]
    cmp r8, #8
    bge hid_free_all
    
    str r5, [r6, r8, lsl #2]
    add r8, #1
    str r8, [r7]
    
    // Set idle rate (prevents device from sending reports too fast)
    mov r0, r5
    mov r1, #0                          // 0 = duration in 4ms units, 0 = infinite
    bl hid_set_idle
    
    // Start first read
    mov r0, r5
    bl hid_start_read
    
    mov r0, #0
    pop {r4-r11, pc}

hid_free_all:
    ldr r0, [r5, #HID_BUFFER]
    cmp r0, #0
    beq skip_buffer
    mov r1, #8
    bl buddy_free

skip_buffer:
    mov r0, r5
    mov r1, #HID_SIZE
    bl buddy_free

hid_probe_fail:
    mov r0, #-1
    pop {r4-r11, pc}

hid_free_instance:
    mov r0, r5
    mov r1, #HID_SIZE
    bl buddy_free
    mov r0, #-1
    pop {r4-r11, pc}

// ========== GET HID DESCRIPTOR ==========
// r0 = HID instance
hid_get_descriptor:
    push {r4-r11, lr}
    
    mov r4, r0                          // r4 = HID instance
    ldr r5, [r4, #HID_DEVICE]           // r5 = USB device
    
    // Find interrupt endpoint in configuration
    // For simplicity, assume first interrupt endpoint is the one
    // Real driver would parse interface descriptors
    
    // For keyboard, typical endpoint is:
    // - Interrupt IN
    // - Max packet size = 8
    
    // Allocate endpoint structure
    mov r0, #USB_EP_SIZE
    bl buddy_alloc
    cmp r0, #0
    bep hid_desc_done
    
    mov r6, r0                          // r6 = endpoint
    
    // Initialize endpoint
    mov r1, #1                          // endpoint 1
    str r1, [r6, #USB_EP_NUM]
    mov r1, #USB_TRANSFER_INTERRUPT
    str r1, [r6, #USB_EP_TYPE]
    mov r1, #1                          // IN direction
    str r1, [r6, #USB_EP_DIR]
    mov r1, #8                          // max packet 8
    str r1, [r6, #USB_EP_MAX_PKT]
    mov r1, #10                         // polling interval 10ms
    str r1, [r6, #USB_EP_INTERVAL]
    mov r1, #0                          // initial toggle DATA0
    str r1, [r6, #USB_EP_TOGGLE]
    str r5, [r6, #USB_EP_DEVICE]
    
    // Store endpoint in HID instance
    str r6, [r4, #HID_EP_IN]
    
    // Get report size from endpoint max packet
    ldr r1, [r6, #USB_EP_MAX_PKT]
    str r1, [r4, #HID_REPORT_SIZE]

hid_desc_done:
    pop {r4-r11, pc}

// ========== SET IDLE ==========
// r0 = HID instance, r1 = idle rate (0 = infinite)
hid_set_idle:
    push {r4-r11, lr}
    
    mov r4, r0
    mov r5, r1
    ldr r6, [r4, #HID_DEVICE]
    
    // Control transfer: SET_IDLE
    mov r0, r6                          // device
    mov r1, #0x21                       // host-to-device, class, interface
    mov r2, #HID_REQ_SET_IDLE
    mov r3, r5, lsl #8                   // idle rate << 8
    mov r4, #0                          // interface 0
    mov r5, #0                          // wLength = 0
    mov r6, #0                          // no data
    bl usb_control_transfer
    
    pop {r4-r11, pc}

// ========== START READING ==========
// r0 = HID instance
.globl hid_start_read
hid_start_read:
    push {r4-r11, lr}
    
    mov r4, r0                          // r4 = HID instance
    
    // Check if already reading
    ldr r0, [r4, #HID_STATE]
    cmp r0, #HID_STATE_READING
    beq hid_read_done
    
    ldr r5, [r4, #HID_DEVICE]           // device
    ldr r6, [r4, #HID_EP_IN]            // endpoint
    ldr r7, [r4, #HID_BUFFER]           // buffer
    ldr r8, [r4, #HID_REPORT_SIZE]      // size
    
    // Allocate URB
    mov r0, r5
    mov r1, r6
    mov r2, r7
    mov r3, r8
    ldr r4, =hid_read_callback
    mov r5, r4
    bl usb_alloc_urb
    
    cmp r0, #0
    beq hid_read_done
    
    str r0, [r4, #HID_URB]
    mov r1, #HID_STATE_READING
    str r1, [r4, #HID_STATE]
    
    // Submit URB
    bl usb_submit_urb

hid_read_done:
    pop {r4-r11, pc}

// ========== READ CALLBACK ==========
// r0 = URB pointer
.globl hid_read_callback
hid_read_callback:
    push {r4-r11, lr}
    
    mov r4, r0                          // r4 = URB
    ldr r5, [r4, #URB_PRIVATE]          // r5 = HID instance
    ldr r6, [r4, #URB_STATUS]
    
    // Update state
    mov r0, #HID_STATE_IDLE
    str r0, [r5, #HID_STATE]
    
    cmp r6, #XFER_COMPLETE
    bne handle_error
    
    // Process the report
    ldr r0, [r5, #HID_BUFFER]
    ldr r1, [r4, #URB_ACTUAL]
    ldr r2, [r5, #HID_CALLBACK]
    
    // Call input handler if registered
    cmp r2, #0
    beq no_callback
    
    mov lr, pc
    bx r2
    
no_callback:
    // Queue raw event for kernel
    ldr r0, [r5, #HID_BUFFER]
    ldr r1, [r4, #URB_ACTUAL]
    bl hid_queue_event
    
    // Start next read
    mov r0, r5
    bl hid_start_read
    
    b callback_done

handle_error:
    // On error, wait and retry
    ldr r0, =10000
    bl usb_delay_us
    mov r0, r5
    bl hid_start_read

callback_done:
    // Free URB
    mov r0, r4
    bl usb_free_urb
    
    pop {r4-r11, pc}

// ========== QUEUE EVENT ==========
// r0 = report buffer, r1 = length
hid_queue_event:
    push {r4-r11, lr}
    
    ldr r4, =hid_event_tail
    ldr r5, [r4]
    ldr r6, =hid_event_head
    ldr r7, [r6]
    
    // Calculate next tail
    add r8, r5, #1
    and r8, #63                         // 64-entry circular buffer
    
    // Check if buffer full
    cmp r8, r7
    beq queue_full
    
    // Store event (simplified - store first byte for keyboard)
    ldrb r9, [r0, #2]                    // First key code
    ldr r10, =hid_event_queue
    str r9, [r10, r5, lsl #2]
    
    // Update tail
    str r8, [r4]

queue_full:
    pop {r4-r11, pc}

// ========== REGISTER CALLBACK ==========
// r0 = HID instance, r1 = callback, r2 = private
.globl hid_register_callback
hid_register_callback:
    push {lr}
    str r1, [r0, #HID_CALLBACK]
    str r2, [r0, #HID_PRIVATE]
    pop {pc}

// ========== GET KEYCODE ==========
// Returns next keycode from queue, or -1 if empty
.globl hid_get_key
hid_get_key:
    push {r4-r11, lr}
    
    ldr r4, =hid_event_head
    ldr r5, [r4]
    ldr r6, =hid_event_tail
    ldr r7, [r6]
    
    // Check if empty
    cmp r5, r7
    beq queue_empty
    
    // Get event
    ldr r8, =hid_event_queue
    ldr r0, [r8, r5, lsl #2]
    
    // Update head
    add r5, #1
    and r5, #63
    str r5, [r4]
    
    pop {r4-r11, pc}

queue_empty:
    mov r0, #-1
    pop {r4-r11, pc}
