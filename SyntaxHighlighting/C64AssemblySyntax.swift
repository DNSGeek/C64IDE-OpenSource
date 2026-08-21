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

/// A single machine-code encoding of an instruction: one opcode byte, the
/// addressing mode it selects, and what that costs.
///
/// These are derived from `Disassembler6502.opcodeTable` rather than typed out
/// a second time, so the reference panel and the disassembler can never
/// disagree about a byte value, a length or a cycle count.
struct OpcodeEncoding {
    let opcode: UInt8
    let mode: AddressingMode
    /// Total instruction length, opcode byte included.
    let bytes: Int
    /// Cycles with no penalty applied.
    let cycles: Int
    /// Extra cycles when a page boundary is crossed (or, for branches, when
    /// the branch is taken -- see `cycleText`).
    let pageCrossPenalty: Int
    /// Undocumented encoding. A mnemonic can have both kinds: `NOP` is legal
    /// as $EA and undocumented in 27 other forms.
    let isIllegal: Bool

    /// Cycle count spelled out with its conditional penalty, e.g. "4 (+1 if
    /// page crossed)" or, for branches, "2 (+1 if taken, +1 more if page crossed)".
    var cycleText: String {
        let unit = cycles == 1 ? "cycle" : "cycles"
        guard pageCrossPenalty > 0 else { return "\(cycles) \(unit)" }
        if mode == .relative {
            return "\(cycles) \(unit) (+1 if taken, +1 more if page crossed)"
        }
        return "\(cycles) \(unit) (+1 if page crossed)"
    }
}

/// Documentation entry for a single 6502 opcode.
struct OpcodeRef {
    let mnemonic: String
    let fullName: String
    let description: String
    let flags: String        // Which processor flags are affected
    let cycles: String       // Base cycle count
    let addressingModes: String
    /// True for the undocumented ("illegal") NMOS 6502 instructions. These
    /// execute on a real 6502/6510 and appear in shipped C64 software, but
    /// MOS never specified them and later CMOS parts dropped them.
    let isIllegal: Bool
    /// Other mnemonics the same instruction is known by, for users coming from
    /// a different assembler or reference table.
    let aliases: String?
    let example: String?
    let notes: String?

    init(mnemonic: String,
         fullName: String,
         description: String,
         flags: String,
         cycles: String,
         addressingModes: String,
         isIllegal: Bool = false,
         aliases: String? = nil,
         example: String? = nil,
         notes: String? = nil) {
        self.mnemonic = mnemonic
        self.fullName = fullName
        self.description = description
        self.flags = flags
        self.cycles = cycles
        self.addressingModes = addressingModes
        self.isIllegal = isIllegal
        self.aliases = aliases
        self.example = example
        self.notes = notes
    }

    /// Every opcode byte that assembles to this mnemonic, in the same order
    /// the addressing modes are listed in `addressingModes`.
    var encodings: [OpcodeEncoding] {
        C64AssemblySyntax.encodings(for: mnemonic)
    }
}

// MARK: - 6502 Assembly Syntax

/// Central repository for 6502 assembly language syntax rules, references, and tokenization.
struct C64AssemblySyntax {

