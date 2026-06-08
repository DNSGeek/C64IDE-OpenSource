; ============================================================
;  SIMPLE GAME STARTER - 6502 ASSEMBLY FOR C64
;  ca65 assembler / ld65 linker
;
;  This template gives you a working skeleton for a simple
;  C64 game. It includes:
;    - BASIC stub launcher (SYS to start your code)
;    - CIA timer-based frame sync (~60Hz)
;    - Joystick reading (port 2)
;    - One placeholder sprite
;    - Score display via CHROUT
;    - Title screen and game over screen
;    - Clean zero page variable layout
;
;  BUILD: Use the C64 IDE build button, or:
;    ca65 game.s -o game.o
;    ld65 -C c64.cfg game.o -o game.prg
; ============================================================

    .include "c64.inc"       ; C64 hardware register definitions

; ============================================================
;  ZERO PAGE VARIABLES
;  Zero page ($00-$FF) is special on the 6502 — instructions
;  that reference zero page addresses are one byte shorter
;  and one cycle faster than absolute addresses. Use it for
;  your most frequently accessed variables.
;
;  We start at $02 because $00/$01 are the CPU I/O port
;  registers. The Kernal uses some zero page too — see the
;  C64 memory map for the full picture. We stay safely in
;  $02-$1B per our linker config.
;
;  For more info: https://www.c64-wiki.com/wiki/Zero_Page
; ============================================================

    .segment "ZEROPAGE"

score_lo:   .res 1      ; score, low byte  (score is 16-bit)
score_hi:   .res 1      ; score, high byte
lives:      .res 1      ; remaining lives
game_over:  .res 1      ; 0 = playing, 1 = game over
player_x:   .res 1      ; player sprite X position (0-255 coarse)
player_y:   .res 1      ; player sprite Y position (0-255 coarse)
joy:        .res 1      ; raw joystick byte from $DC00
frame:      .res 1      ; frame counter (incremented each CIA tick)
tmp:        .res 2      ; general purpose temp bytes (tmp, tmp+1)

; ============================================================
;  BSS (UNINITIALIZED DATA)
;  Variables that need RAM but don't need values in the
;  binary. The linker reserves space but writes no bytes.
;  Initialize these in your INIT routine at runtime.
; ============================================================

    .segment "BSS"

enemy_x:    .res 8      ; X positions for up to 8 enemies
enemy_y:    .res 8      ; Y positions for up to 8 enemies
enemy_act:  .res 8      ; active flag per enemy (0=inactive)

; ============================================================
;  BASIC STUB — SYS LAUNCHER
;  This sits at $0801 and gives you a one-line BASIC program:
;    10 SYS 2061
;  When the user types RUN, BASIC jumps to your code.
;  $0801 is the standard BASIC program start address.
; ============================================================

    .segment "STARTUP"

basic_stub:
    .word   @next_line      ; pointer to next BASIC line
    .word   10              ; line number 10
    .byte   $9E             ; SYS token
    .byte   " 2061"         ; address as ASCII (adjust if stub grows!)
    .byte   0               ; end of BASIC statement
@next_line:
    .word   0               ; end of BASIC program

; ============================================================
;  MAIN ENTRY POINT
; ============================================================

    .segment "CODE"

main:
    jsr     init            ; set up hardware and variables
    jsr     title_screen    ; show title, wait for fire

game_loop:
    jsr     wait_frame      ; sync to ~60Hz via CIA timer
    jsr     read_joy        ; read joystick port 2
    jsr     update_game     ; move player, check collisions
    jsr     draw_screen     ; update display
    lda     game_over
    beq     game_loop       ; loop until game over flag set

    jsr     game_over_screen
    jmp     game_loop       ; restart (title_screen resets state)

; ============================================================
;  INIT
;  Called once at startup. Set up VIC, CIA timer, sprites,
;  and initialize all game variables.
; ============================================================

