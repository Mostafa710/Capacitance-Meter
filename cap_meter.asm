;----------------------------------------------------------------------------;
; Capacitance Meter Control Program R0.01  (C)ChaN, 2003
;----------------------------------------------------------------------------;

.include "2313def.inc"	;Device definition file included in "AVR Family Assembler".
.include "avr.inc"

.def	_0	= r15	;Zero register
.def	_Stm1	= r14	;System timer (250Hz decrement/zero stopped)
.def	_Stm2	= r13	;System timer (250Hz decrement/zero stopped)

.def	_Flags	= r25	;b0:Result is minus
			;b1:Capture completed
			;b2:Integration time out
			;b7:Button pressed

;----------------------------------------------------------;
; Data memory area

.dseg
	.org	RAMTOP

DispPtr:.byte	1	;Display buffer
DispBuf:.byte	4	;/
KeyScan:.byte	2	;

Comp1:	.byte	2	;Range low compensation
Comp2:	.byte	2	;Range high compensation
Comp3:	.byte	2	;Zero compensation value

StrBuf:	.byte	10	;Decimal conversion buffer


;----------------------------------------------------------;
; Program code area

.cseg
	rjmp	reset		;Reset
	rjmp	0		;Extrenal INT0
	rjmp	0		;External INT1
	rjmp	tc1_cap		;TC1 capture
	rjmp	0		;TC1 compare
	rjmp	tc1_ovf		;TC1 overflow
	rjmp	tc0_ovf		;TC0 overflow
;	rjmp	0		;UART Rx UDR ready
;	rjmp	0		;UART Tx UDR ready
;	rjmp	0		;UART Tx sfr empty
;	rjmp	0		;Analog comparator


;----------------------------------------------------------;
; Initialize

reset:
	outi	SPL,low(RAMEND)		;SP
	clr	_0			;Permanent zero reg.

	ldiw	Z, RAMTOP		;Clear RAM
	ldi	AL, 128			;
	st	Z+, _0			;
	dec	AL			;
	brne	PC-2			;/

	outi	PORTD, 0b0111100	;Port D
	outi	DDRD,  0b1111111	;/

	outi	PORTB, 0b01111000	;Port B
	outi	DDRB,  0b10001101	;/

	outi	TCCR0, 0b100		;TC0.ck = 39kHz
	outi	TIMSK, 0b00000010	;Enable TC0.ov

	sbi	ACSR, ACIC		;Connect ACO to TC1 input capture

	clr	_Flags
	sei

	ldiw	Y, DispBuf	;Lamp test (500ms)
	ldi	AL, -1		;
	std	Y+0, AL		;
	std	Y+1, AL		;
	std	Y+2, AL		;
	std	Y+3, AL		;
	ldi	AL, 125		;
	 rcall	dly		;/

	 rcall	load_eep	;Load gain compensation values
	breq	PC+6		;
	ldiw	Z, form3*2	;
	 rcall	put_formed	;
	ldi	AL, 250		;
	 rcall	dly		;/



;----------------------------------------------------------;
; Command processing loop (main)

main:
	ldi	AL, 25		;Wait for 100ms and Timer2 erapsed.
	mov	_Stm1, AL	;
	cbr	_Flags, bit7	;
	sbrc	_Flags, 7	;
	rjmp	btn_pressed	;
	tst	_Stm1		;
	brne	PC-3		;
	tst	_Stm2		;
	brne	PC-5		;/


	ldi	AL, 125		;Start Timer2 (500ms)
	mov	_Stm2, AL	;/
	 rcall	measure		;Measure at low range
	brcc	PC+3		;If time out, retry at high range
	cbi	PORTB, 3	;
	 rcall	measure		;/
	 rcall	adjust_zero	;Refresh display
	 rcall	adjust_gain	;
	 rcall	disp_val	;/
	sbi	PORTB, 3	;Set low range

	rjmp	main



btn_pressed:
	ldi	AL, 4		;Delay 16ms
	 rcall	dly		;/
	sbis	PINB, 6		;Is ISP 1-3 shorted?
	rjmp	cal_low		; yes, calibrate low range
	sbis	PINB, 5		;Is ISP 4-6 shorted?
	rjmp	cal_high	; yes, calibrate high range
	rjmp	can_offset	;else, zero adjustment


