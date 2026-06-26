import Foundation
import AppKit

// MARK: - 6502 Assembly Token Types

/// Represents the semantic classification of a token during assembly syntax highlighting.
enum AsmTokenType {
    case opcode           // LDA, STA, JMP, etc.
    case directive        // .byte, .word, .org, etc. (ca65 directives)
    case register         // A, X, Y
    case number           // Numeric literals ($FF, #$00, %10101010, 42)
    case label            // Labels and label references
    case comment          // ; comments
    case string           // String literals
    case macro            // .macro, .endmacro, .define
    case separator        // , ( ) : # 
    case plain

    /// Returns the appropriate syntax color for this token type based on the current theme.
    var color: NSColor {
        let t = AppTheme.current
        switch self {
        case .opcode:    return t.asmOpcode
        case .directive: return t.asmDirective
        case .register:  return t.asmRegister
        case .number:    return t.asmNumber
        case .label:     return t.asmLabel
        case .comment:   return t.asmComment
        case .string:    return t.asmString
        case .macro:     return t.asmMacro
        case .separator: return t.asmSeparator
        case .plain:     return t.asmPlain
        }
    }
}

/// Represents a single tokenized unit of assembly source code.
struct AsmSyntaxToken {
    let range: NSRange
    let type: AsmTokenType
    let text: String
}

// MARK: - 6502 Opcode Reference

/// Documentation entry for a single 6502 opcode.
struct OpcodeRef {
    let mnemonic: String
    let fullName: String
    let description: String
    let flags: String        // Which processor flags are affected
    let cycles: String       // Base cycle count
    let addressingModes: String
}

// MARK: - 6502 Assembly Syntax

/// Central repository for 6502 assembly language syntax rules, references, and tokenization.
struct C64AssemblySyntax {

    /// All official 6502 opcodes.
    static let opcodes: Set<String> = [
        // Load/Store
        "LDA", "LDX", "LDY", "STA", "STX", "STY",
        // Transfer
        "TAX", "TAY", "TXA", "TYA", "TSX", "TXS",
        // Stack
        "PHA", "PHP", "PLA", "PLP",
        // Arithmetic
        "ADC", "SBC", "INC", "INX", "INY", "DEC", "DEX", "DEY",
        // Logic
        "AND", "ORA", "EOR", "BIT",
        // Shift/Rotate
        "ASL", "LSR", "ROL", "ROR",
        // Branch
        "BCC", "BCS", "BEQ", "BMI", "BNE", "BPL", "BVC", "BVS",
        // Jump/Call
        "JMP", "JSR", "RTS", "RTI",
        // Compare
        "CMP", "CPX", "CPY",
        // Flag
        "CLC", "CLD", "CLI", "CLV", "SEC", "SED", "SEI",
        // Other
        "BRK", "NOP",
    ]

    /// Standard ca65 assembler directives.
    static let directives: Set<String> = [
        // Data
        // Note: .DB and .DW are NOT native ca65 directives (they come from DASM/MASM traditions).
        // ca65 uses .BYTE and .WORD. Including them here for highlighter tolerance only.
        ".BYTE", ".WORD", ".DB", ".DW",
        // Note: .DS is not the canonical ca65 storage reservation directive -- .RES is.
        // .DS may work as an alias in some ca65 builds; included for compatibility.
        ".DS", ".RES",
        // Note: ca65 string directives use .ASCIIZ (two i's), not .ASCIZ (one i).
        // .ASC is also not a standard ca65 directive; .BYTE "string" is the ca65 idiom.
        ".ASCIIZ",
        // Segment / scope
        ".ORG", ".SEGMENT", ".PROC", ".ENDPROC", ".SCOPE", ".ENDSCOPE",
        // Macros / defines
        ".MACRO", ".ENDMACRO", ".DEFINE", ".UNDEFINE",
        // Conditionals
        ".IF", ".IFDEF", ".IFNDEF", ".ELSE", ".ELSEIF", ".ENDIF",
        // Repeat
        ".REPEAT", ".ENDREP",
        // File ops
        ".INCLUDE", ".INCBIN", ".IMPORT", ".EXPORT", ".EXPORTZP", ".IMPORTZP",
        // Symbol scope
        ".LOCAL", ".LOCALCHAR",
        // Address/data helpers
        ".ADDR", ".FARADDR", ".LOBYTES", ".HIBYTES",
        // Miscellaneous
        ".ALIGN", ".ASSERT", ".CHARMAP", ".CONDES",
        ".CONSTRUCTOR", ".DESTRUCTOR", ".INTERRUPTOR",
        ".ENUM", ".ENDENUM", ".STRUCT", ".ENDSTRUCT", ".UNION", ".ENDUNION",
        ".ERROR", ".WARNING", ".OUT", ".FATAL",
        ".FEATURE", ".FILEOPT", ".FOPT",
        ".GLOBALZP", ".GLOBAL",
        ".LINECONT", ".LIST", ".LISTBYTES",
        ".P02", ".P816", ".PC02", ".PSC02",
        ".POPSEG", ".PUSHSEG",
        // Note: .RODATA is a segment NAME defined in the default ld65 linker config,
        // NOT a ca65 assembler directive. Removed.
        ".RELOC",
        ".SETCPU", ".SMART",
        ".TAG", ".ZEROPAGE",
    ]

