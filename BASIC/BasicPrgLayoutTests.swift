import XCTest
@testable import C64IDE

// ═══════════════════════════════════════════════════════════
// MARK: - BasicPrgLayoutTests
// ═══════════════════════════════════════════════════════════

/// Covers the scanner that separates a BASIC loader stub from the machine
/// code stored behind it in the same PRG.
final class BasicPrgLayoutTests: XCTestCase {

    // ── Helpers ────────────────────────────────────────────

    /// `10 SYS2061` as the C64 stores it, loading at $0801. The program ends
    /// at $080D, which is exactly where the SYS points.
    private let sys2061Stub: [UInt8] = [
        0x01, 0x08,                     // load address $0801
        0x0B, 0x08,                     // link -> $080B
        0x0A, 0x00,                     // line 10
        0x9E, 0x32, 0x30, 0x36, 0x31,   // SYS2061
        0x00,                           // end of line
        0x00, 0x00,                     // end of program
    ]

    /// Builds a one-line program from a line number and token bytes.
    private func program(load: UInt16 = 0x0801, line: UInt16 = 10, body: [UInt8]) -> [UInt8] {
        let lineStart = Int(load)
        let link = lineStart + 4 + body.count + 1
        return [UInt8(load & 0xFF), UInt8(load >> 8),
                UInt8(link & 0xFF), UInt8(link >> 8),
                UInt8(line & 0xFF), UInt8(line >> 8)]
            + body + [0x00, 0x00, 0x00]
    }

    private func layout(_ bytes: [UInt8]) -> BasicPrgLayout? {
        BasicPrgLayout.analyze(Data(bytes))
    }

    private let code: [UInt8] = [0xA9, 0x00, 0x8D, 0x20, 0xD0, 0xEE, 0x20, 0xD0,
                                 0x4C, 0x12, 0x08, 0xEA, 0xEA, 0xEA, 0xEA, 0xEA,
                                 0xEA, 0xEA, 0xEA, 0x60]

    // ── Detection ──────────────────────────────────────────

    func testPlainBasicProgramHasNothingBehindIt() throws {
        let l = try XCTUnwrap(layout(sys2061Stub))
        XCTAssertEqual(l.lineCount, 1)
        XCTAssertEqual(l.basicEndOffset, sys2061Stub.count)
        XCTAssertEqual(l.trailingByteCount, 0)
        XCTAssertEqual(l.sysAddress, 2061)
        XCTAssertFalse(l.hasMachineCode)
        XCTAssertFalse(l.isBasicWithMachineCode)
    }

    func testSysStubFollowedByCodeIsDetected() throws {
        let prg = sys2061Stub + code
        let l = try XCTUnwrap(layout(prg))
        XCTAssertEqual(l.lineCount, 1)
        XCTAssertEqual(l.trailingAddress, 0x080D)
        XCTAssertEqual(l.trailingByteCount, code.count)
        XCTAssertEqual(l.trailingEndAddress, 0x080D + UInt16(code.count) - 1)
        XCTAssertTrue(l.sysTargetsTrailingBytes)
        XCTAssertTrue(l.isBasicWithMachineCode)
        XCTAssertEqual(l.machineCode(in: Data(prg)), code)
        XCTAssertEqual(Array(l.basicPortion(of: Data(prg))), sys2061Stub)
    }

    func testBasicPortionDetokenizesToTheStubAlone() throws {
        let prg = Data(sys2061Stub + code)
        let l = try XCTUnwrap(layout(Array(prg)))
        XCTAssertEqual(BasicTokenizer.detokenize(l.basicPortion(of: prg)), "10 SYS2061")
    }

    /// A couple of stray bytes after the end marker are padding, not a program.
    func testShortPaddingWithoutSysIntoItIsNotMachineCode() throws {
        // 10 SYS49152 : the SYS goes elsewhere, three bytes follow.
        let prg = program(body: [0x9E, 0x34, 0x39, 0x31, 0x35, 0x32]) + [0x00, 0x00, 0x00]
        let l = try XCTUnwrap(layout(prg))
        XCTAssertEqual(l.sysAddress, 49152)
        XCTAssertFalse(l.sysTargetsTrailingBytes)
        XCTAssertFalse(l.hasMachineCode)
    }