cal_high:
	cbi	PORTB, 3	;Measure capacitance for reference high
	 rcall	measure		;
	sbi	PORTB, 3	;/
	ldiw	C, 0		;X:D:C = 1000*65536; (100nF reference cap)
	ldiw	D, 1000		;
	ldiw	X, 0		;/
	ldiw	Z, Comp2
	rjmp	cal_comp

cal_low:
	 rcall	measure		;Measure capacitance for reference low
	 rcall	adjust_zero	;/
	ldiw	C, 0		;X:D:C = 10000*65536; (1nF reference cap)
	ldiw	D, 10000	;
	ldiw	X, 0		;/
	ldiw	Z, Comp1
cal_comp:
	clrw	T0		;X:D:C /= B:A;
	clrw	T2		;
	ldi	EL, 48		;
	lslw	C		;
	rolw	D		;
	rolw	X		;
	rolw	T0		;
	rolw	T2		;
	cpw	T0, A		;
	cpcw	T2, B		;
	brcs	PC+6		;
	subw	T0, A		;
	sbcw	T2, B		;
	inc	CL		;
	dec	EL		;
	brne	PC-21		;/
	or	DL, DH		;Check over flow
	or	DL, XL		;
	or	DL, XH		;
	brne	cal_err		;/
	stdw	Z+0, C
	 rcall	clr_disp
	 rcall	save_eep
	rjmp	main

can_offset:
	 rcall	measure			;Measure capacitance as zero
	or	BL, BH			;Check adjustment range
	brne	cal_err			;
	cpi	BH, high(2000)		;
	brcc	cal_err			;/
	stsw	Comp3, A		;Set the value as zero point
	 rcall	clr_disp
	rjmp	main

cal_err:
	ldiw	Z, form4*2
	 rcall	put_formed
	ldi	AL, 250
	 rcall	dly
	rjmp	main

dly:
	mov	_Stm1, AL
	tst	_Stm1
	brne	PC-1
	ret


;----------------------------------------------------------;
; Measure capacitance

measure:
	out	TCNT1H, _0		;Clear TC1 and set time limit
	out	TCNT1L, _0		;
	clr	T2L			;
	ldi	AL, 20			;
	sbis	PORTB, 3		;
	ldi	AL, 152			;
	mov	T2H, AL			;/
	outi	TIFR,   0b10001000	;Enable TC1.ov, TC1.cap
	outi	TIMSK,  0b10001010	;
	cbr	_Flags, bit0+bit1+bit2	;/
	outi	TCCR1B, 0b01000001	;Start TC1
	cbi	DDRB, 0			;Start to charge

	sbrc	_Flags, 2		;Wait for end of integration
	rjmp	mea_over		;
	sbrs	_Flags, 1		;
	rjmp	PC-3			;/

	outi	TCCR1B, 0b01000000	;Stop TC1
	movew	A, T4			;Get result
	movew	B, T6			;/
	clc
	ret

mea_over:
	outi	TCCR1B, 0b01000000	;Stop TC1
	ldi	AL, 4			;Wait for 16ms
	 rcall	dly			;
	ldi	BH, -1
	sec
	ret



adjust_zero:
	sbis	PORTB, 3	;Skip if in high range
	rjmp	PC+19		;/
	ldsw	C, Comp3	;B:A -= Comp3;
	subw	A, C		;
	sbc	BL, _0		;
	sbc	BH, _0		;/
	brcc	PC+10		;if sign, B:A *= -1; and set sign flag.
	sbr	_Flags, bit0	;
	comw	A		;
	comw	B		;
	adc	AL, _0		;
	adc	AH, _0		;
	adc	BL, _0		;
	adc	BH, _0		;/
	ret

adjust_gain:
	ldiw	Y, Comp1
	sbis	PORTB, 3	;Gain adjustment
	adiw	YL, 2		;Load compensation value in to D by range
	lddw	D, Y+0		;/
	subw	C, C		;B:A = B:A * D / 65536;
	ldi	EL, 33		;
	brcc	PC+3		;
	addw	C, D		;
	rorw	C		;
	rorw	B		;
	rorw	A		;
	dec	EL		;
	brne	PC-10		;
	movew	A, B		;
	movew	B, C		;/
	ret



;----------------------------------------------------------;
; Display value of B:A in unit of 0.1pF