init:
    ; --- Screen colors ---
    lda     #0
    sta     $D020           ; border color = black
    sta     $D021           ; background color = black

    ; --- CIA #1 Timer A: frame sync ---
    ; We use CIA1 Timer A to count down from ~16667 ($412B),
    ; which at 1MHz gives us approximately one tick per frame
    ; (1/60th of a second on NTSC, close enough for PAL too).
    ;
    ; NOTE: This is a simple polling approach — we just check
    ; whether the timer has underflowed. A more robust method
    ; uses a raster IRQ at a specific scan line, which gives
    ; you precise, jitter-free timing and lets you do per-line
    ; effects. When you're ready for that, look up:
    ;   https://codebase64.org/doku.php?id=base:introduction_to_raster_irqs
    ;
    lda     #$6B            ; low byte of 16667 ($412B)
    sta     $DC04           ; CIA1 Timer A low
    lda     #$41            ; high byte
    sta     $DC05           ; CIA1 Timer A high
    lda     #$01            ; start timer, one-shot mode
    sta     $DC0E

    ; --- Initialize game variables ---
    lda     #0
    sta     score_lo
    sta     score_hi
    sta     game_over
    lda     #3
    sta     lives

    ; --- Player starting position ---
    lda     #160            ; center-ish X
    sta     player_x
    lda     #120            ; center-ish Y
    sta     player_y

    ; --- Set up sprite 0 (player sprite) ---
    ; Sprite data pointer: screen RAM + $3F8, one byte per sprite.
    ; Value = (address of sprite data) / 64
    ; We put our sprite data at $3000, so pointer = $3000/64 = $C0
    ;
    ; For more on sprites: https://www.c64-wiki.com/wiki/Sprite
    ;
    lda     #$C0            ; sprite data block at $3000
    sta     $07F8           ; sprite 0 pointer (screen RAM + $3F8)

    lda     #1
    sta     $D015           ; enable sprite 0 only

    lda     player_x
    sta     $D000           ; sprite 0 X
    lda     player_y
    sta     $D001           ; sprite 0 Y

    lda     #7              ; color 7 = yellow
    sta     $D027           ; sprite 0 color

    ; Copy placeholder sprite data to $3000
    ldx     #62
@copy_sprite:
    lda     sprite_data, x
    sta     $3000, x
    dex
    bpl     @copy_sprite

    rts

; ============================================================
;  WAIT_FRAME
;  Spin until CIA1 Timer A underflows (bit 0 of $DC0D set),
;  then restart the timer for the next frame.
; ============================================================

wait_frame:
@wait:
    lda     $DC0D           ; CIA1 interrupt control register
    and     #$01            ; bit 0 = Timer A underflow
    beq     @wait           ; keep waiting if not set

    ; Restart timer for next frame
    lda     #$6B
    sta     $DC04
    lda     #$41
    sta     $DC05
    lda     #$01
    sta     $DC0E

    inc     frame           ; bump frame counter
    rts

; ============================================================
;  READ_JOY
;  Read joystick port 2 from CIA1 $DC00.
;  Bits: 0=up 1=down 2=left 3=right 4=fire
;  A bit is CLEAR (0) when that direction is pressed.
;
;  WHY PORT 2?
;  Port 2 ($DC00) is safe to read at any time. Port 1
;  ($DC01) shares data lines with the keyboard matrix,
;  which can cause phantom key reads if the keyboard and
;  joystick are read at the same time. Port 1 is fine for
;  two-player games but requires care.
;
;  TO SWITCH TO PORT 1: change $DC00 to $DC01 here and
;  in any other place you read the joystick.
; ============================================================

read_joy:
    lda     $DC00
    sta     joy
    rts

; ============================================================
;  UPDATE_GAME
;  Move the player based on joystick, check collisions,
;  update score. Add your own logic here.
; ============================================================

update_game:
    lda     joy

    ; Move up
    and     #$01
    bne     @check_down
    lda     player_y
    sec
    sbc     #2
    sta     player_y
    lda     $D001
    sec
    sbc     #2
    sta     $D001

