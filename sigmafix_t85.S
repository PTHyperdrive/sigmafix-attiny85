; Sigma EF protocol compatibility fix - ATtiny85 port
;
; Ported from https://github.com/marcan/sigmafix (ATtiny13, avra syntax) to the
; ATtiny85 and GNU as (avr-gcc) syntax. Logic is unchanged; differences are:
;   - LCLK moved from PB1 (pin 6) to PB2 (pin 7), because INT0 is on PB2 here
;   - TIMER0_OVF is vector 5 (it is vector 3 on the ATtiny13)
;   - TIMSK0/TIFR0 are called TIMSK/TIFR, and SPH must be set as well
;   - clock is the 8 MHz internal RC (the ATtiny13 version runs at 9.6 MHz)
;
; Build with -DDIGISPARK for a chip taken off a Digispark board, flashed through
; its micronucleus bootloader (fuses left at the 16.5 MHz PLL clock). Add
; -DBYPASS_BOOTLOADER to skip the bootloader's 5 s wait on every power-up; see
; bypass_bootloader below.
;
; Copyright 2018 Hector Martin "marcan" <marcan@marcan.st>
; ATtiny85 port Copyright 2026 PT.Hyperdrive
;
; Permission is hereby granted, free of charge, to any person obtaining a copy
; of this software and associated documentation files (the "Software"), to deal
; in the Software without restriction, including without limitation the rights
; to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
; copies of the Software, and to permit persons to whom the Software is
; furnished to do so, subject to the following conditions:
;
; The above copyright notice and this permission notice shall be included in all
; copies or substantial portions of the Software.
;
; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
; AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
; SOFTWARE.

#include <avr/io.h>

#define IO(reg) _SFR_IO_ADDR(reg)

; EF protocol pins. We don't need DLC.
#define DCL     0       /* PB0, pin 5 */
#define LCLK    2       /* PB2, pin 7 (INT0) */

#ifdef DIGISPARK
; Waking from power-down takes far too long on the PLL clock to catch the first
; bit, so sleep in idle mode instead. PB3/PB4 are the USB lines of the bootloader,
; so the debugging outputs are disabled and those pins are left as inputs.
#define F_CPU       16500000
#define SLEEP_MODE  0               /* idle */
#define DBG_DDR     0
#define DBG_SET(pin)
#define DBG_CLR(pin)
#else
; debugging pins
#define CMD     3       /* PB3, pin 2 */
#define AWAKE   4       /* PB4, pin 3 */

#define F_CPU       8000000
#define SLEEP_MODE  2               /* power-down */
#define DBG_DDR     ((1<<CMD)|(1<<AWAKE))
#define DBG_SET(pin) sbi IO(PORTB), pin
#define DBG_CLR(pin) cbi IO(PORTB), pin
#endif

; 700µs command timeout
#define TIMEOUT (700 * (F_CPU / 64) / 1000000)

#define zl r30
#define zh r31

    .section .text
    .org 0
vectors:
    rjmp    reset   ; cold boot
    reti            ; INT0 - just wake up from SLEEP
    reti            ; PCINT0 (unused)
    reti            ; TIMER1_COMPA (unused)
    reti            ; TIMER1_OVF (unused)
    rjmp    reset   ; TIMER0_OVF - on timeout, reset everything (incl. SP)

reset:
    cli
    clr r1
    ldi r18, lo8(RAMEND)
    out IO(SPL), r18
    ldi r18, hi8(RAMEND)
    out IO(SPH), r18

    ; a bootloader may have left the watchdog running
    wdr
    out IO(MCUSR), r1
    ldi r18, (1<<WDCE)|(1<<WDE)
    out IO(WDTCR), r18
    out IO(WDTCR), r1

#ifdef BYPASS_BOOTLOADER
    rcall bypass_bootloader
#endif

    ldi r18, DBG_DDR               ; CMD+AWAKE outputs
    out IO(DDRB), r18
    ldi r18, (1<<PB1)|(1<<PB5)      ; pull-up on all unused pins
    out IO(PORTB), r18
    DBG_SET(AWAKE)

    ; set up low level IRQ (for LCLK), but disable it for now
    ; set sleep mode to power-down (idle on a Digispark chip)
    ldi r18, (1<<SE)|(SLEEP_MODE<<SM0)
    out IO(MCUCR), r18
    ldi r20, (1<<INT0)
    out IO(GIMSK), r1

