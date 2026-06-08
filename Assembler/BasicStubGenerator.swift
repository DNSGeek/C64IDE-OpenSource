//  BasicStubGenerator.swift
//  C64 IDE
//
//  Generates ca65-compatible BASIC startup stubs. Creates the classic "10 SYS <addr>"
//  header so the resulting .prg can be loaded and RUN from BASIC.

import Foundation

/// Generates a ca65-compatible BASIC startup stub for .prg files.
struct BasicStubGenerator {

    /// Generates a ca65 assembly file that provides the BASIC stub and includes the user's source.
    /// - Parameters:
    ///   - mainSourceFile: Path to the user's main assembly file to be included.
    ///   - entryLabel: Symbol name representing the program's entry point. Defaults to `"main"`.
    /// - Returns: A complete ca65 assembly string ready for assembly.
    static func generateStub(mainSourceFile: String, entryLabel: String = "main") -> String {
        return """
        ; ═══════════════════════════════════════════════════════
        ; C64 IDE — Auto-generated BASIC startup stub
        ; Provides a BASIC line: 10 SYS <entry_address>
        ; ═══════════════════════════════════════════════════════

        .export __LOADADDR__: absolute = 1

        ; ── Load address ──────────────────────────────────────
        .segment "LOADADDR"
        .word $0801          ; Load at BASIC start

        ; ── BASIC stub ────────────────────────────────────────
        .segment "STARTUP"

        ; BASIC line: 10 SYS <decimal address of entry>
        .word @end           ; Pointer to next BASIC line
        .word 10             ; Line number 10
        .byte $9E            ; SYS token

        ; Resolve entry address at assemble time
        .if .defined(\(entryLabel))
            start_addr = \(entryLabel)
        .else
            start_addr = code_start
        .endif

        ; Emit decimal digits of the start address (handles up to 65535)
        .if start_addr >= 10000
            .byte '0' + (start_addr / 10000)
        .endif
        .if start_addr >= 1000
            .byte '0' + ((start_addr / 1000) .mod 10)
        .endif
        .if start_addr >= 100
            .byte '0' + ((start_addr / 100) .mod 10)
        .endif
        .if start_addr >= 10
            .byte '0' + ((start_addr / 10) .mod 10)
        .endif
        .byte '0' + (start_addr .mod 10)

        .byte 0              ; End of BASIC line

        @end:
        .word 0              ; End of BASIC program (null pointer)

        ; ── User code starts here ─────────────────────────────
        .segment "CODE"
        code_start:

        .include "\(mainSourceFile)"
        """
    }

    /// Generates a standalone BASIC stub with a hardcoded entry point.
    /// Useful when the user wants to assemble their file directly without an .include.
    static func generateStandaloneStub() -> String {
        return """
        ; ═══════════════════════════════════════════════════════
        ; C64 IDE — BASIC startup stub
        ; 10 SYS 2064 (entry point right after this stub)
        ; ═══════════════════════════════════════════════════════

        .export __LOADADDR__: absolute = 1

        .segment "LOADADDR"
        .word $0801

        .segment "STARTUP"

        .word @end           ; Next line pointer
        .word 10             ; Line 10
        .byte $9E            ; SYS
        .byte "2064"         ; Address as ASCII
        .byte 0              ; End of line
        @end:
        .word 0              ; End of BASIC program

        ; ── Your code starts here at $0810 ────────────────────
        .segment "CODE"
        """
    }
}

