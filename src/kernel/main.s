org 0x7c00
bits 16

%define ENDL 0x0d, 0x0a

start:
	jmp main

; print a string to the screen
; param:
;  - ds:si points to string
puts:
	; save registers we will modify
	push si
	push ax

.loop:
	lodsb ; loads next char in al
	or al, al ; verify if next char is null
	jz .done

	mov ah, 0x0e ; call bios interrupt
	mov bh, 0
	int 0x10

	jmp .loop

.done:
	pop ax
	pop si
	ret

main:
	; setup data segments
	mov ax, 0 ; can't write a constant to ds/es directly
	mov ds, ax
	mov es, ax

	; setup stack
	mov ss, ax
	mov sp, 0x7c00 ; stack grows downwards from where we are loaded in memory

	; print message
	mov si, msg
	call puts

	hlt

.halt:
	jmp .halt

msg: db "Hello world!", ENDL, 0

times 510-($-$$) db 0
dw 0AA55h