waitcmd:
    ; stop timer 0 and prepare to use it as a command timeout
    out IO(TCCR0A), r1
    out IO(TCCR0B), r1
    ldi r17, (3 << CS00)
    ldi r18, 255 - TIMEOUT
    out IO(TCNT0), r18
    ; clear IRQ flag and enable
    out IO(TIMSK), r1
    ldi r18, (1 << TOV0)
    out IO(TIFR), r18
    ldi r18, (1 << TOIE0)
    out IO(TIMSK), r18

    ; ensure LCLK is high (idle)
1:  sbis IO(PINB), LCLK
    rjmp 1b

    ldi zh, hi8(argctab)
    clr zl  ; command opcode

    ; LCLK is high, wait in SLEEP mode until the next command
    DBG_CLR(AWAKE)
    out IO(GIMSK), r20 ; (1 << INT0)
    sei
    ; note that AVR guarantees forward progress even if we never clear the IRQ
    ; source in the IRQ handler. Under normal conditions, the sleep instruction
    ; should execute with no IRQ pending, then when LCLK goes low the IRQ will
    ; be triggered, be returned from left pending, and then AVR guarantees that
    ; the out following the SLEEP will be executed, which should prevent the IRQ
    ; handler from firing again. In a pathological case where LCLK goes low
    ; before the sleep instruction, the handler may be entered more than once.
    sleep
    out IO(GIMSK), r1   ; disable INT0 IRQ
    out IO(TCCR0B), r17 ; start Timer 0 (command timeout)
    DBG_SET(AWAKE)
    DBG_SET(CMD)

    ; bit 7
    ; wait for LCLK rising edge (sample)
1:  sbis IO(PINB), LCLK
    rjmp 1b
    sbic IO(PINB), DCL
    sbr zl, 0x80

.macro cbit mask
    ; wait for LCLK falling edge (drive)
1:  sbic IO(PINB), LCLK
    rjmp 1b
    ; wait for LCLK rising edge (sample)
1:  sbis IO(PINB), LCLK
    rjmp 1b
    sbic IO(PINB), DCL
    sbr zl, \mask
.endm

    cbit 0x40
    cbit 0x20
    cbit 0x10
    cbit 0x08
    cbit 0x04
    cbit 0x02

    cpi zl, 0x12   ; Aperture command (0x12 or 0x13)
    brne passthrough

    ; Aperture command, stomp on last bit!
    ; Prepare DDRB value
    in r18, IO(DDRB)
    sbr r18, (1<<DCL)
    ; Wait for LCLK falling edge (drive)
1:  sbic IO(PINB), LCLK
    rjmp 1b
    ; Stomp
    out IO(DDRB), r18
    ; Wait for LCLK rising edge (sample)
1:  sbis IO(PINB), LCLK
    rjmp 1b
    ; Wait a bit (~1us) before releasing
    .rept F_CPU / 1000000
    nop
    .endr
    ; Release
    cbi IO(DDRB), DCL

    rjmp handle_command

passthrough:
    cbit 0x01

handle_command:

    ; Wait for LCLK falling edge (ACK)
1:  sbic IO(PINB), LCLK
    rjmp 1b

    ; transfer complete, stop timer and reset
    out IO(TCCR0B), r1
    ldi r18, 255 - TIMEOUT
    out IO(TCNT0), r18
    DBG_CLR(CMD)

    lpm r16, Z  ; get argument count

next_argument:
    tst r16
    brne have_arg
    rjmp waitcmd

have_arg:
    dec r16

    ; Wait for LCLK rising edge (end of ACK)
1:  sbis IO(PINB), LCLK
    rjmp 1b

    ; wait for LCLK falling edge (drive)
1:  sbic IO(PINB), LCLK
    rjmp 1b

    ; enable timer
    out IO(TCCR0B), r17 ; start Timer 0 (command timeout)
    ; wait for LCLK rising edge (sample)
1:  sbis IO(PINB), LCLK
    rjmp 1b

.macro abit
    ; wait for LCLK falling edge (drive)
1:  sbic IO(PINB), LCLK
    rjmp 1b
    ; wait for LCLK rising edge (sample)
1:  sbis IO(PINB), LCLK
    rjmp 1b
.endm

    abit ; bit 6
    abit ; bit 5
    abit ; bit 4
    abit ; bit 3
    abit ; bit 2
    abit ; bit 1
    abit ; bit 0

    ; Wait for LCLK falling edge (ACK)