    /// All official (documented) 6502 opcodes.
    static let officialOpcodes: Set<String> = [
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

    /// Undocumented ("illegal") NMOS 6502 mnemonics.
    ///
    /// These run on the 6510 in every C64 and are used by real released
    /// software, so the editor highlights them like any other instruction.
    /// ca65 only assembles them once the source selects the extended
    /// instruction set with `.setcpu "6502X"`.
    ///
    /// `NOP` and `SBC` are deliberately absent: both are documented mnemonics
    /// that happen to have extra undocumented encodings ($EB and the 27 NOP
    /// forms), and they are already in `officialOpcodes`.
    static let illegalOpcodes: Set<String> = [
        // Read-modify-write combinations of a documented pair
        "SLO", "RLA", "SRE", "RRA", "DCP", "ISB",
        // Load / store combinations
        "LAX", "SAX", "LAS",
        // Immediate-mode combinations
        "ANC", "ALR", "ARR", "XAA", "SBX",
        // Unstable stores involving the address high byte
        "SHA", "SHX", "SHY", "TAS",
        // Processor lock-up
        "JAM",
    ]

    /// Every mnemonic the highlighter recognises, documented or not,
    /// including the alternate spellings in `mnemonicAliases`.
    static let opcodes: Set<String> = officialOpcodes
        .union(illegalOpcodes)
        .union(mnemonicAliases.keys)

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

    /// Alternate spellings mapped to the mnemonic this reference documents.
    ///
    /// The undocumented instructions were named independently by half a dozen
    /// disassemblers over the years, so the same opcode byte answers to
    /// several names. Three of these matter in this IDE specifically: the
    /// Disassembler window prints `ISB`, `XAA` and `SBX`, but ca65 spells the
    /// same three opcodes `ISC`, `ANE` and `AXS` -- verified by assembling
    /// them and checking the emitted bytes ($E7, $8B, $CB). Both spellings
    /// resolve here so a lookup works whichever one the user is holding.
    ///
    /// `XAS` is deliberately absent: different tables use it for $9E and for
    /// $9B, so resolving it silently would be a guess. `AXS` has the same
    /// history ($CB vs $87), but ca65 -- the assembler this IDE drives --
    /// defines it as $CB, so that is what it maps to.
    static let mnemonicAliases: [String: String] = [
        "ISC": "ISB", "INS": "ISB",
        "AXS": "SBX",
        "ASO": "SLO",
        "LSE": "SRE",
        "DCM": "DCP",
        "ASR": "ALR",
        "ANE": "XAA",
        "AHX": "SHA", "AXA": "SHA",
        "SHS": "TAS",
        "LAE": "LAS", "LAR": "LAS",
        "SAY": "SHY",
        "KIL": "JAM", "HLT": "JAM",
    ]

    // MARK: - Instruction Encodings

    /// Presentation order for the encoding table -- roughly simplest operand
    /// first, matching the order the `addressingModes` summaries use.
    private static let addressingModeOrder: [AddressingMode] = [
        .implied, .accumulator, .immediate,
        .zeroPage, .zeroPageX, .zeroPageY,
        .absolute, .absoluteX, .absoluteY,
        .indirect, .indirectX, .indirectY,
        .relative,
    ]

    /// Every opcode byte in the instruction set, grouped by mnemonic.
    ///
    /// Built once from the disassembler's 256-entry table so that byte values,
    /// instruction lengths and cycle counts have exactly one definition in the
    /// app. `OpcodeReferenceTests` asserts that the prose `cycles` and
    /// `addressingModes` summaries stay consistent with what is derived here.
    static let encodingsByMnemonic: [String: [OpcodeEncoding]] = {
        var map: [String: [OpcodeEncoding]] = [:]
        for (byte, info) in Disassembler6502.opcodeTable.enumerated() {
            // The table pads unassigned slots with a "???" placeholder.
            guard info.mnemonic != "???" else { continue }
            map[info.mnemonic, default: []].append(
                OpcodeEncoding(opcode: UInt8(byte),
                               mode: info.mode,
                               bytes: info.mode.instructionSize,
                               cycles: info.cycles,
                               pageCrossPenalty: info.pageCrossPenalty,
                               isIllegal: info.illegal)
            )
        }
        let rank = Dictionary(uniqueKeysWithValues:
            addressingModeOrder.enumerated().map { ($0.element, $0.offset) })
        for key in map.keys {
            // Documented encodings first, then by addressing mode, then by
            // byte value -- the JAM opcodes all share implied mode.
            map[key]?.sort {
                if $0.isIllegal != $1.isIllegal { return !$0.isIllegal }
                let l = rank[$0.mode] ?? 0, r = rank[$1.mode] ?? 0
                return l == r ? $0.opcode < $1.opcode : l < r
            }
        }
        return map
    }()

    /// Every opcode byte that assembles to `mnemonic`, resolving aliases.
    static func encodings(for mnemonic: String) -> [OpcodeEncoding] {
        let upper = mnemonic.uppercased()
        return encodingsByMnemonic[upper]
            ?? mnemonicAliases[upper].flatMap { encodingsByMnemonic[$0] }
            ?? []
    }

    // MARK: - Opcode Reference Database

    /// Reference for every 6502 instruction: the 56 documented opcodes and the
    /// 19 undocumented mnemonics the NMOS 6502/6510 also executes.
    ///
    /// Per-mode opcode bytes, lengths and cycle counts are NOT typed out here.
    /// They are derived from `Disassembler6502.opcodeTable` via `encodings`,
    /// so the panel cannot drift from the disassembler. The `cycles` and
    /// `addressingModes` fields are prose summaries of that derived data, and
    /// `OpcodeReferenceTests` asserts they agree with it.
    static let opcodeReference: [String: OpcodeRef] = [
        // ══ Load/Store ═══════════════════════════════════════════
        "LDA": OpcodeRef(mnemonic: "LDA", fullName: "Load Accumulator",
            description: "Loads a byte into the accumulator. Sets N and Z flags based on the value loaded.",
            flags: "N, Z", cycles: "2-6",
            addressingModes: "Immediate, Zero Page, ZP X, Absolute, Abs X, Abs Y, (Ind,X), (Ind),Y",
            example: "LDA #$41        ; A = the literal value $41\nLDA $D012       ; A = current raster line\nLDA MESSAGE,X   ; A = MESSAGE[X]\nLDA ($FB),Y     ; A = byte at pointer $FB/$FC, offset by Y",
            notes: "The (Ind),Y form is how you walk a buffer bigger than 256 bytes: store a 16-bit pointer in zero page once, then index through it with Y.\nLoading does not affect carry, so a LDA between a CMP and its branch is safe."),
        "LDX": OpcodeRef(mnemonic: "LDX", fullName: "Load X Register",
            description: "Loads a byte into the X register. Sets N and Z flags.",
            flags: "N, Z", cycles: "2-5",
            addressingModes: "Immediate, Zero Page, ZP Y, Absolute, Abs Y",
            example: "LDX #$00        ; X = 0, ready to index a loop\nLDX #$FF        ; the standard stack reset...\nTXS             ; ...paired with TXS",
            notes: "The indexed zero-page form is ZP,Y -- not ZP,X. There is no (Ind),X or (Ind),Y for LDX.\nX is the register TXS/TSX use, so interrupt and stack code often keeps it reserved for that."),
        "LDY": OpcodeRef(mnemonic: "LDY", fullName: "Load Y Register",
            description: "Loads a byte into the Y register. Sets N and Z flags.",
            flags: "N, Z", cycles: "2-5",
            addressingModes: "Immediate, Zero Page, ZP X, Absolute, Abs X",
            example: "LDY #$00        ; Y = 0\nLDY TABLE,X     ; Y = TABLE[X]",
            notes: "Mirror image of LDX: the indexed zero-page form is ZP,X.\nY is the only register that can index the (Ind),Y pointer mode, so buffer loops usually spend Y on that."),
        "STA": OpcodeRef(mnemonic: "STA", fullName: "Store Accumulator",
            description: "Stores the contents of the accumulator into a memory location.",
            flags: "None", cycles: "3-6",
            addressingModes: "Zero Page, ZP X, Absolute, Abs X, Abs Y, (Ind,X), (Ind),Y",
            example: "STA $D020       ; set the border colour\nSTA SCREEN,X    ; SCREEN[X] = A\nSTA ($FB),Y     ; write through a zero-page pointer",
            notes: "No flags are touched, so a store cannot disturb a pending branch.\nThere is no immediate mode -- there is nothing to store into.\nIndexed stores always pay their worst-case cycle count (STA $D020,X is 5 cycles, never 4). A store must not be allowed to happen twice, so the CPU cannot use the page-cross shortcut that the indexed loads get."),
        "STX": OpcodeRef(mnemonic: "STX", fullName: "Store X Register",
            description: "Stores the contents of the X register into a memory location.",
            flags: "None", cycles: "3-4",
            addressingModes: "Zero Page, ZP Y, Absolute",
            example: "STX $D016       ; write X to a VIC register\nSTX $FB         ; save X in zero page",
            notes: "Only three modes -- no absolute-indexed form exists. When you need STX ABS,X, use TXA and STA instead."),
        "STY": OpcodeRef(mnemonic: "STY", fullName: "Store Y Register",
            description: "Stores the contents of the Y register into a memory location.",
            flags: "None", cycles: "3-4",
            addressingModes: "Zero Page, ZP X, Absolute",
            example: "STY $FC         ; save Y in zero page\nSTY $FB,X       ; zero page, indexed by X\nSTY $D001       ; absolute -- but STY $D001,X does not exist",
            notes: "Mirror of STX, with ZP,X instead of ZP,Y. Also has no absolute-indexed form."),

        // ══ Transfer ═════════════════════════════════════════════
        "TAX": OpcodeRef(mnemonic: "TAX", fullName: "Transfer A to X",
            description: "Copies the accumulator into the X register.", flags: "N, Z", cycles: "2",
            addressingModes: "Implied",
            example: "LDA #$05\nTAX             ; X = 5, A still 5",
            notes: "A is left unchanged -- this is a copy, not a move."),
        "TAY": OpcodeRef(mnemonic: "TAY", fullName: "Transfer A to Y",
            description: "Copies the accumulator into the Y register.", flags: "N, Z", cycles: "2",
            addressingModes: "Implied",
            example: "LDA COUNT\nTAY             ; Y = COUNT, ready to index",
            notes: "A is left unchanged."),
        "TXA": OpcodeRef(mnemonic: "TXA", fullName: "Transfer X to A",
            description: "Copies the X register into the accumulator.", flags: "N, Z", cycles: "2",
            addressingModes: "Implied",
            example: "TXA             ; A = X\nPHA             ; the usual way to stack X before an ISR body",
            notes: "X is left unchanged. Because the 6502 cannot push X directly, TXA/PHA is the standard register-save idiom in interrupt handlers."),
        "TYA": OpcodeRef(mnemonic: "TYA", fullName: "Transfer Y to A",
            description: "Copies the Y register into the accumulator.", flags: "N, Z", cycles: "2",
            addressingModes: "Implied",
            example: "TYA             ; A = Y\nCLC\nADC #$10        ; arithmetic on Y, via A",
            notes: "Y is left unchanged. The 6502 has no arithmetic on X or Y beyond INC/DEC, so moving through A is how you do anything else to them."),
        "TSX": OpcodeRef(mnemonic: "TSX", fullName: "Transfer SP to X",
            description: "Copies the stack pointer into the X register.", flags: "N, Z", cycles: "2",
            addressingModes: "Implied",
            example: "TSX             ; X = stack pointer\nLDA $0101,X     ; peek at the byte below the top of stack",
            notes: "The only way to read the stack pointer. TSX followed by an indexed load into $0100,X is how you inspect stacked values without popping them."),
        "TXS": OpcodeRef(mnemonic: "TXS", fullName: "Transfer X to SP",
            description: "Copies the X register into the stack pointer.", flags: "None", cycles: "2",
            addressingModes: "Implied",
            example: "LDX #$FF\nTXS             ; reset the stack to the top of page 1",
            notes: "The odd one out: TXS is the only transfer that leaves the flags alone. Do not expect it to set Z or N.\nLDX #$FF / TXS is the standard stack reset at the start of a program that will never return to the caller."),

        // ══ Stack ════════════════════════════════════════════════
        "PHA": OpcodeRef(mnemonic: "PHA", fullName: "Push Accumulator",
            description: "Pushes a copy of the accumulator onto the stack.", flags: "None", cycles: "3",
            addressingModes: "Implied",
            example: "PHA             ; save A\nJSR SOMETHING\nPLA             ; restore A",
            notes: "The stack lives in page 1 ($0100-$01FF) and grows downward. The pointer wraps within that page, so an unbalanced push eventually corrupts the other end rather than escaping the page."),
        "PHP": OpcodeRef(mnemonic: "PHP", fullName: "Push Processor Status",
            description: "Pushes a copy of the status flags onto the stack. Note: B flag is always set in the pushed byte.",
            flags: "None", cycles: "3", addressingModes: "Implied",
            example: "PHP             ; save the flags (and the I bit)\nSEI\nJSR CRITICAL\nPLP             ; restore them, re-enabling IRQs if they were on",
            notes: "PHP always writes the B bit as 1 in the stacked copy, and bit 5 as 1 too. The live P register is unchanged.\nPHP/PLP is the correct way to make a routine interrupt-safe without assuming the caller had interrupts enabled."),
        "PLA": OpcodeRef(mnemonic: "PLA", fullName: "Pull Accumulator",
            description: "Pulls a byte from the stack into the accumulator.", flags: "N, Z", cycles: "4",
            addressingModes: "Implied",
            example: "PLA             ; A = top of stack, SP moves up\nPLA             ; discard a second stacked byte",
            notes: "Unlike PHA, PLA does set N and Z from the pulled value.\nPulling more than you pushed silently reads whatever is above the stack pointer -- there is no underflow check."),
        "PLP": OpcodeRef(mnemonic: "PLP", fullName: "Pull Processor Status",
            description: "Pulls a byte from the stack into the processor status register.", flags: "All", cycles: "4",
            addressingModes: "Implied",
            example: "PHP\nSEI\nJSR CRITICAL\nPLP             ; flags, including I, exactly as they were",
            notes: "Restores every flag at once, so it can change the interrupt-disable bit as a side effect. That is usually the point.\nThe B bit and bit 5 have no real storage in the P register; what you pull into them is not observable except via a later PHP."),

        // ══ Arithmetic ═══════════════════════════════════════════
        "ADC": OpcodeRef(mnemonic: "ADC", fullName: "Add with Carry",
            description: "Adds a value to the accumulator plus the carry flag. Result stored in A. Always CLC before the first ADC in a multi-byte add.",
            flags: "N, V, Z, C", cycles: "2-6",
            addressingModes: "Immediate, Zero Page, ZP X, Absolute, Abs X, Abs Y, (Ind,X), (Ind),Y",
            example: "CLC             ; 16-bit add: NUM1 + NUM2 -> RESULT\nLDA NUM1\nADC NUM2\nSTA RESULT\nLDA NUM1+1\nADC NUM2+1      ; carry from the low byte feeds in here\nSTA RESULT+1",
            notes: "CLC before the first ADC, then let the carry chain through the higher bytes untouched.\nC is the unsigned carry-out; V is the signed overflow. Test the one that matches how you are reading the numbers.\nIn decimal mode (after SED) ADC produces a BCD result, but N, V and Z are computed from the binary result and are not meaningful."),
        "SBC": OpcodeRef(mnemonic: "SBC", fullName: "Subtract with Carry",
            description: "Subtracts a value from the accumulator with borrow (inverse of carry). Always SEC before the first SBC.",
            flags: "N, V, Z, C", cycles: "2-6",
            addressingModes: "Immediate, Zero Page, ZP X, Absolute, Abs X, Abs Y, (Ind,X), (Ind),Y",
            example: "SEC             ; 16-bit subtract: NUM1 - NUM2 -> RESULT\nLDA NUM1\nSBC NUM2\nSTA RESULT\nLDA NUM1+1\nSBC NUM2+1      ; borrow chains through the carry flag\nSTA RESULT+1",
            notes: "Carry is an inverted borrow: SEC means no borrow. C stays set afterwards if the result did not need to borrow, which is why SBC and CMP set carry the same way.\nUndocumented $EB is a second SBC #imm that behaves identically to $E9 -- see the ENCODINGS list."),
        "INC": OpcodeRef(mnemonic: "INC", fullName: "Increment Memory",
            description: "Adds 1 to the value at a memory location.", flags: "N, Z", cycles: "5-7",
            addressingModes: "Zero Page, ZP X, Absolute, Abs X",
            example: "INC $D020       ; cycle the border colour\nINC COUNTER\nBNE SKIP        ; branch unless it wrapped to zero\nINC COUNTER+1   ; 16-bit increment",
            notes: "There is no INC A on the NMOS 6502 -- that arrived with the 65C02. Use CLC/ADC #$01, or keep the counter in X or Y.\nRead-modify-write instructions write the *old* value back before the new one. On hardware registers that double write is visible and is occasionally used deliberately."),
        "INX": OpcodeRef(mnemonic: "INX", fullName: "Increment X Register",
            description: "Adds 1 to the X register.", flags: "N, Z", cycles: "2", addressingModes: "Implied",
            example: "LOOP:\n  LDA SOURCE,X\n  STA DEST,X\n  INX\n  CPX #$10\n  BNE LOOP",
            notes: "Wraps $FF -> $00 and sets Z there, which is what makes counting up to a wrap a cheap loop terminator."),
        "INY": OpcodeRef(mnemonic: "INY", fullName: "Increment Y Register",
            description: "Adds 1 to the Y register.", flags: "N, Z", cycles: "2", addressingModes: "Implied",
            example: "LDY #$00\nLOOP:\n  LDA ($FB),Y\n  BEQ DONE      ; stop at the zero terminator\n  JSR $FFD2\n  INY\n  BNE LOOP",
            notes: "The natural partner to (Ind),Y string walks."),
        "DEC": OpcodeRef(mnemonic: "DEC", fullName: "Decrement Memory",
            description: "Subtracts 1 from the value at a memory location.", flags: "N, Z", cycles: "5-7",
            addressingModes: "Zero Page, ZP X, Absolute, Abs X",
            example: "DEC COUNTER\nBNE LOOP        ; keep going until it hits zero",
            notes: "No DEC A on the NMOS 6502; see INC.\nDecrementing to zero sets Z, so DEC/BNE is the cheapest countdown loop when the counter has to live in memory."),
        "DEX": OpcodeRef(mnemonic: "DEX", fullName: "Decrement X Register",
            description: "Subtracts 1 from the X register.", flags: "N, Z", cycles: "2", addressingModes: "Implied",
            example: "LDX #$08\nLOOP:\n  ASL VALUE\n  DEX\n  BNE LOOP      ; eight shifts",
            notes: "Counting down to zero with DEX/BNE is one instruction cheaper than counting up with INX/CPX/BNE."),
        "DEY": OpcodeRef(mnemonic: "DEY", fullName: "Decrement Y Register",
            description: "Subtracts 1 from the Y register.", flags: "N, Z", cycles: "2", addressingModes: "Implied",
            example: "LDY #$28\nLOOP:\n  LDA #$20\n  STA $0400,Y   ; blank a screen line\n  DEY\n  BPL LOOP",
            notes: "DEY/BPL runs a loop down through zero and stops at $FF, giving you one more iteration than DEY/BNE."),

        // ══ Logic ════════════════════════════════════════════════
        "AND": OpcodeRef(mnemonic: "AND", fullName: "Logical AND",
            description: "Bitwise AND with the accumulator. Each bit of A is ANDed with the corresponding bit of the operand.",
            flags: "N, Z", cycles: "2-6",
            addressingModes: "Immediate, Zero Page, ZP X, Absolute, Abs X, Abs Y, (Ind,X), (Ind),Y",
            example: "LDA $DC00\nAND #$10        ; isolate the fire-button bit\nBEQ FIRE        ; the joystick lines are active low",
            notes: "Use AND to clear bits (mask off) and to test a group of bits at once.\nAND #$7F clears bit 7; AND #$0F keeps the low nybble."),
        "ORA": OpcodeRef(mnemonic: "ORA", fullName: "Logical OR",
            description: "Bitwise OR with the accumulator. Used to set specific bits.",
            flags: "N, Z", cycles: "2-6",
            addressingModes: "Immediate, Zero Page, ZP X, Absolute, Abs X, Abs Y, (Ind,X), (Ind),Y",
            example: "LDA $D011\nORA #$20        ; turn on bitmap mode\nSTA $D011",
            notes: "Load / ORA / store is the standard read-modify-write on a hardware register when you must leave the other bits alone."),
        "EOR": OpcodeRef(mnemonic: "EOR", fullName: "Exclusive OR",
            description: "Bitwise XOR with the accumulator. Used to toggle/flip specific bits. EOR #$FF inverts all bits.",
            flags: "N, Z", cycles: "2-6",
            addressingModes: "Immediate, Zero Page, ZP X, Absolute, Abs X, Abs Y, (Ind,X), (Ind),Y",
            example: "LDA $D020\nEOR #$01        ; flip the low bit of the border colour\nSTA $D020",
            notes: "EOR #$FF gives the one's complement; follow it with CLC/ADC #$01 for the two's complement (negate).\nEOR is its own inverse, which is what makes it the basis of simple sprite XOR-draw and of cheap obfuscation."),
        "BIT": OpcodeRef(mnemonic: "BIT", fullName: "Bit Test",
            description: "Tests bits in memory with the accumulator. Z flag is set if A AND operand = 0. N flag = bit 7, V flag = bit 6 of the operand (not A).",
            flags: "N, V, Z", cycles: "3-4",
            addressingModes: "Zero Page, Absolute",
            example: "BIT $DC0D       ; read and clear the CIA interrupt flags\nBMI IRQ_HAPPENED ; N came from bit 7 of the register",
            notes: "N and V come straight from bits 7 and 6 of the *operand*, whatever A holds. That makes BIT the cheapest way to test the top two bits of a hardware register.\nA is never modified, and there is no immediate mode on the NMOS 6502.\nBecause BIT can set or clear V, it is one of the ways to control the overflow flag without arithmetic."),

        // ══ Shift/Rotate ═════════════════════════════════════════
        "ASL": OpcodeRef(mnemonic: "ASL", fullName: "Arithmetic Shift Left",
            description: "Shifts all bits left by one. Bit 0 becomes 0, old bit 7 goes to carry. Effectively multiplies by 2.",
            flags: "N, Z, C", cycles: "2-7",
            addressingModes: "Accumulator, Zero Page, ZP X, Absolute, Abs X",
            example: "ASL A           ; A = A * 2\nASL LOW         ; 16-bit shift left:\nROL HIGH        ; carry from LOW rotates into HIGH",
            notes: "ASL then ROL on the next byte up is the standard multi-byte shift left.\nThe memory forms are read-modify-write and write the old value back first."),
        "LSR": OpcodeRef(mnemonic: "LSR", fullName: "Logical Shift Right",
            description: "Shifts all bits right by one. Bit 7 becomes 0, old bit 0 goes to carry. Effectively unsigned divide by 2.",
            flags: "N(=0), Z, C", cycles: "2-7",
            addressingModes: "Accumulator, Zero Page, ZP X, Absolute, Abs X",
            example: "LSR A           ; unsigned A / 2\nLSR HIGH        ; 16-bit shift right:\nROR LOW         ; start at the high byte and rotate down",
            notes: "N is always cleared, since bit 7 becomes 0 -- LSR can never leave a negative result.\nThis is an unsigned divide. For a signed halving you need to preserve bit 7 yourself.\nMulti-byte shifts right run high byte first: LSR the top, ROR each byte below."),
        "ROL": OpcodeRef(mnemonic: "ROL", fullName: "Rotate Left",
            description: "Rotates all bits left through carry. Old carry goes to bit 0, old bit 7 goes to carry.",
            flags: "N, Z, C", cycles: "2-7",
            addressingModes: "Accumulator, Zero Page, ZP X, Absolute, Abs X",
            example: "ASL LOW\nROL HIGH        ; 16-bit value shifted left by one",
            notes: "A nine-bit rotate: carry is part of the ring, so the value takes nine ROLs to return to where it started.\nSet or clear C deliberately before a lone ROL -- whatever is in carry lands in bit 0."),
        "ROR": OpcodeRef(mnemonic: "ROR", fullName: "Rotate Right",
            description: "Rotates all bits right through carry. Old carry goes to bit 7, old bit 0 goes to carry.",
            flags: "N, Z, C", cycles: "2-7",
            addressingModes: "Accumulator, Zero Page, ZP X, Absolute, Abs X",
            example: "LSR HIGH\nROR LOW         ; 16-bit value shifted right by one",
            notes: "Nine-bit rotate, mirroring ROL.\nThe very earliest 6502s shipped without ROR; any 6510 in a C64 has it."),

        // ══ Branch ═══════════════════════════════════════════════
        "BCC": OpcodeRef(mnemonic: "BCC", fullName: "Branch if Carry Clear",
            description: "Branches if the carry flag is 0. Used after CMP/SBC for 'less than' (unsigned).",
            flags: "None", cycles: "2-4", addressingModes: "Relative",
            example: "LDA VALUE\nCMP #$10\nBCC LESS        ; taken when VALUE < $10, unsigned",
            notes: "Range is -128 to +127 bytes measured from the instruction *after* the branch. Out of range is an assembler error; the fix is to branch the opposite way over a JMP.\n2 cycles when not taken, 3 when taken, 4 when the target is on a different page."),
        "BCS": OpcodeRef(mnemonic: "BCS", fullName: "Branch if Carry Set",
            description: "Branches if the carry flag is 1. Used after CMP/SBC for 'greater than or equal' (unsigned).",
            flags: "None", cycles: "2-4", addressingModes: "Relative",
            example: "LDA VALUE\nCMP #$10\nBCS GTE         ; taken when VALUE >= $10, unsigned",
            notes: "Range is -128 to +127 bytes from the next instruction.\n2 cycles not taken, 3 taken, 4 taken across a page boundary."),
        "BEQ": OpcodeRef(mnemonic: "BEQ", fullName: "Branch if Equal (Zero Set)",
            description: "Branches if the zero flag is 1. Used after CMP for equality, or after LDA/DEC/etc. to test for zero.",
            flags: "None", cycles: "2-4", addressingModes: "Relative",
            example: "LDA ($FB),Y\nBEQ END_OF_STRING   ; a zero byte terminates",
            notes: "Any instruction that sets Z can be branched on -- you do not need a CMP first if a load or a decrement already did the work.\nRange is -128 to +127 bytes from the next instruction."),
        "BMI": OpcodeRef(mnemonic: "BMI", fullName: "Branch if Minus",
            description: "Branches if the negative flag is 1 (bit 7 of result was set).",
            flags: "None", cycles: "2-4", addressingModes: "Relative",
            example: "LDA $D012\nBMI LOWER_HALF  ; raster line >= 128",
            notes: "N is just a copy of bit 7 of the last result, so BMI is equally a 'bit 7 is set' test on unsigned data.\nRange is -128 to +127 bytes from the next instruction."),
        "BNE": OpcodeRef(mnemonic: "BNE", fullName: "Branch if Not Equal (Zero Clear)",
            description: "Branches if the zero flag is 0. The workhorse branch -- used in loops and inequality tests.",
            flags: "None", cycles: "2-4", addressingModes: "Relative",
            example: "LDX #$00\nLOOP:\n  STA $0400,X\n  INX\n  BNE LOOP      ; 256 iterations, ends when X wraps to 0",
            notes: "The most common loop terminator on the 6502.\nRange is -128 to +127 bytes from the next instruction."),
        "BPL": OpcodeRef(mnemonic: "BPL", fullName: "Branch if Plus",
            description: "Branches if the negative flag is 0 (bit 7 of result was clear). Often used to wait for raster line.",
            flags: "None", cycles: "2-4", addressingModes: "Relative",
            example: "WAIT:\n  LDA $D011\n  BPL WAIT      ; wait until the raster passes line 255",
            notes: "Counting a loop down with DEY/BPL runs one iteration past zero, stopping at $FF.\nRange is -128 to +127 bytes from the next instruction."),
        "BVC": OpcodeRef(mnemonic: "BVC", fullName: "Branch if Overflow Clear",
            description: "Branches if the overflow flag is 0. Rarely used in C64 game code.",
            flags: "None", cycles: "2-4", addressingModes: "Relative",
            example: "CLC\nADC DELTA\nBVC NO_OVERFLOW ; signed result still fits in a byte",
            notes: "Only meaningful after ADC, SBC, BIT, PLP, RTI or CLV -- nothing else touches V.\nRange is -128 to +127 bytes from the next instruction."),
        "BVS": OpcodeRef(mnemonic: "BVS", fullName: "Branch if Overflow Set",
            description: "Branches if the overflow flag is 1.",
            flags: "None", cycles: "2-4", addressingModes: "Relative",
            example: "BIT FLAGS\nBVS BIT6_WAS_SET    ; V came from bit 6 of FLAGS",
            notes: "Pairs naturally with BIT, which loads V straight from bit 6 of the operand.\nRange is -128 to +127 bytes from the next instruction."),

        // ══ Jump/Call ════════════════════════════════════════════
        "JMP": OpcodeRef(mnemonic: "JMP", fullName: "Jump",
            description: "Unconditional jump to an address. Indirect mode loads the target from a pointer.",
            flags: "None", cycles: "3-5",
            addressingModes: "Absolute, Indirect",
            example: "JMP MAIN_LOOP   ; absolute\nJMP ($0314)     ; indirect: jump through the IRQ vector",
            notes: "WARNING -- the indirect form has a hardware bug. JMP ($xxFF) reads the low byte from $xxFF but the high byte from $xx00 instead of $(xx+1)00, because the pointer increment does not carry into the high byte. Never place a jump vector across a page boundary.\nJMP does not touch the stack, so jumping out of a subroutine leaves the return address stranded."),
        "JSR": OpcodeRef(mnemonic: "JSR", fullName: "Jump to Subroutine",
            description: "Pushes the return address (minus 1) onto the stack, then jumps to the target. Use RTS to return.",
            flags: "None", cycles: "6", addressingModes: "Absolute",
            example: "JSR $FFD2       ; KERNAL CHROUT: print the character in A\nJSR CLEAR_SCREEN",
            notes: "Only absolute mode exists -- there is no indirect JSR. To call through a pointer, JSR to a stub containing JMP (vector).\nThe stacked address points at the last byte of the JSR itself; RTS adds 1 to compensate. Pushing your own address for an RTS jump means pushing target-1."),
        "RTS": OpcodeRef(mnemonic: "RTS", fullName: "Return from Subroutine",
            description: "Pulls the return address from the stack and jumps to it (plus 1). Pairs with JSR.",
            flags: "None", cycles: "6", addressingModes: "Implied",
            example: "MY_ROUTINE:\n  LDA #$93\n  JSR $FFD2\n  RTS           ; back to the caller",
            notes: "Adds 1 to the pulled address, unlike RTI which does not.\nPushing high byte then low byte of (target-1) and executing RTS is the classic computed-jump trick."),
        "RTI": OpcodeRef(mnemonic: "RTI", fullName: "Return from Interrupt",
            description: "Pulls the processor flags and program counter from the stack. Used at the end of interrupt handlers.",
            flags: "All (from stack)", cycles: "6", addressingModes: "Implied",
            example: "IRQ_HANDLER:\n  ; ...body...\n  LDA #$01\n  STA $D019     ; acknowledge the VIC interrupt\n  RTI",
            notes: "Pulls P first, then the return address, and does NOT add 1 to it -- the opposite of RTS.\nBecause P comes back off the stack, RTI restores the interrupt-disable bit automatically; there is no need to CLI first."),

        // ══ Compare ══════════════════════════════════════════════
        "CMP": OpcodeRef(mnemonic: "CMP", fullName: "Compare Accumulator",
            description: "Compares A with a value by performing A - operand without storing the result. Sets flags for subsequent branches. C=1 if A >= operand, Z=1 if equal.",
            flags: "N, Z, C", cycles: "2-6",
            addressingModes: "Immediate, Zero Page, ZP X, Absolute, Abs X, Abs Y, (Ind,X), (Ind),Y",
            example: "LDA KEY\nCMP #$0D\nBEQ RETURN_PRESSED\nCMP #$20\nBCC CONTROL_CHAR    ; unsigned: KEY < $20",
            notes: "A is never modified. Carry is the unsigned result: set means A >= operand.\nCMP does NOT set V, so it cannot be used for a correct signed comparison on its own. For signed work use SBC and test N against V.\nCMP #$00 is redundant after any load or arithmetic -- Z and N are already set."),
        "CPX": OpcodeRef(mnemonic: "CPX", fullName: "Compare X Register",
            description: "Compares X with a value. Sets flags like CMP but for X.", flags: "N, Z, C", cycles: "2-4",
            addressingModes: "Immediate, Zero Page, Absolute",
            example: "LOOP:\n  INX\n  CPX #$28\n  BNE LOOP      ; run X from 1 to $27",
            notes: "Only three modes -- no indexed or indirect forms. X is unchanged."),
        "CPY": OpcodeRef(mnemonic: "CPY", fullName: "Compare Y Register",
            description: "Compares Y with a value. Sets flags like CMP but for Y.", flags: "N, Z, C", cycles: "2-4",
            addressingModes: "Immediate, Zero Page, Absolute",
            example: "CPY #$19\nBCS OFF_SCREEN  ; unsigned: Y >= 25 rows",
            notes: "Same three modes as CPX. Y is unchanged."),

        // ══ Flags ════════════════════════════════════════════════
        "CLC": OpcodeRef(mnemonic: "CLC", fullName: "Clear Carry Flag",
            description: "Sets the carry flag to 0. Always do this before ADC for addition.", flags: "C=0", cycles: "2",
            addressingModes: "Implied",
            example: "CLC\nLDA LOW\nADC #$10        ; no stray carry leaking into the sum",
            notes: "Forgetting CLC before the first ADC is the single most common 6502 arithmetic bug: the result is intermittently one too high."),
        "CLD": OpcodeRef(mnemonic: "CLD", fullName: "Clear Decimal Mode",
            description: "Clears BCD (decimal) mode. The C64 KERNAL does this at startup, but good practice to CLD in interrupt handlers.",
            flags: "D=0", cycles: "2", addressingModes: "Implied",
            example: "CLD             ; make sure ADC/SBC are binary\nCLC\nADC #$01",
            notes: "Only ADC and SBC read the D flag; everything else ignores it.\nThe KERNAL reset routine clears D, so C64 code can usually assume binary mode -- but an interrupt handler that might preempt BCD arithmetic should CLD defensively."),
        "CLI": OpcodeRef(mnemonic: "CLI", fullName: "Clear Interrupt Disable",
            description: "Enables hardware interrupts (IRQ). Use after setting up an interrupt handler.",
            flags: "I=0", cycles: "2", addressingModes: "Implied",
            example: "SEI\nLDA #<MY_IRQ\nSTA $0314\nLDA #>MY_IRQ\nSTA $0315\nCLI             ; safe to take interrupts again",
            notes: "Affects IRQ only. The NMI line cannot be masked by the I flag -- the RESTORE key and some cartridges use NMI.\nThere is a one-instruction delay: the interrupt is recognised after the instruction following CLI."),
        "CLV": OpcodeRef(mnemonic: "CLV", fullName: "Clear Overflow Flag",
            description: "Sets the overflow flag to 0. It is the only instruction whose sole purpose is clearing V.", flags: "V=0", cycles: "2",
            addressingModes: "Implied",
            example: "CLV\nBVC ALWAYS      ; a 2-byte unconditional branch",
            notes: "V is also written by ADC and SBC (which clear it whenever no signed overflow occurred), by BIT (from bit 6 of the operand), and by PLP and RTI. CLV is simply the only instruction that does nothing else.\nCLV followed by BVC is an unconditional branch that, unlike JMP, is relocatable."),
        "SEC": OpcodeRef(mnemonic: "SEC", fullName: "Set Carry Flag",
            description: "Sets the carry flag to 1. Always do this before SBC for subtraction.", flags: "C=1", cycles: "2",
            addressingModes: "Implied",
            example: "SEC\nLDA TOTAL\nSBC AMOUNT      ; no stray borrow",
            notes: "Carry set means 'no borrow'. Forgetting SEC before the first SBC makes the result intermittently one too low."),
        "SED": OpcodeRef(mnemonic: "SED", fullName: "Set Decimal Mode",
            description: "Enables BCD (Binary Coded Decimal) mode for ADC and SBC. Rarely used on C64.",
            flags: "D=1", cycles: "2", addressingModes: "Implied",
            example: "SED\nCLC\nLDA #$19\nADC #$01        ; A = $20 in BCD, not $1A\nCLD             ; always turn it back off",
            notes: "Useful for scores and clocks you want to display without a binary-to-decimal conversion.\nAlways CLD when finished -- leaving D set corrupts any later arithmetic, including the KERNAL's.\nIn decimal mode the N, V and Z flags are computed from the binary result and are not meaningful."),
        "SEI": OpcodeRef(mnemonic: "SEI", fullName: "Set Interrupt Disable",
            description: "Disables hardware interrupts (IRQ). Essential when setting up raster interrupts or modifying interrupt vectors.",
            flags: "I=1", cycles: "2", addressingModes: "Implied",
            example: "SEI             ; no IRQ while the vector is half-written\nLDA #<MY_IRQ\nSTA $0314\nLDA #>MY_IRQ\nSTA $0315\nCLI",
            notes: "Blocks IRQ but not NMI.\nAny sequence that updates a 16-bit vector must be inside SEI/CLI, or an interrupt can fire between the two stores and jump to a half-updated address."),

        // ══ Other ════════════════════════════════════════════════
        "BRK": OpcodeRef(mnemonic: "BRK", fullName: "Break / Software Interrupt",
            description: "Triggers a software interrupt. Pushes PC+2 and status to stack, loads IRQ vector ($FFFE/$FFFF). The B flag is set in the pushed status byte to distinguish a software BRK from a hardware IRQ -- B is NOT set in the live processor register, only in the copy on the stack.",
            flags: "I=1 (live); B=1 (pushed copy of P only)", cycles: "7", addressingModes: "Implied",
            example: "BRK             ; on the C64 this drops to the machine monitor\n.BYTE $00       ; the padding byte BRK skips over",
            notes: "BRK is a one-byte opcode that pushes PC+2, so the byte immediately after it is skipped. Handlers that want to read a signature byte rely on this; everyone else should leave a $00 pad.\nBRK and IRQ share the $FFFE vector. A handler tells them apart by pulling the stacked status byte and testing the B bit.\nAn opcode byte of $00 in data misread as code produces a BRK, which is why a runaway program so often lands in the monitor."),
        "NOP": OpcodeRef(mnemonic: "NOP", fullName: "No Operation",
            description: "Does nothing for 2 cycles. Useful for timing alignment and patching code.",
            flags: "None", cycles: "2", addressingModes: "Implied",
            example: "NOP             ; burn 2 cycles\nNOP\nNOP             ; stable raster routines are mostly this",
            notes: "$EA is the documented NOP. The CPU also has 27 undocumented NOP encodings that take 1, 2 or 3 bytes and 2 to 5 cycles -- they are listed under ENCODINGS above and marked with a dagger.\nThose multi-byte forms are the neatest way to waste an odd number of cycles, or to skip over an operand: older references call the 2-byte forms DOP or SKB and the 3-byte forms TOP or SKW.\nNOP is also the standard way to blank out an instruction when patching a binary."),

        // ══ Undocumented ("illegal") NMOS 6502 instructions ══════
        //
        // Not specified by MOS, but they execute deterministically on the
        // 6510 in every C64 and appear in released software. ca65 assembles
        // the ones noted below only after `.setcpu "6502X"`.
        //
        // Most are a documented read-modify-write instruction and a
        // documented accumulator instruction sharing one opcode, executed
        // back to back on the same fetched byte -- which is why they cost the
        // RMW cycle count and set the union of both instructions' flags.

        "SLO": OpcodeRef(mnemonic: "SLO", fullName: "Shift Left then OR (undocumented)",
            description: "Shifts the memory operand left one bit, then ORs the result into the accumulator. Equivalent to ASL followed by ORA on the same location, in one instruction.",
            flags: "N, Z, C", cycles: "5-8",
            addressingModes: "Zero Page, ZP X, Absolute, Abs X, Abs Y, (Ind,X), (Ind),Y",
            isIllegal: true, aliases: "ASO",
            example: ".setcpu \"6502X\"\nSLO $FB         ; $FB = $FB << 1, then A = A | $FB",
            notes: "C comes from the shift (old bit 7); N and Z from the ORed accumulator result.\nStable on every NMOS 6502 -- safe to use. ca65 accepts SLO.\nHandy for shifting a value and accumulating the bits that were set, in 5 cycles instead of the 8 that ASL plus ORA would cost in zero page."),
        "RLA": OpcodeRef(mnemonic: "RLA", fullName: "Rotate Left then AND (undocumented)",
            description: "Rotates the memory operand left one bit through carry, then ANDs the result into the accumulator. ROL followed by AND on the same location.",
            flags: "N, Z, C", cycles: "5-8",
            addressingModes: "Zero Page, ZP X, Absolute, Abs X, Abs Y, (Ind,X), (Ind),Y",
            isIllegal: true,
            example: ".setcpu \"6502X\"\nRLA $FB         ; $FB = ROL $FB, then A = A & $FB",
            notes: "C is the bit rotated out of the operand; N and Z come from the ANDed result in A.\nStable on every NMOS 6502. ca65 accepts RLA."),
        "SRE": OpcodeRef(mnemonic: "SRE", fullName: "Shift Right then EOR (undocumented)",
            description: "Shifts the memory operand right one bit, then EORs the result into the accumulator. LSR followed by EOR on the same location.",
            flags: "N, Z, C", cycles: "5-8",
            addressingModes: "Zero Page, ZP X, Absolute, Abs X, Abs Y, (Ind,X), (Ind),Y",
            isIllegal: true, aliases: "LSE",
            example: ".setcpu \"6502X\"\nSRE $FB         ; $FB = $FB >> 1, then A = A ^ $FB",
            notes: "C is the old bit 0 of the operand; N and Z come from the EORed result in A.\nStable on every NMOS 6502. ca65 accepts SRE."),
        "RRA": OpcodeRef(mnemonic: "RRA", fullName: "Rotate Right then Add (undocumented)",
            description: "Rotates the memory operand right one bit through carry, then adds the result to the accumulator with carry. ROR followed by ADC on the same location.",
            flags: "N, V, Z, C", cycles: "5-8",
            addressingModes: "Zero Page, ZP X, Absolute, Abs X, Abs Y, (Ind,X), (Ind),Y",
            isIllegal: true,
            example: ".setcpu \"6502X\"\nRRA $FB         ; $FB = ROR $FB, then A = A + $FB + C",
            notes: "The carry the ROR shifts out is the same carry the ADC then consumes, so the two halves are genuinely chained.\nObeys the D flag in its ADC half, exactly like a real ADC.\nStable on every NMOS 6502. ca65 accepts RRA."),
        "SAX": OpcodeRef(mnemonic: "SAX", fullName: "Store A AND X (undocumented)",
            description: "Stores the bitwise AND of the accumulator and the X register into memory. Neither register is modified and no flags are affected.",
            flags: "None", cycles: "3-6",
            addressingModes: "Zero Page, ZP Y, Absolute, (Ind,X)",
            isIllegal: true, aliases: "AXS, AAX",
            example: ".setcpu \"6502X\"\nLDA #$F0\nLDX #$3C\nSAX $FB         ; $FB = $F0 & $3C = $30",
            notes: "The AND happens on the bus on the way out; A and X are untouched, and no flag moves.\nStable on every NMOS 6502. ca65 accepts SAX.\nBeware the naming clash: some older tables call this opcode AXS, and use SAX for $CB (documented here as SBX). ca65 uses SAX for $87 and AXS for $CB, which is the convention this reference follows."),
        "LAX": OpcodeRef(mnemonic: "LAX", fullName: "Load A and X (undocumented)",
            description: "Loads the same memory byte into both the accumulator and the X register at once.",
            flags: "N, Z", cycles: "2-6",
            addressingModes: "Immediate, Zero Page, ZP Y, Absolute, Abs Y, (Ind,X), (Ind),Y",
            isIllegal: true,
            example: ".setcpu \"6502X\"\nLAX $FB         ; A = X = value at $FB, in 3 cycles\nLAX ($FB),Y     ; load both through a pointer",
            notes: "Every form except immediate is stable and widely used -- it saves the TAX that would otherwise follow the load.\nUNSTABLE: the immediate form LAX #imm ($AB) is not reliable. It computes (A | magic) & imm, where the magic constant is typically $EE, $FF or $00 depending on the individual chip, its temperature and its supply voltage. Do not use it in code you intend to ship.\nca65 accepts LAX, including the unstable immediate form."),
        "DCP": OpcodeRef(mnemonic: "DCP", fullName: "Decrement then Compare (undocumented)",
            description: "Decrements the memory operand by one, then compares the accumulator against the new value. DEC followed by CMP on the same location.",
            flags: "N, Z, C", cycles: "5-8",
            addressingModes: "Zero Page, ZP X, Absolute, Abs X, Abs Y, (Ind,X), (Ind),Y",
            isIllegal: true, aliases: "DCM",
            example: ".setcpu \"6502X\"\nDCP COUNTER     ; COUNTER = COUNTER - 1, then compare with A\nBNE LOOP",
            notes: "Flags come from the comparison, not from the decrement, so C is set when A >= the decremented value.\nA useful loop primitive: decrement a memory counter and test it against A in one 5-cycle instruction.\nStable on every NMOS 6502. ca65 accepts DCP."),
        "ISB": OpcodeRef(mnemonic: "ISB", fullName: "Increment then Subtract (undocumented)",
            description: "Increments the memory operand by one, then subtracts the new value from the accumulator with borrow. INC followed by SBC on the same location.",
            flags: "N, V, Z, C", cycles: "5-8",
            addressingModes: "Zero Page, ZP X, Absolute, Abs X, Abs Y, (Ind,X), (Ind),Y",
            isIllegal: true, aliases: "ISC, INS",
            example: ".setcpu \"6502X\"\nSEC\nISC $FB         ; $FB = $FB + 1, then A = A - $FB - (1-C)",
            notes: "ca65 spells this ISC, not ISB. The Disassembler window prints ISB, so copying disassembly straight into a source file will not assemble until the mnemonic is changed -- both spellings are searchable in this panel.\nObeys the D flag in its SBC half.\nStable on every NMOS 6502."),
        "ANC": OpcodeRef(mnemonic: "ANC", fullName: "AND then Copy N to Carry (undocumented)",
            description: "ANDs an immediate value into the accumulator, then copies bit 7 of the result into the carry flag. Equivalent to AND #imm followed by ASL A -- but without actually shifting A.",
            flags: "N, Z, C", cycles: "2",
            addressingModes: "Immediate",
            isIllegal: true,
            example: ".setcpu \"6502X\"\nLDA VALUE\nANC #$80        ; isolate bit 7 and land it in carry\nBCS WAS_NEGATIVE",
            notes: "C ends up equal to N, which is what makes it a one-instruction 'test the sign into carry'.\nTwo opcodes, $0B and $2B, behave identically.\nStable on every NMOS 6502. ca65 accepts ANC."),
        "ALR": OpcodeRef(mnemonic: "ALR", fullName: "AND then Shift Right (undocumented)",
            description: "ANDs an immediate value into the accumulator, then shifts the accumulator right one bit. AND #imm followed by LSR A.",
            flags: "N(=0), Z, C", cycles: "2",
            addressingModes: "Immediate",
            isIllegal: true, aliases: "ASR",
            example: ".setcpu \"6502X\"\nLDA VALUE\nALR #$FE        ; mask off bit 0, then halve -- 2 cycles, 2 bytes",
            notes: "C is the bit shifted out *after* the AND, not before. N is always cleared, as with any LSR.\nMasking then halving in a single 2-cycle instruction makes this a common table-index trick.\nStable on every NMOS 6502. ca65 accepts ALR (not ASR)."),
        "ARR": OpcodeRef(mnemonic: "ARR", fullName: "AND then Rotate Right (undocumented)",
            description: "ANDs an immediate value into the accumulator, then rotates the accumulator right through carry -- but with its own unusual flag behaviour rather than ROR's.",
            flags: "N, V, Z, C (non-standard, see notes)", cycles: "2",
            addressingModes: "Immediate",
            isIllegal: true,
            example: ".setcpu \"6502X\"\nLDA VALUE\nARR #$FF        ; rotate right, with C and V taken from the result",
            notes: "The flags do NOT follow ROR. In binary mode: N is the carry that rotated in (so N equals the old C), Z is the usual zero test, C is bit 6 of the result, and V is bit 6 EOR bit 5 of the result.\nIn decimal mode the instruction additionally applies BCD fixups and the flags differ again -- avoid ARR with D set.\nThe odd C and V behaviour makes it useful for fast multiply and divide inner loops, which is the main reason it appears in real code.\nStable in binary mode on every NMOS 6502. ca65 accepts ARR."),
        "XAA": OpcodeRef(mnemonic: "XAA", fullName: "Transfer X to A then AND (undocumented, unstable)",
            description: "Computes A = (A | magic) & X & immediate, where 'magic' is an unpredictable constant supplied by the chip itself.",
            flags: "N, Z", cycles: "2",
            addressingModes: "Immediate",
            isIllegal: true, aliases: "ANE",
            example: ".setcpu \"6502X\"\nANE #$00        ; the only reliably predictable case: A = 0",
            notes: "UNSTABLE -- do not use. The magic constant is commonly $EE, $FF or $00, but it varies between individual chips and with temperature and supply voltage, so the same binary can behave differently on two C64s.\nThe result is predictable only when the immediate operand is $00, or when every bit of A that matters is already set.\nca65 spells this ANE, not XAA. The Disassembler window prints XAA; both are searchable here."),
        "SBX": OpcodeRef(mnemonic: "SBX", fullName: "Subtract from A AND X into X (undocumented)",
            description: "Computes X = (A AND X) - immediate and stores the result in X. The subtraction ignores the carry flag and sets carry the way a comparison does.",
            flags: "N, Z, C", cycles: "2",
            addressingModes: "Immediate",
            isIllegal: true, aliases: "AXS",
            example: ".setcpu \"6502X\"\nLDA #$FF\nAXS #$01        ; X = (A & X) - 1, and C reports no borrow",
            notes: "No borrow is taken in, so there is no need to SEC first. C is set exactly as CMP sets it: 1 when (A AND X) >= the immediate.\nIt is the only instruction that can subtract from X directly, which makes it valuable for pointer loops that need X to step by more than one.\nV is not affected, so this cannot overflow-check.\nca65 spells this AXS, not SBX. Note the clash described under SAX.\nStable on every NMOS 6502."),
        "LAS": OpcodeRef(mnemonic: "LAS", fullName: "Load A, X and SP from memory AND SP (undocumented)",
            description: "ANDs the memory operand with the stack pointer, then stores that one value into the accumulator, the X register and the stack pointer simultaneously.",
            flags: "N, Z", cycles: "4-5",
            addressingModes: "Abs Y",
            isIllegal: true, aliases: "LAR, LAE",
            example: ".setcpu \"6502X\"\nLAS $1234,Y     ; A = X = SP = ($1234+Y) & SP",
            notes: "Clobbers the stack pointer, so any subsequent RTS or interrupt returns to the wrong place unless SP is restored. That makes it essentially unusable in ordinary code, and it is vanishingly rare in real software.\nStable, despite the exotic behaviour. ca65 accepts LAS."),
        "TAS": OpcodeRef(mnemonic: "TAS", fullName: "Transfer A AND X to SP, then store (undocumented, unstable)",
            description: "Sets the stack pointer to A AND X, then stores SP AND (high byte of the target address + 1) into memory.",
            flags: "None", cycles: "5",
            addressingModes: "Abs Y",
            isIllegal: true, aliases: "SHS, XAS",
            example: ".setcpu \"6502X\"\nTAS $1234,Y     ; SP = A & X; ($1234+Y) = SP & ($12+1)",
            notes: "UNSTABLE -- do not use. It belongs to the family of stores that AND the value with the address high byte plus one, and when the Y index carries into a new page the high byte written to the bus is itself corrupted, so the instruction targets an unintended address.\nIt also destroys the stack pointer.\nca65 accepts TAS."),
        "SHA": OpcodeRef(mnemonic: "SHA", fullName: "Store A AND X AND address high byte (undocumented, unstable)",
            description: "Stores A AND X AND (high byte of the target address + 1) into memory.",
            flags: "None", cycles: "5-6",
            addressingModes: "Abs Y, (Ind),Y",
            isIllegal: true, aliases: "AHX, AXA",
            example: ".setcpu \"6502X\"\nSHA $1234,Y     ; ($1234+Y) = A & X & ($12+1)",
            notes: "UNSTABLE -- do not use. The value depends on the high byte of the address being written, and if the index carries into a new page the address itself is corrupted as well.\nca65 accepts SHA."),
        "SHX": OpcodeRef(mnemonic: "SHX", fullName: "Store X AND address high byte (undocumented, unstable)",
            description: "Stores X AND (high byte of the target address + 1) into memory.",
            flags: "None", cycles: "5",
            addressingModes: "Abs Y",
            isIllegal: true, aliases: "XAS, SXA",
            example: ".setcpu \"6502X\"\nSHX $1234,Y     ; ($1234+Y) = X & ($12+1)",
            notes: "UNSTABLE -- do not use, for the same page-crossing reason as SHA.\nSome references call this XAS, a name other references attach to TAS instead; this reference does not resolve XAS automatically because of that.\nca65 accepts SHX."),
        "SHY": OpcodeRef(mnemonic: "SHY", fullName: "Store Y AND address high byte (undocumented, unstable)",
            description: "Stores Y AND (high byte of the target address + 1) into memory.",
            flags: "None", cycles: "5",
            addressingModes: "Abs X",
            isIllegal: true, aliases: "SAY, SYA",
            example: ".setcpu \"6502X\"\nSHY $1234,X     ; ($1234+X) = Y & ($12+1)",
            notes: "UNSTABLE -- do not use. Mirror of SHX, indexed by X instead of Y.\nca65 accepts SHY."),
        "JAM": OpcodeRef(mnemonic: "JAM", fullName: "Halt the processor (undocumented)",
            description: "Locks the CPU solid. The processor stops fetching instructions and holds the address bus; nothing short of a hardware reset recovers it.",
            flags: "None", cycles: "-- (never completes)",
            addressingModes: "Implied",
            isIllegal: true, aliases: "KIL, HLT, CIM, CRP",
            example: ".setcpu \"6502X\"\nJAM             ; the machine stops here",
            notes: "Twelve opcode bytes all jam: $02, $12, $22, $32, $42, $52, $62, $72, $92, $B2, $D2 and $F2. The encoding table below lists a nominal 2 cycles, but the instruction never finishes.\nInterrupts do not help -- the CPU has stopped fetching, so IRQ and NMI are both ignored.\nSeeing JAM in a disassembly almost always means the disassembler has walked into data rather than code.\nThis IDE's emulator targets report a CPU halt when they hit one; the Run window surfaces it rather than appearing to freeze.\nca65 accepts JAM (not KIL or HLT)."),
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
    /// - Parameter mnemonic: The opcode to look up. Alternate spellings of the
    ///   undocumented instructions (`ISC`, `KIL`, `ANE`, ...) resolve to the
    ///   entry this reference files them under.
    /// - Returns: An `OpcodeRef` if found, otherwise `nil`.
    static func lookup(_ mnemonic: String) -> OpcodeRef? {
        let upper = mnemonic.uppercased()
        return opcodeReference[upper]
            ?? mnemonicAliases[upper].flatMap { opcodeReference[$0] }
    }
}