    /// Macro-like directives that deserve special highlighting treatment.
    static let macroDirectives: Set<String> = [
        ".MACRO", ".ENDMACRO", ".DEFINE", ".UNDEFINE",
        ".PROC", ".ENDPROC",
    ]

    /// Primary processor registers.
    static let registers: Set<String> = ["A", "X", "Y"]

    // MARK: - Opcode Reference Database

    /// Comprehensive reference for all 6502 opcodes, including flag effects, cycle counts, and addressing modes.
    static let opcodeReference: [String: OpcodeRef] = [
        // ── Load/Store ───────────────────────────────────────────
        "LDA": OpcodeRef(mnemonic: "LDA", fullName: "Load Accumulator",
            description: "Loads a byte into the accumulator. Sets N and Z flags based on the value loaded.",
            flags: "N, Z", cycles: "2-6",
            addressingModes: "Immediate, Zero Page, ZP X, Absolute, Abs X, Abs Y, (Ind,X), (Ind),Y"),
        "LDX": OpcodeRef(mnemonic: "LDX", fullName: "Load X Register",
            description: "Loads a byte into the X register. Sets N and Z flags.",
            flags: "N, Z", cycles: "2-5",
            addressingModes: "Immediate, Zero Page, ZP Y, Absolute, Abs Y"),
        "LDY": OpcodeRef(mnemonic: "LDY", fullName: "Load Y Register",
            description: "Loads a byte into the Y register. Sets N and Z flags.",
            flags: "N, Z", cycles: "2-5",
            addressingModes: "Immediate, Zero Page, ZP X, Absolute, Abs X"),
        "STA": OpcodeRef(mnemonic: "STA", fullName: "Store Accumulator",
            description: "Stores the contents of the accumulator into a memory location.",
            flags: "None", cycles: "3-6",
            addressingModes: "Zero Page, ZP X, Absolute, Abs X, Abs Y, (Ind,X), (Ind),Y"),
        "STX": OpcodeRef(mnemonic: "STX", fullName: "Store X Register",
            description: "Stores the contents of the X register into a memory location.",
            flags: "None", cycles: "3-4",
            addressingModes: "Zero Page, ZP Y, Absolute"),
        "STY": OpcodeRef(mnemonic: "STY", fullName: "Store Y Register",
            description: "Stores the contents of the Y register into a memory location.",
            flags: "None", cycles: "3-4",
            addressingModes: "Zero Page, ZP X, Absolute"),

        // ── Transfer ─────────────────────────────────────────────
        "TAX": OpcodeRef(mnemonic: "TAX", fullName: "Transfer A to X",
            description: "Copies the accumulator into the X register.", flags: "N, Z", cycles: "2",
            addressingModes: "Implied"),
        "TAY": OpcodeRef(mnemonic: "TAY", fullName: "Transfer A to Y",
            description: "Copies the accumulator into the Y register.", flags: "N, Z", cycles: "2",
            addressingModes: "Implied"),
        "TXA": OpcodeRef(mnemonic: "TXA", fullName: "Transfer X to A",
            description: "Copies the X register into the accumulator.", flags: "N, Z", cycles: "2",
            addressingModes: "Implied"),
        "TYA": OpcodeRef(mnemonic: "TYA", fullName: "Transfer Y to A",
            description: "Copies the Y register into the accumulator.", flags: "N, Z", cycles: "2",
            addressingModes: "Implied"),
        "TSX": OpcodeRef(mnemonic: "TSX", fullName: "Transfer SP to X",
            description: "Copies the stack pointer into the X register.", flags: "N, Z", cycles: "2",
            addressingModes: "Implied"),
        "TXS": OpcodeRef(mnemonic: "TXS", fullName: "Transfer X to SP",
            description: "Copies the X register into the stack pointer.", flags: "None", cycles: "2",
            addressingModes: "Implied"),

        // ── Stack ────────────────────────────────────────────────
        "PHA": OpcodeRef(mnemonic: "PHA", fullName: "Push Accumulator",
            description: "Pushes a copy of the accumulator onto the stack.", flags: "None", cycles: "3",
            addressingModes: "Implied"),
        "PHP": OpcodeRef(mnemonic: "PHP", fullName: "Push Processor Status",
            description: "Pushes a copy of the status flags onto the stack. Note: B flag is always set in the pushed byte.",
            flags: "None", cycles: "3", addressingModes: "Implied"),
        "PLA": OpcodeRef(mnemonic: "PLA", fullName: "Pull Accumulator",
            description: "Pulls a byte from the stack into the accumulator.", flags: "N, Z", cycles: "4",
            addressingModes: "Implied"),
        "PLP": OpcodeRef(mnemonic: "PLP", fullName: "Pull Processor Status",
            description: "Pulls a byte from the stack into the processor status register.", flags: "All", cycles: "4",
            addressingModes: "Implied"),

        // ── Arithmetic ──────────────────────────────────────────
        "ADC": OpcodeRef(mnemonic: "ADC", fullName: "Add with Carry",
            description: "Adds a value to the accumulator plus the carry flag. Result stored in A. Always CLC before the first ADC in a multi-byte add.",
            flags: "N, V, Z, C", cycles: "2-6",
            addressingModes: "Immediate, Zero Page, ZP X, Absolute, Abs X, Abs Y, (Ind,X), (Ind),Y"),
        "SBC": OpcodeRef(mnemonic: "SBC", fullName: "Subtract with Carry",
            description: "Subtracts a value from the accumulator with borrow (inverse of carry). Always SEC before the first SBC.",
            flags: "N, V, Z, C", cycles: "2-6",
            addressingModes: "Immediate, Zero Page, ZP X, Absolute, Abs X, Abs Y, (Ind,X), (Ind),Y"),
        "INC": OpcodeRef(mnemonic: "INC", fullName: "Increment Memory",
            description: "Adds 1 to the value at a memory location.", flags: "N, Z", cycles: "5-7",
            addressingModes: "Zero Page, ZP X, Absolute, Abs X"),
        "INX": OpcodeRef(mnemonic: "INX", fullName: "Increment X Register",
            description: "Adds 1 to the X register.", flags: "N, Z", cycles: "2", addressingModes: "Implied"),
        "INY": OpcodeRef(mnemonic: "INY", fullName: "Increment Y Register",
            description: "Adds 1 to the Y register.", flags: "N, Z", cycles: "2", addressingModes: "Implied"),
        "DEC": OpcodeRef(mnemonic: "DEC", fullName: "Decrement Memory",
            description: "Subtracts 1 from the value at a memory location.", flags: "N, Z", cycles: "5-7",
            addressingModes: "Zero Page, ZP X, Absolute, Abs X"),
        "DEX": OpcodeRef(mnemonic: "DEX", fullName: "Decrement X Register",
            description: "Subtracts 1 from the X register.", flags: "N, Z", cycles: "2", addressingModes: "Implied"),
        "DEY": OpcodeRef(mnemonic: "DEY", fullName: "Decrement Y Register",
            description: "Subtracts 1 from the Y register.", flags: "N, Z", cycles: "2", addressingModes: "Implied"),

        // ── Logic ────────────────────────────────────────────────
        "AND": OpcodeRef(mnemonic: "AND", fullName: "Logical AND",
            description: "Bitwise AND with the accumulator. Each bit of A is ANDed with the corresponding bit of the operand.",
            flags: "N, Z", cycles: "2-6",
            addressingModes: "Immediate, Zero Page, ZP X, Absolute, Abs X, Abs Y, (Ind,X), (Ind),Y"),
        "ORA": OpcodeRef(mnemonic: "ORA", fullName: "Logical OR",
            description: "Bitwise OR with the accumulator. Used to set specific bits.",
            flags: "N, Z", cycles: "2-6",
            addressingModes: "Immediate, Zero Page, ZP X, Absolute, Abs X, Abs Y, (Ind,X), (Ind),Y"),
        "EOR": OpcodeRef(mnemonic: "EOR", fullName: "Exclusive OR",
            description: "Bitwise XOR with the accumulator. Used to toggle/flip specific bits. EOR #$FF inverts all bits.",
            flags: "N, Z", cycles: "2-6",
            addressingModes: "Immediate, Zero Page, ZP X, Absolute, Abs X, Abs Y, (Ind,X), (Ind),Y"),
        "BIT": OpcodeRef(mnemonic: "BIT", fullName: "Bit Test",
            description: "Tests bits in memory with the accumulator. Z flag is set if A AND operand = 0. N flag = bit 7, V flag = bit 6 of the operand (not A).",
            flags: "N, V, Z", cycles: "3-4",
            addressingModes: "Zero Page, Absolute"),

        // ── Shift/Rotate ────────────────────────────────────────
        "ASL": OpcodeRef(mnemonic: "ASL", fullName: "Arithmetic Shift Left",
            description: "Shifts all bits left by one. Bit 0 becomes 0, old bit 7 goes to carry. Effectively multiplies by 2.",
            flags: "N, Z, C", cycles: "2-7",
            addressingModes: "Accumulator, Zero Page, ZP X, Absolute, Abs X"),
        "LSR": OpcodeRef(mnemonic: "LSR", fullName: "Logical Shift Right",
            description: "Shifts all bits right by one. Bit 7 becomes 0, old bit 0 goes to carry. Effectively unsigned divide by 2.",
            flags: "N(=0), Z, C", cycles: "2-7",
            addressingModes: "Accumulator, Zero Page, ZP X, Absolute, Abs X"),
        "ROL": OpcodeRef(mnemonic: "ROL", fullName: "Rotate Left",
            description: "Rotates all bits left through carry. Old carry goes to bit 0, old bit 7 goes to carry.",
            flags: "N, Z, C", cycles: "2-7",
            addressingModes: "Accumulator, Zero Page, ZP X, Absolute, Abs X"),
        "ROR": OpcodeRef(mnemonic: "ROR", fullName: "Rotate Right",
            description: "Rotates all bits right through carry. Old carry goes to bit 7, old bit 0 goes to carry.",
            flags: "N, Z, C", cycles: "2-7",
            addressingModes: "Accumulator, Zero Page, ZP X, Absolute, Abs X"),

        // ── Branch ───────────────────────────────────────────────
        "BCC": OpcodeRef(mnemonic: "BCC", fullName: "Branch if Carry Clear",
            description: "Branches if the carry flag is 0. Used after CMP/SBC for 'less than' (unsigned).",
            flags: "None", cycles: "2-4", addressingModes: "Relative (-128 to +127 bytes from next instruction)"),
        "BCS": OpcodeRef(mnemonic: "BCS", fullName: "Branch if Carry Set",
            description: "Branches if the carry flag is 1. Used after CMP/SBC for 'greater than or equal' (unsigned).",
            flags: "None", cycles: "2-4", addressingModes: "Relative (-128 to +127 bytes from next instruction)"),
        "BEQ": OpcodeRef(mnemonic: "BEQ", fullName: "Branch if Equal (Zero Set)",
            description: "Branches if the zero flag is 1. Used after CMP for equality, or after LDA/DEC/etc. to test for zero.",
            flags: "None", cycles: "2-4", addressingModes: "Relative (-128 to +127 bytes from next instruction)"),
        "BMI": OpcodeRef(mnemonic: "BMI", fullName: "Branch if Minus",
            description: "Branches if the negative flag is 1 (bit 7 of result was set).",
            flags: "None", cycles: "2-4", addressingModes: "Relative (-128 to +127 bytes from next instruction)"),
        "BNE": OpcodeRef(mnemonic: "BNE", fullName: "Branch if Not Equal (Zero Clear)",
            description: "Branches if the zero flag is 0. The workhorse branch -- used in loops and inequality tests.",
            flags: "None", cycles: "2-4", addressingModes: "Relative (-128 to +127 bytes from next instruction)"),
        "BPL": OpcodeRef(mnemonic: "BPL", fullName: "Branch if Plus",
            description: "Branches if the negative flag is 0 (bit 7 of result was clear). Often used to wait for raster line.",
            flags: "None", cycles: "2-4", addressingModes: "Relative (-128 to +127 bytes from next instruction)"),
        "BVC": OpcodeRef(mnemonic: "BVC", fullName: "Branch if Overflow Clear",
            description: "Branches if the overflow flag is 0. Rarely used in C64 game code.",
            flags: "None", cycles: "2-4", addressingModes: "Relative (-128 to +127 bytes from next instruction)"),
        "BVS": OpcodeRef(mnemonic: "BVS", fullName: "Branch if Overflow Set",
            description: "Branches if the overflow flag is 1.",
            flags: "None", cycles: "2-4", addressingModes: "Relative (-128 to +127 bytes from next instruction)"),

        // ── Jump/Call ────────────────────────────────────────────
        "JMP": OpcodeRef(mnemonic: "JMP", fullName: "Jump",
            description: "Unconditional jump to an address. Indirect mode loads the target from a pointer.",
            flags: "None", cycles: "3-5",
            addressingModes: "Absolute, Indirect — WARNING: JMP ($xxFF) has a hardware bug! The high byte wraps to $xx00 instead of $(xx+1)00."),
        "JSR": OpcodeRef(mnemonic: "JSR", fullName: "Jump to Subroutine",
            description: "Pushes the return address (minus 1) onto the stack, then jumps to the target. Use RTS to return.",
            flags: "None", cycles: "6", addressingModes: "Absolute"),
        "RTS": OpcodeRef(mnemonic: "RTS", fullName: "Return from Subroutine",
            description: "Pulls the return address from the stack and jumps to it (plus 1). Pairs with JSR.",
            flags: "None", cycles: "6", addressingModes: "Implied"),
        "RTI": OpcodeRef(mnemonic: "RTI", fullName: "Return from Interrupt",
            description: "Pulls the processor flags and program counter from the stack. Used at the end of interrupt handlers.",
            flags: "All (from stack)", cycles: "6", addressingModes: "Implied"),

        // ── Compare ──────────────────────────────────────────────
        "CMP": OpcodeRef(mnemonic: "CMP", fullName: "Compare Accumulator",
            description: "Compares A with a value by performing A - operand without storing the result. Sets flags for subsequent branches. C=1 if A >= operand, Z=1 if equal.",
            flags: "N, Z, C", cycles: "2-6",
            addressingModes: "Immediate, Zero Page, ZP X, Absolute, Abs X, Abs Y, (Ind,X), (Ind),Y"),
        "CPX": OpcodeRef(mnemonic: "CPX", fullName: "Compare X Register",
            description: "Compares X with a value. Sets flags like CMP but for X.", flags: "N, Z, C", cycles: "2-4",
            addressingModes: "Immediate, Zero Page, Absolute"),
        "CPY": OpcodeRef(mnemonic: "CPY", fullName: "Compare Y Register",
            description: "Compares Y with a value. Sets flags like CMP but for Y.", flags: "N, Z, C", cycles: "2-4",
            addressingModes: "Immediate, Zero Page, Absolute"),

        // ── Flags ────────────────────────────────────────────────
        "CLC": OpcodeRef(mnemonic: "CLC", fullName: "Clear Carry Flag",
            description: "Sets the carry flag to 0. Always do this before ADC for addition.", flags: "C=0", cycles: "2",
            addressingModes: "Implied"),
        "CLD": OpcodeRef(mnemonic: "CLD", fullName: "Clear Decimal Mode",
            description: "Clears BCD (decimal) mode. The C64 KERNAL does this at startup, but good practice to CLD in interrupt handlers.",
            flags: "D=0", cycles: "2", addressingModes: "Implied"),
        "CLI": OpcodeRef(mnemonic: "CLI", fullName: "Clear Interrupt Disable",
            description: "Enables hardware interrupts (IRQ). Use after setting up an interrupt handler.",
            flags: "I=0", cycles: "2", addressingModes: "Implied"),
        "CLV": OpcodeRef(mnemonic: "CLV", fullName: "Clear Overflow Flag",
            description: "Clears the overflow flag. The only way to clear V besides PLP or BIT.", flags: "V=0", cycles: "2",
            addressingModes: "Implied"),
        "SEC": OpcodeRef(mnemonic: "SEC", fullName: "Set Carry Flag",
            description: "Sets the carry flag to 1. Always do this before SBC for subtraction.", flags: "C=1", cycles: "2",
            addressingModes: "Implied"),
        "SED": OpcodeRef(mnemonic: "SED", fullName: "Set Decimal Mode",
            description: "Enables BCD (Binary Coded Decimal) mode for ADC and SBC. Rarely used on C64.",
            flags: "D=1", cycles: "2", addressingModes: "Implied"),
        "SEI": OpcodeRef(mnemonic: "SEI", fullName: "Set Interrupt Disable",
            description: "Disables hardware interrupts (IRQ). Essential when setting up raster interrupts or modifying interrupt vectors.",
            flags: "I=1", cycles: "2", addressingModes: "Implied"),

        // ── Other ────────────────────────────────────────────────
        "BRK": OpcodeRef(mnemonic: "BRK", fullName: "Break / Software Interrupt",
            description: "Triggers a software interrupt. Pushes PC+2 and status to stack, loads IRQ vector ($FFFE/$FFFF). The B flag is set in the pushed status byte to distinguish a software BRK from a hardware IRQ -- B is NOT set in the live processor register, only in the copy on the stack.",
            flags: "I=1 (live); B=1 (pushed copy of P only)", cycles: "7", addressingModes: "Implied"),
        "NOP": OpcodeRef(mnemonic: "NOP", fullName: "No Operation",
            description: "Does nothing for 2 cycles. Useful for timing alignment and patching code.",
            flags: "None", cycles: "2", addressingModes: "Implied"),
    ]

