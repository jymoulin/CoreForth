@ -- vim:syntax=asm:foldmethod=marker:foldmarker=@\ --\ ,@\ ---:

@ ---------------------------------------------------------------------
@ -- Definitions ------------------------------------------------------

    .set UART1,       0x40013800
    .set UART2,       0x40004400
    .set UART3,       0x40004800
    .set UART_SR,           0x00
    .set UART_DR,           0x04
    .set UART_BRR,          0x08
    .set UART_CR1,          0x0c
    .set UART_CR2,          0x10
    .set UART_CR3,          0x14
    .set UART_GPTR,         0x18

    .set RCC,         0x40021000
    .set RCC_CR,      0x40021000
    .set RCC_CFGR,    0x40021004
    .set RCC_CIR,     0x40021008
    .set RCC_APB2RSTR,0x4002100c
    .set RCC_APB1RSTR,0x40021010
    .set RCC_AHBENR,  0x40021014
    .set RCC_APB2ENR, 0x40021018
    .set RCC_APB1ENR, 0x4002101c
    .set RCC_BDCR,    0x40021020
    .set RCC_CSR,     0x40021024
    .set RCC_AHBRSTR, 0x40021028
    .set RCC_CFGR2,   0x4002102c

    .set NVIC,        0xe000e000
    .set NVIC_SETENA_BASE, 0x100
    .set NVIC_ACTIVE_BASE, 0x300

    .set GPIOA,       0x40010800
    .set GPIOB,       0x40010c00
    .set GPIOC,       0x40011000
    .set GPIOD,       0x40011400
    .set GPIOE,       0x40011800
    .set GPIOF,       0x40011c00
    .set GPIOG,       0x40012000
    .set GPIO_CRL,         0x000
    .set GPIO_CRH,         0x004
    .set GPIO_IDR,         0x008
    .set GPIO_ODR,         0x00c
    .set GPIO_BSRR,        0x010
    .set GPIO_BRR,         0x014
    .set GPIO_LCKR,        0x018

    .set STCTRL,      0xe000e010
    .set STRELOAD,    0xe000e014
    .set STCURRENT,   0xe000e018

@ ---------------------------------------------------------------------
@ -- Interrupt vectors ------------------------------------------------

    .text
    .syntax unified

    .global _start
    .global reset_handler
_start:
    .long addr_TOS                    /* Top of Stack                 */
    .long reset_handler + 1           /* Reset Handler                */
    .long nmi_handler + 1             /* NMI Handler                  */
    .long hardfault_handler + 1       /* Hard Fault Handler           */
    .long memmanage_handler + 1       /* MPU Fault Handler            */
    .long busfault_handler + 1        /* Bus Fault Handler            */
    .long usagefault_handler + 1      /* Usage Fault Handler          */
    .long 0                           /* Reserved                     */
    .long 0                           /* Reserved                     */
    .long 0                           /* Reserved                     */
    .long 0                           /* Reserved                     */

    .org 0x150

@ ---------------------------------------------------------------------
@ -- Board specific code and initialization ---------------------------

init_board:
    push {lr}

    @ safety delay of 3x8000000 ticks (~ 3 seconds)
    ldr r0, =8000000
    bl delay

    @ reset the interrupt vector table
    ldr r0, =addr_IVT
    mov r1, #0
    mov r2, 48
1:  str r1, [r0], #4
    subs r2, r2, #1
    bgt 1b

    @ enable PIC interrupts
    mov r0, #0
    msr primask, r0
    mov r0, #0
    msr basepri, r0
    ldr r0, =(NVIC + NVIC_SETENA_BASE)
    mov r1, #0
.ifdef UART_USE_INTERRUPTS
    orr r1, #0x20
