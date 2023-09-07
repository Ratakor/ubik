org 0x0
bits 16

%define ENDL 0x0d, 0x0a

start:
	; print kernel message
	mov si, msg_kernel
	call puts

.halt:
	cli
	hlt

; print a string to the screen
; param:
;  - ds:si points to string
puts:
	; save registers we will modify
	push si
	push ax
	push bx

.loop:
	lodsb ; loads next char in al
	or al, al ; verify if next char is null
	jz .done

	mov ah, 0x0e ; call bios interrupt
	mov bh, 0
	int 0x10

	jmp .loop

.done:
	pop bx
	pop ax
	pop si
	ret

msg_kernel: db "hello world from kernel", ENDL, 0