@check_down:
    lda     joy
    and     #$02
    bne     @check_left
    lda     player_y
    clc
    adc     #2
    sta     player_y
    lda     $D001
    clc
    adc     #2
    sta     $D001

@check_left:
    lda     joy
    and     #$04
    bne     @check_right
    lda     player_x
    sec
    sbc     #2
    sta     player_x
    lda     $D000
    sec
    sbc     #2
    sta     $D000

@check_right:
    lda     joy
    and     #$08
    bne     @check_fire
    lda     player_x
    clc
    adc     #2
    sta     player_x
    lda     $D000
    clc
    adc     #2
    sta     $D000

@check_fire:
    ; Fire button: bit 4, clear = pressed
    ; Add your fire action here (shoot, jump, etc.)

    ; --------------------------------------------------------
    ; ADD YOUR GAME LOGIC HERE:
    ;   - Move enemies (update enemy_x/enemy_y)
    ;   - Collision detection (player vs enemy, player vs item)
    ;   - Score updates
    ;   - Level progression
    ;   - Set game_over = 1 when appropriate
    ; --------------------------------------------------------

    rts

; ============================================================
;  DRAW_SCREEN
;  Update the display each frame.
;
;  We use CHROUT (Kernal $FFD2) for score display here
;  because it's simple and readable. The tradeoff is speed —
;  CHROUT is relatively slow because it goes through the
;  Kernal's cursor logic.
;
;  For faster text output, write directly to screen RAM at
;  $0400 and color RAM at $D800 using STA absolute,X.
;  This is especially important if you're drawing a lot of
;  characters per frame. See:
;    https://codebase64.org/doku.php?id=base:fast_screen_clear_and_fill
;
;  The sprite (player_x/player_y) is already updated in
;  update_game by writing directly to $D000/$D001, which
;  is instant and costs almost no CPU time.
; ============================================================

draw_screen:
    ; Home cursor without clearing (less flicker than $93)
    lda     #$13            ; PETSCII home
    jsr     $FFD2

    ; Print "SCORE: " label
    ldx     #0
@print_label:
    lda     score_label, x
    beq     @print_score_val
    jsr     $FFD2
    inx
    bne     @print_label

@print_score_val:
    ; Print score (16-bit, printed as decimal)
    ; For simplicity we just print score_lo as 0-255 here.
    ; For a full 5-digit decimal routine, see:
    ;   https://codebase64.org/doku.php?id=base:16bit_decimal_display
    lda     score_lo
    jsr     print_byte_decimal

    ; Print "  LIVES: " and lives count
    ldx     #0
@print_lives_label:
    lda     lives_label, x
    beq     @print_lives_val
    jsr     $FFD2
    inx
    bne     @print_lives_label

@print_lives_val:
    lda     lives
    jsr     print_byte_decimal

    rts

; ============================================================
;  TITLE_SCREEN
;  Clear screen, show title, wait for fire button.
; ============================================================

title_screen:
    ; Reset game state
    lda     #0
    sta     score_lo
    sta     score_hi
    sta     game_over
    lda     #3
    sta     lives

    ; Clear screen
    lda     #$93
    jsr     $FFD2

    ; Print title text
    ldx     #0
@print_title:
    lda     title_text, x
    beq     @wait_fire
    jsr     $FFD2
    inx
    bne     @print_title

@wait_fire:
    ; Wait for fire button (bit 4 of $DC00 = 0 when pressed)
    lda     $DC00
    and     #$10
    bne     @wait_fire

    ; Wait for release
@wait_release:
    lda     $DC00
    and     #$10
    beq     @wait_release

    rts

; ============================================================
;  GAME_OVER_SCREEN
;  Show game over message, wait for fire to restart.
; ============================================================

game_over_screen:
    lda     #$93
    jsr     $FFD2

    ldx     #0
@print_go:
    lda     gameover_text, x
    beq     @wait_fire
    jsr     $FFD2
    inx
    bne     @print_go