disp_val:
	ldiw	X, StrBuf	;Decimal buffer
	clr	DL		;Number of digits
	inc	DL		;--- Digits++
	clr	CL		; --- /= 10;
	ldi	CH,32		;
	lslw	A		;
	rolw	B		;
	rol	CL		;
	cpi	CL,10		;
	brcs	PC+3		;
	subi	CL,10		;
	inc	AL		;
	dec	CH		;
	brne	PC-10		; /
	st	X+, CL		;
	cp	AL, _0		;
	cpc	AH, _0		;
	cpc	BL, _0		;
	cpc	BH, _0		;
	brne	PC-19		;/
	cpi	DL, 2		;Adjust digits for 0.0pF
	brcc	PC+3		;
	st	X+, _0		;
	inc	DL		;/
	sbis	PORTB, 3	;Adjust digits if in high range
	addi	DL, 3		;/

	ldiw	Z, form2*2-4	;Select form
	sbrs	_Flags, 0	;
	adiw	ZL, 16		;
	adiw	ZL, 4		;
	dec	DL		;
	cpi	DL, 2		;
	brcc	PC-3		;/

put_formed:
	clr	AH
	ldiw	Y, DispBuf
	lpm
	adiw	ZL, 1
	mov	AL, T0L
	clt
	cpi	AL, 2
	brcc	PC+3
	bst	AL, 0
	ld	AL, -X
	pushw	Z
	ldiw	Z, seg7*2
	addw	Z, A
	lpm
	popw	Z
	bld	T0L, 0
	st	Y+, T0L
	cpi	YL, DispBuf+4
	brne	PC-20

	ret


clr_disp:
	ldiw	Y, DispBuf
	st	Y+, _0
	cpi	YL, DispBuf+4
	brne	PC-2
	ret


form4:	.db	14, 5, 15, 15	;E5

form3:	.db	14, 4, 15, 15	;E4

form2:	.db	10, 1, 0, 13	;-0.0p
	.db	10, 0, 0, 13	;-00p
	.db	14, 3, 15, 15	;E3  
	.db	14, 3, 15, 15	;E3  

form1:	.db	15, 1, 0, 13	; 0.0p
	.db	0, 1, 0, 13	;00.0p
	.db	0, 0, 0, 13	;000p
	.db	1, 0, 0, 12	;0.00n
	.db	0, 1, 0, 12	;00.0n
	.db	0, 0, 0, 12	;000n
	.db	1, 0, 0, 11	;0.00u
	.db	0, 1, 0, 11	;00.0u
	.db	0, 0, 0, 11	;000u
	.db	14, 2, 15,15	;E2  
	.db	14, 2, 15,15	;E2  
	.db	14, 2, 15,15	;E2  



seg7:	.db	0xfc,0x60,0xda,0xf2,0x66,0xb6,0xbe,0xe0
	;	 0  , 1  , 2  , 3  , 4  , 5  , 6  , 7 
	.db	0xfe,0xf6,0x02,0x4e,0xc4,0xce,0x9e,0x00
	;	 8  , 9  , -   ,u  , n  , p  , E  ,   


;----------------------------------------------------------;
; Load/Save EEPROM

load_eep:
	ldiw	Y, Comp1	;Load compensation data
	ldiw	C, 0x5501	;
	 rcall	read_eep	;
	st	Y+, AL		;
	add	CH, AL		;
	cpi	YL, Comp1+4	;
	brne	PC-4		;/
	 rcall	read_eep	;Check SUM
	cp	AL, CH		;
	breq	PC+6		;/
	sti	-Y, -1		;Set default value if data have been broken.
	st	-Y, AL		;
	st	-Y, AL		;
	st	-Y, AL		;/
	ret


save_eep:
	ldiw	Y, Comp1	;Save compensation data
	ldiw	C, 0x5501	;
	ld	AL, Y+		;
	add	CH, AL		;
	 rcall	write_eep	;
	cpi	YL, Comp1+4	;
	brne	PC-4		;/
	mov	AL, CH		;Save check SUM

write_eep:
	out	EEAR, CL
	inc	CL
	out	EEDR, AL
	cli
	sbi	EECR, EEMWE
	sbi	EECR, EEWE
	sei
	sbic	EECR, EEWE
	rjmp	PC-1
	ret

read_eep:
	out	EEAR, CL
	inc	CL
	sbi	EECR, EERE
	in	AL, EEDR
	ret