.endif
    str r1, [r0]

    @ enable clocks on all timers, UARTS, ADC, PWM, SSI and I2C and GPIO ports
    ldr r0, =RCC_APB2ENR
    ldr r1, =0x4
    str r1, [r0]
    ldr r0, =RCC_APB1ENR
    ldr r1, =0x20000
    str r1, [r0]

    mov r0, #32
    bl delay

    @ enable pins on GPIOA
    ldr r0, =(GPIOA + GPIO_CRL)
    ldr r1, =0x44444b44
    str r1, [r0]

    mov r0, #32
    bl delay

    @ enable UART
    ldr r0, =(UART2 + UART_CR1)
    ldr r1, =0x200c
    str r1, [r0]

    @ set UART baud rate
    ldr r0, =(UART2 + UART_BRR)
    ldr r1, =(8000000 / 115200)
    str r1, [r0]

    @ enable SYSTICK
    ldr r0, =STRELOAD
    ldr r1, =0x00ffffff
    str r1, [r0]
    ldr r0, =STCTRL
    mov r1, #5
    str r1, [r0]

    mov r0, #32
    bl delay

    pop {pc}
    .align 2, 0
    .ltorg

read_key_interrupt:
    mov pc, lr

read_key_polled:
    push {r1, r2, r3, lr}
    ldr r1, =UART2
    mov r2, #32
1:  ldr r3, [r1, #UART_SR]
    and r3, r2
    cmp r3, r2
    bne 1b
    ldrb r0, [r1, #UART_DR]
    pop {r1, r2, r3, pc}

.ifdef UART_USE_INTERRUPTS
    .set read_key, read_key_interrupt
.else
    .set read_key, read_key_polled
.endif

putchar:
    push {r1, r2, r3, lr}
    mov r2, #0x80
    ldr r3, =UART2
1:  ldr r1, [r3, #UART_SR]
    and r1, r2
    cmp r1, r2
    bne 1b
    str r0, [r3, #UART_DR]
    pop {r1, r2, r3, pc}

@ ---------------------------------------------------------------------
@ -- IRQ handlers -----------------------------------------------------

@ Generic handler which checks if a Forth word is defined to handle the
@ IRQ. If not, this handler will simply return. Note that this will
@ usually lock up the system as the interrupt will be retriggered, the
@ generic handler is not clearing the interrupt.

generic_forth_handler:
    ldr r0, =addr_IVT
    mrs r1, ipsr
    sub r1, r1, #1
    lsl r1, #2
    add r0, r0, r1
    ldr r2, [r0]
    cmp r2, #0
    beq 1f
    push {r4 - r12, lr}
    ldr r6, =irq_stack_top
    mov r7, r0
    ldr r0, [r7]
    add r7, r7, #4
    ldr r1, [r0]
    add r1, r1, #1
    bx r1
1:  bx lr

nmi_handler:
    b .

hardfault_handler:
    mrs r0, psp
    b .

memmanage_handler:
    b .

busfault_handler:
    b .

usagefault_handler:
    b .

svc_handler:
    b .

debugmon_handler:
    b .

pendsv_handler:
    b .

systick_handler:
    b .

gpioa_handler:
gpiob_handler:
gpioc_handler:
gpiod_handler:
gpioe_handler:
uart0_handler:
uart1_handler:
ssi_handler:
i2c_handler:
pwm0_handler:
pwm1_handler:
pwm2_handler:
adcseq0_handler:
adcseq1_handler:
adcseq2_handler:
adcseq3_handler:
watchdog_handler:
timer0a_handler:
timer0b_handler:
timer1a_handler:
timer1b_handler:
timer2a_handler:
timer2b_handler:
adcomp_handler:
    b generic_forth_handler

@ ---------------------------------------------------------------------
@ -- CoreForth starts here --------------------------------------------

    .ltorg

    .include "CoreForth.s"

@ ---------------------------------------------------------------------
@ -- Board specific words ---------------------------------------------

    defconst "NVIC", 4, , _NVIC, NVIC

    defcode "NVIC-SETENA", 11, , NVIC_SETENA
    ldr r0, =NVIC
    ldr r1, =NVIC_SETENA_BASE
    add r0, r1, r0
    push {r0}
    NEXT

    defconst "DISP-FONT", 9, , _DISP_FONT, DISP_FONT
DISP_FONT:
    .byte 0x00, 0x00, 0x00, 0x00, 0x00   @ " "
    .byte 0x00, 0x00, 0x4f, 0x00, 0x00   @ !
    .byte 0x00, 0x07, 0x00, 0x07, 0x00   @ "
    .byte 0x14, 0x7f, 0x14, 0x7f, 0x14   @ #
    .byte 0x24, 0x2a, 0x7f, 0x2a, 0x12   @ $
    .byte 0x23, 0x13, 0x08, 0x64, 0x62   @ %
    .byte 0x36, 0x49, 0x55, 0x22, 0x50   @ &
    .byte 0x00, 0x05, 0x03, 0x00, 0x00   @ '
    .byte 0x00, 0x1c, 0x22, 0x41, 0x00   @ (
    .byte 0x00, 0x41, 0x22, 0x1c, 0x00   @ )
    .byte 0x14, 0x08, 0x3e, 0x08, 0x14   @ *
    .byte 0x08, 0x08, 0x3e, 0x08, 0x08   @ +
    .byte 0x00, 0x50, 0x30, 0x00, 0x00   @ ,
    .byte 0x08, 0x08, 0x08, 0x08, 0x08   @ -
    .byte 0x00, 0x60, 0x60, 0x00, 0x00   @ .
    .byte 0x20, 0x10, 0x08, 0x04, 0x02   @ /
    .byte 0x3e, 0x51, 0x49, 0x45, 0x3e   @ 0
    .byte 0x00, 0x42, 0x7f, 0x40, 0x00   @ 1
    .byte 0x42, 0x61, 0x51, 0x49, 0x46   @ 2
    .byte 0x21, 0x41, 0x45, 0x4b, 0x31   @ 3
    .byte 0x18, 0x14, 0x12, 0x7f, 0x10   @ 4
    .byte 0x27, 0x45, 0x45, 0x45, 0x39   @ 5
    .byte 0x3c, 0x4a, 0x49, 0x49, 0x30   @ 6
    .byte 0x01, 0x71, 0x09, 0x05, 0x03   @ 7
    .byte 0x36, 0x49, 0x49, 0x49, 0x36   @ 8
    .byte 0x06, 0x49, 0x49, 0x29, 0x1e   @ 9
    .byte 0x00, 0x36, 0x36, 0x00, 0x00   @ :
    .byte 0x00, 0x56, 0x36, 0x00, 0x00   @ ;
    .byte 0x08, 0x14, 0x22, 0x41, 0x00   @ <
    .byte 0x14, 0x14, 0x14, 0x14, 0x14   @ =
    .byte 0x00, 0x41, 0x22, 0x14, 0x08   @ >
    .byte 0x02, 0x01, 0x51, 0x09, 0x06   @ ?
    .byte 0x32, 0x49, 0x79, 0x41, 0x3e   @ @
    .byte 0x7e, 0x11, 0x11, 0x11, 0x7e   @ A
    .byte 0x7f, 0x49, 0x49, 0x49, 0x36   @ B
    .byte 0x3e, 0x41, 0x41, 0x41, 0x22   @ C
    .byte 0x7f, 0x41, 0x41, 0x22, 0x1c   @ D
    .byte 0x7f, 0x49, 0x49, 0x49, 0x41   @ E
    .byte 0x7f, 0x09, 0x09, 0x09, 0x01   @ F
    .byte 0x3e, 0x41, 0x49, 0x49, 0x7a   @ G
    .byte 0x7f, 0x08, 0x08, 0x08, 0x7f   @ H
    .byte 0x00, 0x41, 0x7f, 0x41, 0x00   @ I
    .byte 0x20, 0x40, 0x41, 0x3f, 0x01   @ J
    .byte 0x7f, 0x08, 0x14, 0x22, 0x41   @ K
    .byte 0x7f, 0x40, 0x40, 0x40, 0x40   @ L
    .byte 0x7f, 0x02, 0x0c, 0x02, 0x7f   @ M
    .byte 0x7f, 0x04, 0x08, 0x10, 0x7f   @ N
    .byte 0x3e, 0x41, 0x41, 0x41, 0x3e   @ O
    .byte 0x7f, 0x09, 0x09, 0x09, 0x06   @ P
    .byte 0x3e, 0x41, 0x51, 0x21, 0x5e   @ Q
    .byte 0x7f, 0x09, 0x19, 0x29, 0x46   @ R
    .byte 0x46, 0x49, 0x49, 0x49, 0x31   @ S
    .byte 0x01, 0x01, 0x7f, 0x01, 0x01   @ T
    .byte 0x3f, 0x40, 0x40, 0x40, 0x3f   @ U
    .byte 0x1f, 0x20, 0x40, 0x20, 0x1f   @ V
    .byte 0x3f, 0x40, 0x38, 0x40, 0x3f   @ W
    .byte 0x63, 0x14, 0x08, 0x14, 0x63   @ X
    .byte 0x07, 0x08, 0x70, 0x08, 0x07   @ Y
    .byte 0x61, 0x51, 0x49, 0x45, 0x43   @ Z
    .byte 0x00, 0x7f, 0x41, 0x41, 0x00   @ [
    .byte 0x02, 0x04, 0x08, 0x10, 0x20   @ "\"
    .byte 0x00, 0x41, 0x41, 0x7f, 0x00   @ ]
    .byte 0x04, 0x02, 0x01, 0x02, 0x04   @ ^
    .byte 0x40, 0x40, 0x40, 0x40, 0x40   @ _
    .byte 0x00, 0x01, 0x02, 0x04, 0x00   @ `
    .byte 0x20, 0x54, 0x54, 0x54, 0x78   @ a
    .byte 0x7f, 0x48, 0x44, 0x44, 0x38   @ b
    .byte 0x38, 0x44, 0x44, 0x44, 0x20   @ c
    .byte 0x38, 0x44, 0x44, 0x48, 0x7f   @ d
    .byte 0x38, 0x54, 0x54, 0x54, 0x18   @ e
    .byte 0x08, 0x7e, 0x09, 0x01, 0x02   @ f
    .byte 0x0c, 0x52, 0x52, 0x52, 0x3e   @ g
    .byte 0x7f, 0x08, 0x04, 0x04, 0x78   @ h
    .byte 0x00, 0x44, 0x7d, 0x40, 0x00   @ i
    .byte 0x20, 0x40, 0x44, 0x3d, 0x00   @ j
    .byte 0x7f, 0x10, 0x28, 0x44, 0x00   @ k
    .byte 0x00, 0x41, 0x7f, 0x40, 0x00   @ l
    .byte 0x7c, 0x04, 0x18, 0x04, 0x78   @ m
    .byte 0x7c, 0x08, 0x04, 0x04, 0x78   @ n
    .byte 0x38, 0x44, 0x44, 0x44, 0x38   @ o
    .byte 0x7c, 0x14, 0x14, 0x14, 0x08   @ p
    .byte 0x08, 0x14, 0x14, 0x18, 0x7c   @ q
    .byte 0x7c, 0x08, 0x04, 0x04, 0x08   @ r
    .byte 0x48, 0x54, 0x54, 0x54, 0x20   @ s
    .byte 0x04, 0x3f, 0x44, 0x40, 0x20   @ t
    .byte 0x3c, 0x40, 0x40, 0x20, 0x7c   @ u
    .byte 0x1c, 0x20, 0x40, 0x20, 0x1c   @ v
    .byte 0x3c, 0x40, 0x30, 0x40, 0x3c   @ w
    .byte 0x44, 0x28, 0x10, 0x28, 0x44   @ x
    .byte 0x0c, 0x50, 0x50, 0x50, 0x3c   @ y
    .byte 0x44, 0x64, 0x54, 0x4c, 0x44   @ z
    .byte 0x00, 0x08, 0x36, 0x41, 0x00   @ {
    .byte 0x00, 0x00, 0x7f, 0x00, 0x00   @ |
    .byte 0x00, 0x41, 0x36, 0x08, 0x00   @ }
    .byte 0x02, 0x01, 0x02, 0x04, 0x02   @ ~

    .ltorg

    defcode "RETI", 4, , RETI
    pop {r4 - r12, pc}

    defword ";I", 2, F_IMMED, SEMICOLONI
    .word LIT, RETI, COMMAXT, REVEAL, LBRACKET, EXIT

    defword "COLD", 4, , COLD
.ifdef PRECOMPILE
    .word PRECOMP_BEGIN, LIT, 1f, EVALUATE, PRECOMP_END
1:  .include "CoreForth.gen.s"
.else
    .word QUIT
.endif

    defvar "SBUF", 4, , SBUF, 128
    defvar "SBUF-HEAD", 9, , SBUF_HEAD
    defvar "SBUF-TAIL", 9, , SBUF_TAIL
    defvar "IVT", 3, , IVT, 48 * 4

    .ltorg

    .set last_rom_word, link
    .set end_of_rom, .

@ eval_words:
@    .include "stm32p103.gen.s"

    .set last_word, link
    .set data_start, compiled_here 
