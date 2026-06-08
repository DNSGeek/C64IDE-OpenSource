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
}

// ═══════════════════════════════════════════════════════════
// MARK: - Disassembled Line
// ═══════════════════════════════════════════════════════════

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

    /// Formats the line for display: "0810  A9 00     LDA #$00    ; comment"
    var formatted: String {
        let addrStr = String(format: "$%04X", address)
        let hexBytes = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        let hexPadded = hexBytes.padding(toLength: 9, withPad: " ", startingAt: 0)

        if isData {
            return "\(addrStr)  \(hexPadded)  \(mnemonic) \(operand)"
        }

        let inst = operand.isEmpty ? mnemonic : "\(mnemonic) \(operand)"
        let instPadded = inst.padding(toLength: 14, withPad: " ", startingAt: 0)

        if let comment = comment {
            return "\(addrStr)  \(hexPadded)  \(instPadded) ; \(comment)"
        }
        return "\(addrStr)  \(hexPadded)  \(inst)"
    }

    /// Formats the line as reassemblable source: "    LDA #$00    ; comment"
    var asmSource: String {
        if isData {
            let values = bytes.map { String(format: "$%02X", $0) }.joined(separator: ", ")
            return "    .byte \(values)"
        }
        let inst = operand.isEmpty ? mnemonic : "\(mnemonic) \(operand)"
        if let comment = comment {
            return "    \(inst.padding(toLength: 16, withPad: " ", startingAt: 0)); \(comment)"
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

    /// Known labels for annotation (address → name)
    private var labels: [UInt16: String] = [:]

    /// Branch/jump targets found during disassembly
    private(set) var branchTargets: Set<UInt16> = []

    init() {
        loadKernalLabels()
        loadIOLabels()
    }

    // MARK: - Load PRG

    /// Loads a `.prg` file and extracts the load address and program data.
    /// - Parameter url: Path to the `.prg` file.
    /// - Returns: Tuple of `(loadAddress, data)`.
    /// - Throws: `DisassemblerError.fileTooSmall` if the file is invalid.
    static func loadPRG(from url: URL) throws -> (address: UInt16, data: [UInt8]) {
        let fileData = try Data(contentsOf: url)
        guard fileData.count >= 3 else {
            throw DisassemblerError.fileTooSmall
        }

        let loadAddr = UInt16(fileData[0]) | (UInt16(fileData[1]) << 8)
        let programData = Array(fileData.dropFirst(2))
        return (loadAddr, programData)
    }

    // MARK: - Disassemble

    /// Disassembles a block of data starting at the given address.
    /// - Parameters:
    ///   - data: Raw machine code bytes.
    ///   - startAddress: Memory address where the data is loaded.
    /// - Returns: Array of `DisassembledLine` objects.
    func disassemble(data: [UInt8], startAddress: UInt16) -> [DisassembledLine] {
        var lines: [DisassembledLine] = []
        var offset = 0
        branchTargets.removeAll()

        // First pass: find branch/jump targets for label generation
        var tempOffset = 0
        while tempOffset < data.count {
            let opcode = data[tempOffset]
            let info = Self.opcodeTable[Int(opcode)]
            let size = info.mode.instructionSize

            if tempOffset + size <= data.count {
                let addr = startAddress &+ UInt16(tempOffset)

                if info.mode == .relative && tempOffset + 2 <= data.count {
                    let rel = Int8(bitPattern: data[tempOffset + 1])
                    let target = UInt16(Int(addr) + 2 + Int(rel))
                    branchTargets.insert(target)
                } else if (info.mnemonic == "JMP" || info.mnemonic == "JSR") && info.mode == .absolute && tempOffset + 3 <= data.count {
                    let target = UInt16(data[tempOffset + 1]) | (UInt16(data[tempOffset + 2]) << 8)
                    branchTargets.insert(target)
                }
            }

            tempOffset += size
            if size == 0 { tempOffset += 1 }  // Safety for unknown opcodes
        }

        // Second pass: disassemble with labels and annotations
        while offset < data.count {
            let currentAddr = startAddress &+ UInt16(offset)
            let opcode = data[offset]
            let info = Self.opcodeTable[Int(opcode)]
            let size = info.mode.instructionSize

            // Check if we have enough bytes for a complete instruction
            guard offset + size <= data.count else {
                // Remaining bytes as data
                let remaining = Array(data[offset...])
                lines.append(DisassembledLine(
                    address: currentAddr, bytes: remaining,
                    mnemonic: ".byte", operand: remaining.map { String(format: "$%02X", $0) }.joined(separator: ", "),
                    comment: "incomplete instruction", isIllegal: false, isData: true,
                    cycles: 0, pageCrossPenalty: 0
                ))
                break
            }

            let instrBytes = Array(data[offset..<offset + size])
            let operand = formatOperand(info.mode, bytes: instrBytes, address: currentAddr)
            let comment = annotateInstruction(info, bytes: instrBytes, address: currentAddr)

            lines.append(DisassembledLine(
                address: currentAddr, bytes: instrBytes,
                mnemonic: info.mnemonic, operand: operand,
                comment: comment, isIllegal: info.illegal, isData: false,
                cycles: info.cycles, pageCrossPenalty: info.pageCrossPenalty
            ))

            offset += size
        }

        return lines
    }

    // MARK: - Operand Formatting

    private func formatOperand(_ mode: AddressingMode, bytes: [UInt8], address: UInt16) -> String {
        switch mode {
        case .implied:
            return ""
        case .accumulator:
            return "A"
        case .immediate:
            return String(format: "#$%02X", bytes[1])
        case .zeroPage:
            return String(format: "$%02X", bytes[1])
        case .zeroPageX:
            return String(format: "$%02X,X", bytes[1])
        case .zeroPageY:
            return String(format: "$%02X,Y", bytes[1])
        case .absolute:
            let addr = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
            if let label = labels[addr] { return label }
            return String(format: "$%04X", addr)
        case .absoluteX:
            let addr = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
            if let label = labels[addr] { return "\(label),X" }
            return String(format: "$%04X,X", addr)
        case .absoluteY:
            let addr = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
            if let label = labels[addr] { return "\(label),Y" }
            return String(format: "$%04X,Y", addr)
        case .indirect:
            let addr = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
            return String(format: "($%04X)", addr)
        case .indirectX:
            return String(format: "($%02X,X)", bytes[1])
        case .indirectY:
            return String(format: "($%02X),Y", bytes[1])
        case .relative:
            let rel = Int8(bitPattern: bytes[1])
            let target = UInt16(Int(address) + 2 + Int(rel))
            if let label = labels[target] { return label }
            return String(format: "$%04X", target)
        }
    }

    // MARK: - Annotations

    private func annotateInstruction(_ info: OpcodeInfo, bytes: [UInt8], address: UInt16) -> String? {
        // Annotate absolute addresses with known labels
        if info.mode == .absolute || info.mode == .absoluteX || info.mode == .absoluteY {
            let targetAddr = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
            if labels[targetAddr] != nil {
                return descriptionForAddress(targetAddr)
            }
        }

        // Annotate immediate values for common patterns
        if info.mode == .immediate {
            let val = bytes[1]
            if info.mnemonic == "LDA" || info.mnemonic == "LDX" || info.mnemonic == "LDY" {
                if val >= 0x20 && val < 0x7F {
                    return "'\(Character(UnicodeScalar(val)))'"
                }
            }
        }

        // Annotate illegal opcodes
        if info.illegal {
            return "ILLEGAL OPCODE"
        }

        return nil
    }

    private func descriptionForAddress(_ address: UInt16) -> String? {
        // ROM symbols — covers BASIC, floating point, KERNAL jump table, and internals
        if let sym = C64ROMSymbols.symbol(at: address) {
            return "\(sym.name) — \(sym.description)"
        }

        // KERNAL routines (in case of any not in ROM symbols)
        for routine in C64Reference.kernalRoutines {
            if routine.address == address {
                return routine.name
            }
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
        // VIC-II registers
        let vicLabels: [(UInt16, String)] = [
            (0xD000, "VIC_SPR0X"), (0xD001, "VIC_SPR0Y"),
            (0xD010, "VIC_SPRXMSB"), (0xD011, "VIC_CR1"),
            (0xD012, "VIC_RASTER"), (0xD015, "VIC_SPREN"),
            (0xD016, "VIC_CR2"), (0xD018, "VIC_MEMCTL"),
            (0xD019, "VIC_IRR"), (0xD01A, "VIC_IMR"),
            (0xD020, "VIC_BORDERCOLOR"), (0xD021, "VIC_BGCOLOR0"),
            (0xD022, "VIC_BGCOLOR1"), (0xD023, "VIC_BGCOLOR2"),
            (0xD024, "VIC_BGCOLOR3"), (0xD025, "VIC_SPRMCOL0"),
            (0xD026, "VIC_SPRMCOL1"), (0xD027, "VIC_SPR0COL"),
        ]
        for (addr, name) in vicLabels { labels[addr] = name }

        // SID registers
        let sidLabels: [(UInt16, String)] = [
            (0xD400, "SID_V1FREQ_LO"), (0xD401, "SID_V1FREQ_HI"),
            (0xD402, "SID_V1PW_LO"), (0xD403, "SID_V1PW_HI"),
            (0xD404, "SID_V1CR"), (0xD405, "SID_V1AD"),
            (0xD406, "SID_V1SR"), (0xD418, "SID_VOLUME"),
        ]
        for (addr, name) in sidLabels { labels[addr] = name }

        // CIA registers
        let ciaLabels: [(UInt16, String)] = [
            (0xDC00, "CIA1_PRA"), (0xDC01, "CIA1_PRB"),
            (0xDC02, "CIA1_DDRA"), (0xDC03, "CIA1_DDRB"),
            (0xDC04, "CIA1_TALO"), (0xDC05, "CIA1_TAHI"),
            (0xDC0D, "CIA1_ICR"), (0xDC0E, "CIA1_CRA"),
            (0xDD00, "CIA2_PRA"), (0xDD01, "CIA2_PRB"),
            (0xDD0D, "CIA2_ICR"), (0xDD0E, "CIA2_CRA"),
        ]
        for (addr, name) in ciaLabels { labels[addr] = name }

        // Common zero page / system addresses
        let zpLabels: [(UInt16, String)] = [
            (0x0001, "CPU_PORT"), (0x0314, "IRQ_VECTOR"),
            (0x0316, "BRK_VECTOR"), (0x0318, "NMI_VECTOR"),
            (0x0400, "SCREEN_RAM"), (0xD800, "COLOR_RAM"),
        ]
        for (addr, name) in zpLabels { labels[addr] = name }
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

    /// Generates assembly source, optionally with a full ca65 header that can be assembled and run.
    func generateAssembly(lines: [DisassembledLine], startAddress: UInt16, buildable: Bool) -> String {
        var output: [String] = []

        if buildable {
            output.append("; ═══════════════════════════════════════════════════════")
            output.append("; Disassembled by C64 IDE")
            output.append(String(format: "; Original load address: $%04X", startAddress))
            output.append("; ═══════════════════════════════════════════════════════")
            output.append("")
            output.append(".export __LOADADDR__: absolute = 1")
            output.append("")
            output.append(".segment \"LOADADDR\"")
            output.append(String(format: "    .word $%04X", startAddress))
            output.append("")

            // If loading at $0801, add a BASIC stub
            if startAddress == 0x0801 || startAddress == 0x0800 {
                output.append(".segment \"STARTUP\"")
                output.append("    ; BASIC stub: 10 SYS <entry>")
                output.append("    .word @stub_end")
                output.append("    .word 10")
                output.append("    .byte $9E             ; SYS")
                let entryAddr = lines.first(where: { !$0.isData })?.address ?? startAddress
                output.append("    .byte \"\(entryAddr)\"")
                output.append("    .byte 0")
                output.append("@stub_end:")
                output.append("    .word 0")
                output.append("")
            }

            output.append(".segment \"CODE\"")
            output.append("")
        } else {
            output.append("; Disassembled by C64 IDE")
            output.append(String(format: "; Load address: $%04X", startAddress))
            output.append("")
            output.append(".segment \"CODE\"")
            output.append("")
        }

        // Add labels at branch targets
        for line in lines {
            if branchTargets.contains(line.address) {
                output.append(String(format: "L_%04X:", line.address))
            }
            output.append(line.asmSource)
        }

        return output.joined(separator: "\n")
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

        return t
    }()
}

// MARK: - Errors

enum DisassemblerError: Error, LocalizedError {
    case fileTooSmall
    case invalidPRG

    var errorDescription: String? {
        switch self {
        case .fileTooSmall: return "File too small to be a valid PRG"
        case .invalidPRG: return "Invalid PRG file format"
        }
    }
}