;----------------------------------------------------------;
; TC1 overflow interrupt
;
; T2L counts carry outs from TCNT1. When T2L reaches T2H,
; a time-out error flag will be set.

tc1_ovf:
	push	AL
	in	AL, SREG
	push	AL

	inc	T2L
	cp	T2L, T2H
	brcs	PC+6
	sbi	DDRB, 2
	sbi	DDRB, 0
	sbr	_Flags, bit2
	outi	TIMSK,  0b00000010

	pop	AL
	out	SREG, AL
	pop	AL
	reti



;----------------------------------------------------------;
; TC1 capture interrupt
;
; When Vc reaches 0.17 Vcc, capture t1 and change reference
; voltage to 0.5Vcc. When Vc reaches 0.5 Vcc, capture t2 and
; terminate the measureing.

tc1_cap:
	push	AL
	in	AL, SREG
	push	AL
	sbis	DDRB, 2			;Branch by measureing phase.
	rjmp	tc1c_ed			;/

tc1c_st:	; Vc reaches 0.17 Vcc
	in	T4L, ICR1L		;Capture t1
	in	T4H, ICR1H		;
	mov	T6L, T2L		;/
	cbi	DDRB, 2			;Change Vth to 0.5 Vcc.
	ldi	AL, 20			;Deley several microseconds and clear Irq.
	dec	AL			;
	brne	PC-1			;
	outi	TIFR,   0b00001000	;/
	rjmp	tc1c_e

tc1c_ed:	; Vc reaches 0.5 Vcc
	mov	T6H, T4L		;Capture t2-t1
	in	T4L, ICR1L		;
	sub	T4L, T6H		;
	mov	T6H, T4H		;
	in	T4H, ICR1H		;
	sbc	T4H, T6H		;
	mov	T6H, T6L		;
	mov	T6L, T2L		;
	sbc	T6L, T6H		;
	clr	T6H			;/
	sbi	DDRB, 2			;Set Vth to 0.17 Vcc.
	sbi	DDRB, 0			;Discharge capacitor
	outi	TIMSK,  0b00000010	;Disable Irq.
	sbr	_Flags, bit1		;End of measureing.

tc1c_e:
	pop	AL
	out	SREG, AL
	pop	AL
	reti


;----------------------------------------------------------;
; TC0 overflow interrupt (1kHz)
;
; - Refresh LED display.
; - Scan button inputs.
; - Decrement _Stm1 and _Stm2. (250Hz)

tc0_ovf:
	push	AL
	outi	TCNT0, -39
	sei
	in	AL, SREG
	pushw	A
	pushw	Z

	ldiw	Z, DispPtr		;Next display digit
	ld	AH, Z			;
	inc	AH			;
	cpi	AH, 4			;
	brcs	PC+3			;
	 rcall	scan_key		;
	clr	AH			;
	st	Z+, AH			;/
	outi	PORTD, 0b0111100	;Disable row drive
	add	ZL, AH			;Select row bit
	ldi	AL, bit6		;
	lsr	AL			;
	subi	AH, 1			;
	brcc	PC-2			;
	com	AL			;
	andi	AL, 0b0111100		;/
	ld	AH, Z			;Load column pattern
	ldi	ZL, 8			;Set column pattern into sreg
	sbrs	AH, 0			;
	sbi	PORTD, 1		;
	sbrc	AH, 0			;
	cbi	PORTD, 1		;
	sbi	PORTD, 0		;
	cbi	PORTD, 0		;
	lsr	AH			;
	dec	ZL			;
	brne	PC-8			;/
	out	PORTD, AL		;Enable row drive

t0_exit:
	popw	Z
	popw	A
	out	SREG, AL
	pop	AL
	reti

scan_key:
	in	AL, PINB	;Scan button
	com	AL		;
	andi	AL, bit4	;
	ldd	AH, Z+6		;
	std	Z+6, AL		;
	cp	AL, AH		;
	brne	PC+7		;
	ldd	AH, Z+5		;
	std	Z+5, AL		;
	eor	AH, AL		;
	and	AH, AL		;
	breq	PC+2		;
	sbr	_Flags, bit7	;/

	tst	_Stm1		;Decrement Stm with zero stopeed...
	breq	PC+2		;
	dec	_Stm1		;
	tst	_Stm2		;
	breq	PC+2		;
	dec	_Stm2		;/

	ret

