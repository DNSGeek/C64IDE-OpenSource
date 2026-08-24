import XCTest
@testable import C64IDE

// ═══════════════════════════════════════════════════════════
// MARK: - DisassemblerTests
// ═══════════════════════════════════════════════════════════

/// Covers the parts of the disassembler that operate on hostile input.
///
/// The disassembler decodes *every* byte it is handed as an opcode, so a block
/// of graphics or text produces branches to wherever the data happens to point.
/// Several of the tests below are regressions for arithmetic that trapped when
/// such a branch ran off either end of the address space -- a crash, not a bad
/// listing, and reachable from any file the Load PRG panel would open.
final class DisassemblerTests: XCTestCase {

    // ── Helpers ────────────────────────────────────────────

    private func lines(_ bytes: [UInt8], at address: UInt16 = 0x0801) -> [DisassembledLine] {
        Disassembler6502().disassemble(data: bytes, startAddress: address)
    }

    private func writeTempFile(_ bytes: [UInt8], ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("disasm-test-\(UUID().uuidString).\(ext)")
        try Data(bytes).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // ── Branch target arithmetic ───────────────────────────

    /// A backward branch decoded near $0000 used to compute a negative address
    /// and trap converting it to UInt16. The 6502 wraps, so the disassembler
    /// must too.
    func testBackwardBranchNearZeroWraps() {
        // $0004: BNE -128  ->  $0004 + 2 - 128 = -122 -> $FF86
        XCTAssertEqual(Disassembler6502.branchTarget(from: 0x0004, offset: 0x80), 0xFF86)
    }

    /// The mirror case: a forward branch near $FFFF used to exceed UInt16.
    func testForwardBranchNearTopOfMemoryWraps() {
        // $FFFE: BNE +100  ->  $FFFE + 2 + 100 = $10064 -> $0064
        XCTAssertEqual(Disassembler6502.branchTarget(from: 0xFFFE, offset: 0x64), 0x0064)
    }

    func testBranchTargetMatchesHardwareForOrdinaryCase() {
        // $0810: BNE +$10 -> $0822
        XCTAssertEqual(Disassembler6502.branchTarget(from: 0x0810, offset: 0x10), 0x0822)
        // A -2 offset is the classic "branch to self".
        XCTAssertEqual(Disassembler6502.branchTarget(from: 0x0810, offset: 0xFE), 0x0810)
    }

    /// Disassembling data that decodes as an out-of-range branch must produce a
    /// listing rather than bringing the app down.
    func testDisassemblingWrappingBranchesDoesNotTrap() {
        // BNE -128 at the very start of a block loaded at $0000.
        let low = lines([0xD0, 0x80, 0xEA], at: 0x0000)
        XCTAssertEqual(low.first?.mnemonic, "BNE")

        // BEQ +127 at the very end of the address space.
        let high = lines([0xEA, 0xF0, 0x7F], at: 0xFFFD)
        XCTAssertEqual(high.count, 2)
    }

    // ── Address space limits ───────────────────────────────

    /// A full 64 KB block exercises the offset-to-address conversion at the
    /// point where it no longer fits in a UInt16.
    func testFullAddressSpaceDisassembles() {
        let data = [UInt8](repeating: 0xEA, count: 0x10000)   // 65536 x NOP
        let result = lines(data, at: 0x0000)
        XCTAssertEqual(result.count, 0x10000)
        XCTAssertEqual(result.first?.address, 0x0000)
        XCTAssertEqual(result.last?.address, 0xFFFF)
    }

    func testPayloadLargerThanAddressSpaceIsRejected() throws {
        let url = try writeTempFile([0x01, 0x08] + [UInt8](repeating: 0xEA, count: 0x10001),
                                    ext: "bin")
        XCTAssertThrowsError(try Disassembler6502.load(from: url)) { error in
            XCTAssertEqual(error as? DisassemblerError, .tooLarge)
        }
    }

    // ── Container formats ──────────────────────────────────

    func testPRGLoadAddressIsLittleEndian() throws {
        let url = try writeTempFile([0x01, 0x08, 0xA9, 0x00], ext: "prg")
        let file = try Disassembler6502.load(from: url)
        XCTAssertEqual(file.format, .prg)
        XCTAssertEqual(file.loadAddress, 0x0801)
        XCTAssertEqual(file.data, [0xA9, 0x00])
    }

    /// A .p00 buries the load address behind a 26-byte `C64File` header. Read as
    /// a plain .prg it yielded load address $3643 -- the ASCII "C6" -- and 24
    /// bytes of header disassembled as instructions.
    func testP00HeaderIsStripped() throws {
        var bytes = Array("C64File".utf8) + [0x00]
        bytes += [UInt8](repeating: 0x00, count: 26 - bytes.count)  // name + record + reserved
        bytes += [0x01, 0x08, 0xA9, 0x00]
        let url = try writeTempFile(bytes, ext: "p00")

        let file = try Disassembler6502.load(from: url)
        XCTAssertEqual(file.format, .p00)
        XCTAssertEqual(file.loadAddress, 0x0801)
        XCTAssertEqual(file.data, [0xA9, 0x00])
    }

    func testTooShortFileIsRejected() throws {
        let url = try writeTempFile([0x01, 0x08], ext: "prg")
        XCTAssertThrowsError(try Disassembler6502.load(from: url)) { error in
            XCTAssertEqual(error as? DisassemblerError, .fileTooSmall)
        }
    }

    // ── Raw binaries ───────────────────────────────────────

    /// A .bin is a raw dump. Consuming its first two bytes as a load address
    /// both lost them from the dump and based the listing wherever they
    /// happened to point, so the payload must come back whole and unaddressed.
    func testRawBinaryKeepsEveryByteAndDeclaresNoAddress() throws {
        let url = try writeTempFile([0xA9, 0x00, 0x8D, 0x20, 0xD0, 0x60], ext: "bin")
        let file = try Disassembler6502.load(from: url)

        XCTAssertEqual(file.format, .raw)
        XCTAssertNil(file.loadAddress)
        XCTAssertEqual(file.data, [0xA9, 0x00, 0x8D, 0x20, 0xD0, 0x60])
    }

    /// The extension decides, not the content: bytes that look like a plausible
    /// load address must not tempt a .bin into being read as a .prg.
    func testRawBinaryIsNotSniffedAsPRG() throws {
        let url = try writeTempFile([0x01, 0x08, 0xEA], ext: "bin")
        XCTAssertNil(try Disassembler6502.load(from: url).loadAddress)

        let prg = try writeTempFile([0x01, 0x08, 0xEA], ext: "prg")
        XCTAssertEqual(try Disassembler6502.load(from: prg).loadAddress, 0x0801)
    }

    /// A .p00 is recognised by its magic even when it is named .bin, because the
    /// header is unambiguous where a bare extension is not.
    func testP00MagicWinsOverBinExtension() throws {
        var bytes = Array("C64File".utf8) + [0x00]
        bytes += [UInt8](repeating: 0x00, count: 26 - bytes.count)
        bytes += [0x00, 0xC0, 0x60]
        let url = try writeTempFile(bytes, ext: "bin")

        let file = try Disassembler6502.load(from: url)
        XCTAssertEqual(file.format, .p00)
        XCTAssertEqual(file.loadAddress, 0xC000)
    }

    func testEmptyRawBinaryIsRejected() throws {
        let url = try writeTempFile([], ext: "bin")
        XCTAssertThrowsError(try Disassembler6502.load(from: url)) { error in
            XCTAssertEqual(error as? DisassemblerError, .fileTooSmall)
        }
    }

    /// The escape hatch for a .bin that really is a .prg.
    func testRawBinaryCanBeReinterpretedAsCarryingAHeader() throws {
        let url = try writeTempFile([0x00, 0xC0, 0xA9, 0x00], ext: "bin")
        let file = try Disassembler6502.load(from: url)

        let (address, payload) = try Disassembler6502.splitLoadAddress(from: file.data)
        XCTAssertEqual(address, 0xC000)
        XCTAssertEqual(payload, [0xA9, 0x00])
    }

    /// Basing the same bytes elsewhere has to move every address and branch
    /// target with them -- that is the whole point of asking.
    func testRebasingMovesAddressesAndBranchTargets() {
        let code: [UInt8] = [0xE8, 0xD0, 0xFD, 0x60]   // INX / BNE -3 / RTS

        let low = lines(code, at: 0x1000)
        XCTAssertEqual(low[0].address, 0x1000)
        XCTAssertEqual(low[1].operand, "L_1000")

        let high = lines(code, at: 0xC000)
        XCTAssertEqual(high[0].address, 0xC000)
        XCTAssertEqual(high[1].operand, "L_C000")
    }

    // ── Address parsing ────────────────────────────────────

    func testAddressParserAcceptsTheFormsUsersType() {
        let parse = DisassemblerViewController.parseHexAddress
        XCTAssertEqual(parse("C000"), 0xC000)
        XCTAssertEqual(parse("$C000"), 0xC000)
        XCTAssertEqual(parse("0xC000"), 0xC000)
        XCTAssertEqual(parse("  c000 "), 0xC000)
        XCTAssertEqual(parse("801"), 0x0801)
        XCTAssertEqual(parse("0"), 0)
        XCTAssertEqual(parse("FFFF"), 0xFFFF)
    }

    func testAddressParserRejectsWhatItCannotRepresent() {
        let parse = DisassemblerViewController.parseHexAddress
        XCTAssertNil(parse(""))
        XCTAssertNil(parse("$"))
        XCTAssertNil(parse("10000"))    // past $FFFF
        XCTAssertNil(parse("C0G0"))
        XCTAssertNil(parse("hello"))
        XCTAssertNil(parse("-1"))
    }

    // ── Cycle counting ─────────────────────────────────────

    /// A taken branch costs +1 and a taken branch onto another page +1 again,
    /// so BNE runs 2, 3 or 4 cycles. The worst case used to be reported as 3.
    func testBranchWorstCaseIncludesBothPenalties() {
        let bne = Disassembler6502.opcodeTable[0xD0]
        XCTAssertEqual(bne.cycles, 2)
        XCTAssertEqual(bne.maxCycles, 4)

        XCTAssertEqual(lines([0xD0, 0x10]).first?.maxCycles, 4)
    }

    /// Non-branch modes charge their penalty at most once.
    func testPageCrossPenaltyAppliesOnceForNonBranches() {
        let ldaAbsX = Disassembler6502.opcodeTable[0xBD]
        XCTAssertEqual(ldaAbsX.cycles, 4)
        XCTAssertEqual(ldaAbsX.maxCycles, 5)
    }

    func testDataLinesCostNoCycles() {
        // A lone $AD (LDA abs) with no operand bytes becomes a .byte line.
        let result = lines([0xAD])
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].isData)
        XCTAssertEqual(result[0].maxCycles, 0)
    }

    // ── Formatting ─────────────────────────────────────────

    /// `String.padding(toLength:)` truncates, which silently cut operands short
    /// as soon as a symbol name made an instruction longer than its column:
    /// `LDA VIC_BORDERCOLOR,X` came out as `LDA VIC_BORDER`.
    func testColumnPaddingNeverTruncates() {
        XCTAssertEqual("AB".columnPadded(to: 5), "AB   ")
        XCTAssertEqual("LDA VIC_BORDERCOLOR,X".columnPadded(to: 14), "LDA VIC_BORDERCOLOR,X")
    }

    func testLongSymbolicOperandSurvivesFormatting() {
        // BD 20 D0 = LDA $D020,X
        let line = lines([0xBD, 0x20, 0xD0])[0]
        XCTAssertEqual(line.operand, "VIC_BORDERCOLOR,X")
        XCTAssertTrue(line.formatted.contains("VIC_BORDERCOLOR,X"),
                      "operand was truncated: \(line.formatted)")
    }

    // ── Symbol resolution ──────────────────────────────────

    func testKnownRoutinesAndRegistersResolveToNames() {
        // 20 D2 FF = JSR $FFD2
        XCTAssertEqual(lines([0x20, 0xD2, 0xFF])[0].operand, "CHROUT")
        // 8D 20 D0 = STA $D020
        XCTAssertEqual(lines([0x8D, 0x20, 0xD0])[0].operand, "VIC_BORDERCOLOR")
    }

    /// Zero-page and indirect operands were never checked against the symbol
    /// table, so `JMP ($0314)` printed raw despite CINV being a known vector.
    func testZeroPageAndIndirectOperandsResolve() {
        // A5 01 = LDA $01
        XCTAssertEqual(lines([0xA5, 0x01])[0].operand, "CPU_PORT")
        // 6C 14 03 = JMP ($0314)
        XCTAssertEqual(lines([0x6C, 0x14, 0x03])[0].operand, "(CINV)")
    }

    /// A branch to an address that starts an instruction gets a generated
    /// label; the label and the operand have to agree.
    func testBranchToInstructionBoundaryUsesGeneratedLabel() {
        // $0801 BNE +1 -> $0804, $0803 NOP, $0804 NOP
        let result = lines([0xD0, 0x01, 0xEA, 0xEA])
        XCTAssertEqual(result[0].operand, "L_0804")
        XCTAssertTrue(result.contains { $0.address == 0x0804 })
    }

    /// A target outside the block has no line to label, so it must stay numeric
    /// rather than referencing a label the source never defines.
    func testBranchOutsideBlockStaysNumeric() {
        let result = lines([0xD0, 0x7F, 0xEA])
        XCTAssertEqual(result[0].operand, "$0882")
    }

    /// Every label name must be unique, or an operand could resolve to the
    /// wrong address once equates are emitted.
    func testLabelNamesAreUnique() {
        let disassembler = Disassembler6502()
        var names: Set<String> = []
        for address in 0...UInt16.max {
            // Drive the public surface: any address that formats to a symbol
            // does so through the same table the equates come from.
            let line = disassembler.disassemble(
                data: [0xAD, UInt8(address & 0xFF), UInt8(address >> 8)],
                startAddress: 0x0801)[0]
            let operand = line.operand
            guard !operand.hasPrefix("$") else { continue }
            XCTAssertTrue(names.insert(operand).inserted,
                          "duplicate label name \(operand)")
        }
    }

    // ── Annotations ────────────────────────────────────────

    /// An undocumented opcode with a recognised target used to lose its
    /// "illegal" note, because the annotator returned on the first match.
    func testIllegalOpcodeWithKnownAddressKeepsBothNotes() {
        // 0F 20 D0 = SLO $D020 (undocumented, absolute)
        let line = lines([0x0F, 0x20, 0xD0])[0]
        XCTAssertTrue(line.isIllegal)
        XCTAssertTrue(line.comment?.contains("ILLEGAL OPCODE") ?? false,
                      "lost the illegal note: \(line.comment ?? "nil")")
    }

    func testIllegalOpcodeIsMarkedInExportedSource() {
        let line = lines([0x0F, 0x20, 0xD0])[0]
        XCTAssertTrue(line.asmSource.contains("undocumented"), line.asmSource)
    }

    // ── ca65 export ────────────────────────────────────────

    /// ca65 sizes an operand from its value, so an absolute instruction reading
    /// below $0100 has to be forced wide or `LDA $0010` ($AD) assembles back as
    /// the two-byte zero-page `LDA $10` ($A5) and every later address shifts.
    func testAbsoluteOperandBelowPageOneGetsSizeOverride() {
        // AD 10 00 = LDA $0010
        let line = lines([0xAD, 0x10, 0x00])[0]
        XCTAssertEqual(line.operand, "$0010", "display form should stay clean")
        XCTAssertEqual(line.asmOperand, "a:$0010")
        XCTAssertTrue(line.asmSource.contains("a:$0010"), line.asmSource)
    }

    func testZeroPageOperandGetsNoSizeOverride() {
        // A5 10 = LDA $10
        XCTAssertEqual(lines([0xA5, 0x10])[0].asmOperand, "$10")
    }

    /// ca65 spells three undocumented mnemonics differently. Verified against
    /// ca65 by assembling each and checking the emitted opcode byte.
    func testUndocumentedMnemonicsUseCa65Spelling() {
        XCTAssertEqual(lines([0xE7, 0x10])[0].mnemonic, "ISB")
        XCTAssertEqual(lines([0xE7, 0x10])[0].ca65Mnemonic, "ISC")
        XCTAssertEqual(lines([0x8B, 0x10])[0].ca65Mnemonic, "ANE")
        XCTAssertEqual(lines([0xCB, 0x10])[0].ca65Mnemonic, "AXS")
    }

    func testExportDefinesEverySymbolItReferences() {
        let disassembler = Disassembler6502()
        // JSR CHROUT / STA VIC_BORDERCOLOR / RTS
        let code: [UInt8] = [0x20, 0xD2, 0xFF, 0x8D, 0x20, 0xD0, 0x60]
        let result = disassembler.disassemble(data: code, startAddress: 0x0801)
        let source = disassembler.generateAssembly(lines: result, startAddress: 0x0801,
                                                   buildable: true)

        XCTAssertTrue(source.contains("CHROUT"))
        XCTAssertTrue(source.contains("= $FFD2"), source)
        XCTAssertTrue(source.contains("VIC_BORDERCOLOR"))
        XCTAssertTrue(source.contains("= $D020"), source)
    }

    func testExportSelectsExtendedInstructionSetOnlyWhenNeeded() {
        let disassembler = Disassembler6502()

        let clean = disassembler.disassemble(data: [0xEA, 0x60], startAddress: 0x0801)
        XCTAssertFalse(disassembler.generateAssembly(lines: clean, startAddress: 0x0801,
                                                     buildable: true).contains(".setcpu"))

        let illegal = disassembler.disassemble(data: [0x0F, 0x20, 0xD0], startAddress: 0x0801)
        XCTAssertTrue(disassembler.generateAssembly(lines: illegal, startAddress: 0x0801,
                                                    buildable: true).contains(".setcpu \"6502X\""))
    }

    /// A .prg that loads at $0801 already contains its own BASIC stub. The
    /// exporter used to synthesise a second one, duplicating the bytes and
    /// emitting a SYS that pointed back at the stub itself.
    func testExportDoesNotSynthesiseADuplicateBasicStub() {
        let disassembler = Disassembler6502()
        // A real "10 SYS 2062" stub followed by RTS.
        let stub: [UInt8] = [0x0C, 0x08, 0x0A, 0x00, 0x9E, 0x32, 0x30, 0x36, 0x32,
                             0x00, 0x00, 0x00, 0x60]
        let result = disassembler.disassemble(data: stub, startAddress: 0x0801)
        let source = disassembler.generateAssembly(lines: result, startAddress: 0x0801,
                                                   buildable: true)

        XCTAssertFalse(source.contains("STARTUP"), source)
        XCTAssertFalse(source.contains("stub_end"), source)
        XCTAssertEqual(source.components(separatedBy: "$9E").count - 1, 0,
                       "no synthesised SYS token expected")
    }

    /// Generated labels must be defined wherever they are referenced.
    func testEveryReferencedGeneratedLabelIsDefined() {
        let disassembler = Disassembler6502()
        let code: [UInt8] = [0xA2, 0x00, 0xE8, 0xD0, 0xFD, 0x60]  // LDX #0 / INX / BNE -3 / RTS
        let result = disassembler.disassemble(data: code, startAddress: 0x0801)
        let source = disassembler.generateAssembly(lines: result, startAddress: 0x0801,
                                                   buildable: true)

        let referenced = Set(matches(of: #"(?<![:\w])L_[0-9A-F]{4}"#, in: source))
        let defined = Set(matches(of: #"L_[0-9A-F]{4}(?=:)"#, in: source))
        XCTAssertFalse(referenced.isEmpty, "expected a generated label\n\(source)")
        XCTAssertTrue(referenced.subtracting(defined).isEmpty,
                      "undefined labels \(referenced.subtracting(defined))\n\(source)")
    }

    // ── Layout ─────────────────────────────────────────────

    /// The load-address control shares its row with the cycle readout, and both
    /// rows are laid out with hand-computed frames. Overlapping controls are
    /// invisible in code review and obvious only on screen, so assert the
    /// arithmetic instead of eyeballing it.
    @MainActor
    func testToolbarControlsDoNotOverlap() {
        let controller = DisassemblerViewController()
        _ = controller.view          // forces loadView + viewDidLoad + buildUI
        let bounds = controller.view.bounds

        let controls = controller.view.subviews.filter {
            $0 is NSControl && !($0 is NSScrollView)
        }
        XCTAssertGreaterThanOrEqual(controls.count, 6, "expected the toolbar controls")

        for control in controls {
            XCTAssertTrue(bounds.contains(control.frame),
                          "\(control.className) at \(control.frame) escapes \(bounds)")
        }

        // Group by row (controls on a row share a baseline within a few points).
        for a in controls {
            for b in controls where b !== a {
                guard abs(a.frame.midY - b.frame.midY) < 8 else { continue }
                XCTAssertFalse(a.frame.intersects(b.frame),
                               "\(a.className) \(a.frame) overlaps \(b.className) \(b.frame)")
            }
        }
    }

    private func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }
}
