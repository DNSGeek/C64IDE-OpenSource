import XCTest
@testable import C64IDE

// ═══════════════════════════════════════════════════════════
// MARK: - ROMSymbolReferenceTests
// ═══════════════════════════════════════════════════════════

/// Guards the ROM tab of the reference panel.
///
/// Every address in `C64ROMSymbols` was checked against the original
/// Commodore ROM sources, which assemble byte-for-byte to BASIC 901226-01
/// and KERNAL 901227-03. Several of the entries had been wrong in ways that
/// are easy to reintroduce, because the mistaken values are the ones printed
/// in a lot of secondary sources:
///
///  * MEMTOP and MEMBOT were swapped, in both the jump table and the
///    internal routines behind it.
///  * Thirteen BASIC command handlers carried the value stored in the
///    dispatch table at $A00C, which is the entry point MINUS ONE because
///    the interpreter dispatches with RTS.
///  * ROUND/SIGN/FCOMP and the FMULT/MOVMF entry points were shifted onto
///    each other's addresses.
///
/// These tests pin the corrected values.
final class ROMSymbolReferenceTests: XCTestCase {

    private func symbol(_ name: String) -> C64ROMSymbols.Symbol? {
        C64ROMSymbols.allSymbols.first { $0.name == name }
    }

    // ── Structural invariants ──────────────────────────────

    func testNoDuplicateAddresses() {
        var seen: [UInt16: String] = [:]
        for sym in C64ROMSymbols.allSymbols {
            if let other = seen[sym.address] {
                XCTFail(String(format: "$%04X is claimed by both %@ and %@",
                               sym.address, other, sym.name))
            }
            seen[sym.address] = sym.name
        }
    }

    func testNoDuplicateNames() {
        var seen = Set<String>()
        for sym in C64ROMSymbols.allSymbols {
            XCTAssertTrue(seen.insert(sym.name).inserted,
                          "\(sym.name) is used for more than one address")
        }
    }

    func testEverySymbolLivesInROM() {
        for sym in C64ROMSymbols.allSymbols {
            let inBasic  = (0xA000...0xBFFF).contains(sym.address)
            let inKernal = (0xE000...0xFFFF).contains(sym.address)
            XCTAssertTrue(inBasic || inKernal,
                          String(format: "%@ at $%04X is outside both ROMs", sym.name, sym.address))
        }
    }

    func testLookupsAgree() {
        for sym in C64ROMSymbols.allSymbols {
            XCTAssertEqual(C64ROMSymbols.symbol(at: sym.address)?.name, sym.name)
            XCTAssertEqual(C64ROMSymbols.containingRoutine(for: sym.address)?.name, sym.name)
        }
    }

    func testBankingRequirementMatchesTheAddressRange() {
        for sym in C64ROMSymbols.allSymbols {
            XCTAssertNotNil(sym.bankingRequirement,
                            "\(sym.name) should name the ROM it needs banked in")
        }
        XCTAssertTrue(symbol("CHROUT")!.bankingRequirement!.contains("KERNAL"))
        XCTAssertTrue(symbol("FRMEVL")!.bankingRequirement!.contains("BASIC"))
    }

    // ── The KERNAL jump table ──────────────────────────────