    // MARK: - Tokenization

    /// Tokenizes a single line of 6502 assembly source code into semantic tokens.
    /// - Parameter line: The raw source line to tokenize.
    /// - Returns: An array of `AsmSyntaxToken` representing the line's structure.
    static func tokenize(_ line: String) -> [AsmSyntaxToken] {
        var tokens: [AsmSyntaxToken] = []
        let nsLine = line as NSString
        let length = nsLine.length
        var pos = 0

        // Check for comment line
        while pos < length && nsLine.character(at: pos) == 0x20 { pos += 1 }

        if pos < length && nsLine.character(at: pos) == 0x3B { // ;
            tokens.append(AsmSyntaxToken(
                range: NSRange(location: 0, length: length),
                type: .comment,
                text: line
            ))
            return tokens
        }

        pos = 0
        var isFirstWord = true

        while pos < length {
            let ch = nsLine.character(at: pos)

            // Comment
            if ch == 0x3B { // ;
                tokens.append(AsmSyntaxToken(
                    range: NSRange(location: pos, length: length - pos),
                    type: .comment,
                    text: nsLine.substring(from: pos)
                ))
                break
            }

            // String literal
            if ch == 0x22 { // "
                let start = pos
                pos += 1
                while pos < length && nsLine.character(at: pos) != 0x22 { pos += 1 }
                if pos < length { pos += 1 }
                tokens.append(AsmSyntaxToken(
                    range: NSRange(location: start, length: pos - start),
                    type: .string,
                    text: nsLine.substring(with: NSRange(location: start, length: pos - start))
                ))
                continue
            }

            // Numbers: $hex, %binary, #immediate prefix
            if ch == 0x24 || ch == 0x25 || (ch == 0x23 && pos + 1 < length) { // $, %, #
                if ch == 0x23 { // # immediate prefix
                    tokens.append(AsmSyntaxToken(
                        range: NSRange(location: pos, length: 1),
                        type: .separator,
                        text: "#"
                    ))
                    pos += 1
                    continue
                }
                let start = pos
                pos += 1
                while pos < length {
                    let c = nsLine.character(at: pos)
                    if CharacterSet.alphanumerics.contains(Unicode.Scalar(c)!) {
                        pos += 1
                    } else {
                        break
                    }
                }
                tokens.append(AsmSyntaxToken(
                    range: NSRange(location: start, length: pos - start),
                    type: .number,
                    text: nsLine.substring(with: NSRange(location: start, length: pos - start))
                ))
                isFirstWord = false
                continue
            }

            // Decimal numbers
            if CharacterSet.decimalDigits.contains(Unicode.Scalar(ch)!) {
                let start = pos
                while pos < length && CharacterSet.decimalDigits.contains(Unicode.Scalar(nsLine.character(at: pos))!) {
                    pos += 1
                }
                tokens.append(AsmSyntaxToken(
                    range: NSRange(location: start, length: pos - start),
                    type: .number,
                    text: nsLine.substring(with: NSRange(location: start, length: pos - start))
                ))
                isFirstWord = false
                continue
            }

            // Directives (start with .)
            if ch == 0x2E { // .
                let start = pos
                pos += 1
                while pos < length && CharacterSet.alphanumerics.contains(Unicode.Scalar(nsLine.character(at: pos))!) {
                    pos += 1
                }
                let word = nsLine.substring(with: NSRange(location: start, length: pos - start))
                let upper = word.uppercased()
                let type: AsmTokenType = macroDirectives.contains(upper) ? .macro : .directive
                tokens.append(AsmSyntaxToken(
                    range: NSRange(location: start, length: pos - start),
                    type: type,
                    text: word
                ))
                isFirstWord = false
                continue
            }

            // Separators
            if [0x2C, 0x28, 0x29, 0x3A].contains(ch) { // , ( ) :
                tokens.append(AsmSyntaxToken(
                    range: NSRange(location: pos, length: 1),
                    type: .separator,
                    text: String(Character(UnicodeScalar(ch)!))
                ))
                pos += 1
                // After a colon, the next word is typically a label or the start of a new statement.
                if ch == 0x3A { isFirstWord = true }
                continue
            }

            // Whitespace
            if ch == 0x20 || ch == 0x09 { // space or tab
                let start = pos
                while pos < length && (nsLine.character(at: pos) == 0x20 || nsLine.character(at: pos) == 0x09) {
                    pos += 1
                }
                tokens.append(AsmSyntaxToken(
                    range: NSRange(location: start, length: pos - start),
                    type: .plain,
                    text: nsLine.substring(with: NSRange(location: start, length: pos - start))
                ))
                continue
            }

            // Words: opcodes, labels, registers
            if CharacterSet.letters.contains(Unicode.Scalar(ch)!) || ch == 0x5F { // letter or _
                let start = pos
                pos += 1
                while pos < length {
                    let c = nsLine.character(at: pos)
                    if CharacterSet.alphanumerics.contains(Unicode.Scalar(c)!) || c == 0x5F {
                        pos += 1
                    } else {
                        break
                    }
                }
                let word = nsLine.substring(with: NSRange(location: start, length: pos - start))
                let upper = word.uppercased()

                let type: AsmTokenType
                if opcodes.contains(upper) {
                    type = .opcode
                } else if registers.contains(upper) && !isFirstWord {
                    // Registers are only highlighted as such when they appear as operands,
                    // not when they appear as labels (e.g., "A: LDA #1").
                    type = .register
                } else {
                    type = .label
                }

                tokens.append(AsmSyntaxToken(
                    range: NSRange(location: start, length: pos - start),
                    type: type,
                    text: word
                ))
                isFirstWord = false
                continue
            }

            // Anything else
            tokens.append(AsmSyntaxToken(
                range: NSRange(location: pos, length: 1),
                type: .plain,
                text: String(Character(UnicodeScalar(ch)!))
            ))
            pos += 1
            isFirstWord = false
        }

        return tokens
    }

    /// Looks up documentation for a given opcode mnemonic.
    /// - Parameter mnemonic: The opcode to look up.
    /// - Returns: An `OpcodeRef` if found, otherwise `nil`.
    static func lookup(_ mnemonic: String) -> OpcodeRef? {
        return opcodeReference[mnemonic.uppercased()]
    }
}

