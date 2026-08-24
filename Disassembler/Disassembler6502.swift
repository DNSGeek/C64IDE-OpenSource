import Foundation

// ═══════════════════════════════════════════════════════════
// MARK: - 6502 Addressing Modes
// ═══════════════════════════════════════════════════════════

/// Represents the addressing mode used by a 6502 instruction.
enum AddressingMode: String {
    case implied     = "impl"    // BRK, RTS, NOP
    case accumulator = "A"       // ASL A, ROL A
    case immediate   = "#"       // LDA #$FF
    case zeroPage    = "zp"      // LDA $FF
    case zeroPageX   = "zp,X"    // LDA $FF,X
    case zeroPageY   = "zp,Y"    // LDX $FF,Y
    case absolute    = "abs"     // LDA $FFFF
    case absoluteX   = "abs,X"   // LDA $FFFF,X
    case absoluteY   = "abs,Y"   // LDA $FFFF,Y
    case indirect    = "(ind)"   // JMP ($FFFF)
    case indirectX   = "(zp,X)"  // LDA ($FF,X)
    case indirectY   = "(zp),Y"  // LDA ($FF),Y
    case relative    = "rel"     // BEQ $FF (branch)

    /// Number of operand bytes (not counting the opcode itself)
    var operandSize: Int {
        switch self {
        case .implied, .accumulator: return 0
        case .immediate, .zeroPage, .zeroPageX, .zeroPageY,
             .indirectX, .indirectY, .relative: return 1
        case .absolute, .absoluteX, .absoluteY, .indirect: return 2
        }
    }

    /// Total instruction size in bytes (opcode + operands)
    var instructionSize: Int { 1 + operandSize }