    /// ...unless the SYS points straight at them.
    func testTinyBlockCountsWhenSysPointsIntoIt() throws {
        let prg = sys2061Stub + [0x4C, 0x0D, 0x08]   // JMP $080D
        let l = try XCTUnwrap(layout(prg))
        XCTAssertTrue(l.sysTargetsTrailingBytes)
        XCTAssertTrue(l.isBasicWithMachineCode)
    }

    func testPaddingBeforeTheEntryPointIsIncluded() throws {
        // 10 SYS2064 with the code aligned at $0810: the stub ends at $080D
        // and three padding bytes sit in front of the entry.
        let prg = program(body: [0x9E, 0x32, 0x30, 0x36, 0x34]) + [0x00, 0x00, 0x00] + code
        let l = try XCTUnwrap(layout(prg))
        XCTAssertEqual(l.trailingAddress, 0x080D)
        XCTAssertEqual(l.sysAddress, 0x0810)
        XCTAssertTrue(l.sysTargetsTrailingBytes)
        XCTAssertEqual(l.machineCode(in: Data(prg)).count, code.count + 3)
    }

    func testMultiLineProgramEndsAtMarker() throws {
        // 10 SYS2061 / 20 END, then code.
        let line1: [UInt8] = [0x0B, 0x08, 0x0A, 0x00, 0x9E, 0x32, 0x30, 0x36, 0x31, 0x00]
        let line2: [UInt8] = [0x11, 0x08, 0x14, 0x00, 0x80, 0x00]
        let prg = [0x01, 0x08] + line1 + line2 + [0x00, 0x00] + code
        let l = try XCTUnwrap(layout(prg))
        XCTAssertEqual(l.lineCount, 2)
        XCTAssertEqual(l.trailingAddress, 0x0813)
        XCTAssertEqual(l.sysAddress, 2061)
        // The SYS lands inside line 2, not in the trailing block.
        XCTAssertFalse(l.sysTargetsTrailingBytes)
        XCTAssertTrue(l.isBasicWithMachineCode)
    }

    // ── Broken links ───────────────────────────────────────

    /// A loader whose only line is followed by code with no end marker: the
    /// code's first bytes read as a link that points backwards, which no
    /// BASIC line has, so the program ends there.
    func testBackwardLinkEndsTheProgram() throws {
        let stubNoMarker = Array(sys2061Stub.dropLast(2))        // ends at $080B
        let prg = stubNoMarker + [0x01, 0x08] + code             // "link" -> $0801
        let l = try XCTUnwrap(layout(prg))
        XCTAssertEqual(l.lineCount, 1)
        XCTAssertEqual(l.trailingAddress, 0x080B)
        XCTAssertEqual(l.trailingByteCount, code.count + 2)
    }

    func testLinkOutsideTheFileEndsTheProgram() throws {
        let stubNoMarker = Array(sys2061Stub.dropLast(2))
        let prg = stubNoMarker + [0xFF, 0xFF] + code
        let l = try XCTUnwrap(layout(prg))
        XCTAssertEqual(l.lineCount, 1)
        XCTAssertEqual(l.trailingAddress, 0x080B)
    }

    func testLinkIntoOwnBodyIsNotALine() throws {
        // Link points at the line's own number bytes.
        let prg: [UInt8] = [0x01, 0x08, 0x03, 0x08, 0x0A, 0x00, 0x9E, 0x00] + code
        let l = try XCTUnwrap(layout(prg))
        XCTAssertEqual(l.lineCount, 0)
        XCTAssertFalse(l.isBasicWithMachineCode)
    }

    /// A file cut off inside its only line has no usable line, so it is not
    /// reported as BASIC with code behind it.
    func testTruncatedLineIsNotBasicWithMachineCode() throws {
        let prg = Array(sys2061Stub.dropLast(3))     // no terminator, no marker
        let l = try XCTUnwrap(layout(prg))
        XCTAssertEqual(l.lineCount, 0)
        XCTAssertFalse(l.isBasicWithMachineCode)
    }

    func testTooShortDataIsRejected() {
        XCTAssertNil(layout([0x01, 0x08, 0x00]))
    }

    // ── SYS argument ───────────────────────────────────────

