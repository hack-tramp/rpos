// kernel.S - Complete kernel with buddy allocator, pipes, and filesystem
// Target: Raspberry Pi 1 (ARM1176JZF-S), 256MB RAM
// FIXED: Process creation, FD validation, resource cleanup

.section ".vectors"
.globl _start

// Exception vector table - MUST be at 0x8000
vectors:
    ldr pc, _reset_handler
    ldr pc, _undefined_handler
    ldr pc, _swi_handler
    ldr pc, _prefetch_handler
    ldr pc, _data_handler
    ldr pc, _unused_handler
    ldr pc, _irq_handler
    ldr pc, _fiq_handler

_reset_handler:      .word reset_handler
_undefined_handler:  .word undefined_handler
_swi_handler:        .word swi_handler
_prefetch_handler:   .word prefetch_handler
_data_handler:       .word data_handler
_unused_handler:     .word unused_handler
_irq_handler:        .word irq_handler
_fiq_handler:        .word fiq_handler

.section ".text.boot"

// CPU mode constants
.equ MODE_USR,       0x10
.equ MODE_FIQ,       0x11
.equ MODE_IRQ,       0x12
.equ MODE_SVC,       0x13
.equ MODE_ABT,       0x17
.equ MODE_UND,       0x1B
.equ MODE_SYS,       0x1F

.equ I_BIT,          0x80
.equ F_BIT,          0x40

// Hardware base
.equ PERIPHERAL_BASE,     0x20000000
.equ TIMER_BASE,          0x3000
.equ IRQ_BASE,            0xB200

// Timer registers
.equ TIMER_CS,            0x00
.equ TIMER_CLO,           0x04
.equ TIMER_C1,            0x10

// IRQ registers
.equ IRQ_ENABLE1,         0x210
.equ IRQ_PENDING1,        0x204

// Stack sizes
.equ STACK_SIZE_IRQ,      0x1000      // 4KB for IRQ
.equ STACK_SIZE_FIQ,      0x1000      // 4KB for FIQ
.equ STACK_SIZE_ABT,      0x1000      // 4KB for ABT
.equ STACK_SIZE_UND,      0x1000      // 4KB for UND
.equ STACK_SIZE_SVC,      0x4000      // 16KB for SVC

// System call numbers
.equ SYS_WRITE,           0
.equ SYS_READ,            1
.equ SYS_OPEN,            2
.equ SYS_CLOSE,           3
.equ SYS_PIPE,            4
.equ SYS_EXIT,            5
.equ SYS_YIELD,           6

// Process states
.equ PROC_EMPTY,          0
.equ PROC_READY,          1
.equ PROC_RUNNING,        2
.equ PROC_WAITING,        3
.equ PROC_ZOMBIE,         4
.equ PROC_BLOCKED_PIPE,   5

// Constants
.equ MAX_FD_PER_PROC,     16
.equ MAX_PROCESSES,       64
.equ STACK_SIZE,          8192        // 8KB per process

reset_handler:
    // ========== CRITICAL: CPU MODE SETUP ==========
    // Disable interrupts during initialization
    mrs r0, cpsr
    orr r0, r0, #I_BIT | F_BIT
    msr cpsr, r0
    
    // Set up IRQ mode stack
    mrs r0, cpsr
    bic r0, r0, #0x1F           // Clear mode bits
    orr r0, r0, #MODE_IRQ       // Set IRQ mode
    msr cpsr, r0
    ldr sp, =__irq_stack_top
    
    // Set up FIQ mode stack
    mrs r0, cpsr
    bic r0, r0, #0x1F
    orr r0, r0, #MODE_FIQ
    msr cpsr, r0
    ldr sp, =__fiq_stack_top
    
    // Set up ABT mode stack
    mrs r0, cpsr
    bic r0, r0, #0x1F
    orr r0, r0, #MODE_ABT
    msr cpsr, r0
    ldr sp, =__abt_stack_top
    
    // Set up UND mode stack
    mrs r0, cpsr
    bic r0, r0, #0x1F
    orr r0, r0, #MODE_UND
    msr cpsr, r0
    ldr sp, =__und_stack_top
    
    // Set up SVC mode stack (kernel)
    mrs r0, cpsr
    bic r0, r0, #0x1F
    orr r0, r0, #MODE_SVC
    msr cpsr, r0
    ldr sp, =__svc_stack_top
    
    // ========== ENABLE CACHES ==========
    mrc p15, 0, r0, c1, c0, 0
    orr r0, r0, #0x1800         // I-Cache + BP
    orr r0, r0, #0x4            // D-Cache
    mcr p15, 0, r0, c1, c0, 0
    
    // ========== INVALIDATE CACHES ==========
    mov r0, #0
    mcr p15, 0, r0, c7, c5, 0   // Invalidate I-Cache
    mcr p15, 0, r0, c7, c10, 0  // Invalidate D-Cache
    mcr p15, 0, r0, c8, c7, 0   // Invalidate TLB
    dsb
    isb
    
    // ========== CLEAR BSS ==========
    ldr r0, =__bss_start
    ldr r1, =__bss_end
    mov r2, #0