    /// Human-readable name used by the ASM reference panel's encoding table.
    var displayName: String {
        switch self {
        case .implied:     return "Implied"
        case .accumulator: return "Accumulator"
        case .immediate:   return "Immediate"
        case .zeroPage:    return "Zero Page"
        case .zeroPageX:   return "Zero Page,X"
        case .zeroPageY:   return "Zero Page,Y"
        case .absolute:    return "Absolute"
        case .absoluteX:   return "Absolute,X"
        case .absoluteY:   return "Absolute,Y"
        case .indirect:    return "Indirect"
        case .indirectX:   return "(Indirect,X)"
        case .indirectY:   return "(Indirect),Y"
        case .relative:    return "Relative"
        }
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - Opcode Definition
// ═══════════════════════════════════════════════════════════

/// Metadata describing a 6502 instruction's behavior and timing.
struct OpcodeInfo {
    let mnemonic: String
    let mode: AddressingMode
    let cycles: Int
    /// Extra cycles if a page boundary is crossed (abs,X / abs,Y / (zp),Y)
    /// or if a branch is taken (+1), and a further +1 if that crosses a page.
    let pageCrossPenalty: Int
    let illegal: Bool

    init(_ mnemonic: String, _ mode: AddressingMode, _ cycles: Int,
         pageCross: Int = 0, illegal: Bool = false) {
        self.mnemonic = mnemonic
        self.mode = mode
        self.cycles = cycles
        self.pageCrossPenalty = pageCross
        self.illegal = illegal
    }

    /// Worst-case cycle count for this instruction.
    ///
    /// Every mode except `.relative` charges `pageCrossPenalty` at most once,
    /// when the effective address crosses a page boundary. Branches charge it
    /// twice: +1 when the branch is taken, and +1 again when the taken branch
    /// lands on a different page -- so `BNE` runs 2, 3 or 4 cycles. Deriving the
    /// worst case here rather than at each call site keeps the disassembler,
    /// the debugger and the ASM reference panel from drifting apart.
    var maxCycles: Int {
        mode == .relative ? cycles + 2 * pageCrossPenalty
                          : cycles + pageCrossPenalty
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - Disassembled Line
// ═══════════════════════════════════════════════════════════

extension String {
    /// Right-pads to `width` with spaces, but never truncates.
    ///
    /// `String.padding(toLength:)` silently *cuts* anything longer than the
    /// target, which corrupted operands the moment a symbol name made an
    /// instruction longer than its column (`LDA VIC_BORDERCOLOR,X` came out as
    /// `LDA VIC_BORDER`). Columns may drift on an over-long line; the text may
    /// not be lost.
    func columnPadded(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}

/// Represents a single line of disassembled 6502 code.
struct DisassembledLine {
    let address: UInt16
    let bytes: [UInt8]
    let mnemonic: String
    let operand: String
    let comment: String?
    let isIllegal: Bool
    let isData: Bool        // Data bytes, not executable
    /// Base cycle count for this instruction (0 for data lines)
    let cycles: Int
    /// Additional cycles if page boundary crossed or branch taken
    let pageCrossPenalty: Int
    /// Addressing mode of the decoded instruction; `nil` on data lines.
    /// Needed to apply the branch-specific worst-case cycle rule and to know
    /// when ca65 needs an explicit address-size override on export.
    let mode: AddressingMode?
    /// Operand text for ca65 export, which is not always the text shown on
    /// screen -- see `Disassembler6502.formatOperand(forAssembly:)`.
    let asmOperand: String

    /// Worst-case cycle count, applying the branch rule described on
    /// `OpcodeInfo.maxCycles`. Data lines cost nothing.
    var maxCycles: Int {
        guard !isData else { return 0 }
        return mode == .relative ? cycles + 2 * pageCrossPenalty
                                 : cycles + pageCrossPenalty
    }

    // MARK: - PETSCII hint

    /// Returns the displayable character for a byte in the PETSCII hint column,
    /// following the same logic a hex editor's ASCII column does but PETSCII-aware.
    ///
    /// Mapping:
    ///   $20-$7E  printable ASCII-overlap range (A-Z at $41-$5A, digits, punctuation)
    ///   $A0      reverse-space -- shown as a regular space
    ///   $C1-$DA  PETSCII shifted uppercase A-Z (same glyphs, different code points)
    ///   everything else -> '.'
    private static func petsciiChar(_ byte: UInt8) -> Character {
        switch byte {
        case 0x20...0x7E: return Character(UnicodeScalar(byte))
        case 0xA0:        return " "
        case 0xC1...0xDA: return Character(UnicodeScalar(byte - 0x80))  // $C1 -> 'A' ... $DA -> 'Z'
        default:          return "."
        }
    }

    /// Three-character PETSCII hint for the instruction bytes, always padded to three
    /// characters so the column stays at a fixed position regardless of instruction length.
    ///
    /// Example: bytes $48 $45 $4C -> "|HEL|", bytes $EA -> "|.  |"
    ///
    /// This lets you scan down and spot sequences that are really string data rather
    /// than genuine code -- even if the disassembler has decoded them as illegal opcodes.
    var petsciiHint: String {
        let chars = String(bytes.prefix(3).map { Self.petsciiChar($0) })
        return "|" + chars.padding(toLength: 3, withPad: " ", startingAt: 0) + "|"
    }

    // MARK: - Formatted output

    /// Formats the line for display:
    ///   "$0810  A9 00 EA  LDA #$00        ; comment  |...|"
    ///
    /// The rightmost column is a PETSCII hint for the raw bytes -- useful for
    /// spotting string data that the disassembler has decoded as (illegal) opcodes.
    var formatted: String {
        let addrStr = String(format: "$%04X", address)
        let hexBytes = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        let hexPadded = hexBytes.columnPadded(to: 9)

        if isData {
            return "\(addrStr)  \(hexPadded)  \(mnemonic) \(operand)  \(petsciiHint)"
        }

        // Always pad the instruction to 14 chars so the PETSCII column stays at a
        // fixed offset regardless of whether this line has a comment.
        let inst = operand.isEmpty ? mnemonic : "\(mnemonic) \(operand)"
        let instPadded = inst.columnPadded(to: 14)

        if let comment = comment {
            return "\(addrStr)  \(hexPadded)  \(instPadded) ; \(comment)  \(petsciiHint)"
        }
        return "\(addrStr)  \(hexPadded)  \(instPadded)  \(petsciiHint)"
    }

    /// ca65 spells three of the undocumented mnemonics differently from the
    /// names this disassembler prints. Verified by assembling each form with
    /// `.setcpu "6502X"` and checking the emitted byte: ISC = $E7, ANE = $8B,
    /// AXS = $CB. Every other mnemonic the table produces -- including JAM,
    /// SHA, SHX, SHY and TAS -- ca65 accepts as spelled.
    static let ca65Mnemonics: [String: String] = [
        "ISB": "ISC",
        "XAA": "ANE",
        "SBX": "AXS",
    ]

    /// Mnemonic as ca65 spells it.
    var ca65Mnemonic: String { Self.ca65Mnemonics[mnemonic] ?? mnemonic }

    /// Formats the line as reassemblable source: "    LDA #$00    ; comment"
    var asmSource: String {
        if isData {
            let values = bytes.map { String(format: "$%02X", $0) }.joined(separator: ", ")
            return "    .byte \(values)"
        }
        let inst = asmOperand.isEmpty ? ca65Mnemonic : "\(ca65Mnemonic) \(asmOperand)"
        // An undocumented opcode is worth calling out in exported source even
        // when the operand already earned a more specific comment.
        let note = isIllegal ? (comment.map { "\($0) [undocumented]" } ?? "undocumented opcode")
                             : comment
        if let note = note {
            // columnPadded stops at the column width, so an over-long
            // instruction still needs a separating space before the comment.
            let padded = inst.columnPadded(to: 16)
            return "    \(padded)\(padded.hasSuffix(" ") ? "" : " "); \(note)"
        }
        return "    \(inst)"
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - Disassembler
// ═══════════════════════════════════════════════════════════

/// Disassembles 6502 machine code into annotated assembly lines.
///
/// Performs a two-pass analysis:
/// 1. Scans for branch/jump targets to generate label annotations.
/// 2. Disassembles instructions, formatting operands and adding ROM/I/O comments.
class Disassembler6502 {

    /// Largest block the 6502 address space can hold.
    static let addressSpaceSize = 0x10000

    /// Known labels for annotation (address → name)
    private var labels: [UInt16: String] = [:]

    /// Branch/jump targets that land on an instruction boundary within the
    /// disassembled block, and so can carry a generated `L_xxxx` label.
    private(set) var branchTargets: Set<UInt16> = []

    /// Named labels actually referenced by the operands of the last
    /// disassembly. Export uses this to emit equates for exactly the symbols
    /// the source mentions, instead of dumping the whole ROM symbol table.
    private(set) var referencedLabels: Set<UInt16> = []

    /// Memoised results of `descriptionForAddress`, which otherwise re-runs a
    /// linear memory-map scan for every annotated instruction.
    private var descriptionCache: [UInt16: String?] = [:]

    init() {
        loadKernalLabels()
        loadIOLabels()
        ensureUniqueLabelNames()
    }

    /// Guarantees no two addresses share a label name.
    ///
    /// Labels are merged from several independent tables -- the ROM symbol set,
    /// the KERNAL jump table and the hand-written VIC/SID/CIA lists -- so a name
    /// collision between them is possible. Left alone it would surface far
    /// downstream as either a duplicate-symbol error from ca65 or, worse, an
    /// operand quietly resolving to the wrong address. Colliding names get their
    /// address appended, which is both unique and self-explanatory.
    private func ensureUniqueLabelNames() {
        var used: Set<String> = []
        for address in labels.keys.sorted() {
            guard let name = labels[address] else { continue }
            if used.insert(name).inserted { continue }
            let unique = "\(name)_\(String(format: "%04X", address))"
            labels[address] = unique
            used.insert(unique)
        }
    }

    // MARK: - Load PRG

    /// Header a `.p00` (PC64) container puts in front of the payload:
    /// the eight bytes `C64File\0`, a 16-byte PETSCII name, one record-size
    /// byte and one reserved byte -- 26 in all -- then the usual two-byte
    /// load address.
    private static let p00Magic = Array("C64File".utf8) + [0x00]
    private static let p00HeaderSize = 26

    /// How a program file carries -- or fails to carry -- its load address.
    enum ProgramFormat {
        /// Two-byte little-endian load address, then the payload.
        case prg
        /// A `.prg` behind a 26-byte `C64File` container header.
        case p00
        /// A raw memory dump. Nothing in the file records where it belongs.
        case raw
    }

    /// A program file split into its load address and payload.
    struct ProgramFile {
        let format: ProgramFormat
        /// The address the file declares, or `nil` for `.raw`, where only the
        /// user can say where the bytes were meant to live.
        let loadAddress: UInt16?
        let data: [UInt8]
    }

    /// Loads a program file and splits off its load address, if it has one.
    ///
    /// Three layouts reach this method and they are not interchangeable:
    ///
    /// - `.prg` puts a two-byte little-endian load address in front.
    /// - `.p00` buries that same pair behind a `C64File` header. Read as a
    ///   plain `.prg` it yields a load address of `$3643` -- the ASCII `C6` --
    ///   and 24 bytes of header disassembled as instructions.
    /// - `.bin` is a raw dump by convention and carries no address at all.
    ///   Reading its first two bytes as one both loses them from the dump and
    ///   bases the whole listing wherever those bytes happen to point, so every
    ///   address, branch target and symbol comes out wrong. There is nothing to
    ///   guess from, so `loadAddress` is `nil` and the caller must ask.
    ///
    /// - Throws: `DisassemblerError.fileTooSmall` if there is nothing to
    ///   disassemble, or `.tooLarge` if the payload cannot fit in the 6502
    ///   address space.
    static func load(from url: URL) throws -> ProgramFile {
        var bytes = [UInt8](try Data(contentsOf: url))

        let isP00 = bytes.count >= p00HeaderSize
            && Array(bytes.prefix(p00Magic.count)) == p00Magic
        if isP00 { bytes.removeFirst(p00HeaderSize) }

        if !isP00 && url.pathExtension.lowercased() == "bin" {
            guard !bytes.isEmpty else { throw DisassemblerError.fileTooSmall }
            guard bytes.count <= addressSpaceSize else { throw DisassemblerError.tooLarge }
            return ProgramFile(format: .raw, loadAddress: nil, data: bytes)
        }

        let (address, payload) = try splitLoadAddress(from: bytes)
        return ProgramFile(format: isP00 ? .p00 : .prg, loadAddress: address, data: payload)
    }

    /// Splits a two-byte little-endian load address off the front of a block.
    ///
    /// Exposed separately so a raw `.bin` that does turn out to carry a header
    /// can be reinterpreted without going back to disk.
    static func splitLoadAddress(from bytes: [UInt8]) throws -> (address: UInt16, data: [UInt8]) {
        guard bytes.count >= 3 else { throw DisassemblerError.fileTooSmall }
        let address = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        let payload = Array(bytes.dropFirst(2))

        // Everything downstream indexes memory with a UInt16, so a payload that
        // cannot be addressed is rejected here rather than trapping mid-decode.
        guard payload.count <= addressSpaceSize else { throw DisassemblerError.tooLarge }
        return (address, payload)
    }

    // MARK: - Disassemble

    /// Disassembles a block of data starting at the given address.
    /// - Parameters:
    ///   - data: Raw machine code bytes.
    ///   - startAddress: Memory address where the data is loaded.
    /// - Returns: Array of `DisassembledLine` objects.
    func disassemble(data: [UInt8], startAddress: UInt16) -> [DisassembledLine] {
        var lines: [DisassembledLine] = []
        branchTargets.removeAll()
        referencedLabels.removeAll()

        // ── First pass ───────────────────────────────────────
        // Walk the instruction stream collecting control-flow targets, and the
        // set of addresses that begin an instruction. A target is only usable
        // as a label if it lands on a boundary this walk actually reached --
        // otherwise the exported source would define `L_xxxx` nowhere and the
        // operand referencing it would not resolve.
        var rawTargets: Set<UInt16> = []
        var instructionStarts: Set<UInt16> = []
        var offset = 0
        while offset < data.count {
            let info = Self.opcodeTable[Int(data[offset])]
            let size = info.mode.instructionSize
            let addr = startAddress &+ UInt16(truncatingIfNeeded: offset)
            instructionStarts.insert(addr)

            if offset + size <= data.count {
                if info.mode == .relative {
                    rawTargets.insert(Self.branchTarget(from: addr, offset: data[offset + 1]))
                } else if info.mode == .absolute,
                          info.mnemonic == "JMP" || info.mnemonic == "JSR" {
                    rawTargets.insert(UInt16(data[offset + 1]) | (UInt16(data[offset + 2]) << 8))
                }
            }
            // `instructionSize` is `1 + operandSize`, so it is never zero and
            // this walk always advances.
            offset += size
        }
        branchTargets = rawTargets.intersection(instructionStarts)

        // ── Second pass ──────────────────────────────────────
        // Disassemble with labels and annotations.
        offset = 0
        while offset < data.count {
            let currentAddr = startAddress &+ UInt16(truncatingIfNeeded: offset)
            let info = Self.opcodeTable[Int(data[offset])]
            let size = info.mode.instructionSize

            // Check if we have enough bytes for a complete instruction
            guard offset + size <= data.count else {
                // Remaining bytes as data
                let remaining = Array(data[offset...])
                lines.append(DisassembledLine(
                    address: currentAddr, bytes: remaining,
                    mnemonic: ".byte", operand: remaining.map { String(format: "$%02X", $0) }.joined(separator: ", "),
                    comment: "incomplete instruction", isIllegal: false, isData: true,
                    cycles: 0, pageCrossPenalty: 0, mode: nil, asmOperand: ""
                ))
                break
            }

            let instrBytes = Array(data[offset..<offset + size])
            let operand = formatOperand(info, bytes: instrBytes, address: currentAddr,
                                        forAssembly: false)
            let asmOperand = formatOperand(info, bytes: instrBytes, address: currentAddr,
                                           forAssembly: true)
            let comment = annotateInstruction(info, bytes: instrBytes, address: currentAddr)

            lines.append(DisassembledLine(
                address: currentAddr, bytes: instrBytes,
                mnemonic: info.mnemonic, operand: operand,
                comment: comment, isIllegal: info.illegal, isData: false,
                cycles: info.cycles, pageCrossPenalty: info.pageCrossPenalty,
                mode: info.mode, asmOperand: asmOperand
            ))

            offset += size
        }

        return lines
    }

    /// Resolves a relative branch to its target address.
    ///
    /// The 6502 computes this in a 16-bit register that simply wraps, so the
    /// arithmetic is done on `UInt16` with wrapping operators. Doing it through
    /// a checked `UInt16(Int(...))` conversion used to trap the whole app: any
    /// backward branch decoded near `$0000`, or forward branch near `$FFFF`,
    /// left the representable range. Because every byte is decoded as an
    /// opcode, data regions produce such branches constantly.
    static func branchTarget(from address: UInt16, offset: UInt8) -> UInt16 {
        let signed = Int16(Int8(bitPattern: offset))
        return address &+ 2 &+ UInt16(bitPattern: signed)
    }

    // MARK: - Operand Formatting

    /// Renders an instruction's operand.
    ///
    /// - Parameter forAssembly: when `true`, produce text ca65 will assemble
    ///   back to the same bytes. The two forms differ in one place: an
    ///   absolute-mode operand whose address is below `$0100` needs ca65's `a:`
    ///   size override, because ca65 otherwise "optimises" `LDA $0010` from the
    ///   three-byte absolute encoding ($AD) down to the two-byte zero-page one
    ///   ($A5), shifting every following address. Verified against ca65 2.19.
    private func formatOperand(_ info: OpcodeInfo, bytes: [UInt8], address: UInt16,
                               forAssembly: Bool) -> String {
        /// Symbolic name for an address, preferring a known ROM/IO symbol and
        /// falling back to a generated branch-target label.
        func symbol(for addr: UInt16) -> String? {
            if let label = labels[addr] {
                referencedLabels.insert(addr)
                return label
            }
            return nil
        }

        /// Absolute operand text, with ca65's size override where required.
        func absolute(_ addr: UInt16, suffix: String) -> String {
            // ca65 picks the encoding from the value, so anything that fits in
            // a byte must be forced wide to preserve the original instruction.
            let prefix = (forAssembly && addr < 0x0100) ? "a:" : ""
            if let name = symbol(for: addr) { return "\(prefix)\(name)\(suffix)" }
            return prefix + String(format: "$%04X", addr) + suffix
        }

        /// Jump/branch destination: a ROM symbol if there is one, otherwise the
        /// generated label when the target starts an instruction we emitted.
        func destination(_ addr: UInt16) -> String {
            if let name = symbol(for: addr) { return name }
            if branchTargets.contains(addr) { return String(format: "L_%04X", addr) }
            return String(format: "$%04X", addr)
        }

        let word = { UInt16(bytes[1]) | (UInt16(bytes[2]) << 8) }

        switch info.mode {
        case .implied:
            return ""
        case .accumulator:
            return "A"
        case .immediate:
            return String(format: "#$%02X", bytes[1])
        case .zeroPage:
            return symbol(for: UInt16(bytes[1])) ?? String(format: "$%02X", bytes[1])
        case .zeroPageX:
            return (symbol(for: UInt16(bytes[1])) ?? String(format: "$%02X", bytes[1])) + ",X"
        case .zeroPageY:
            return (symbol(for: UInt16(bytes[1])) ?? String(format: "$%02X", bytes[1])) + ",Y"
        case .absolute:
            // JMP/JSR are control flow and can reach a generated label; every
            // other absolute instruction is a data reference.
            if info.mnemonic == "JMP" || info.mnemonic == "JSR" {
                return destination(word())
            }
            return absolute(word(), suffix: "")
        case .absoluteX:
            return absolute(word(), suffix: ",X")
        case .absoluteY:
            return absolute(word(), suffix: ",Y")
        case .indirect:
            let addr = word()
            // `JMP (CINV)` reads far better than `JMP ($0314)`. No size override
            // is needed: $6C is the only indirect JMP encoding, so ca65 has
            // nothing to optimise it down to.
            if let name = symbol(for: addr) { return "(\(name))" }
            return "(" + String(format: "$%04X", addr) + ")"
        case .indirectX:
            return "(" + (symbol(for: UInt16(bytes[1])) ?? String(format: "$%02X", bytes[1])) + ",X)"
        case .indirectY:
            return "(" + (symbol(for: UInt16(bytes[1])) ?? String(format: "$%02X", bytes[1])) + "),Y"
        case .relative:
            return destination(Self.branchTarget(from: address, offset: bytes[1]))
        }
    }

    // MARK: - Annotations

    /// Builds the trailing `; comment` for an instruction.
    ///
    /// Annotations accumulate rather than short-circuit. The previous version
    /// returned on the first match, so an undocumented opcode with a known
    /// target address (`SLO $D020`) silently lost its "illegal" note -- and if
    /// the address had a label but no description, the line ended up with no
    /// comment at all even though there was something to say about it.
    private func annotateInstruction(_ info: OpcodeInfo, bytes: [UInt8], address: UInt16) -> String? {
        var notes: [String] = []

        switch info.mode {
        case .absolute, .absoluteX, .absoluteY, .indirect:
            let target = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
            if let desc = descriptionForAddress(target) { notes.append(desc) }
        case .zeroPage, .zeroPageX, .zeroPageY, .indirectX, .indirectY:
            if let desc = descriptionForAddress(UInt16(bytes[1])) { notes.append(desc) }
        case .immediate:
            // Show the character an immediate load would put on screen. The
            // C64's PETSCII and ASCII agree over this range, so the same
            // mapping the byte-hint column uses applies here.
            let val = bytes[1]
            if ["LDA", "LDX", "LDY", "CMP", "CPX", "CPY"].contains(info.mnemonic),
               val >= 0x20, val < 0x7F {
                notes.append("'\(Character(UnicodeScalar(val)))'")
            }
        case .implied, .accumulator, .relative:
            break
        }

        if info.illegal { notes.append("ILLEGAL OPCODE") }

        return notes.isEmpty ? nil : notes.joined(separator: " — ")
    }

    /// Human-readable description of a memory address, or `nil` if nothing is
    /// known about it.
    ///
    /// Results are memoised: this runs once per instruction, and the underlying
    /// memory-map lookup is a linear scan over the whole C64 memory map.
    private func descriptionForAddress(_ address: UInt16) -> String? {
        if let cached = descriptionCache[address] { return cached }
        let result = computeDescription(for: address)
        descriptionCache[address] = result
        return result
    }

    private func computeDescription(for address: UInt16) -> String? {
        // ROM symbols — covers BASIC, floating point, KERNAL jump table, and internals.
        // KERNAL jump-table entries are merged into this set by `loadKernalLabels`,
        // so there is no need to scan `C64Reference.kernalRoutines` separately.
        if let sym = C64ROMSymbols.symbol(at: address) {
            return "\(sym.name) — \(sym.description)"
        }

        // KERNAL routines (in case of any not in ROM symbols)
        if let routine = C64Reference.lookupKernal(address: address) {
            return routine.name
        }

        // VIC-II, SID, CIA registers — provide register-level detail if available
        if let entry = C64Reference.lookup(address: address) {
            return entry.name
        }

        // Broad chip ranges as fallback
        if address >= 0xD000 && address <= 0xD3FF { return "VIC-II" }
        if address >= 0xD400 && address <= 0xD7FF { return "SID" }
        if address >= 0xDC00 && address <= 0xDCFF { return "CIA1" }
        if address >= 0xDD00 && address <= 0xDDFF { return "CIA2" }

        return nil
    }

    // MARK: - Label Loading

    private func loadKernalLabels() {
        // Load KERNAL jump table labels
        for routine in C64Reference.kernalRoutines {
            labels[routine.address] = routine.name
        }
        // Load all ROM symbols (BASIC, FP math, KERNAL internals)
        for sym in C64ROMSymbols.allSymbols {
            if labels[sym.address] == nil {
                labels[sym.address] = sym.name
            }
        }
    }

    private func loadIOLabels() {
        // VIC-II registers ($D000-$D3FF) -- full register set
        let vicLabels: [(UInt16, String)] = [
            // Sprite X/Y positions
            (0xD000, "VIC_SPR0X"),  (0xD001, "VIC_SPR0Y"),
            (0xD002, "VIC_SPR1X"),  (0xD003, "VIC_SPR1Y"),
            (0xD004, "VIC_SPR2X"),  (0xD005, "VIC_SPR2Y"),
            (0xD006, "VIC_SPR3X"),  (0xD007, "VIC_SPR3Y"),
            (0xD008, "VIC_SPR4X"),  (0xD009, "VIC_SPR4Y"),
            (0xD00A, "VIC_SPR5X"),  (0xD00B, "VIC_SPR5Y"),
            (0xD00C, "VIC_SPR6X"),  (0xD00D, "VIC_SPR6Y"),
            (0xD00E, "VIC_SPR7X"),  (0xD00F, "VIC_SPR7Y"),
            // Control registers
            (0xD010, "VIC_SPRXMSB"),  // MSB of sprite X coords
            (0xD011, "VIC_CR1"),      // vertical scroll, screen height, bitmap, blank, raster bit 8
            (0xD012, "VIC_RASTER"),   // current raster line (write=IRQ trigger line)
            (0xD013, "VIC_LIGHTX"),   // light pen X (latched)
            (0xD014, "VIC_LIGHTY"),   // light pen Y (latched)
            (0xD015, "VIC_SPREN"),    // sprite enable
            (0xD016, "VIC_CR2"),      // horizontal scroll, screen width, multicolor
            (0xD017, "VIC_SPRYE"),    // sprite Y expansion
            (0xD018, "VIC_MEMCTL"),   // VIC memory bank and character/bitmap pointer
            (0xD019, "VIC_IRR"),      // interrupt request register
            (0xD01A, "VIC_IMR"),      // interrupt mask register
            (0xD01B, "VIC_SPRBG"),    // sprite-background priority
            (0xD01C, "VIC_SPRMC"),    // sprite multicolor enable
            (0xD01D, "VIC_SPRXE"),    // sprite X expansion
            (0xD01E, "VIC_SPRSPR"),   // sprite-sprite collision (cleared on read)
            (0xD01F, "VIC_SPRBGCOL"), // sprite-background collision (cleared on read)
            // Color registers
            (0xD020, "VIC_BORDERCOLOR"), (0xD021, "VIC_BGCOLOR0"),
            (0xD022, "VIC_BGCOLOR1"),    (0xD023, "VIC_BGCOLOR2"),
            (0xD024, "VIC_BGCOLOR3"),    // multicolor extra background
            (0xD025, "VIC_SPRMCOL0"),   (0xD026, "VIC_SPRMCOL1"),
            // Sprite individual colors
            (0xD027, "VIC_SPR0COL"), (0xD028, "VIC_SPR1COL"),
            (0xD029, "VIC_SPR2COL"), (0xD02A, "VIC_SPR3COL"),
            (0xD02B, "VIC_SPR4COL"), (0xD02C, "VIC_SPR5COL"),
            (0xD02D, "VIC_SPR6COL"), (0xD02E, "VIC_SPR7COL"),
        ]
        for (addr, name) in vicLabels { labels[addr] = name }

        // SID registers ($D400-$D41C) -- all three voices, filters, read-only regs
        let sidLabels: [(UInt16, String)] = [
            // Voice 1
            (0xD400, "SID_V1FREQ_LO"), (0xD401, "SID_V1FREQ_HI"),
            (0xD402, "SID_V1PW_LO"),   (0xD403, "SID_V1PW_HI"),
            (0xD404, "SID_V1CR"),      // waveform, ring mod, sync, gate
            (0xD405, "SID_V1AD"),      // attack/decay
            (0xD406, "SID_V1SR"),      // sustain/release
            // Voice 2
            (0xD407, "SID_V2FREQ_LO"), (0xD408, "SID_V2FREQ_HI"),
            (0xD409, "SID_V2PW_LO"),   (0xD40A, "SID_V2PW_HI"),
            (0xD40B, "SID_V2CR"),
            (0xD40C, "SID_V2AD"),
            (0xD40D, "SID_V2SR"),
            // Voice 3
            (0xD40E, "SID_V3FREQ_LO"), (0xD40F, "SID_V3FREQ_HI"),
            (0xD410, "SID_V3PW_LO"),   (0xD411, "SID_V3PW_HI"),
            (0xD412, "SID_V3CR"),
            (0xD413, "SID_V3AD"),
            (0xD414, "SID_V3SR"),
            // Filter
            (0xD415, "SID_FILTFREQ_LO"), // filter cutoff low 3 bits
            (0xD416, "SID_FILTFREQ_HI"), // filter cutoff high 8 bits
            (0xD417, "SID_FILTRESON"),   // filter resonance and voice routing
            (0xD418, "SID_MODVOL"),      // filter mode (LP/BP/HP/3OFF) and master volume
            // Read-only: paddles and voice 3 oscillator/envelope
            (0xD419, "SID_POTX"),   // paddle X (ADC)
            (0xD41A, "SID_POTY"),   // paddle Y (ADC)
            (0xD41B, "SID_OSC3"),   // voice 3 oscillator output (read-only)
            (0xD41C, "SID_ENV3"),   // voice 3 envelope output (read-only)
        ]
        for (addr, name) in sidLabels { labels[addr] = name }

        // CIA 1 registers ($DC00-$DC0F)
        let cia1Labels: [(UInt16, String)] = [
            (0xDC00, "CIA1_PRA"),   // port A (keyboard columns, joystick 2)
            (0xDC01, "CIA1_PRB"),   // port B (keyboard rows, joystick 1, light pen)
            (0xDC02, "CIA1_DDRA"),  // data direction A
            (0xDC03, "CIA1_DDRB"),  // data direction B
            (0xDC04, "CIA1_TALO"),  // timer A low byte
            (0xDC05, "CIA1_TAHI"),  // timer A high byte
            (0xDC06, "CIA1_TBLO"),  // timer B low byte
            (0xDC07, "CIA1_TBHI"),  // timer B high byte
            (0xDC08, "CIA1_TODTS"), // TOD tenths of seconds
            (0xDC09, "CIA1_TODSC"), // TOD seconds
            (0xDC0A, "CIA1_TODMN"), // TOD minutes
            (0xDC0B, "CIA1_TODHR"), // TOD hours + AM/PM flag
            (0xDC0C, "CIA1_SDR"),   // serial shift register
            (0xDC0D, "CIA1_ICR"),   // interrupt control register
            (0xDC0E, "CIA1_CRA"),   // control register A
            (0xDC0F, "CIA1_CRB"),   // control register B
        ]
        for (addr, name) in cia1Labels { labels[addr] = name }

        // CIA 2 registers ($DD00-$DD0F)
        let cia2Labels: [(UInt16, String)] = [
            (0xDD00, "CIA2_PRA"),   // port A (VIC bank select bits 0-1, serial bus, user port)
            (0xDD01, "CIA2_PRB"),   // port B (user port)
            (0xDD02, "CIA2_DDRA"),  // data direction A
            (0xDD03, "CIA2_DDRB"),  // data direction B
            (0xDD04, "CIA2_TALO"),  // timer A low byte
            (0xDD05, "CIA2_TAHI"),  // timer A high byte
            (0xDD06, "CIA2_TBLO"),  // timer B low byte
            (0xDD07, "CIA2_TBHI"),  // timer B high byte
            (0xDD08, "CIA2_TODTS"), // TOD tenths of seconds
            (0xDD09, "CIA2_TODSC"), // TOD seconds
            (0xDD0A, "CIA2_TODMN"), // TOD minutes
            (0xDD0B, "CIA2_TODHR"), // TOD hours + AM/PM flag
            (0xDD0C, "CIA2_SDR"),   // serial shift register
            (0xDD0D, "CIA2_ICR"),   // interrupt control register
            (0xDD0E, "CIA2_CRA"),   // control register A
            (0xDD0F, "CIA2_CRB"),   // control register B
        ]
        for (addr, name) in cia2Labels { labels[addr] = name }

        // System addresses (CPU port, screen, color RAM, patchable KERNAL vectors)
        let sysLabels: [(UInt16, String)] = [
            // 6510 CPU I/O port
            (0x0000, "CPU_IODIR"),   // 6510 data direction register
            (0x0001, "CPU_PORT"),    // 6510 data port (bank switching, cassette)
            // Default screen and color RAM locations
            (0x0400, "SCREEN_RAM"),
            (0xD800, "COLOR_RAM"),
            // Patchable KERNAL I/O vectors ($0314-$0333)
            // Replace these to redirect KERNAL I/O to custom routines.
            (0x0314, "CINV"),    // IRQ handler vector    (default: $EA31 IRQ_MAIN)
            (0x0316, "CBINV"),   // BRK handler vector    (default: $FE66)
            (0x0318, "NMINV"),   // NMI handler vector    (default: $FE47)
            (0x031A, "IOPEN"),   // OPEN vector           (default: $F34A OPEN_INT)
            (0x031C, "ICLOSE"),  // CLOSE vector          (default: $F291 CLOSE_INT)
            (0x031E, "ICHKIN"),  // CHKIN vector          (default: $F20E CHKIN_INT)
            (0x0320, "ICKOUT"),  // CHKOUT vector         (default: $F250 CHKOUT_INT)
            (0x0322, "ICLRCH"),  // CLRCHN vector         (default: $F333 CLRCHN_INT)
            (0x0324, "IBASIN"),  // BASIN/CHRIN vector    (default: $F157 CHRIN_INT)
            (0x0326, "IBSOUT"),  // BSOUT/CHROUT vector   (default: $F1CA CHROUT_INT)
            (0x0328, "ISTOP"),   // STOP vector           (default: $F6ED STOP_INT)
            (0x032A, "IGETIN"),  // GETIN vector          (default: $F13E GETIN_INT)
            (0x032C, "ICLALL"),  // CLALL vector          (default: $F32F)
            (0x032E, "USRCMD"), // User function vector   (default: $FE66)
            (0x0330, "ILOAD"),   // LOAD vector           (default: $F49E LOAD_INT)
            (0x0332, "ISAVE"),   // SAVE vector           (default: $F5DD SAVE_INT)
        ]
        for (addr, name) in sysLabels { labels[addr] = name }
    }

    /// Adds a custom label to the disassembler's annotation map.
    func addLabel(_ address: UInt16, name: String) {
        labels[address] = name
    }

    // MARK: - Export

    /// Exports disassembly as ca65-compatible assembly source (non-buildable).
    func exportAsAssembly(lines: [DisassembledLine], startAddress: UInt16) -> String {
        return generateAssembly(lines: lines, startAddress: startAddress, buildable: false)
    }

    /// Generates assembly source, optionally with a full ca65 header that can be
    /// assembled and linked back into the original program.
    ///
    /// Reassembling to the *same bytes* takes more than printing mnemonics, and
    /// each of the following was a way the old output failed to build:
    ///
    /// - Operands name ROM and I/O symbols (`CHROUT`, `VIC_BORDERCOLOR`), so the
    ///   source has to define them. Only the symbols actually referenced are
    ///   emitted, not the whole table.
    /// - Undocumented opcodes need `.setcpu "6502X"`, and three of them are
    ///   spelled differently by ca65 -- handled by `asmSource`.
    /// - No BASIC stub is synthesised. A `.prg` that loads at `$0801` already
    ///   *contains* its stub, and emitting a second one both duplicated the
    ///   bytes and produced a `SYS` that pointed back at the stub itself.
    func generateAssembly(lines: [DisassembledLine], startAddress: UInt16, buildable: Bool) -> String {
        var output: [String] = []
        let usesIllegalOpcodes = lines.contains { $0.isIllegal }

        output.append("; ═══════════════════════════════════════════════════════")
        output.append("; Disassembled by C64 IDE")
        output.append(String(format: "; Load address: $%04X", startAddress))
        if buildable && startAddress != 0x0801 {
            // The bundled c64Prg config defaults %S to $0801; anything else has
            // to be passed through to ld65 or the program links to the wrong place.
            output.append(String(format: "; Link with: ld65 --start-addr $%04X", startAddress))
        }
        output.append("; ═══════════════════════════════════════════════════════")
        output.append("")

        if usesIllegalOpcodes {
            output.append("; This program uses undocumented opcodes.")
            output.append(".setcpu \"6502X\"")
            output.append("")
        }

        // Equates for every ROM/IO symbol the operands mention.
        let equates = symbolEquates()
        if !equates.isEmpty {
            output.append("; ── Symbols referenced below ──────────────────────────")
            output.append(contentsOf: equates)
            output.append("")
        }

        if buildable {
            // The two-byte load address that prefixes a .prg. The bundled linker
            // configs import __LOADADDR__ and place this segment at %S - 2.
            output.append(".export __LOADADDR__: absolute = 1")
            output.append("")
            output.append(".segment \"LOADADDR\"")
            output.append(String(format: "    .word $%04X", startAddress))
            output.append("")
        }

        output.append(".segment \"CODE\"")
        output.append("")

        // Add labels at branch targets
        for line in lines {
            if branchTargets.contains(line.address) {
                output.append(String(format: "L_%04X:", line.address))
            }
            output.append(line.asmSource)
        }
        output.append("")

        return output.joined(separator: "\n")
    }

    /// `NAME = $ADDR` definitions for the symbols referenced by the last
    /// disassembly, sorted by address. `ensureUniqueLabelNames` guarantees the
    /// names are distinct, so this cannot emit a duplicate definition.
    private func symbolEquates() -> [String] {
        referencedLabels.sorted().compactMap { address in
            guard let name = labels[address] else { return nil }
            return "\(name.columnPadded(to: 16))= $\(String(format: "%04X", address))"
        }
    }

    // MARK: - Full 6502 Opcode Table

    /// Comprehensive table of 6502 opcodes, including official and illegal opcodes.
    /// Initialized by filling all entries with a default illegal opcode, then overriding official ones.
    static let opcodeTable: [OpcodeInfo] = {
        let IMP = AddressingMode.implied
        let ACC = AddressingMode.accumulator
        let IMM = AddressingMode.immediate
        let ZP  = AddressingMode.zeroPage
        let ZPX = AddressingMode.zeroPageX
        let ZPY = AddressingMode.zeroPageY
        let ABS = AddressingMode.absolute
        let ABX = AddressingMode.absoluteX
        let ABY = AddressingMode.absoluteY
        let IND = AddressingMode.indirect
        let IZX = AddressingMode.indirectX
        let IZY = AddressingMode.indirectY
        let REL = AddressingMode.relative

        var t = [OpcodeInfo](repeating: OpcodeInfo("???", IMP, 2, illegal: true), count: 256)

        // ── Official opcodes ─────────────────────────────
        // 0x
        t[0x00] = OpcodeInfo("BRK", IMP, 7)
        t[0x01] = OpcodeInfo("ORA", IZX, 6)
        t[0x05] = OpcodeInfo("ORA", ZP,  3)
        t[0x06] = OpcodeInfo("ASL", ZP,  5)
        t[0x08] = OpcodeInfo("PHP", IMP, 3)
        t[0x09] = OpcodeInfo("ORA", IMM, 2)
        t[0x0A] = OpcodeInfo("ASL", ACC, 2)
        t[0x0D] = OpcodeInfo("ORA", ABS, 4)
        t[0x0E] = OpcodeInfo("ASL", ABS, 6)
        // 1x
        t[0x10] = OpcodeInfo("BPL", REL, 2, pageCross: 1)   // +1 taken, +1 page cross
        t[0x11] = OpcodeInfo("ORA", IZY, 5, pageCross: 1)
        t[0x15] = OpcodeInfo("ORA", ZPX, 4)
        t[0x16] = OpcodeInfo("ASL", ZPX, 6)
        t[0x18] = OpcodeInfo("CLC", IMP, 2)
        t[0x19] = OpcodeInfo("ORA", ABY, 4, pageCross: 1)
        t[0x1D] = OpcodeInfo("ORA", ABX, 4, pageCross: 1)
        t[0x1E] = OpcodeInfo("ASL", ABX, 7)
        // 2x
        t[0x20] = OpcodeInfo("JSR", ABS, 6)
        t[0x21] = OpcodeInfo("AND", IZX, 6)
        t[0x24] = OpcodeInfo("BIT", ZP,  3)
        t[0x25] = OpcodeInfo("AND", ZP,  3)
        t[0x26] = OpcodeInfo("ROL", ZP,  5)
        t[0x28] = OpcodeInfo("PLP", IMP, 4)
        t[0x29] = OpcodeInfo("AND", IMM, 2)
        t[0x2A] = OpcodeInfo("ROL", ACC, 2)
        t[0x2C] = OpcodeInfo("BIT", ABS, 4)
        t[0x2D] = OpcodeInfo("AND", ABS, 4)
        t[0x2E] = OpcodeInfo("ROL", ABS, 6)
        // 3x
        t[0x30] = OpcodeInfo("BMI", REL, 2, pageCross: 1)
        t[0x31] = OpcodeInfo("AND", IZY, 5, pageCross: 1)
        t[0x35] = OpcodeInfo("AND", ZPX, 4)
        t[0x36] = OpcodeInfo("ROL", ZPX, 6)
        t[0x38] = OpcodeInfo("SEC", IMP, 2)
        t[0x39] = OpcodeInfo("AND", ABY, 4, pageCross: 1)
        t[0x3D] = OpcodeInfo("AND", ABX, 4, pageCross: 1)
        t[0x3E] = OpcodeInfo("ROL", ABX, 7)
        // 4x
        t[0x40] = OpcodeInfo("RTI", IMP, 6)
        t[0x41] = OpcodeInfo("EOR", IZX, 6)
        t[0x45] = OpcodeInfo("EOR", ZP,  3)
        t[0x46] = OpcodeInfo("LSR", ZP,  5)
        t[0x48] = OpcodeInfo("PHA", IMP, 3)
        t[0x49] = OpcodeInfo("EOR", IMM, 2)
        t[0x4A] = OpcodeInfo("LSR", ACC, 2)
        t[0x4C] = OpcodeInfo("JMP", ABS, 3)
        t[0x4D] = OpcodeInfo("EOR", ABS, 4)
        t[0x4E] = OpcodeInfo("LSR", ABS, 6)
        // 5x
        t[0x50] = OpcodeInfo("BVC", REL, 2, pageCross: 1)
        t[0x51] = OpcodeInfo("EOR", IZY, 5, pageCross: 1)
        t[0x55] = OpcodeInfo("EOR", ZPX, 4)
        t[0x56] = OpcodeInfo("LSR", ZPX, 6)
        t[0x58] = OpcodeInfo("CLI", IMP, 2)
        t[0x59] = OpcodeInfo("EOR", ABY, 4, pageCross: 1)
        t[0x5D] = OpcodeInfo("EOR", ABX, 4, pageCross: 1)
        t[0x5E] = OpcodeInfo("LSR", ABX, 7)
        // 6x
        t[0x60] = OpcodeInfo("RTS", IMP, 6)
        t[0x61] = OpcodeInfo("ADC", IZX, 6)
        t[0x65] = OpcodeInfo("ADC", ZP,  3)
        t[0x66] = OpcodeInfo("ROR", ZP,  5)
        t[0x68] = OpcodeInfo("PLA", IMP, 4)
        t[0x69] = OpcodeInfo("ADC", IMM, 2)
        t[0x6A] = OpcodeInfo("ROR", ACC, 2)
        t[0x6C] = OpcodeInfo("JMP", IND, 5)
        t[0x6D] = OpcodeInfo("ADC", ABS, 4)
        t[0x6E] = OpcodeInfo("ROR", ABS, 6)
        // 7x
        t[0x70] = OpcodeInfo("BVS", REL, 2, pageCross: 1)
        t[0x71] = OpcodeInfo("ADC", IZY, 5, pageCross: 1)
        t[0x75] = OpcodeInfo("ADC", ZPX, 4)
        t[0x76] = OpcodeInfo("ROR", ZPX, 6)
        t[0x78] = OpcodeInfo("SEI", IMP, 2)
        t[0x79] = OpcodeInfo("ADC", ABY, 4, pageCross: 1)
        t[0x7D] = OpcodeInfo("ADC", ABX, 4, pageCross: 1)
        t[0x7E] = OpcodeInfo("ROR", ABX, 7)
        // 8x
        t[0x81] = OpcodeInfo("STA", IZX, 6)
        t[0x84] = OpcodeInfo("STY", ZP,  3)
        t[0x85] = OpcodeInfo("STA", ZP,  3)
        t[0x86] = OpcodeInfo("STX", ZP,  3)
        t[0x88] = OpcodeInfo("DEY", IMP, 2)
        t[0x8A] = OpcodeInfo("TXA", IMP, 2)
        t[0x8C] = OpcodeInfo("STY", ABS, 4)
        t[0x8D] = OpcodeInfo("STA", ABS, 4)
        t[0x8E] = OpcodeInfo("STX", ABS, 4)
        // 9x
        t[0x90] = OpcodeInfo("BCC", REL, 2, pageCross: 1)
        t[0x91] = OpcodeInfo("STA", IZY, 6)
        t[0x94] = OpcodeInfo("STY", ZPX, 4)
        t[0x95] = OpcodeInfo("STA", ZPX, 4)
        t[0x96] = OpcodeInfo("STX", ZPY, 4)
        t[0x98] = OpcodeInfo("TYA", IMP, 2)
        t[0x99] = OpcodeInfo("STA", ABY, 5)
        t[0x9A] = OpcodeInfo("TXS", IMP, 2)
        t[0x9D] = OpcodeInfo("STA", ABX, 5)
        // Ax
        t[0xA0] = OpcodeInfo("LDY", IMM, 2)
        t[0xA1] = OpcodeInfo("LDA", IZX, 6)
        t[0xA2] = OpcodeInfo("LDX", IMM, 2)
        t[0xA4] = OpcodeInfo("LDY", ZP,  3)
        t[0xA5] = OpcodeInfo("LDA", ZP,  3)
        t[0xA6] = OpcodeInfo("LDX", ZP,  3)
        t[0xA8] = OpcodeInfo("TAY", IMP, 2)
        t[0xA9] = OpcodeInfo("LDA", IMM, 2)
        t[0xAA] = OpcodeInfo("TAX", IMP, 2)
        t[0xAC] = OpcodeInfo("LDY", ABS, 4)
        t[0xAD] = OpcodeInfo("LDA", ABS, 4)
        t[0xAE] = OpcodeInfo("LDX", ABS, 4)
        // Bx
        t[0xB0] = OpcodeInfo("BCS", REL, 2, pageCross: 1)
        t[0xB1] = OpcodeInfo("LDA", IZY, 5, pageCross: 1)
        t[0xB4] = OpcodeInfo("LDY", ZPX, 4)
        t[0xB5] = OpcodeInfo("LDA", ZPX, 4)
        t[0xB6] = OpcodeInfo("LDX", ZPY, 4)
        t[0xB8] = OpcodeInfo("CLV", IMP, 2)
        t[0xB9] = OpcodeInfo("LDA", ABY, 4, pageCross: 1)
        t[0xBA] = OpcodeInfo("TSX", IMP, 2)
        t[0xBC] = OpcodeInfo("LDY", ABX, 4, pageCross: 1)
        t[0xBD] = OpcodeInfo("LDA", ABX, 4, pageCross: 1)
        t[0xBE] = OpcodeInfo("LDX", ABY, 4, pageCross: 1)
        // Cx
        t[0xC0] = OpcodeInfo("CPY", IMM, 2)
        t[0xC1] = OpcodeInfo("CMP", IZX, 6)
        t[0xC4] = OpcodeInfo("CPY", ZP,  3)
        t[0xC5] = OpcodeInfo("CMP", ZP,  3)
        t[0xC6] = OpcodeInfo("DEC", ZP,  5)
        t[0xC8] = OpcodeInfo("INY", IMP, 2)
        t[0xC9] = OpcodeInfo("CMP", IMM, 2)
        t[0xCA] = OpcodeInfo("DEX", IMP, 2)
        t[0xCC] = OpcodeInfo("CPY", ABS, 4)
        t[0xCD] = OpcodeInfo("CMP", ABS, 4)
        t[0xCE] = OpcodeInfo("DEC", ABS, 6)
        // Dx
        t[0xD0] = OpcodeInfo("BNE", REL, 2, pageCross: 1)
        t[0xD1] = OpcodeInfo("CMP", IZY, 5, pageCross: 1)
        t[0xD5] = OpcodeInfo("CMP", ZPX, 4)
        t[0xD6] = OpcodeInfo("DEC", ZPX, 6)
        t[0xD8] = OpcodeInfo("CLD", IMP, 2)
        t[0xD9] = OpcodeInfo("CMP", ABY, 4, pageCross: 1)
        t[0xDD] = OpcodeInfo("CMP", ABX, 4, pageCross: 1)
        t[0xDE] = OpcodeInfo("DEC", ABX, 7)
        // Ex
        t[0xE0] = OpcodeInfo("CPX", IMM, 2)
        t[0xE1] = OpcodeInfo("SBC", IZX, 6)
        t[0xE4] = OpcodeInfo("CPX", ZP,  3)
        t[0xE5] = OpcodeInfo("SBC", ZP,  3)
        t[0xE6] = OpcodeInfo("INC", ZP,  5)
        t[0xE8] = OpcodeInfo("INX", IMP, 2)
        t[0xE9] = OpcodeInfo("SBC", IMM, 2)
        t[0xEA] = OpcodeInfo("NOP", IMP, 2)
        t[0xEC] = OpcodeInfo("CPX", ABS, 4)
        t[0xED] = OpcodeInfo("SBC", ABS, 4)
        t[0xEE] = OpcodeInfo("INC", ABS, 6)
        // Fx
        t[0xF0] = OpcodeInfo("BEQ", REL, 2, pageCross: 1)
        t[0xF1] = OpcodeInfo("SBC", IZY, 5, pageCross: 1)
        t[0xF5] = OpcodeInfo("SBC", ZPX, 4)
        t[0xF6] = OpcodeInfo("INC", ZPX, 6)
        t[0xF8] = OpcodeInfo("SED", IMP, 2)
        t[0xF9] = OpcodeInfo("SBC", ABY, 4, pageCross: 1)
        t[0xFD] = OpcodeInfo("SBC", ABX, 4, pageCross: 1)
        t[0xFE] = OpcodeInfo("INC", ABX, 7)

        // ── Illegal / undocumented opcodes (NMOS 6502) ──────────
        // These are used in commercial C64 software and must be decoded
        // correctly to avoid misaligning the disassembly stream.

        // JAM (KIL/HLT): halt processor; requires reset to recover
        // All odd-column $x2 opcodes (except $02 which is the same pattern)
        t[0x02] = OpcodeInfo("JAM", IMP, 2, illegal: true)
        t[0x12] = OpcodeInfo("JAM", IMP, 2, illegal: true)
        t[0x22] = OpcodeInfo("JAM", IMP, 2, illegal: true)
        t[0x32] = OpcodeInfo("JAM", IMP, 2, illegal: true)
        t[0x42] = OpcodeInfo("JAM", IMP, 2, illegal: true)
        t[0x52] = OpcodeInfo("JAM", IMP, 2, illegal: true)
        t[0x62] = OpcodeInfo("JAM", IMP, 2, illegal: true)
        t[0x72] = OpcodeInfo("JAM", IMP, 2, illegal: true)
        t[0x92] = OpcodeInfo("JAM", IMP, 2, illegal: true)
        t[0xB2] = OpcodeInfo("JAM", IMP, 2, illegal: true)
        t[0xD2] = OpcodeInfo("JAM", IMP, 2, illegal: true)
        t[0xF2] = OpcodeInfo("JAM", IMP, 2, illegal: true)

        // NOP variants: consume operand bytes without doing anything
        // Single-byte imm NOPs
        t[0x80] = OpcodeInfo("NOP", IMM, 2, illegal: true)
        t[0x82] = OpcodeInfo("NOP", IMM, 2, illegal: true)
        t[0x89] = OpcodeInfo("NOP", IMM, 2, illegal: true)
        t[0xC2] = OpcodeInfo("NOP", IMM, 2, illegal: true)
        t[0xE2] = OpcodeInfo("NOP", IMM, 2, illegal: true)
        // Zero-page NOPs
        t[0x04] = OpcodeInfo("NOP", ZP,  3, illegal: true)
        t[0x44] = OpcodeInfo("NOP", ZP,  3, illegal: true)
        t[0x64] = OpcodeInfo("NOP", ZP,  3, illegal: true)
        // Zero-page,X NOPs
        t[0x14] = OpcodeInfo("NOP", ZPX, 4, illegal: true)
        t[0x34] = OpcodeInfo("NOP", ZPX, 4, illegal: true)
        t[0x54] = OpcodeInfo("NOP", ZPX, 4, illegal: true)
        t[0x74] = OpcodeInfo("NOP", ZPX, 4, illegal: true)
        t[0xD4] = OpcodeInfo("NOP", ZPX, 4, illegal: true)
        t[0xF4] = OpcodeInfo("NOP", ZPX, 4, illegal: true)
        // Absolute NOP
        t[0x0C] = OpcodeInfo("NOP", ABS, 4, illegal: true)
        // Absolute,X NOPs (page-cross penalty applies)
        t[0x1C] = OpcodeInfo("NOP", ABX, 4, pageCross: 1, illegal: true)
        t[0x3C] = OpcodeInfo("NOP", ABX, 4, pageCross: 1, illegal: true)
        t[0x5C] = OpcodeInfo("NOP", ABX, 4, pageCross: 1, illegal: true)
        t[0x7C] = OpcodeInfo("NOP", ABX, 4, pageCross: 1, illegal: true)
        t[0xDC] = OpcodeInfo("NOP", ABX, 4, pageCross: 1, illegal: true)
        t[0xFC] = OpcodeInfo("NOP", ABX, 4, pageCross: 1, illegal: true)

        // SLO (ASL memory, then ORA result into A)
        t[0x03] = OpcodeInfo("SLO", IZX, 8, illegal: true)
        t[0x07] = OpcodeInfo("SLO", ZP,  5, illegal: true)
        t[0x0F] = OpcodeInfo("SLO", ABS, 6, illegal: true)
        t[0x13] = OpcodeInfo("SLO", IZY, 8, illegal: true)
        t[0x17] = OpcodeInfo("SLO", ZPX, 6, illegal: true)
        t[0x1B] = OpcodeInfo("SLO", ABY, 7, illegal: true)
        t[0x1F] = OpcodeInfo("SLO", ABX, 7, illegal: true)

        // RLA (ROL memory, then AND result into A)
        t[0x23] = OpcodeInfo("RLA", IZX, 8, illegal: true)
        t[0x27] = OpcodeInfo("RLA", ZP,  5, illegal: true)
        t[0x2F] = OpcodeInfo("RLA", ABS, 6, illegal: true)
        t[0x33] = OpcodeInfo("RLA", IZY, 8, illegal: true)
        t[0x37] = OpcodeInfo("RLA", ZPX, 6, illegal: true)
        t[0x3B] = OpcodeInfo("RLA", ABY, 7, illegal: true)
        t[0x3F] = OpcodeInfo("RLA", ABX, 7, illegal: true)

        // SRE (LSR memory, then EOR result into A)
        t[0x43] = OpcodeInfo("SRE", IZX, 8, illegal: true)
        t[0x47] = OpcodeInfo("SRE", ZP,  5, illegal: true)
        t[0x4F] = OpcodeInfo("SRE", ABS, 6, illegal: true)
        t[0x53] = OpcodeInfo("SRE", IZY, 8, illegal: true)
        t[0x57] = OpcodeInfo("SRE", ZPX, 6, illegal: true)
        t[0x5B] = OpcodeInfo("SRE", ABY, 7, illegal: true)
        t[0x5F] = OpcodeInfo("SRE", ABX, 7, illegal: true)

        // RRA (ROR memory, then ADC result into A)
        t[0x63] = OpcodeInfo("RRA", IZX, 8, illegal: true)
        t[0x67] = OpcodeInfo("RRA", ZP,  5, illegal: true)
        t[0x6F] = OpcodeInfo("RRA", ABS, 6, illegal: true)
        t[0x73] = OpcodeInfo("RRA", IZY, 8, illegal: true)
        t[0x77] = OpcodeInfo("RRA", ZPX, 6, illegal: true)
        t[0x7B] = OpcodeInfo("RRA", ABY, 7, illegal: true)
        t[0x7F] = OpcodeInfo("RRA", ABX, 7, illegal: true)

        // SAX (store A AND X into memory -- no flags affected)
        t[0x83] = OpcodeInfo("SAX", IZX, 6, illegal: true)
        t[0x87] = OpcodeInfo("SAX", ZP,  3, illegal: true)
        t[0x8F] = OpcodeInfo("SAX", ABS, 4, illegal: true)
        t[0x97] = OpcodeInfo("SAX", ZPY, 4, illegal: true)

        // LAX (load A and X from same memory byte)
        t[0xA3] = OpcodeInfo("LAX", IZX, 6, illegal: true)
        t[0xA7] = OpcodeInfo("LAX", ZP,  3, illegal: true)
        t[0xAB] = OpcodeInfo("LAX", IMM, 2, illegal: true)  // highly unstable
        t[0xAF] = OpcodeInfo("LAX", ABS, 4, illegal: true)
        t[0xB3] = OpcodeInfo("LAX", IZY, 5, pageCross: 1, illegal: true)
        t[0xB7] = OpcodeInfo("LAX", ZPY, 4, illegal: true)
        t[0xBF] = OpcodeInfo("LAX", ABY, 4, pageCross: 1, illegal: true)

        // DCP (DEC memory, then CMP result with A)
        t[0xC3] = OpcodeInfo("DCP", IZX, 8, illegal: true)
        t[0xC7] = OpcodeInfo("DCP", ZP,  5, illegal: true)
        t[0xCF] = OpcodeInfo("DCP", ABS, 6, illegal: true)
        t[0xD3] = OpcodeInfo("DCP", IZY, 8, illegal: true)
        t[0xD7] = OpcodeInfo("DCP", ZPX, 6, illegal: true)
        t[0xDB] = OpcodeInfo("DCP", ABY, 7, illegal: true)
        t[0xDF] = OpcodeInfo("DCP", ABX, 7, illegal: true)

        // ISB (INC memory, then SBC result from A; also called ISC)
        t[0xE3] = OpcodeInfo("ISB", IZX, 8, illegal: true)
        t[0xE7] = OpcodeInfo("ISB", ZP,  5, illegal: true)
        t[0xEF] = OpcodeInfo("ISB", ABS, 6, illegal: true)
        t[0xF3] = OpcodeInfo("ISB", IZY, 8, illegal: true)
        t[0xF7] = OpcodeInfo("ISB", ZPX, 6, illegal: true)
        t[0xFB] = OpcodeInfo("ISB", ABY, 7, illegal: true)
        t[0xFF] = OpcodeInfo("ISB", ABX, 7, illegal: true)

        // Single-byte combinatoric illegals
        t[0x0B] = OpcodeInfo("ANC", IMM, 2, illegal: true)  // AND imm, copy N to C
        t[0x2B] = OpcodeInfo("ANC", IMM, 2, illegal: true)  // same behaviour as $0B
        t[0x4B] = OpcodeInfo("ALR", IMM, 2, illegal: true)  // AND imm, then LSR A
        t[0x6B] = OpcodeInfo("ARR", IMM, 2, illegal: true)  // AND imm, then ROR A (complex flags)
        t[0x8B] = OpcodeInfo("XAA", IMM, 2, illegal: true)  // A = X AND imm (very chip-dependent)
        t[0xCB] = OpcodeInfo("SBX", IMM, 2, illegal: true)  // X = (A AND X) - imm (also AXS)
        t[0xEB] = OpcodeInfo("SBC", IMM, 2, illegal: true)  // alternate SBC #imm (identical to $E9)

        // Implied single-byte NOPs (1-byte, no operand consumed)
        t[0x1A] = OpcodeInfo("NOP", IMP, 2, illegal: true)
        t[0x3A] = OpcodeInfo("NOP", IMP, 2, illegal: true)
        t[0x5A] = OpcodeInfo("NOP", IMP, 2, illegal: true)
        t[0x7A] = OpcodeInfo("NOP", IMP, 2, illegal: true)
        t[0xDA] = OpcodeInfo("NOP", IMP, 2, illegal: true)
        t[0xFA] = OpcodeInfo("NOP", IMP, 2, illegal: true)

        // Rare/exotic illegals
        t[0x9B] = OpcodeInfo("TAS", ABY, 5, illegal: true)  // SP = A AND X; mem = SP AND (addrHi+1)
        t[0x9C] = OpcodeInfo("SHY", ABX, 5, illegal: true)  // mem = Y AND (addrHi+1)
        t[0x9E] = OpcodeInfo("SHX", ABY, 5, illegal: true)  // mem = X AND (addrHi+1)
        t[0x93] = OpcodeInfo("SHA", IZY, 6, illegal: true)  // mem = A AND X AND (addrHi+1)
        t[0x9F] = OpcodeInfo("SHA", ABY, 5, illegal: true)  // mem = A AND X AND (addrHi+1)
        t[0xBB] = OpcodeInfo("LAS", ABY, 4, pageCross: 1, illegal: true) // A,X,SP = mem AND SP

        return t
    }()
}

// MARK: - Errors

enum DisassemblerError: Error, LocalizedError, Equatable {
    case fileTooSmall
    case invalidPRG
    case tooLarge
    case invalidAddress(String)

    var errorDescription: String? {
        switch self {
        case .fileTooSmall: return "File is too small to disassemble"
        case .invalidPRG:   return "Invalid PRG file format"
        case .tooLarge:     return "File is larger than the 64 KB the 6502 can address"
        case .invalidAddress(let text):
            return "\"\(text)\" is not a valid address. Enter 1 to 4 hexadecimal digits, for example C000."
        }
    }
}