    /// $FF81-$FFF3, three bytes per entry, in the order Commodore published.
    private static let jumpTable: [(UInt16, String)] = [
        (0xFF81, "SCINIT"), (0xFF84, "IOINIT"), (0xFF87, "RAMTAS"), (0xFF8A, "RESTOR"),
        (0xFF8D, "VECTOR"), (0xFF90, "SETMSG"), (0xFF93, "LSTNSA"), (0xFF96, "TALKSA"),
        (0xFF99, "MEMTOP"), (0xFF9C, "MEMBOT"), (0xFF9F, "SCNKEY"), (0xFFA2, "SETTMO"),
        (0xFFA5, "IECIN"),  (0xFFA8, "IECOUT"), (0xFFAB, "UNTALK"), (0xFFAE, "UNLSTN"),
        (0xFFB1, "LISTEN"), (0xFFB4, "TALK"),   (0xFFB7, "READST"), (0xFFBA, "SETLFS"),
        (0xFFBD, "SETNAM"), (0xFFC0, "OPEN"),   (0xFFC3, "CLOSE"),  (0xFFC6, "CHKIN"),
        (0xFFC9, "CHKOUT"), (0xFFCC, "CLRCHN"), (0xFFCF, "CHRIN"),  (0xFFD2, "CHROUT"),
        (0xFFD5, "LOAD"),   (0xFFD8, "SAVE"),   (0xFFDB, "SETTIM"), (0xFFDE, "RDTIM"),
        (0xFFE1, "STOP"),   (0xFFE4, "GETIN"),  (0xFFE7, "CLALL"),  (0xFFEA, "UDTIM"),
        (0xFFED, "SCREEN"), (0xFFF0, "PLOT"),   (0xFFF3, "IOBASE"),
    ]

    func testJumpTableIsCompleteAndInOrder() {
        for (address, name) in Self.jumpTable {
            let sym = C64ROMSymbols.symbol(at: address)
            XCTAssertEqual(sym?.name, name,
                           String(format: "$%04X should be %@", address, name))
            XCTAssertEqual(sym?.category, .kernalJumpTable,
                           "\(name) belongs in the KERNAL Jump Table category")
        }
    }

    /// The same 39 entries appear in `C64Reference.kernalRoutines`, which the
    /// panel merges in for the input/output detail. The two must not disagree.
    func testKernalRoutineTableAgreesWithTheSymbolTable() {
        for (address, name) in Self.jumpTable {
            let routine = C64Reference.kernalRoutines.first { $0.address == address }
            XCTAssertEqual(routine?.name, name,
                           String(format: "C64Reference disagrees about $%04X", address))
        }
        XCTAssertEqual(C64Reference.kernalRoutines.count, Self.jumpTable.count)
    }

    /// MEMTOP is $FF99 and MEMBOT is $FF9C, and the routines behind them are
    /// $FE25 and $FE34 respectively. Both tables used to have this backwards.
    func testMemTopAndMemBotAreNotSwapped() {
        XCTAssertEqual(symbol("MEMTOP")?.address, 0xFF99)
        XCTAssertEqual(symbol("MEMBOT")?.address, 0xFF9C)
        XCTAssertEqual(symbol("MEMTOP_INT")?.address, 0xFE25)
        XCTAssertEqual(symbol("MEMBOT_INT")?.address, 0xFE34)

        let memtop = C64Reference.kernalRoutines.first { $0.address == 0xFF99 }
        XCTAssertEqual(memtop?.name, "MEMTOP")
        XCTAssertEqual(memtop?.realAddress, 0xFE25)
        let membot = C64Reference.kernalRoutines.first { $0.address == 0xFF9C }
        XCTAssertEqual(membot?.name, "MEMBOT")
        XCTAssertEqual(membot?.realAddress, 0xFE34)
    }

    // ── Entry points, not dispatch-table values ────────────

    /// The statement dispatch table at $A00C stores each handler's address
    /// minus one. These are the handlers themselves.
    func testBasicCommandHandlersAreEntryPointsNotTableValues() {
        let expected: [String: UInt16] = [
            "CMD_CLR": 0xA65E, "CMD_LIST": 0xA69C, "CMD_RESTORE": 0xA81D,
            "CMD_STOP": 0xA82F, "CMD_CONT": 0xA857, "CMD_PRINT": 0xAAA0,
            "CMD_SYS": 0xE12A, "CMD_SAVE": 0xE156, "CMD_VERIFY": 0xE165,
            "CMD_LOAD": 0xE168, "CMD_OPEN": 0xE1BE, "CMD_CLOSE": 0xE1C7,
        ]
        for (name, address) in expected {
            XCTAssertEqual(symbol(name)?.address, address,
                           String(format: "%@ should be $%04X", name, address))
        }
    }

    // ── Floating-point entry points that used to be shifted ─