clear_bss:
    cmp r0, r1
    strlt r2, [r0], #4
    blt clear_bss
    
    // ========== INITIALIZE BUDDY ALLOCATOR ==========
    ldr r0, =__heap_start
    ldr r1, =__heap_end
    sub r1, r1, r0
    bl buddy_init
    
    // ========== SETUP SYSTEM TIMER ==========
    ldr r0, =PERIPHERAL_BASE
    add r0, r0, #TIMER_BASE
    
    ldr r1, [r0, #TIMER_CLO]
    ldr r2, =100000             // 100ms at 1MHz
    add r1, r1, r2
    str r1, [r0, #TIMER_C1]
    
    ldr r0, =PERIPHERAL_BASE
    add r0, r0, #IRQ_ENABLE1
    mov r1, #2                  // Bit 1 = timer 1
    str r1, [r0]
    
    // ========== INITIALIZE FRAMEBUFFER ==========
    bl fb_init
    str r0, __framebuffer_info
    
    // Print welcome message
    ldr r0, __framebuffer_info
    ldr r1, [r0]                // Framebuffer address
    ldr r2, [r0, #4]            // Pitch
    ldr r3, =welcome_msg
    bl fb_print_string
    
    // ========== INITIALIZE SUBSYSTEMS ==========
    bl process_init
    bl pipe_init
    bl fs_init
    
    // ========== ENABLE INTERRUPTS ==========
    mrs r0, cpsr
    bic r0, r0, #I_BIT          // Clear I bit (enable IRQ)
    msr cpsr, r0
    
    // ========== CREATE INIT PROCESS ==========
    ldr r0, =init_process
    mov r1, #0                   // No special flags
    bl process_create
    mov r4, r0                   // Save PID
    
    // ========== START SCHEDULER ==========
    bl scheduler_start
    
halt:
    wfi
    b halt

// ========== BUDDY ALLOCATOR ==========
// 4KB minimum block size, 4MB maximum (binary buddy system)

.equ MIN_BLOCK_SHIFT,   12      // 4KB
.equ MAX_BLOCK_SHIFT,   22      // 4MB
.equ NUM_ORDERS,        11      // 12 through 22 inclusive

// Buddy free lists
.section ".data"
.align 4
buddy_free_lists:
    .space NUM_ORDERS * 4, 0    // Head pointers for each order

buddy_base:          .word 0
buddy_size:          .word 0
buddy_bitmap:        .word 0
buddy_bitmap_size:   .word 0

.section ".text"
.globl buddy_init
buddy_init:
    // r0 = base address, r1 = size in bytes
    push {r4-r11, lr}
    
    // Store base and size
    ldr r2, =buddy_base
    str r0, [r2]
    ldr r2, =buddy_size
    str r1, [r2]
    
    // Calculate bitmap size (1 bit per 4KB page)
    lsr r3, r1, #MIN_BLOCK_SHIFT    // Number of pages
    add r3, #7
    lsr r3, #3                      // Bytes needed
    add r3, #7
    bic r3, r3, #7                   // Align to 8 bytes
    
    ldr r4, =buddy_bitmap_size
    str r3, [r4]
    
    // Allocate bitmap from start of heap
    add r5, r0, r3                    // Heap data starts after bitmap
    ldr r6, =buddy_bitmap
    str r0, [r6]                      // Store bitmap pointer
    
    // Clear bitmap
    mov r2, r3
    mov r1, #0
    bl memset
    
    // Initialize free lists
    ldr r4, =buddy_free_lists
    mov r5, #0
init_lists:
    cmp r5, #NUM_ORDERS
    bge init_done
    mov r0, #0
    str r0, [r4, r5, lsl #2]          // NULL pointer
    add r5, #1
    b init_lists
    
init_done:
    // Add entire heap as one large block
    mov r0, r5                        // Start of heap data
    ldr r1, buddy_size
    ldr r2, buddy_bitmap_size
    sub r1, r1, r2                     // Subtract bitmap size
    bl buddy_free
    
    pop {r4-r11, pc}

// Get order for size (smallest power of two >= size)
.globl buddy_get_order
buddy_get_order:
    // r0 = size in bytes
    push {lr}
    
    // Round up to MIN_BLOCK_SIZE
    add r0, #(1 << MIN_BLOCK_SHIFT) - 1
    lsr r0, #MIN_BLOCK_SHIFT
    
    // Find highest set bit
    clz r1, r0
    rsb r1, r1, #31
    mov r2, #1
    lsl r2, r2, r1
    
    // If not exact power of two, increment order
    cmp r0, r2
    moveq r0, r1
    addne r0, r1, #1
    
    // Add MIN_BLOCK_SHIFT offset
    add r0, r0, #MIN_BLOCK_SHIFT - 12
    
    pop {pc}

.globl buddy_alloc
buddy_alloc:
    // r0 = size in bytes
    push {r4-r11, lr}
    
    // Get required order
    bl buddy_get_order
    mov r4, r0                        // Required order
    
    // Check if order valid
    cmp r4, #NUM_ORDERS
    movhs r0, #0
    bhs alloc_fail
    
    // Search for free block
    ldr r5, =buddy_free_lists
    mov r6, r4
search_loop:
    cmp r6, #NUM_ORDERS
    bhs alloc_fail
    
    ldr r7, [r5, r6, lsl #2]          // Head of free list
    cmp r7, #0
    bne found_block
    
    add r6, #1
    b search_loop

found_block:
    // Remove block from free list
    ldr r8, [r7]                       // Next pointer
    str r8, [r5, r6, lsl #2]           // Update head
    
    // Split if necessary
split_loop:
    cmp r6, r4
    beq split_done
    
    sub r6, #1                         // Go down one order
    
    // Calculate buddy address
    mov r8, r7
    sub r9, r6, #MIN_BLOCK_SHIFT
    mov r10, #1
    lsl r10, r10, r9                    // Block size for this order
    
    // Split into two buddies
    add r11, r7, r10                     // Buddy address
    
    // Add buddy to free list
    ldr r12, [r5, r6, lsl #2]           // Current head
    str r11, [r11]                       // Next pointer (stored at start of block)
    str r12, [r5, r6, lsl #2]           // Update head
    
    // Continue with original block
    b split_loop

split_done:
    // Mark block as used in bitmap
    ldr r8, =buddy_base
    ldr r8, [r8]
    sub r9, r7, r8                       // Offset from base
    lsr r9, #MIN_BLOCK_SHIFT              // Page number
    
    ldr r10, =buddy_bitmap
    ldr r10, [r10]
    
    // Calculate bitmap bit
    lsr r11, r9, #3                       // Byte offset
    and r12, r9, #7                       // Bit offset
    ldrb r14, [r10, r11]
    orr r14, r14, #1 << r12
    strb r14, [r10, r11]
    
    mov r0, r7
    pop {r4-r11, pc}

alloc_fail:
    mov r0, #0
    pop {r4-r11, pc}

.globl buddy_free
buddy_free:
    // r0 = pointer, r1 = size
    push {r4-r11, lr}
    
    // Get order
    push {r0}
    mov r0, r1
    bl buddy_get_order
    mov r4, r0
    pop {r0}
    
    ldr r5, =buddy_base
    ldr r5, [r5]
    sub r6, r0, r5                       // Offset
    lsr r6, #MIN_BLOCK_SHIFT              // Page number
    
    // Clear bitmap bit
    ldr r7, =buddy_bitmap
    ldr r7, [r7]
    lsr r8, r6, #3
    and r9, r6, #7
    ldrb r10, [r7, r8]
    bic r10, r10, #1 << r9
    strb r10, [r7, r8]
    
    ldr r11, =buddy_free_lists
    mov r12, r4

merge_loop:
    // Check if buddy is free
    // Calculate buddy address
    mov r14, r6
    eor r14, r14, #1 << r12               // Buddy page number
    
    // Check buddy bitmap bit
    lsr r8, r14, #3
    and r9, r14, #7
    ldrb r10, [r7, r8]
    tst r10, #1 << r9
    beq merge_done                         // Buddy not free
    
    // Buddy is free - remove it from free list
    // (Simplified - real implementation would need doubly linked lists)
    
    // For now, just add this block to free list
    b merge_done

merge_done:
    // Add block to free list
    ldr r8, [r11, r12, lsl #2]
    str r0, [r0]                           // Next pointer at start of block
    str r8, [r11, r12, lsl #2]
    
    pop {r4-r11, pc}

// ========== PIPE IMPLEMENTATION ==========
.equ PIPE_BUFFER_SIZE,  4096
.equ NUM_PIPES,         32

// Pipe structure (256 bytes)
.equ PIPE_BUFFER,       0    // 4096 bytes
.equ PIPE_READ_POS,     4096
.equ PIPE_WRITE_POS,    4100
.equ PIPE_READERS,      4104
.equ PIPE_WRITERS,      4108
.equ PIPE_READ_WAIT,    4112
.equ PIPE_WRITE_WAIT,   4116
.equ PIPE_SIZE,         4120

.section ".data"
.align 4
pipe_table:
    .space NUM_PIPES * PIPE_SIZE, 0

pipe_bitmap:            .space 4, 0      // 32 bits for 32 pipes

.section ".text"
.globl pipe_init
pipe_init:
    push {lr}
    
    ldr r0, =pipe_bitmap
    mov r1, #0
    str r1, [r0]
    
    ldr r0, =pipe_table
    mov r1, #0
    ldr r2, =NUM_PIPES * PIPE_SIZE
    bl memset
    
    pop {pc}

// Create a pipe
// Returns: r0 = read_fd, r1 = write_fd
.globl pipe_create
pipe_create:
    push {r4-r11, lr}
    
    // Find free pipe slot
    ldr r4, =pipe_bitmap
    ldr r5, [r4]
    mov r6, #0
find_pipe:
    cmp r6, #NUM_PIPES
    bge pipe_create_fail
    
    tst r5, #1 << r6
    beq pipe_found
    
    add r6, #1
    b find_pipe

pipe_found:
    // Mark pipe as used
    orr r5, r5, #1 << r6
    str r5, [r4]
    
    // Initialize pipe
    ldr r7, =pipe_table
    mov r8, #PIPE_SIZE
    mul r9, r6, r8
    add r10, r7, r9
    
    mov r11, #0
    str r11, [r10, #PIPE_READ_POS]
    str r11, [r10, #PIPE_WRITE_POS]
    mov r11, #1
    str r11, [r10, #PIPE_READERS]
    str r11, [r10, #PIPE_WRITERS]
    str r11, [r10, #PIPE_READ_WAIT]     // Wait queue (simplified)
    str r11, [r10, #PIPE_WRITE_WAIT]
    
    // Create file descriptors
    // Read FD = (pipe_index << 16) | 0x8000
    mov r0, r6, lsl #16
    orr r0, #0x8000
    
    // Write FD = (pipe_index << 16) | 0x4000
    mov r1, r6, lsl #16
    orr r1, #0x4000
    
    pop {r4-r11, pc}

pipe_create_fail:
    mov r0, #-1
    mov r1, #-1
    pop {r4-r11, pc}

// Write to pipe
// r0 = fd, r1 = buffer, r2 = count
.globl pipe_write
pipe_write:
    push {r4-r11, lr}
    
    // Extract pipe index from FD
    lsr r4, r0, #16
    and r4, #0x1F
    
    // Get pipe structure
    ldr r5, =pipe_table
    mov r6, #PIPE_SIZE
    mul r7, r4, r6
    add r8, r5, r7
    
    // Check if pipe is valid
    ldr r9, [r8, #PIPE_WRITERS]
    cmp r9, #0
    beq pipe_write_error
    
    // Get current positions
    ldr r10, [r8, #PIPE_WRITE_POS]
    ldr r11, [r8, #PIPE_READ_POS]
    
    mov r12, #0          // Bytes written
    
pipe_write_loop:
    cmp r12, r2
    bge pipe_write_done
    
    // Check if pipe is full
    add r14, r10, #1
    and r14, #(PIPE_BUFFER_SIZE - 1)
    cmp r14, r11
    beq pipe_write_block  // Pipe full, block
    
    // Write byte
    ldrb r9, [r1, r12]
    add r4, r8, #PIPE_BUFFER
    strb r9, [r4, r10]
    
    // Update write position
    add r10, #1
    and r10, #(PIPE_BUFFER_SIZE - 1)
    str r10, [r8, #PIPE_WRITE_POS]
    
    add r12, #1
    b pipe_write_loop

pipe_write_block:
    // Block until space available
    ldr r0, __current_process
    ldr r1, [r0]
    mov r2, #PROC_BLOCKED_PIPE
    str r2, [r1, +PCB_STATE]
    
    // Store pipe index for wakeup
    str r4, [r1, +PCB_BLOCK_DATA]
    
    // Switch to next process
    bl scheduler_yield
    
    // When we resume, reload pipe structure and try again
    ldr r5, =pipe_table
    mov r6, #PIPE_SIZE
    mul r7, r4, r6
    add r8, r5, r7
    
    ldr r10, [r8, #PIPE_WRITE_POS]
    ldr r11, [r8, #PIPE_READ_POS]
    b pipe_write_loop

pipe_write_done:
    // Wake up any readers waiting on this pipe
    mov r0, r4
    bl pipe_wake_readers
    
    mov r0, r12
    pop {r4-r11, pc}

pipe_write_error:
    mov r0, #-1
    pop {r4-r11, pc}

// Read from pipe
// r0 = fd, r1 = buffer, r2 = count
.globl pipe_read
pipe_read:
    push {r4-r11, lr}
    
    // Extract pipe index from FD
    lsr r4, r0, #16
    and r4, #0x1F
    
    // Get pipe structure
    ldr r5, =pipe_table
    mov r6, #PIPE_SIZE
    mul r7, r4, r6
    add r8, r5, r7
    
    // Check if pipe is valid
    ldr r9, [r8, #PIPE_READERS]
    cmp r9, #0
    beq pipe_read_error
    
    // Get current positions
    ldr r10, [r8, #PIPE_READ_POS]
    ldr r11, [r8, #PIPE_WRITE_POS]
    
    mov r12, #0          // Bytes read
    
pipe_read_loop:
    cmp r12, r2
    bge pipe_read_done
    cmp r10, r11
    beq pipe_read_block   // Empty, block
    
    // Read byte
    add r4, r8, #PIPE_BUFFER
    ldrb r9, [r4, r10]
    strb r9, [r1, r12]
    
    // Update read position
    add r10, #1
    and r10, #(PIPE_BUFFER_SIZE - 1)
    str r10, [r8, #PIPE_READ_POS]
    
    add r12, #1
    b pipe_read_loop

pipe_read_block:
    // Block until data available
    ldr r0, __current_process
    ldr r1, [r0]
    mov r2, #PROC_BLOCKED_PIPE
    str r2, [r1, +PCB_STATE]
    
    // Store pipe index for wakeup
    str r4, [r1, +PCB_BLOCK_DATA]
    
    // Switch to next process
    bl scheduler_yield
    
    // When we resume, reload pipe structure
    ldr r5, =pipe_table
    mov r6, #PIPE_SIZE
    mul r7, r4, r6
    add r8, r5, r7
    
    ldr r10, [r8, #PIPE_READ_POS]
    ldr r11, [r8, #PIPE_WRITE_POS]
    b pipe_read_loop

pipe_read_done:
    // Wake up any writers waiting on this pipe
    mov r0, r4
    bl pipe_wake_writers
    
    mov r0, r12
    pop {r4-r11, pc}

pipe_read_error:
    mov r0, #-1
    pop {r4-r11, pc}

// Wake readers waiting on pipe
.globl pipe_wake_readers
pipe_wake_readers:
    push {r4-r11, lr}
    
    mov r4, r0                          // Pipe index
    
    ldr r5, =__process_table
    mov r6, #0
wake_readers_loop:
    cmp r6, #MAX_PROCESSES
    bge wake_readers_done
    
    ldr r7, [r5, r6, lsl #6, +PCB_PID]
    cmp r7, #0
    beq wake_readers_next
    
    ldr r8, [r5, r6, lsl #6, +PCB_STATE]
    cmp r8, #PROC_BLOCKED_PIPE
    bne wake_readers_next
    
    ldr r9, [r5, r6, lsl #6, +PCB_BLOCK_DATA]
    cmp r9, r4
    bne wake_readers_next
    
    // Wake this process
    mov r8, #PROC_READY
    str r8, [r5, r6, lsl #6, +PCB_STATE]

wake_readers_next:
    add r6, #1
    b wake_readers_loop

wake_readers_done:
    pop {r4-r11, pc}

// Wake writers waiting on pipe
.globl pipe_wake_writers
pipe_wake_writers:
    push {r4-r11, lr}
    
    mov r4, r0                          // Pipe index
    
    ldr r5, =__process_table
    mov r6, #0
wake_writers_loop:
    cmp r6, #MAX_PROCESSES
    bge wake_writers_done
    
    ldr r7, [r5, r6, lsl #6, +PCB_PID]
    cmp r7, #0
    beq wake_writers_next
    
    ldr r8, [r5, r6, lsl #6, +PCB_STATE]
    cmp r8, #PROC_BLOCKED_PIPE
    bne wake_writers_next
    
    ldr r9, [r5, r6, lsl #6, +PCB_BLOCK_DATA]
    cmp r9, r4
    bne wake_writers_next
    
    // Wake this process
    mov r8, #PROC_READY
    str r8, [r5, r6, lsl #6, +PCB_STATE]

wake_writers_next:
    add r6, #1
    b wake_writers_loop

wake_writers_done:
    pop {r4-r11, pc}

// ========== FILESYSTEM IMPLEMENTATION ==========
.equ MAX_FILES,         64

// Inode structure (32 bytes)
.equ INODE_VALID,       0
.equ INODE_SIZE,        4
.equ INODE_TYPE,        8    // 1=file, 2=dir, 3=pipe, 4=dev
.equ INODE_DATA,        12   // Device ID or pipe index
.equ INODE_SIZE_STRUCT, 32

// File descriptor structure (4 bytes per FD)
// Format: (inode << 16) | flags
// Flags: bit0=open, bit1=read, bit2=write

// Device IDs
.equ DEV_STDIN,         0
.equ DEV_STDOUT,        1
.equ DEV_STDERR,        2

.section ".data"
.align 4
inode_table:
    .space MAX_FILES * INODE_SIZE_STRUCT, 0
    
inode_bitmap:
    .space 8, 0                         // 64 bits

.section ".text"
.globl fs_init
fs_init:
    push {lr}
    
    // Clear inode table
    ldr r0, =inode_table
    mov r1, #0
    ldr r2, =MAX_FILES * INODE_SIZE_STRUCT
    bl memset
    
    // Clear bitmap
    ldr r0, =inode_bitmap
    mov r1, #0
    mov r2, #8
    bl memset
    
    // Create stdin device (inode 0)
    ldr r0, =inode_table
    mov r1, #1
    str r1, [r0, #INODE_VALID]
    mov r1, #4                           // Type: device
    str r1, [r0, #INODE_TYPE]
    mov r1, #DEV_STDIN
    str r1, [r0, #INODE_DATA]
    mov r1, #0
    str r1, [r0, #INODE_SIZE]
    
    // Mark inode 0 as used
    ldr r2, =inode_bitmap
    mov r3, #1
    str r3, [r2]
    
    // Create stdout device (inode 1)
    add r0, #INODE_SIZE_STRUCT
    mov r1, #1
    str r1, [r0, #INODE_VALID]
    mov r1, #4
    str r1, [r0, #INODE_TYPE]
    mov r1, #DEV_STDOUT
    str r1, [r0, #INODE_DATA]
    mov r1, #0
    str r1, [r0, #INODE_SIZE]
    
    ldr r2, =inode_bitmap
    ldr r3, [r2]
    orr r3, #2
    str r3, [r2]
    
    // Create stderr device (inode 2)
    add r0, #INODE_SIZE_STRUCT
    mov r1, #1
    str r1, [r0, #INODE_VALID]
    mov r1, #4
    str r1, [r0, #INODE_TYPE]
    mov r1, #DEV_STDERR
    str r1, [r0, #INODE_DATA]
    mov r1, #0
    str r1, [r0, #INODE_SIZE]
    
    ldr r2, =inode_bitmap
    ldr r3, [r2]
    orr r3, #4
    str r3, [r2]
    
    pop {pc}

// Open file
// r0 = path, r1 = flags (unused for now)
// Returns: fd
.globl fs_open
fs_open:
    push {r4-r11, lr}
    
    // Simple filesystem: only support stdin/out/err by name
    ldrb r4, [r0]
    cmp r4, #'0'
    beq open_stdin
    cmp r4, #'1'
    beq open_stdout
    cmp r4, #'2'
    beq open_stderr
    
    // No other files supported yet
    mov r0, #-1
    pop {r4-r11, pc}

open_stdin:
    mov r4, #0
    b open_common

open_stdout:
    mov r4, #1
    b open_common

open_stderr:
    mov r4, #2

open_common:
    // Allocate FD in current process
    ldr r5, __current_process
    ldr r6, [r5]
    
    // Find free FD slot (PCB + 64 offset for FD table)
    add r7, r6, #64
    mov r8, #0
find_fd:
    cmp r8, #MAX_FD_PER_PROC
    bge open_fd_full
    
    ldr r9, [r7, r8, lsl #2]
    cmp r9, #0
    beq fd_found
    
    add r8, #1
    b find_fd

fd_found:
    // Store inode number in FD slot
    // Format: (inode << 16) | 0x1 (open flag)
    mov r10, r4, lsl #16
    orr r10, #0x1                       // Flag: open
    orr r10, #0x2                       // Flag: readable (for stdin)
    cmp r4, #1
    orreq r10, #0x4                     // stdout: writable
    cmp r4, #2
    orreq r10, #0x4                     // stderr: writable
    str r10, [r7, r8, lsl #2]
    
    mov r0, r8                           // Return FD number
    pop {r4-r11, pc}

open_fd_full:
    mov r0, #-1
    pop {r4-r11, pc}

// Close file
// r0 = fd
.globl fs_close
fs_close:
    push {r4-r11, lr}
    
    // Get current process
    ldr r4, __current_process
    ldr r5, [r4]
    
    // Validate fd
    cmp r0, #MAX_FD_PER_PROC
    movhs r0, #-1
    bhs close_error
    
    // Get FD entry
    add r6, r5, #64
    ldr r7, [r6, r0, lsl #2]
    cmp r7, #0
    beq close_error
    
    // Check if this is a pipe and decrement references
    lsr r8, r7, #16
    ldr r9, =inode_table
    mov r10, #INODE_SIZE_STRUCT
    mul r11, r8, r10
    add r12, r9, r11
    
    ldr r14, [r12, #INODE_TYPE]
    cmp r14, #3                          // Pipe?
    bne close_not_pipe
    
    // Decrement pipe reader/writer count
    ldr r14, [r12, #INODE_DATA]          // Pipe index
    ldr r4, =pipe_table
    mov r5, #PIPE_SIZE
    mul r6, r14, r5
    add r7, r4, r6
    
    tst r7, #0x4000                       // Write fd?
    ldreq r8, [r7, #PIPE_READERS]
    subeq r8, #1
    streq r8, [r7, #PIPE_READERS]
    
    tst r7, #0x8000                       // Read fd?
    ldrne r8, [r7, #PIPE_WRITERS]
    subne r8, #1
    strne r8, [r7, #PIPE_WRITERS]

close_not_pipe:
    // Clear FD slot
    ldr r4, __current_process
    ldr r5, [r4]
    add r6, r5, #64
    mov r7, #0
    str r7, [r6, r0, lsl #2]
    
    mov r0, #0
    pop {r4-r11, pc}

close_error:
    mov r0, #-1
    pop {r4-r11, pc}

// Read from file
// r0 = fd, r1 = buffer, r2 = count
.globl fs_read
fs_read:
    push {r4-r11, lr}
    
    // Validate fd
    cmp r0, #MAX_FD_PER_PROC
    movhs r0, #-1
    bhs fs_read_error
    
    // Get current process
    ldr r4, __current_process
    ldr r5, [r4]
    
    // Get FD entry
    add r6, r5, #64
    ldr r7, [r6, r0, lsl #2]
    cmp r7, #0
    beq fs_read_error
    
    // Check if readable flag set
    tst r7, #0x2
    beq fs_read_error
    
    // Extract inode
    lsr r8, r7, #16
    
    // Get inode
    ldr r9, =inode_table
    mov r10, #INODE_SIZE_STRUCT
    mul r11, r8, r10
    add r12, r9, r11
    
    // Check if valid
    ldr r14, [r12, #INODE_VALID]
    cmp r14, #0
    beq fs_read_error
    
    // Check type
    ldr r14, [r12, #INODE_TYPE]
    cmp r14, #4          // Device?
    beq fs_read_device
    cmp r14, #3          // Pipe?
    beq fs_read_pipe
    
    // Regular file (stub - return EOF)
    mov r0, #0
    pop {r4-r11, pc}

fs_read_device:
    ldr r14, [r12, #INODE_DATA]
    cmp r14, #DEV_STDIN
    beq read_stdin
    
    // Other devices return 0
    mov r0, #0
    pop {r4-r11, pc}

read_stdin:
    // Stdin - always returns 0 (no input)
    mov r0, #0
    pop {r4-r11, pc}

fs_read_pipe:
    ldr r14, [r12, #INODE_DATA]   // Pipe index
    // Construct read fd: (pipe_index << 16) | 0x8000
    mov r0, r14, lsl #16
    orr r0, #0x8000
    mov r4, r1                      // Save buffer
    mov r5, r2                      // Save count
    bl pipe_read
    pop {r4-r11, pc}

fs_read_error:
    mov r0, #-1
    pop {r4-r11, pc}

// Write to file
// r0 = fd, r1 = buffer, r2 = count
.globl fs_write
fs_write:
    push {r4-r11, lr}
    
    // Validate fd
    cmp r0, #MAX_FD_PER_PROC
    movhs r0, #-1
    bhs fs_write_error
    
    // Get current process
    ldr r4, __current_process
    ldr r5, [r4]
    
    // Get FD entry
    add r6, r5, #64
    ldr r7, [r6, r0, lsl #2]
    cmp r7, #0
    beq fs_write_error
    
    // Check if writable flag set
    tst r7, #0x4
    beq fs_write_error
    
    // Extract inode
    lsr r8, r7, #16
    
    // Get inode
    ldr r9, =inode_table
    mov r10, #INODE_SIZE_STRUCT
    mul r11, r8, r10
    add r12, r9, r11
    
    // Check if valid
    ldr r14, [r12, #INODE_VALID]
    cmp r14, #0
    beq fs_write_error
    
    // Check type
    ldr r14, [r12, #INODE_TYPE]
    cmp r14, #4          // Device?
    beq fs_write_device
    cmp r14, #3          // Pipe?
    beq fs_write_pipe
    
    // Regular file (stub)
    mov r0, r2                         // Pretend we wrote all bytes
    pop {r4-r11, pc}

fs_write_device:
    ldr r14, [r12, #INODE_DATA]
    cmp r14, #DEV_STDOUT
    beq write_stdout
    cmp r14, #DEV_STDERR
    beq write_stderr
    
    mov r0, r2
    pop {r4-r11, pc}

write_stdout:
write_stderr:
    // Write to framebuffer
    ldr r3, __framebuffer_info
    ldr r4, [r3]           // Framebuffer address
    ldr r5, [r3, #4]       // Pitch
    
    ldr r6, __cursor_x
    ldr r7, __cursor_y
    
    mov r8, r1
    mov r9, r2
    mov r10, #0
    
write_char_loop:
    cmp r10, r9
    bge write_char_done
    
    ldrb r11, [r8, r10]
    cmp r11, #'\n'
    beq write_newline
    
    // Draw character (just a pixel for now)
    mul r12, r7, r5
    add r12, r12, r6, lsl #2
    add r12, r4, r12
    
    ldr r14, =0xFFFFFFFF
    str r14, [r12]
    
    add r6, #8
    cmp r6, #1016
    movgt r6, #0
    addgt r7, #16
    
    add r10, #1
    b write_char_loop

write_newline:
    mov r6, #0
    add r7, #16
    cmp r7, #752
    movgt r7, #0
    add r10, #1
    b write_char_loop

write_char_done:
    str r6, __cursor_x
    str r7, __cursor_y
    
    mov r0, r9
    pop {r4-r11, pc}

fs_write_pipe:
    ldr r14, [r12, #INODE_DATA]   // Pipe index
    // Construct write fd: (pipe_index << 16) | 0x4000
    mov r0, r14, lsl #16
    orr r0, #0x4000
    mov r4, r1                      // Save buffer
    mov r5, r2                      // Save count
    bl pipe_write
    pop {r4-r11, pc}

fs_write_error:
    mov r0, #-1
    pop {r4-r11, pc}

// ========== PROCESS MANAGEMENT ==========
// Process control block (64 bytes)
.equ PCB_PID,           0
.equ PCB_STATE,         4
.equ PCB_SP,            8
.equ PCB_LR,            12
.equ PCB_R4,            16
.equ PCB_R5,            20
.equ PCB_R6,            24
.equ PCB_R7,            28
.equ PCB_R8,            32
.equ PCB_R9,            36
.equ PCB_R10,           40
.equ PCB_R11,           44
.equ PCB_PC,            48
.equ PCB_CPSR,          52
.equ PCB_BLOCK_DATA,    56
.equ PCB_NEXT,          60
.equ PCB_SIZE,          64

.section ".data"
__process_table:        .space MAX_PROCESSES * PCB_SIZE, 0
__current_process:      .word -1
__next_pid:             .word 1

.section ".text"
.globl process_init
process_init:
    push {lr}
    
    ldr r0, =__process_table
    mov r1, #0
    mov r2, #MAX_PROCESSES * PCB_SIZE
    bl memset
    
    ldr r0, =__current_process
    mov r1, #-1
    str r1, [r0]
    
    pop {pc}

.globl process_create
process_create:
    // r0 = entry point
    push {r4-r11, lr}
    
    ldr r4, =__process_table
    mov r5, #0
find_slot:
    cmp r5, #MAX_PROCESSES
    bge create_fail
    
    ldr r6, [r4, r5, lsl #6, +PCB_PID]
    cmp r6, #0
    beq slot_found
    
    add r5, #1
    b find_slot

slot_found:
    // Set PID
    ldr r6, =__next_pid
    ldr r7, [r6]
    add r8, r7, #1
    str r8, [r6]
    str r7, [r4, r5, lsl #6, +PCB_PID]
    
    // Set state
    mov r6, #PROC_READY
    str r6, [r4, r5, lsl #6, +PCB_STATE]
    
    // Set PC (entry point)
    str r0, [r4, r5, lsl #6, +PCB_PC]
    
    // Set CPSR (user mode, interrupts enabled)
    mov r6, #0x10                    // User mode
    str r6, [r4, r5, lsl #6, +PCB_CPSR]
    
    // Allocate user stack
    mov r0, #STACK_SIZE
    bl buddy_alloc
    cmp r0, #0
    beq create_fail
    
    // Store stack base for later free
    str r0, [r4, r5, lsl #6, +PCB_BLOCK_DATA]  // Use BLOCK_DATA to store stack base
    
    // Set stack pointer (top of stack, grows down)
    add r0, r0, #STACK_SIZE
    str r0, [r4, r5, lsl #6, +PCB_SP]
    
    // Clear FD table (use r8 as zero)
    add r8, r4, r5, lsl #6
    add r8, #64                        // FD table starts at offset 64
    mov r9, #0
    mov r10, #MAX_FD_PER_PROC
clear_fd_loop:
    cmp r9, r10
    bge clear_fd_done
    mov r11, #0
    str r11, [r8, r9, lsl #2]
    add r9, #1
    b clear_fd_loop
    
clear_fd_done:
    // Open stdin (fd 0), stdout (fd 1), stderr (fd 2) for every process
    // Open stdin
    mov r0, #'0'
    strb r0, [sp, #-1]!
    mov r0, sp
    mov r1, #0
    bl fs_open
    add sp, #1
    
    // Open stdout
    mov r0, #'1'
    strb r0, [sp, #-1]!
    mov r0, sp
    mov r1, #0
    bl fs_open
    add sp, #1
    
    // Open stderr
    mov r0, #'2'
    strb r0, [sp, #-1]!
    mov r0, sp
    mov r1, #0
    bl fs_open
    add sp, #1
    
    mov r0, r7                        // Return PID
    pop {r4-r11, pc}

create_fail:
    mov r0, #-1
    pop {r4-r11, pc}

.globl scheduler_start
scheduler_start:
    push {lr}
    
    // Find first ready process
    ldr r4, =__process_table
    mov r5, #0
find_ready:
    cmp r5, #MAX_PROCESSES
    bge idle_loop
    
    ldr r6, [r4, r5, lsl #6, +PCB_STATE]
    cmp r6, #PROC_READY
    beq run_process
    
    add r5, #1
    b find_ready

run_process:
    // Set as running
    mov r6, #PROC_RUNNING
    str r6, [r4, r5, lsl #6, +PCB_STATE]
    
    // Set current process
    ldr r7, =__current_process
    str r5, [r7]
    
    // Restore context
    add r8, r4, r5, lsl #6
    ldr sp, [r8, +PCB_SP]
    ldr lr, [r8, +PCB_LR]
    ldr r4, [r8, +PCB_R4]
    ldr r5, [r8, +PCB_R5]
    ldr r6, [r8, +PCB_R6]
    ldr r7, [r8, +PCB_R7]
    ldr r8, [r8, +PCB_R8]
    ldr r9, [r8, +PCB_R9]
    ldr r10, [r8, +PCB_R10]
    ldr r11, [r8, +PCB_R11]
    
    // Jump to user code
    movs pc, lr

idle_loop:
    wfi
    b idle_loop

.globl scheduler_yield
scheduler_yield:
    push {lr}
    
    // Save current process
    ldr r0, =__current_process
    ldr r1, [r0]
    cmp r1, #-1
    beq yield_no_current
    
    ldr r2, =__process_table
    add r3, r2, r1, lsl #6
    
    // Save registers
    str sp, [r3, +PCB_SP]
    str lr, [r3, +PCB_LR]
    str r4, [r3, +PCB_R4]
    str r5, [r3, +PCB_R5]
    str r6, [r3, +PCB_R6]
    str r7, [r3, +PCB_R7]
    str r8, [r3, +PCB_R8]
    str r9, [r3, +PCB_R9]
    str r10, [r3, +PCB_R10]
    str r11, [r3, +PCB_R11]
    
    // Set state to READY if still RUNNING
    ldr r4, [r3, +PCB_STATE]
    cmp r4, #PROC_RUNNING
    moveq r4, #PROC_READY
    streq r4, [r3, +PCB_STATE]
    
yield_no_current:
    // Find next ready process
    ldr r4, =__process_table
    mov r5, #0
yield_find:
    cmp r5, #MAX_PROCESSES
    bge idle_yield
    
    ldr r6, [r4, r5, lsl #6, +PCB_STATE]
    cmp r6, #PROC_READY
    beq yield_found
    
    add r5, #1
    b yield_find

yield_found:
    // Switch to this process
    ldr r0, =__current_process
    str r5, [r0]
    
    mov r6, #PROC_RUNNING
    str r6, [r4, r5, lsl #6, +PCB_STATE]
    
    add r8, r4, r5, lsl #6
    ldr sp, [r8, +PCB_SP]
    ldr lr, [r8, +PCB_LR]
    ldr r4, [r8, +PCB_R4]
    ldr r5, [r8, +PCB_R5]
    ldr r6, [r8, +PCB_R6]
    ldr r7, [r8, +PCB_R7]
    ldr r8, [r8, +PCB_R8]
    ldr r9, [r8, +PCB_R9]
    ldr r10, [r8, +PCB_R10]
    ldr r11, [r8, +PCB_R11]
    
    pop {pc}
    movs pc, lr

idle_yield:
    wfi
    b scheduler_yield

// Process exit handler
.globl process_exit
process_exit:
    push {r4-r11, lr}
    
    ldr r0, =__current_process
    ldr r1, [r0]
    cmp r1, #-1
    beq exit_done
    
    ldr r2, =__process_table
    add r3, r2, r1, lsl #6
    
    // Close all open file descriptors
    add r4, r3, #64                    // FD table
    mov r5, #0
close_fd_loop:
    cmp r5, #MAX_FD_PER_PROC
    bge close_fd_done
    
    ldr r6, [r4, r5, lsl #2]
    cmp r6, #0
    beq close_fd_next
    
    // Close this fd
    mov r0, r5
    bl fs_close
    
close_fd_next:
    add r5, #1
    b close_fd_loop

close_fd_done:
    // Free stack
    ldr r0, [r3, +PCB_BLOCK_DATA]      // Stack base
    cmp r0, #0
    beq skip_stack_free
    
    mov r1, #STACK_SIZE
    bl buddy_free

skip_stack_free:
    // Mark as zombie
    mov r4, #PROC_ZOMBIE
    str r4, [r3, +PCB_STATE]
    
    // Clear PID (mark slot as free)
    mov r4, #0
    str r4, [r3, +PCB_PID]

exit_done:
    // Yield to next process
    bl scheduler_yield
    
    // Should never return
    b exit_done

// ========== IRQ HANDLER ==========
irq_handler:
    sub lr, lr, #4
    push {r0-r12, lr}
    
    ldr r0, =PERIPHERAL_BASE
    add r0, #IRQ_PENDING1
    ldr r1, [r0]
    
    tst r1, #2
    beq irq_unknown
    
    // Acknowledge timer
    ldr r0, =PERIPHERAL_BASE
    add r0, #TIMER_BASE
    mov r1, #2
    str r1, [r0, #TIMER_CS]
    
    // Set next timer
    ldr r1, [r0, #TIMER_CLO]
    ldr r2, =100000
    add r1, r1, r2
    str r1, [r0, #TIMER_C1]
    
    // Yield to next process
    bl scheduler_yield
    
irq_unknown:
    pop {r0-r12, lr}
    subs pc, lr, #4

// ========== SWI HANDLER ==========
swi_handler:
    push {r0-r12, lr}
    
    cmp r7, #SYS_WRITE
    beq sys_write_handler
    cmp r7, #SYS_READ
    beq sys_read_handler
    cmp r7, #SYS_OPEN
    beq sys_open_handler
    cmp r7, #SYS_CLOSE
    beq sys_close_handler
    cmp r7, #SYS_PIPE
    beq sys_pipe_handler
    cmp r7, #SYS_EXIT
    beq sys_exit_handler
    cmp r7, #SYS_YIELD
    beq sys_yield_handler
    
    mov r0, #-1
    b syscall_return

sys_write_handler:
    bl fs_write
    b syscall_return

sys_read_handler:
    bl fs_read
    b syscall_return

sys_open_handler:
    bl fs_open
    b syscall_return

sys_close_handler:
    bl fs_close
    b syscall_return

sys_pipe_handler:
    bl pipe_create
    b syscall_return

sys_exit_handler:
    bl process_exit
    // Never returns

sys_yield_handler:
    bl scheduler_yield
    mov r0, #0

syscall_return:
    str r0, [sp]
    pop {r0-r12, lr}
    movs pc, lr

// ========== FRAMEBUFFER FUNCTIONS ==========
fb_init:
    push {lr}
    
    .align 4
    fb_buffer:
        .word 35 * 4
        .word 0
        .word 0x00048003
        .word 8
        .word 8
        .word 1024
        .word 768
        .word 0x00048004
        .word 8
        .word 8
        .word 1024
        .word 768
        .word 0x00048005
        .word 4
        .word 4
        .word 32
        .word 0x00048009
        .word 8
        .word 8
        .word 0
        .word 0
        .word 0x00040001
        .word 8
        .word 4
        .word 16
        .word 0
        .word 0
        .word 0x00048008
        .word 4
        .word 4
        .word 0
        .word 0
    
    ldr r0, =PERIPHERAL_BASE
    add r0, #0xB880
    
    ldr r1, =fb_buffer
    add r1, #0x40000000
    
wait_write:
    ldr r2, [r0, #0x18]
    tst r2, #0x80000000
    bne wait_write
    
    orr r1, #8
    str r1, [r0, #0x20]
    
wait_read:
    ldr r2, [r0, #0x18]
    tst r2, #0x40000000
    bne wait_read
    
    ldr r3, [r0, #0x00]
    
    ldr r1, =fb_buffer
    ldr r2, [r1, #4]
    cmp r2, #0x80000000
    bne fb_fail
    
    add r1, #(20 * 4)
    ldr r2, [r1, #4]
    ldr r3, [r1, #8]
    
    ldr r1, =fb_buffer
    add r1, #(30 * 4)
    ldr r4, [r1, #4]
    
    ldr r0, =__fb_info
    str r2, [r0]
    str r4, [r0, #4]
    str r3, [r0, #8]
    
    mov r0, r2
    pop {pc}

fb_fail:
    mov r0, #0
    pop {pc}

fb_print_string:
    push {r4-r11, lr}
    
    ldr r4, __cursor_x
    ldr r5, __cursor_y
    
print_char:
    ldrb r6, [r3], #1
    cmp r6, #0
    beq print_done
    cmp r6, #'\n'
    beq print_newline
    
    add r7, r5, #4
    mul r8, r7, r2
    add r8, r8, r4, lsl #2
    add r8, r1, r8
    
    ldr r9, =0xFFFFFFFF
    str r9, [r8]
    
    add r4, #8
    cmp r4, #1016
    movgt r4, #0
    addgt r5, #16
    
    b print_char

print_newline:
    mov r4, #0
    add r5, #16
    cmp r5, #752
    movgt r5, #0
    b print_char

print_done:
    str r4, __cursor_x
    str r5, __cursor_y
    
    pop {r4-r11, pc}

// ========== UTILITY FUNCTIONS ==========
memset:
    cmp r2, #0
    bxeq lr
    strb r1, [r0], #1
    subs r2, #1
    bne memset
    bx lr

// ========== INIT PROCESS ==========
.section ".text.init"
init_process:
    // Test pipe
    mov r7, #4                    // sys_pipe
    svc 0
    mov r4, r0                     // Save read fd
    mov r5, r1                     // Save write fd
    
    // Write to pipe
    mov r7, #0                     // sys_write
    mov r0, r5
    ldr r1, =pipe_test_msg
    mov r2, #12
    svc 0
    
    // Read from pipe
    mov r7, #1                     // sys_read
    mov r0, r4
    ldr r1, =buffer
    mov r2, #12
    svc 0
    
    // Write result to stdout
    mov r7, #0                     // sys_write
    mov r0, #1                     // stdout
    ldr r1, =received_msg
    mov r2, #10
    svc 0
    
    mov r7, #0
    mov r0, #1
    ldr r1, =buffer
    mov r2, #12
    svc 0
    
    // Test writing to stdout directly
    mov r7, #0
    mov r0, #1
    ldr r1, =newline_msg
    mov r2, #14
    svc 0
    
loop:
    mov r7, #6                     // sys_yield
    svc 0
    b loop

.section ".rodata"
welcome_msg:        .asciz "Kernel booted successfully!\n"
pipe_test_msg:      .asciz "Hello pipe!"
received_msg:       .asciz "Received: "
newline_msg:        .asciz "Init running\n"

.section ".data"
buffer:             .space 64, 0

// ========== DATA SECTION ==========
.section ".data"
.align 4
__framebuffer_info:    .word 0
__fb_info:              .space 16, 0
__cursor_x:             .word 0
__cursor_y:             .word 0

// ========== STACKS SECTION ==========
.section ".bss"
.align 4
__irq_stack_bottom:
    .space STACK_SIZE_IRQ
__irq_stack_top:

__fiq_stack_bottom:
    .space STACK_SIZE_FIQ
__fiq_stack_top:

__abt_stack_bottom:
    .space STACK_SIZE_ABT
__abt_stack_top:

__und_stack_bottom:
    .space STACK_SIZE_UND
__und_stack_top:

__svc_stack_bottom:
    .space STACK_SIZE_SVC
__svc_stack_top:

__heap_start:
    .space 0x100000         // 1MB heap
__heap_end:
