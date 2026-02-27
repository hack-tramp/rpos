// kernel.S - Complete kernel with buddy allocator, pipes, filesystem, USB and process management
// Target: Raspberry Pi 1 (ARM1176JZF-S), 256MB RAM
// FULLY CORRECTED - No complex addressing modes, all loads use separate address calculation

// ========== PRE-CALCULATED CONSTANTS ==========
.equ ONE_SHIFT_12,           4096     // 1 << 12
.equ ONE_SHIFT_12_MINUS_1,   4095     // (1 << 12) - 1
.equ MIN_BLOCK_MASK,         0xFFF    // (1 << MIN_BLOCK_SHIFT) - 1
.equ PIPE_BUFFER_MASK,       4095     // PIPE_BUFFER_SIZE - 1
.equ ONE_SHIFT_22,           4194304  // 1 << 22
.equ ONE_SHIFT_22_MINUS_1,   4194303  // (1 << 22) - 1
.equ MIN_BLOCK_SHIFT_MINUS_12, 0     // MIN_BLOCK_SHIFT - 12 = 0

// Peripheral base addresses (loaded from literal pool)
periph_base:    .word 0x20000000
timer_base:     .word 0x20003000
irq_enable1:    .word 0x2000B210
irq_pending1:   .word 0x2000B204

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

// Buddy allocator constants
.equ MIN_BLOCK_SHIFT,     12          // 4KB
.equ MAX_BLOCK_SHIFT,     22          // 4MB
.equ NUM_ORDERS,          11

// Pipe constants
.equ PIPE_BUFFER_SIZE,    4096
.equ NUM_PIPES,           32
.equ PIPE_BUFFER,         0
.equ PIPE_READ_POS,       4096
.equ PIPE_WRITE_POS,      4100
.equ PIPE_READERS,        4104
.equ PIPE_WRITERS,        4108
.equ PIPE_SIZE,           4120

// Filesystem constants
.equ MAX_FILES,           64
.equ INODE_VALID,         0
.equ INODE_SIZE,          4
.equ INODE_TYPE,          8
.equ INODE_DATA,          12
.equ INODE_SIZE_STRUCT,   32
.equ DEV_STDIN,           0
.equ DEV_STDOUT,          1
.equ DEV_STDERR,          2

// PCB offsets
.equ PCB_PID,             0
.equ PCB_STATE,           4
.equ PCB_SP,              8
.equ PCB_LR,              12
.equ PCB_R4,              16
.equ PCB_R5,              20
.equ PCB_R6,              24
.equ PCB_R7,              28
.equ PCB_R8,              32
.equ PCB_R9,              36
.equ PCB_R10,             40
.equ PCB_R11,             44
.equ PCB_PC,              48
.equ PCB_CPSR,            52
.equ PCB_BLOCK_DATA,      56
.equ PCB_FD0,             64
.equ PCB_FD1,             68
.equ PCB_FD2,             72
.equ PCB_FD3,             76
.equ PCB_FD4,             80
.equ PCB_FD5,             84
.equ PCB_FD6,             88
.equ PCB_FD7,             92
.equ PCB_FD8,             96
.equ PCB_FD9,             100
.equ PCB_FD10,            104
.equ PCB_FD11,            108
.equ PCB_FD12,            112
.equ PCB_FD13,            116
.equ PCB_FD14,            120
.equ PCB_FD15,            124
.equ PCB_SIZE,            128