    func testSysWithSpaceAndParenthesesParses() throws {
        let spaced = try XCTUnwrap(layout(program(body: [0x9E, 0x20, 0x32, 0x30, 0x36, 0x31])))
        XCTAssertEqual(spaced.sysAddress, 2061)
        let parens = try XCTUnwrap(layout(program(body: [0x9E, 0x28, 0x34, 0x39, 0x31, 0x35, 0x32, 0x29])))
        XCTAssertEqual(parens.sysAddress, 49152)
    }

    /// `SYS 12*256+13` starts with digits, but 12 is not where it goes.
    func testSysExpressionIsEvaluated() throws {
        let body: [UInt8] = [0x9E, 0x31, 0x32, 0xAC, 0x32, 0x35, 0x36, 0xAA, 0x31, 0x33]
        let l = try XCTUnwrap(layout(program(body: body)))
        XCTAssertEqual(l.sysAddress, 3085)
    }

    /// Llamasoft's loaders say `SYS π*656`; the ROM truncates 2060.88 to 2060.
    func testSysPiExpressionIsEvaluatedLikeTheRom() throws {
        let l = try XCTUnwrap(layout(program(body: [0x9E, 0xFF, 0xAC, 0x36, 0x35, 0x36])))
        XCTAssertEqual(l.sysAddress, 2060)
    }

    func testSysArithmeticFollowsRomPrecedence() throws {
        // SYS 2^11+13 -> 2061
        let power = try XCTUnwrap(layout(program(body: [0x9E, 0x32, 0xAE, 0x31, 0x31, 0xAA, 0x31, 0x33])))
        XCTAssertEqual(power.sysAddress, 2061)
        // SYS 2*(1000+30)+1 -> 2061
        let parens = try XCTUnwrap(layout(program(body: [0x9E, 0x32, 0xAC, 0x28, 0x31, 0x30, 0x30, 0x30,
                                                           0xAA, 0x33, 0x30, 0x29, 0xAA, 0x31])))
        XCTAssertEqual(parens.sysAddress, 2061)
        // SYS 4096-2*1017.5 -> 2061 (fractions truncate)
        let fraction = try XCTUnwrap(layout(program(body: [0x9E, 0x34, 0x30, 0x39, 0x36, 0xAB, 0x32, 0xAC,
                                                             0x31, 0x30, 0x31, 0x37, 0x2E, 0x35])))
        XCTAssertEqual(fraction.sysAddress, 2061)
        // SYS 2061.9 -> 2061
        let decimal = try XCTUnwrap(layout(program(body: [0x9E, 0x32, 0x30, 0x36, 0x31, 0x2E, 0x39])))
        XCTAssertEqual(decimal.sysAddress, 2061)
    }

    /// `SYS2066 KBR` jumps to 2066; the ROM never looks at the rest until
    /// the routine returns.
    func testSysTrailingTextAfterTheNumberIsIgnored() throws {
        let l = try XCTUnwrap(layout(program(body: [0x9E, 0x32, 0x30, 0x36, 0x36, 0x20, 0x4B, 0x42, 0x52, 0x17])))
        XCTAssertEqual(l.sysAddress, 2066)
    }

    func testSysExpressionsNeedingRuntimeValuesAreNil() throws {
        // SYS 2061+A
        XCTAssertNil(try XCTUnwrap(layout(program(body: [0x9E, 0x32, 0x30, 0x36, 0x31, 0xAA, 0x41]))).sysAddress)
        // SYS PEEK(43)
        XCTAssertNil(try XCTUnwrap(layout(program(body: [0x9E, 0xC2, 0x28, 0x34, 0x33, 0x29]))).sysAddress)
        // SYS (2061  -- unbalanced
        XCTAssertNil(try XCTUnwrap(layout(program(body: [0x9E, 0x28, 0x32, 0x30, 0x36, 0x31]))).sysAddress)
        // SYS 2061/0
        XCTAssertNil(try XCTUnwrap(layout(program(body: [0x9E, 0x32, 0x30, 0x36, 0x31, 0xAD, 0x30]))).sysAddress)
        // SYS -2061  -- GETADR rejects a negative value
        XCTAssertNil(try XCTUnwrap(layout(program(body: [0x9E, 0xAB, 0x32, 0x30, 0x36, 0x31]))).sysAddress)
    }