1:  sbic IO(PINB), LCLK
    rjmp 1b

    ; transfer complete, stop timer and reset
    out IO(TCCR0B), r1
    ldi r18, 255 - TIMEOUT
    out IO(TCNT0), r18

    rjmp next_argument

#ifdef BYPASS_BOOTLOADER
; micronucleus 1.x points word 0 (reset) and word 2 (PCINT0, its USB interrupt)
; at itself, so every power-up first waits ~5 s for a USB host. On the first run,
; put our own vectors back into flash page 0 so the chip starts straight into this
; program. After that the bootloader can no longer be entered: reflash via ISP.
; Must not live in page 0, since that page is being rewritten while this runs.
#define RJMP_RESET  (0xC000 + (reset - vectors) / 2 - 1)
#define RETI_OP     0x9518

bypass_bootloader:
    rcall vectors_ok
    breq 9f

    ; clear the temporary page buffer
    ldi r18, (1<<CTPB)
    out IO(SPMCSR), r18

    ; fill the page buffer with page 0 as it is now, except words 0 and 2
    clr zl
1:  lpm r0, Z+
    lpm r1, Z
    sbiw zl, 1
    cpi zl, 0
    brne 2f
    ldi r18, lo8(RJMP_RESET)
    mov r0, r18
    ldi r18, hi8(RJMP_RESET)
    mov r1, r18
2:  cpi zl, 4
    brne 3f
    ldi r18, lo8(RETI_OP)
    mov r0, r18
    ldi r18, hi8(RETI_OP)
    mov r1, r18
3:  ldi r18, (1<<SPMEN)
    out IO(SPMCSR), r18
    spm
    adiw zl, 2
    cpi zl, SPM_PAGESIZE
    brne 1b

    ; erase and rewrite page 0 (the CPU halts ~4.5 ms for each)
    clr zl
    ldi r18, (1<<PGERS)|(1<<SPMEN)
    out IO(SPMCSR), r18
    spm
    ldi r18, (1<<PGWRT)|(1<<SPMEN)
    out IO(SPMCSR), r18
    spm
    clr r1

    ; blink the Digispark LED on P1 three times if it worked
    rcall vectors_ok
    brne 9f
    sbi IO(DDRB), PB1
    ldi r19, 6
4:  sbi IO(PINB), PB1   ; toggle
    rcall delay_150ms
    dec r19
    brne 4b
    cbi IO(DDRB), PB1
9:  ret

; Z flag set if words 0 and 2 already hold our own vectors
vectors_ok:
    clr zh
    clr zl
    lpm r24, Z+
    lpm r25, Z+
    lpm r22, Z+
    lpm r23, Z
    ldi r18, hi8(RJMP_RESET)
    cpi r24, lo8(RJMP_RESET)
    cpc r25, r18
    brne 1f
    ldi r18, hi8(RETI_OP)
    cpi r22, lo8(RETI_OP)
    cpc r23, r18
1:  ret

delay_150ms:
    ldi r18, F_CPU / 1333333    ; ~12 x 12.5 ms
1:  ldi r24, lo8(50000)
    ldi r25, hi8(50000)
2:  sbiw r24, 1
    brne 2b
    dec r18
    brne 1b
    ret

.if (bypass_bootloader - vectors) < SPM_PAGESIZE
.error "bypass_bootloader must not be in flash page 0"
.endif
#endif

    ; Table of command argument counts, to maintain protocol sync.
    ; Indexed by zl alone, so it must start on a 256-byte boundary.
    .balign 256
argctab:
    .byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0  ;00
    .byte 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1  ;10
    .byte 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1  ;20
    .byte 3, 2, 1, 3, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0  ;30
    .byte 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2  ;40
    .byte 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1  ;50
    .byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 5, 5, 1, 1, 1, 1, 1  ;60
    .byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0  ;70
    .byte 7, 3, 0, 0, 0, 0, 4, 3, 0, 0, 0, 0, 0, 0, 0, 0  ;80
    .byte 1, 2, 0, 3, 1, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0  ;90
    .byte 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0  ;a0
    .byte 2, 1, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0  ;b0
    .byte 1, 1, 3, 0, 1, 1, 0, 1, 0, 5, 5, 0, 0, 0, 0, 1  ;c0
    .byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0  ;d0
    .byte 1, 0, 0, 0, 1, 0, 0, 0, 5, 0, 5, 0, 0, 0, 0, 0  ;e0
    .byte 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0  ;f0