@wait_fire:
    lda     $DC00
    and     #$10
    bne     @wait_fire
@wait_release:
    lda     $DC00
    and     #$10
    beq     @wait_release

    rts

; ============================================================
;  PRINT_BYTE_DECIMAL
;  Print the value in A as a decimal number (0-255).
;  Uses CHROUT ($FFD2) for output.
;  A is preserved. Clobbers X.
;
;  As noted above, for a full 16-bit decimal display routine
;  (for scores up to 65535), see codebase64 link in draw_screen.
; ============================================================

print_byte_decimal:
    pha
    ldx     #0
    sta     tmp

    ; Hundreds digit
    lda     #0
@hundreds:
    lda     tmp
    cmp     #100
    bcc     @tens_setup
    sbc     #100
    sta     tmp
    inx
    bne     @hundreds
@tens_setup:
    pha
    txa
    ora     #$30            ; convert to PETSCII digit
    jsr     $FFD2

    ; Tens digit
    pla
    sta     tmp
    ldx     #0
@tens:
    lda     tmp
    cmp     #10
    bcc     @ones
    sbc     #10
    sta     tmp
    inx
    bne     @tens
@ones:
    txa
    ora     #$30
    jsr     $FFD2
    lda     tmp
    ora     #$30
    jsr     $FFD2

    pla
    rts

; ============================================================
;  READ-ONLY DATA
; ============================================================

    .segment "RODATA"

score_label:
    .byte   $93             ; clear screen on first print
    .byte   "SCORE: "
    .byte   0

lives_label:
    .byte   "  LIVES: "
    .byte   0

title_text:
    .byte   $93             ; clear screen
    .byte   13, 13, 13
    .byte   "   *** MY AWESOME GAME ***"
    .byte   13, 13
    .byte   "    PRESS FIRE TO START"
    .byte   13
    .byte   0

gameover_text:
    .byte   $93
    .byte   13, 13, 13
    .byte   "       GAME OVER"
    .byte   13, 13
    .byte   "    PRESS FIRE TO PLAY AGAIN"
    .byte   13
    .byte   0

; ============================================================
;  SPRITE DATA
;  24x21 pixels = 63 bytes per sprite frame.
;  This placeholder draws a simple diamond shape.
;  Replace with your own sprite data from the Sprite Editor
;  (use Export > Assembly .byte to get the bytes).
;
;  For more on sprite data format:
;    https://www.c64-wiki.com/wiki/Sprite
; ============================================================

sprite_data:
    ;         BYTE0    BYTE1    BYTE2     (24 pixels wide)
    .byte   %00000000,%00000000,%00000000  ; row 1
    .byte   %00000000,%00001000,%00000000  ; row 2
    .byte   %00000000,%00011100,%00000000  ; row 3
    .byte   %00000000,%00111110,%00000000  ; row 4
    .byte   %00000000,%01111111,%00000000  ; row 5
    .byte   %00000000,%11111111,%10000000  ; row 6
    .byte   %00000001,%11111111,%11000000  ; row 7
    .byte   %00000011,%11111111,%11100000  ; row 8
    .byte   %00000001,%11111111,%11000000  ; row 9
    .byte   %00000000,%11111111,%10000000  ; row 10
    .byte   %00000000,%01111111,%00000000  ; row 11
    .byte   %00000000,%00111110,%00000000  ; row 12
    .byte   %00000000,%00011100,%00000000  ; row 13
    .byte   %00000000,%00001000,%00000000  ; row 14
    .byte   %00000000,%00000000,%00000000  ; row 15
    .byte   %00000000,%00000000,%00000000  ; row 16
    .byte   %00000000,%00000000,%00000000  ; row 17
    .byte   %00000000,%00000000,%00000000  ; row 18
    .byte   %00000000,%00000000,%00000000  ; row 19
    .byte   %00000000,%00000000,%00000000  ; row 20
    .byte   %00000000,%00000000,%00000000  ; row 21
    .byte   0                              ; padding byte (64th byte, unused)