    func testFloatingPointEntryPointsAreOnTheRightAddresses() {
        let expected: [String: UInt16] = [
            "ROUND":      0xBC1B,   // was labelled FACSGN
            "SIGN":       0xBC2B,   // was labelled FCOMP
            "FCOMP":      0xBC5B,   // was missing entirely
            "FMULT":      0xBA28,   // the A/Y form; $BA2B is FMULTT
            "FMULTT":     0xBA2B,
            "CONUPK":     0xBA8C,
            "STFAC_XY":   0xBBD4,   // $BBD0 stores via FORPNT, not X/Y
            "GIVAYF":     0xB391,   // was on $BC4F, which is FLOATB
            "FLOATB":     0xBC4F,
            "GETADR":     0xB7F7,   // was on $B7EB, which is GETNUM
            "GETNUM":     0xB7EB,
            "FPWRT":      0xBF7B,
            "LINPRT":     0xBDCD,
            "INPRT":      0xBDC2,
            "FOUT":       0xBDDD,
        ]
        for (name, address) in expected {
            XCTAssertEqual(symbol(name)?.address, address,
                           String(format: "%@ should be $%04X", name, address))
        }
    }

    // ── Hardware vectors ───────────────────────────────────

    func testHardwareVectorsPointWhereTheDescriptionsSay() {
        XCTAssertEqual(symbol("VEC_NMI")?.address, 0xFFFA)
        XCTAssertEqual(symbol("VEC_RESET")?.address, 0xFFFC)
        XCTAssertEqual(symbol("VEC_IRQ")?.address, 0xFFFE)
        XCTAssertTrue(symbol("VEC_NMI")!.description.contains("$FE43"))
        XCTAssertTrue(symbol("VEC_RESET")!.description.contains("$FCE2"))
        XCTAssertTrue(symbol("VEC_IRQ")!.description.contains("$FF48"))
        XCTAssertEqual(symbol("NMI_HANDLER")?.address, 0xFE43)
        XCTAssertEqual(symbol("RESET")?.address, 0xFCE2)
        XCTAssertEqual(symbol("IRQ_ENTRY")?.address, 0xFF48)
    }

    // ── Presentation ───────────────────────────────────────

    func testCallSyntaxUsesTheSymbolsOwnAddress() {
        for sym in C64ROMSymbols.allSymbols {
            XCTAssertTrue(sym.callSyntax.contains(String(format: "$%04X", sym.address)),
                          "\(sym.name) call syntax does not name its own address")
            XCTAssertEqual(sym.sysSyntax, "SYS \(sym.address)")
        }
    }

    func testJumpTableEntriesCarryAFullSignature() {
        // Every jump table entry should tell the reader what it does with the
        // registers, either directly or through the merged KERNAL routine.
        for (address, name) in Self.jumpTable {
            let sym = C64ROMSymbols.symbol(at: address)!
            let routine = C64Reference.kernalRoutines.first { $0.address == address }
            let hasSignature = sym.input != nil || sym.output != nil || sym.registers != nil
                            || routine?.input != nil || routine?.output != nil
                            || routine?.usedRegisters != nil
            XCTAssertTrue(hasSignature, "\(name) documents no input, output or register use")
            XCTAssertNotNil(sym.notes, "\(name) should record which address it jumps to")
        }
    }

    func testExamplesLookLikeAssembly() {
        let withExamples = C64ROMSymbols.allSymbols.filter { $0.example != nil }
        XCTAssertGreaterThan(withExamples.count, 30,
                             "the ROM tab should carry a useful number of worked examples")
        for sym in withExamples {
            let example = sym.example!
            XCTAssertFalse(example.hasSuffix("\n"), "\(sym.name) example has a trailing newline")
            XCTAssertFalse(example.contains("\t"), "\(sym.name) example should use spaces")
        }
    }

    func testEveryCategoryIsUsed() {
        for category in C64ROMSymbols.Category.allCases {
            XCTAssertFalse(C64ROMSymbols.symbols(in: category).isEmpty,
                           "\(category.rawValue) has no entries, so its filter is dead")
        }
    }
}