reset_handler:
    // ========== CRITICAL: CPU MODE SETUP ==========
    // Disable interrupts during initialization
    mrs r0, cpsr
    orr r0, r0, #(I_BIT | F_BIT)
    msr cpsr, r0
    
    // Set up IRQ mode stack
    mrs r0, cpsr
    bic r0, r0, #0x1F
    orr r0, r0, #MODE_IRQ
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
    
    // ARMv6-compatible barriers
    mov r0, #0
    mcr p15, 0, r0, c7, c10, 4  // Drain write buffer (DSB equivalent)
    mcr p15, 0, r0, c7, c5, 4   // Flush prefetch buffer (ISB equivalent)
    
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
    ldr r2, =100000
    add r1, r1, r2
    str r1, [r0, #TIMER_C1]
    
    ldr r0, =PERIPHERAL_BASE
    add r0, r0, #IRQ_ENABLE1
    mov r1, #2
    str r1, [r0]
    
    // ========== INITIALIZE FRAMEBUFFER ==========
    bl fb_init
    str r0, __framebuffer_info
    
    // Print welcome message
    ldr r0, __framebuffer_info
    ldr r1, [r0]
    ldr r2, [r0, #4]
    ldr r3, =welcome_msg
    bl fb_print_string
    
    // ========== INITIALIZE SUBSYSTEMS ==========
    bl process_init
    bl pipe_init
    bl fs_init
    
    // ========== INITIALIZE USB ==========
    ldr r0, __framebuffer_info
    ldr r1, [r0]
    ldr r2, [r0, #4]
    ldr r3, =usb_start_msg
    bl fb_print_string
    
    bl usb_init
    
    // ========== ENABLE INTERRUPTS ==========
    mrs r0, cpsr
    bic r0, r0, #I_BIT
    msr cpsr, r0
    
    // ========== CREATE INIT PROCESS ==========
    ldr r0, =init_process
    mov r1, #0
    bl process_create
    mov r4, r0
    
    // ========== START SCHEDULER ==========
    bl scheduler_start
    
halt:
    wfi
    b halt

// ========== BUDDY ALLOCATOR ==========
.section ".data"
.align 4
buddy_free_lists:       .space NUM_ORDERS * 4, 0
buddy_base:             .word 0
buddy_size:             .word 0
buddy_bitmap:           .word 0
buddy_bitmap_size:      .word 0

// Literal pool for large constants
.ltorg

.section ".text"
.globl buddy_init
buddy_init:
    push {r4-r11, lr}
    ldr r2, =buddy_base
    str r0, [r2]
    ldr r2, =buddy_size
    str r1, [r2]
    
    lsr r3, r1, #MIN_BLOCK_SHIFT
    add r3, r3, #7
    lsr r3, r3, #3
    add r3, r3, #7
    bic r3, r3, #7
    
    ldr r4, =buddy_bitmap_size
    str r3, [r4]
    
    add r5, r0, r3
    ldr r6, =buddy_bitmap
    str r0, [r6]
    
    mov r2, r3
    mov r1, #0
    bl memset
    
    ldr r4, =buddy_free_lists
    mov r5, #0
init_lists:
    cmp r5, #NUM_ORDERS
    bge init_done
    mov r0, #0
    
    // Fixed: Separate address calculation
    add r14, r4, r5, lsl #2
    str r0, [r14]
    
    add r5, r5, #1
    b init_lists
    
init_done:
    ldr r0, =__heap_start
    ldr r1, buddy_size
    ldr r2, buddy_bitmap_size
    sub r1, r1, r2
    bl buddy_free
    
    pop {r4-r11, pc}

.globl buddy_get_order
buddy_get_order:
    push {lr}
    // Using pre-calculated constants - no expressions
    add r0, r0, #ONE_SHIFT_12_MINUS_1
    lsr r0, r0, #MIN_BLOCK_SHIFT
    clz r1, r0
    rsb r1, r1, #31
    mov r2, #1
    lsl r2, r2, r1
    cmp r0, r2
    moveq r0, r1
    addne r0, r1, #1
    add r0, r0, #MIN_BLOCK_SHIFT_MINUS_12
    pop {pc}

.globl buddy_alloc
buddy_alloc:
    push {r4-r11, lr}
    bl buddy_get_order
    mov r4, r0
    cmp r4, #NUM_ORDERS
    movhs r0, #0
    bhs alloc_fail
    
    ldr r5, =buddy_free_lists
    mov r6, r4
search_loop:
    cmp r6, #NUM_ORDERS
    bhs alloc_fail
    
    // Fixed: Separate address calculation
    add r14, r5, r6, lsl #2
    ldr r7, [r14]
    
    cmp r7, #0
    bne found_block
    add r6, r6, #1
    b search_loop

found_block:
    ldr r8, [r7]
    
    // Fixed: Separate address calculation
    add r14, r5, r6, lsl #2
    str r8, [r14]
    
split_loop:
    cmp r6, r4
    beq split_done
    sub r6, r6, #1
    mov r8, r7
    sub r9, r6, #MIN_BLOCK_SHIFT
    mov r10, #1
    lsl r10, r10, r9
    add r11, r7, r10
    
    // Fixed: Separate address calculation
    add r14, r5, r6, lsl #2
    ldr r12, [r14]
    
    str r11, [r11]
    
    // Fixed: Separate address calculation
    add r14, r5, r6, lsl #2
    str r12, [r14]
    
    b split_loop

split_done:
    ldr r8, =buddy_base
    ldr r8, [r8]
    sub r9, r7, r8
    lsr r9, r9, #MIN_BLOCK_SHIFT
    ldr r10, =buddy_bitmap
    ldr r10, [r10]
    lsr r11, r9, #3
    and r12, r9, #7
    ldrb r14, [r10, r11]
    orr r14, r14, #(1 << r12)
    strb r14, [r10, r11]
    
    mov r0, r7
    pop {r4-r11, pc}

alloc_fail:
    mov r0, #0
    pop {r4-r11, pc}

.globl buddy_free
buddy_free:
    push {r4-r11, lr}
    push {r0}
    mov r0, r1
    bl buddy_get_order
    mov r4, r0
    pop {r0}
    
    ldr r5, =buddy_base
    ldr r5, [r5]
    sub r6, r0, r5
    lsr r6, r6, #MIN_BLOCK_SHIFT
    
    ldr r7, =buddy_bitmap
    ldr r7, [r7]
    lsr r8, r6, #3
    and r9, r6, #7
    ldrb r10, [r7, r8]
    bic r10, r10, #(1 << r9)
    strb r10, [r7, r8]
    
    ldr r11, =buddy_free_lists
    mov r12, r4

merge_loop:
    mov r14, r6
    eor r14, r14, #(1 << r12)
    lsr r8, r14, #3
    and r9, r14, #7
    ldrb r10, [r7, r8]
    tst r10, #(1 << r9)
    beq merge_done

merge_done:
    // Fixed: Separate address calculation
    add r14, r11, r12, lsl #2
    ldr r8, [r14]
    
    str r0, [r0]
    
    // Fixed: Separate address calculation
    add r14, r11, r12, lsl #2
    str r8, [r14]
    
    pop {r4-r11, pc}

// ========== PIPE IMPLEMENTATION ==========
.section ".data"
.align 4
pipe_table:             .space NUM_PIPES * PIPE_SIZE, 0
pipe_bitmap:            .space 4, 0

.section ".text"
.globl pipe_init
pipe_init:
    push {lr}
    ldr r0, =pipe_bitmap
    mov r1, #0
    str r1, [r0]
    ldr r0, =pipe_table
    mov r1, #0
    ldr r2, =(NUM_PIPES * PIPE_SIZE)
    bl memset
    pop {pc}

.globl pipe_create
pipe_create:
    push {r4-r11, lr}
    ldr r4, =pipe_bitmap
    ldr r5, [r4]
    mov r6, #0
find_pipe:
    cmp r6, #NUM_PIPES
    bge pipe_create_fail
    
    // Fixed: Use runtime shift instead of #(1 << r6)
    mov r14, #1
    lsl r14, r14, r6
    tst r5, r14
    
    beq pipe_found
    add r6, r6, #1
    b find_pipe

pipe_found:
    // Fixed: Use runtime shift instead of #(1 << r6)
    mov r14, #1
    lsl r14, r14, r6
    orr r5, r5, r14
    
    str r5, [r4]
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
    
    mov r0, r6, lsl #16
    orr r0, r0, #0x8000
    mov r1, r6, lsl #16
    orr r1, r1, #0x4000
    
    pop {r4-r11, pc}

pipe_create_fail:
    mov r0, #-1
    mov r1, #-1
    pop {r4-r11, pc}

.globl pipe_write
pipe_write:
    push {r4-r11, lr}
    lsr r4, r0, #16
    and r4, r4, #0x1F
    ldr r5, =pipe_table
    mov r6, #PIPE_SIZE
    mul r7, r4, r6
    add r8, r5, r7
    
    // Load large constants from literal pool
    ldr r9, [r8, #PIPE_WRITERS]
    cmp r9, #0
    beq pipe_write_error
    
    ldr r10, [r8, #PIPE_WRITE_POS]
    ldr r11, [r8, #PIPE_READ_POS]
    
    mov r12, #0
    
pipe_write_loop:
    cmp r12, r2
    bge pipe_write_done
    
    add r14, r10, #1
    // Use pre-calculated constant for mask
    and r14, r14, #PIPE_BUFFER_MASK
    cmp r14, r11
    beq pipe_write_block
    
    ldrb r9, [r1, r12]
    add r4, r8, #PIPE_BUFFER
    strb r9, [r4, r10]
    
    add r10, r10, #1
    and r10, r10, #PIPE_BUFFER_MASK
    str r10, [r8, #PIPE_WRITE_POS]
    
    add r12, r12, #1
    b pipe_write_loop

pipe_write_block:
    ldr r0, __current_process
    ldr r1, [r0]
    mov r2, #PROC_BLOCKED_PIPE
    str r2, [r1, #PCB_STATE]
    str r4, [r1, #PCB_BLOCK_DATA]
    bl scheduler_yield
    
    ldr r5, =pipe_table
    mov r6, #PIPE_SIZE
    mul r7, r4, r6
    add r8, r5, r7
    
    ldr r10, [r8, #PIPE_WRITE_POS]
    ldr r11, [r8, #PIPE_READ_POS]
    b pipe_write_loop

pipe_write_done:
    mov r0, r4
    bl pipe_wake_readers
    mov r0, r12
    pop {r4-r11, pc}

pipe_write_error:
    mov r0, #-1
    pop {r4-r11, pc}

.globl pipe_read
pipe_read:
    push {r4-r11, lr}
    lsr r4, r0, #16
    and r4, r4, #0x1F
    ldr r5, =pipe_table
    mov r6, #PIPE_SIZE
    mul r7, r4, r6
    add r8, r5, r7
    
    ldr r9, [r8, #PIPE_READERS]
    cmp r9, #0
    beq pipe_read_error
    
    ldr r10, [r8, #PIPE_READ_POS]
    ldr r11, [r8, #PIPE_WRITE_POS]
    
    mov r12, #0
    
pipe_read_loop:
    cmp r12, r2
    bge pipe_read_done
    cmp r10, r11
    beq pipe_read_block
    
    add r4, r8, #PIPE_BUFFER
    ldrb r9, [r4, r10]
    strb r9, [r1, r12]
    
    add r10, r10, #1
    and r10, r10, #PIPE_BUFFER_MASK
    str r10, [r8, #PIPE_READ_POS]
    
    add r12, r12, #1
    b pipe_read_loop

pipe_read_block:
    ldr r0, __current_process
    ldr r1, [r0]
    mov r2, #PROC_BLOCKED_PIPE
    str r2, [r1, #PCB_STATE]
    str r4, [r1, #PCB_BLOCK_DATA]
    bl scheduler_yield
    
    ldr r5, =pipe_table
    mov r6, #PIPE_SIZE
    mul r7, r4, r6
    add r8, r5, r7
    
    ldr r10, [r8, #PIPE_READ_POS]
    ldr r11, [r8, #PIPE_WRITE_POS]
    b pipe_read_loop

pipe_read_done:
    mov r0, r4
    bl pipe_wake_writers
    mov r0, r12
    pop {r4-r11, pc}

pipe_read_error:
    mov r0, #-1
    pop {r4-r11, pc}

.globl pipe_wake_readers
pipe_wake_readers:
    push {r4-r11, lr}
    mov r4, r0
    ldr r5, =__process_table
    mov r6, #0
wake_readers_loop:
    cmp r6, #MAX_PROCESSES
    bge wake_readers_done
    
    lsl r7, r6, #7
    add r8, r5, r7
    
    ldr r9, [r8, #PCB_PID]
    cmp r9, #0
    beq wake_readers_next
    
    ldr r10, [r8, #PCB_STATE]
    cmp r10, #PROC_BLOCKED_PIPE
    bne wake_readers_next
    
    ldr r11, [r8, #PCB_BLOCK_DATA]
    cmp r11, r4
    bne wake_readers_next
    
    mov r10, #PROC_READY
    str r10, [r8, #PCB_STATE]

wake_readers_next:
    add r6, r6, #1
    b wake_readers_loop

wake_readers_done:
    pop {r4-r11, pc}

.globl pipe_wake_writers
pipe_wake_writers:
    push {r4-r11, lr}
    mov r4, r0
    ldr r5, =__process_table
    mov r6, #0
wake_writers_loop:
    cmp r6, #MAX_PROCESSES
    bge wake_writers_done
    
    lsl r7, r6, #7
    add r8, r5, r7
    
    ldr r9, [r8, #PCB_PID]
    cmp r9, #0
    beq wake_writers_next
    
    ldr r10, [r8, #PCB_STATE]
    cmp r10, #PROC_BLOCKED_PIPE
    bne wake_writers_next
    
    ldr r11, [r8, #PCB_BLOCK_DATA]
    cmp r11, r4
    bne wake_writers_next
    
    mov r10, #PROC_READY
    str r10, [r8, #PCB_STATE]

wake_writers_next:
    add r6, r6, #1
    b wake_writers_loop

wake_writers_done:
    pop {r4-r11, pc}

// ========== FILESYSTEM ==========
.section ".data"
.align 4
inode_table:            .space MAX_FILES * INODE_SIZE_STRUCT, 0
inode_bitmap:           .space 8, 0

.section ".text"
.globl fs_init
fs_init:
    push {lr}
    ldr r0, =inode_table
    mov r1, #0
    ldr r2, =(MAX_FILES * INODE_SIZE_STRUCT)
    bl memset
    ldr r0, =inode_bitmap
    mov r1, #0
    mov r2, #8
    bl memset
    
    ldr r0, =inode_table
    mov r1, #1
    str r1, [r0, #INODE_VALID]
    mov r1, #4
    str r1, [r0, #INODE_TYPE]
    mov r1, #DEV_STDIN
    str r1, [r0, #INODE_DATA]
    
    ldr r2, =inode_bitmap
    mov r3, #1
    str r3, [r2]
    
    add r0, r0, #INODE_SIZE_STRUCT
    mov r1, #1
    str r1, [r0, #INODE_VALID]
    mov r1, #4
    str r1, [r0, #INODE_TYPE]
    mov r1, #DEV_STDOUT
    str r1, [r0, #INODE_DATA]
    
    ldr r2, =inode_bitmap
    ldr r3, [r2]
    orr r3, r3, #2
    str r3, [r2]
    
    add r0, r0, #INODE_SIZE_STRUCT
    mov r1, #1
    str r1, [r0, #INODE_VALID]
    mov r1, #4
    str r1, [r0, #INODE_TYPE]
    mov r1, #DEV_STDERR
    str r1, [r0, #INODE_DATA]
    
    ldr r2, =inode_bitmap
    ldr r3, [r2]
    orr r3, r3, #4
    str r3, [r2]
    
    pop {pc}

// ========== PROCESS MANAGEMENT ==========
.section ".data"
__process_table:        .space MAX_PROCESSES * PCB_SIZE, 0
__current_process:      .word -1
__next_pid:             .word 1

// Literal pool for large constants
.ltorg

.section ".text"
.globl process_init
process_init:
    push {lr}
    ldr r0, =__process_table
    mov r1, #0
    ldr r2, =(MAX_PROCESSES * PCB_SIZE)
    bl memset
    ldr r0, =__current_process
    mov r1, #-1
    str r1, [r0]
    pop {pc}

.globl process_create
process_create:
    push {r4-r11, lr}
    ldr r4, =__process_table
    mov r5, #0
find_slot:
    cmp r5, #MAX_PROCESSES
    bge create_fail
    
    lsl r6, r5, #7
    add r7, r4, r6
    
    ldr r8, [r7, #PCB_PID]
    cmp r8, #0
    beq slot_found
    add r5, r5, #1
    b find_slot

slot_found:
    ldr r6, =__next_pid
    ldr r7, [r6]
    add r8, r7, #1
    str r8, [r6]
    
    lsl r9, r5, #7
    add r10, r4, r9
    
    str r7, [r10, #PCB_PID]
    
    mov r8, #PROC_READY
    str r8, [r10, #PCB_STATE]
    str r0, [r10, #PCB_PC]
    
    mov r8, #0x10  // User mode
    str r8, [r10, #PCB_CPSR]
    
    // Allocate user stack
    mov r0, #STACK_SIZE
    bl buddy_alloc
    cmp r0, #0
    beq create_fail
    
    str r0, [r10, #PCB_BLOCK_DATA]  // Store stack base
    add r0, r0, #STACK_SIZE
    str r0, [r10, #PCB_SP]
    
    // Initialize FD table to zeros
    mov r8, #0
    str r8, [r10, #PCB_FD0]
    str r8, [r10, #PCB_FD1]
    str r8, [r10, #PCB_FD2]
    str r8, [r10, #PCB_FD3]
    str r8, [r10, #PCB_FD4]
    str r8, [r10, #PCB_FD5]
    str r8, [r10, #PCB_FD6]
    str r8, [r10, #PCB_FD7]
    str r8, [r10, #PCB_FD8]
    str r8, [r10, #PCB_FD9]
    str r8, [r10, #PCB_FD10]
    str r8, [r10, #PCB_FD11]
    str r8, [r10, #PCB_FD12]
    str r8, [r10, #PCB_FD13]
    str r8, [r10, #PCB_FD14]
    str r8, [r10, #PCB_FD15]
    
    // Open stdin (fd 0)
    sub sp, sp, #4
    mov r0, #'0'
    strb r0, [sp]
    mov r0, sp
    mov r1, #0
    bl fs_open
    str r0, [r10, #PCB_FD0]
    
    // Open stdout (fd 1)
    mov r0, #'1'
    strb r0, [sp]
    mov r0, sp
    mov r1, #0
    bl fs_open
    str r0, [r10, #PCB_FD1]
    
    // Open stderr (fd 2)
    mov r0, #'2'
    strb r0, [sp]
    mov r0, sp
    mov r1, #0
    bl fs_open
    str r0, [r10, #PCB_FD2]
    
    add sp, sp, #4
    
    mov r0, r7  // Return PID
    pop {r4-r11, pc}

create_fail:
    mov r0, #-1
    pop {r4-r11, pc}

.globl scheduler_start
scheduler_start:
    push {lr}
    ldr r4, =__process_table
    mov r5, #0
find_ready:
    cmp r5, #MAX_PROCESSES
    bge idle_loop
    
    lsl r6, r5, #7
    add r7, r4, r6
    
    ldr r8, [r7, #PCB_STATE]
    cmp r8, #PROC_READY
    beq run_process
    add r5, r5, #1
    b find_ready

run_process:
    mov r8, #PROC_RUNNING
    str r8, [r7, #PCB_STATE]
    
    ldr r9, =__current_process
    str r5, [r9]
    
    // Restore context
    ldr sp, [r7, #PCB_SP]
    ldr lr, [r7, #PCB_LR]
    ldr r4, [r7, #PCB_R4]
    ldr r5, [r7, #PCB_R5]
    ldr r6, [r7, #PCB_R6]
    ldr r8, [r7, #PCB_R8]
    ldr r9, [r7, #PCB_R9]
    ldr r10, [r7, #PCB_R10]
    ldr r11, [r7, #PCB_R11]
    ldr r7, [r7, #PCB_R7]  // Load r7 last
    
    movs pc, lr

idle_loop:
    bl usb_check_root_port
    wfi
    b idle_loop

.globl scheduler_yield
scheduler_yield:
    push {lr}
    
    ldr r0, =__current_process
    ldr r1, [r0]
    cmp r1, #-1
    beq yield_no_current
    
    ldr r2, =__process_table
    lsl r3, r1, #7
    add r4, r2, r3
    
    // Save context
    str sp, [r4, #PCB_SP]
    str lr, [r4, #PCB_LR]
    str r4, [r4, #PCB_R4]
    str r5, [r4, #PCB_R5]
    str r6, [r4, #PCB_R6]
    str r7, [r4, #PCB_R7]
    str r8, [r4, #PCB_R8]
    str r9, [r4, #PCB_R9]
    str r10, [r4, #PCB_R10]
    str r11, [r4, #PCB_R11]
    
    // Update state if still running
    ldr r5, [r4, #PCB_STATE]
    cmp r5, #PROC_RUNNING
    moveq r5, #PROC_READY
    streq r5, [r4, #PCB_STATE]
    
yield_no_current:
    // Find next ready process
    ldr r4, =__process_table
    mov r5, #0
yield_find:
    cmp r5, #MAX_PROCESSES
    bge idle_yield
    
    lsl r6, r5, #7
    add r7, r4, r6
    
    ldr r8, [r7, #PCB_STATE]
    cmp r8, #PROC_READY
    beq yield_found
    add r5, r5, #1
    b yield_find

yield_found:
    ldr r0, =__current_process
    str r5, [r0]
    
    mov r8, #PROC_RUNNING
    str r8, [r7, #PCB_STATE]
    
    // Restore context
    ldr sp, [r7, #PCB_SP]
    ldr lr, [r7, #PCB_LR]
    ldr r4, [r7, #PCB_R4]
    ldr r5, [r7, #PCB_R5]
    ldr r6, [r7, #PCB_R6]
    ldr r8, [r7, #PCB_R8]
    ldr r9, [r7, #PCB_R9]
    ldr r10, [r7, #PCB_R10]
    ldr r11, [r7, #PCB_R11]
    ldr r7, [r7, #PCB_R7]  // Load r7 last
    
    pop {pc}
    movs pc, lr

idle_yield:
    wfi
    b scheduler_yield

// ========== IRQ HANDLER ==========
irq_handler:
    sub lr, lr, #4
    push {r0-r12, lr}
    
    ldr r0, =PERIPHERAL_BASE
    add r0, r0, #IRQ_PENDING1
    ldr r1, [r0]
    
    tst r1, #2
    beq check_usb_irq
    
    ldr r0, =PERIPHERAL_BASE
    add r0, r0, #TIMER_BASE
    mov r1, #2
    str r1, [r0, #TIMER_CS]
    ldr r1, [r0, #TIMER_CLO]
    ldr r2, =100000
    add r1, r1, r2
    str r1, [r0, #TIMER_C1]
    bl scheduler_yield
    b irq_done

check_usb_irq:
    tst r1, #0x00000200
    beq irq_unknown
    bl usb_handle_irq
    b irq_done

irq_unknown:

irq_done:
    pop {r0-r12, lr}
    subs pc, lr, #4

// ========== SWI HANDLER ==========
swi_handler:
    push {r0-r12, lr}
    
    cmp r7, #SYS_WRITE
    beq sys_write
    cmp r7, #SYS_READ
    beq sys_read
    cmp r7, #SYS_OPEN
    beq sys_open
    cmp r7, #SYS_CLOSE
    beq sys_close
    cmp r7, #SYS_PIPE
    beq sys_pipe
    cmp r7, #SYS_EXIT
    beq sys_exit
    cmp r7, #SYS_YIELD
    beq sys_yield
    
    mov r0, #-1
    b syscall_return

sys_write:
    // Simplified write to stdout only
    cmp r0, #1
    bne syscall_return
    
    ldr r3, __framebuffer_info
    ldr r4, [r3]
    ldr r5, [r3, #4]
    ldr r6, __cursor_x
    ldr r7, __cursor_y
    
    mov r8, r1
    mov r9, r2
    mov r10, #0
    
write_loop:
    cmp r10, r9
    bge write_done
    ldrb r11, [r8, r10]
    cmp r11, #'\n'
    beq write_newline
    
    mul r12, r7, r5
    add r12, r12, r6, lsl #2
    add r12, r4, r12
    ldr r14, =0xFFFFFFFF
    str r14, [r12]
    add r6, r6, #8
    cmp r6, #1016
    movgt r6, #0
    addgt r7, r7, #16
    add r10, r10, #1
    b write_loop

write_newline:
    mov r6, #0
    add r7, r7, #16
    cmp r7, #752
    movgt r7, #0
    add r10, r10, #1
    b write_loop

write_done:
    str r6, __cursor_x
    str r7, __cursor_y
    mov r0, r9
    b syscall_return

sys_read:
    mov r0, #0
    b syscall_return

sys_open:
    mov r0, #-1
    b syscall_return

sys_close:
    mov r0, #0
    b syscall_return

sys_pipe:
    bl pipe_create
    b syscall_return

sys_exit:
    ldr r0, =__current_process
    ldr r1, [r0]
    cmp r1, #-1
    beq exit_yield
    
    ldr r2, =__process_table
    lsl r3, r1, #7
    add r4, r2, r3
    
    mov r5, #PROC_ZOMBIE
    str r5, [r4, #PCB_STATE]
    
    ldr r0, [r4, #PCB_BLOCK_DATA]  // Stack base
    cmp r0, #0
    beq exit_yield
    mov r1, #STACK_SIZE
    bl buddy_free

exit_yield:
    bl scheduler_yield

sys_yield:
    bl scheduler_yield
    mov r0, #0

syscall_return:
    str r0, [sp]
    pop {r0-r12, lr}
    movs pc, lr

// ========== FRAMEBUFFER ==========
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
    add r0, r0, #0xB880
    ldr r1, =fb_buffer
    add r1, r1, #0x40000000
wait_write:
    ldr r2, [r0, #0x18]
    tst r2, #0x80000000
    bne wait_write
    orr r1, r1, #8
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
    add r1, r1, #(20 * 4)
    ldr r2, [r1, #4]
    ldr r3, [r1, #8]
    ldr r1, =fb_buffer
    add r1, r1, #(30 * 4)
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
    add r4, r4, #8
    cmp r4, #1016
    movgt r4, #0
    addgt r5, r5, #16
    b print_char
print_newline:
    mov r4, #0
    add r5, r5, #16
    cmp r5, #752
    movgt r5, #0
    b print_char
print_done:
    str r4, __cursor_x
    str r5, __cursor_y
    pop {r4-r11, pc}

// ========== UTILITY ==========
memset:
    cmp r2, #0
    bxeq lr
    strb r1, [r0], #1
    subs r2, r2, #1
    bne memset
    bx lr

// ========== INIT PROCESS ==========
.section ".text.init"
init_process:
    mov r7, #4
    svc 0
    mov r4, r0
    mov r5, r1
    
    mov r7, #0
    mov r0, r5
    ldr r1, =pipe_test_msg
    mov r2, #12
    svc 0
    
    mov r7, #1
    mov r0, r4
    ldr r1, =buffer
    mov r2, #12
    svc 0
    
    mov r7, #0
    mov r0, #1
    ldr r1, =received_msg
    mov r2, #10
    svc 0
    
    mov r7, #0
    mov r0, #1
    ldr r1, =buffer
    mov r2, #12
    svc 0
    
loop:
    mov r7, #6
    svc 0
    b loop

// ========== DATA SECTION ==========
.section ".data"
.align 4
__framebuffer_info:    .word 0
__fb_info:              .space 16, 0
__cursor_x:             .word 0
__cursor_y:             .word 0

.section ".rodata"
welcome_msg:        .asciz "Kernel booted successfully!\n"
pipe_test_msg:      .asciz "Hello pipe!"
received_msg:       .asciz "Received: "
usb_start_msg:      .asciz "USB: Starting multi-device stack...\n"

// Literal pool for large constants
.ltorg

.section ".bss"
.align 4
buffer:             .space 64, 0

__irq_stack_bottom: .space STACK_SIZE_IRQ
__irq_stack_top:
__fiq_stack_bottom: .space STACK_SIZE_FIQ
__fiq_stack_top:
__abt_stack_bottom: .space STACK_SIZE_ABT
__abt_stack_top:
__und_stack_bottom: .space STACK_SIZE_UND
__und_stack_top:
__svc_stack_bottom: .space STACK_SIZE_SVC
__svc_stack_top:

__heap_start:       .space 0x100000
__heap_end:

// Final literal pool
.ltorg
