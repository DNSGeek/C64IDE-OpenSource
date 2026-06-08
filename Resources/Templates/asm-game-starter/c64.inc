; ============================================================
;  c64.inc — C64 Hardware Register Definitions
;  Include this in your ca65 source with:  .include "c64.inc"
;
;  This covers the most commonly used registers. For the
;  complete memory map, see:
;    https://www.c64-wiki.com/wiki/Memory_Map
; ============================================================

; ============================================================
;  VIC-II VIDEO CHIP ($D000-$D3FF)
; ============================================================

; Sprite positions (2 bytes per sprite: X, Y)
VIC_SP0X    = $D000     ; Sprite 0 X
VIC_SP0Y    = $D001     ; Sprite 0 Y
VIC_SP1X    = $D002
VIC_SP1Y    = $D003
VIC_SP2X    = $D004
VIC_SP2Y    = $D005
VIC_SP3X    = $D006
VIC_SP3Y    = $D007
VIC_SP4X    = $D008
VIC_SP4Y    = $D009
VIC_SP5X    = $D00A
VIC_SP5Y    = $D00B
VIC_SP6X    = $D00C
VIC_SP6Y    = $D00D
VIC_SP7X    = $D00E
VIC_SP7Y    = $D00F
VIC_SPXMSB  = $D010     ; MSB of X for all sprites (bit N = sprite N)

VIC_CTRL1   = $D011     ; Control register 1 (scroll Y, rows, bitmap, etc.)
VIC_RASTER  = $D012     ; Raster line counter / raster IRQ line
VIC_CTRL2   = $D016     ; Control register 2 (scroll X, columns, multicolor)
VIC_MEMPTR  = $D018     ; Memory pointers (screen RAM and char ROM location)
VIC_IRQFLAG = $D019     ; IRQ status register
VIC_IRQMASK = $D01A     ; IRQ enable mask

VIC_SPEN    = $D015     ; Sprite enable register (bit N = sprite N)
VIC_SPBGPRI = $D01B     ; Sprite-background priority
VIC_SPMCOL  = $D01C     ; Sprite multicolor mode
VIC_SPXEXP  = $D01D     ; Sprite X expansion
VIC_SPYEXP  = $D017     ; Sprite Y expansion

VIC_BORDER  = $D020     ; Border color
VIC_BG0     = $D021     ; Background color 0
VIC_BG1     = $D022     ; Background color 1
VIC_BG2     = $D023     ; Background color 2
VIC_BG3     = $D024     ; Background color 3

VIC_SP0COL  = $D027     ; Sprite 0 color
VIC_SP1COL  = $D028
VIC_SP2COL  = $D029
VIC_SP3COL  = $D02A
VIC_SP4COL  = $D02B
VIC_SP5COL  = $D02C
VIC_SP6COL  = $D02D
VIC_SP7COL  = $D02E

; ============================================================
;  CIA #1 ($DC00-$DCFF) — Keyboard, Joysticks, Timer A/B
; ============================================================

CIA1_PORTA  = $DC00     ; Port A: joystick 2, keyboard column
CIA1_PORTB  = $DC01     ; Port B: joystick 1, keyboard row
CIA1_DDRA   = $DC02     ; Port A data direction
CIA1_DDRB   = $DC03     ; Port B data direction
CIA1_TIMALO = $DC04     ; Timer A low byte
CIA1_TIMAHI = $DC05     ; Timer A high byte
CIA1_TIMBLO = $DC06     ; Timer B low byte
CIA1_TIMBHI = $DC07     ; Timer B high byte
CIA1_TODTEN = $DC08     ; Time of day: tenths of seconds
CIA1_TODSEC = $DC09     ; Time of day: seconds
CIA1_TODMIN = $DC0A     ; Time of day: minutes
CIA1_TODHRS = $DC0B     ; Time of day: hours
CIA1_SDR    = $DC0C     ; Serial data register
CIA1_ICR    = $DC0D     ; Interrupt control register
CIA1_CRA    = $DC0E     ; Control register A (Timer A)
CIA1_CRB    = $DC0F     ; Control register B (Timer B)

; ============================================================
;  CIA #2 ($DD00-$DDFF) — Serial bus, NMI timer, VIC bank
; ============================================================

CIA2_PORTA  = $DD00     ; Port A: serial bus, VIC bank select
CIA2_PORTB  = $DD01     ; Port B: user port
CIA2_DDRA   = $DD02
CIA2_DDRB   = $DD03
CIA2_TIMALO = $DD04
CIA2_TIMAHI = $DD05
CIA2_ICR    = $DD0D
CIA2_CRA    = $DD0E
CIA2_CRB    = $DD0F

; ============================================================
;  KERNAL ROUTINES (via jump table at top of ROM)
;  Call these with JSR. They survive bank switching because
;  the Kernal ROM is mapped at $E000-$FFFF.
;  Full Kernal reference: https://www.c64-wiki.com/wiki/Kernal
; ============================================================

CHROUT      = $FFD2     ; Output character in A to current device
CHRIN       = $FFCF     ; Input character from current device -> A
GETIN       = $FFE4     ; Get character from keyboard buffer -> A (0 if empty)
CLRSCR      = $E544     ; Clear screen (not official Kernal, but widely used)
SETLFS      = $FFBA     ; Set logical file, device, secondary address
SETNAM      = $FFBD     ; Set filename
OPEN        = $FFC0     ; Open logical file
CLOSE       = $FFC3     ; Close logical file
CHKIN       = $FFC6     ; Set input channel
CHKOUT      = $FFC9     ; Set output channel
CLRCHN      = $FFCC     ; Restore default I/O channels
LOAD        = $FFD5     ; Load file
SAVE        = $FFD8     ; Save file

; ============================================================
;  SCREEN AND COLOR RAM
; ============================================================

SCREEN_RAM  = $0400     ; Default screen character RAM (1000 bytes)
COLOR_RAM   = $D800     ; Color RAM (1000 bytes, low nibble only)

; ============================================================
;  SPRITE POINTERS
;  Located at the end of the default screen RAM block.
;  One byte per sprite: value = (sprite data address) / 64
; ============================================================

SP0PTR      = $07F8
SP1PTR      = $07F9
SP2PTR      = $07FA
SP3PTR      = $07FB
SP4PTR      = $07FC
SP5PTR      = $07FD
SP6PTR      = $07FE
SP7PTR      = $07FF