    func testSysNumberFollowedByColonOrCommaParses() throws {
        // SYS2061:REM GO
        let colon = try XCTUnwrap(layout(program(body: [0x9E, 0x32, 0x30, 0x36, 0x31, 0x3A, 0x8F, 0x47, 0x4F])))
        XCTAssertEqual(colon.sysAddress, 2061)
        // SYS 2061,1 (extension-style extra argument)
        let comma = try XCTUnwrap(layout(program(body: [0x9E, 0x20, 0x32, 0x30, 0x36, 0x31, 0x2C, 0x31])))
        XCTAssertEqual(comma.sysAddress, 2061)
    }

    func testSysVariableIsNil() throws {
        let l = try XCTUnwrap(layout(program(body: [0x9E, 0x41])))   // SYS A
        XCTAssertNil(l.sysAddress)
    }

    func testSysByteInsideQuotesOrRemIsIgnored() throws {
        // 10 PRINT "<$9E>2061"
        let quoted = try XCTUnwrap(layout(program(body: [0x99, 0x22, 0x9E, 0x32, 0x30, 0x36, 0x31, 0x22])))
        XCTAssertNil(quoted.sysAddress)
        // 10 REM <$9E>2061
        let rem = try XCTUnwrap(layout(program(body: [0x8F, 0x20, 0x9E, 0x32, 0x30, 0x36, 0x31])))
        XCTAssertNil(rem.sysAddress)
    }

    func testFirstSysWins() throws {
        // 10 SYS2061:SYS49152
        let body: [UInt8] = [0x9E, 0x32, 0x30, 0x36, 0x31, 0x3A, 0x9E, 0x34, 0x39, 0x31, 0x35, 0x32]
        let l = try XCTUnwrap(layout(program(body: body)))
        XCTAssertEqual(l.sysAddress, 2061)
    }

    func testOversizedSysNumberIsNil() throws {
        let l = try XCTUnwrap(layout(program(body: [0x9E, 0x37, 0x30, 0x30, 0x30, 0x30])))  // SYS70000
        XCTAssertNil(l.sysAddress)
    }

    // ── Other load addresses ───────────────────────────────

    func testVic20LoadAddressIsHonoured() throws {
        // 10 SYS4109 at $1001 -> program ends at $100D.
        let prg = program(load: 0x1001, body: [0x9E, 0x34, 0x31, 0x30, 0x39]) + code
        let l = try XCTUnwrap(layout(prg))
        XCTAssertEqual(l.trailingAddress, 0x100D)
        XCTAssertEqual(l.sysAddress, 4109)
        XCTAssertTrue(l.sysTargetsTrailingBytes)
    }

    // ── Summary ────────────────────────────────────────────

    func testSummaryNamesTheRangeAndEntry() throws {
        let l = try XCTUnwrap(layout(sys2061Stub + code))
        XCTAssertEqual(l.summary,
                       "1 BASIC line, then \(code.count) bytes of machine code at $080D-$0820 (SYS 2061 = $080D)")
    }

    // ── Disassembler entry labels ──────────────────────────

    func testDisassemblerLabelsAnEntryPointOnAnInstructionBoundary() {
        let d = Disassembler6502()
        // $080D: NOP NOP / $080F: LDA #$00 / $0811: RTS
        _ = d.disassemble(data: [0xEA, 0xEA, 0xA9, 0x00, 0x60], startAddress: 0x080D,
                          entryPoints: [0x080F])
        XCTAssertTrue(d.branchTargets.contains(0x080F))
    }

    func testDisassemblerIgnoresAnEntryPointInsideAnInstruction() {
        let d = Disassembler6502()
        _ = d.disassemble(data: [0xEA, 0xEA, 0xA9, 0x00, 0x60], startAddress: 0x080D,
                          entryPoints: [0x0810])
        XCTAssertFalse(d.branchTargets.contains(0x0810))
    }

    func testDisassemblerForgetsEntryPointsBetweenRuns() {
        let d = Disassembler6502()
        _ = d.disassemble(data: [0xEA, 0xEA, 0x60], startAddress: 0x080D, entryPoints: [0x080E])
        _ = d.disassemble(data: [0xEA, 0xEA, 0x60], startAddress: 0x080D)
        XCTAssertFalse(d.branchTargets.contains(0x080E))
    }
}
