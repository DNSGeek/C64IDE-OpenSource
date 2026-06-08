; ═══════════════════════════════════════════════════════════
; C64 IDE — Sample Assembly Program
; Border color cycle with raster sync
; Build with: ca65 -t c64 sample.s -o sample.o
;              ld65 -t c64 -C c64_prg.cfg -o sample.prg sample.o
; Or just press ⌘R in C64 IDE!
; ═══════════════════════════════════════════════════════════

.export __LOADADDR__: absolute = 1

; ── Load address ──────────────────────────────────────────
.segment "LOADADDR"
    .word $0801

; ── BASIC stub: 10 SYS 2064 ──────────────────────────────
.segment "STARTUP"
    .word @end          ; Pointer to next BASIC line
    .word 10            ; Line number
    .byte $9E           ; SYS token
    .byte "2064"        ; Start address as ASCII
    .byte 0             ; End of line
@end:
    .word 0             ; End of BASIC program

; ── Main code ─────────────────────────────────────────────
.segment "CODE"

; VIC-II registers
VIC_BORDER  = $D020
VIC_BG      = $D021
VIC_RASTER  = $D012
VIC_CTRL1   = $D011

; Colors
BLACK   = 0
WHITE   = 1
RED     = 2
CYAN    = 3
PURPLE  = 4
GREEN   = 5
BLUE    = 6
YELLOW  = 7

main:
    ; Set black background
    lda #BLACK
    sta VIC_BG
    sta VIC_BORDER

    ; Clear screen (JSR KERNAL SCINIT equivalent)
    lda #$93            ; PETSCII clear screen
    jsr $FFD2           ; CHROUT

    ; Print message
    ldx #0
@print_loop:
    lda message,x
    beq @done_print
    jsr $FFD2           ; CHROUT
    inx
    bne @print_loop
@done_print:

    ; ── Main loop: cycle border colors ────────────────────
    ldx #0              ; Color counter
@cycle:
    ; Wait for raster line 255 (bottom of visible area)
@wait_raster:
    lda VIC_RASTER
    cmp #255
    bne @wait_raster

    ; Wait for raster to leave line 255 (avoid double-trigger)
@wait_leave:
    lda VIC_RASTER
    cmp #255
    beq @wait_leave

    ; Set border color
    stx VIC_BORDER

    ; Advance color (0-15, wrap)
    inx
    cpx #16
    bne @no_wrap
    ldx #0
@no_wrap:

    ; Check for key press to exit
    jsr $FFE4           ; GETIN
    cmp #0
    beq @cycle          ; No key → keep cycling

    ; Restore and exit
    lda #BLUE
    sta VIC_BORDER
    lda #BLUE
    sta VIC_BG
    rts

; ── Data ──────────────────────────────────────────────────
.segment "RODATA"

message:
    .byte $0E           ; Switch to lowercase
    .byte $93           ; Clear screen
    .byte "c64 ide - assembly demo", $0D
    .byte "press any key to exit", $0D, $0D
    .byte 0
