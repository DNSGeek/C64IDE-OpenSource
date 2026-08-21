import XCTest
@testable import C64IDE

// ═══════════════════════════════════════════════════════════
// MARK: - OpcodeReferenceTests
// ═══════════════════════════════════════════════════════════

/// Guards the ASM reference panel's opcode database against the disassembler's
/// 256-entry opcode table.
///
/// The two used to be independent transcriptions of the same hardware manual,
/// which is exactly the arrangement that drifts: a cycle count fixed in one
/// place stays wrong in the other, and nothing complains. The panel now derives
/// every opcode byte, instruction length and cycle count from
/// `Disassembler6502.opcodeTable`, and these tests assert that the prose
/// summaries a human still writes by hand -- `cycles` and `addressingModes` --
/// continue to describe what that table actually says.
final class OpcodeReferenceTests: XCTestCase {

    // ── Helpers ────────────────────────────────────────────

    /// Prose abbreviations used in `addressingModes`, mapped back to modes.
    private static let modeSpelling: [String: AddressingMode] = [
        "Implied": .implied, "Accumulator": .accumulator, "Immediate": .immediate,
        "Zero Page": .zeroPage, "ZP X": .zeroPageX, "ZP Y": .zeroPageY,
        "Absolute": .absolute, "Abs X": .absoluteX, "Abs Y": .absoluteY,
        "Indirect": .indirect, "(Ind,X)": .indirectX, "(Ind),Y": .indirectY,
        "Relative": .relative,
    ]

    /// The encodings a given entry's prose is describing: an undocumented
    /// entry describes its undocumented bytes, and a documented one describes
    /// only its documented bytes. That distinction matters for `NOP` and
    /// `SBC`, which are documented mnemonics carrying undocumented encodings
    /// ($EB and the 27 extra NOP forms) that the prose deliberately omits.
    private func describedEncodings(_ ref: OpcodeRef) -> [OpcodeEncoding] {
        ref.encodings.filter { $0.isIllegal == ref.isIllegal }
    }

    /// Worst-case cycle count, applying the branch rule the summaries use:
    /// a taken branch costs +1, and +1 again if it lands on another page.
    private func maxCycles(_ e: OpcodeEncoding) -> Int {
        e.mode == .relative ? e.cycles + 2 * e.pageCrossPenalty
                            : e.cycles + e.pageCrossPenalty
    }

    // ── Coverage ───────────────────────────────────────────

    /// Every mnemonic the disassembler can produce must be documented,
    /// otherwise a user who disassembles a real C64 binary lands on an
    /// instruction the reference panel has never heard of.
    func testEveryDisassemblableMnemonicIsDocumented() {
        var undocumented: Set<String> = []
        for info in Disassembler6502.opcodeTable where info.mnemonic != "???" {
            if C64AssemblySyntax.lookup(info.mnemonic) == nil {
                undocumented.insert(info.mnemonic)
            }
        }
        XCTAssertTrue(undocumented.isEmpty,
                      "Mnemonics with no reference entry: \(undocumented.sorted())")
    }

    /// All 256 opcode bytes decode to a documented instruction. The 6502 has
    /// no unassigned encodings once the undocumented ones are included, so a
    /// gap here means the disassembler table lost an entry.
    func testAllOpcodeBytesAreAccountedFor() {
        XCTAssertEqual(Disassembler6502.opcodeTable.count, 256)
        for (byte, info) in Disassembler6502.opcodeTable.enumerated() {
            XCTAssertNotEqual(info.mnemonic, "???",
                              String(format: "Opcode $%02X is undecoded", byte))
        }
    }

    func testDocumentedInstructionCountIsFiftySix() {
        let documented = C64AssemblySyntax.opcodeReference.values.filter { !$0.isIllegal }
        XCTAssertEqual(documented.count, 56,
                       "The 6502 has exactly 56 documented instructions")
    }

    /// Each undocumented mnemonic in the disassembler table has an entry
    /// flagged as undocumented -- except NOP and SBC, which are documented
    /// mnemonics that also own undocumented encodings.
    func testUndocumentedInstructionsAreFlagged() {
        for info in Disassembler6502.opcodeTable where info.illegal {
            guard info.mnemonic != "NOP", info.mnemonic != "SBC" else { continue }
            guard let ref = C64AssemblySyntax.lookup(info.mnemonic) else {
                return XCTFail("\(info.mnemonic) has no reference entry")
            }
            XCTAssertTrue(ref.isIllegal, "\(info.mnemonic) should be flagged undocumented")
        }
    }

    /// Conversely, nothing documented is mislabelled as undocumented.
    func testDocumentedInstructionsAreNotFlagged() {
        for mnemonic in C64AssemblySyntax.officialOpcodes {
            guard let ref = C64AssemblySyntax.lookup(mnemonic) else {
                return XCTFail("\(mnemonic) has no reference entry")
            }
            XCTAssertFalse(ref.isIllegal, "\(mnemonic) is a documented instruction")
        }
    }

    // ── Prose vs. derived data ─────────────────────────────

    /// The `cycles` summary must match the range the opcode table implies.
    func testCycleSummariesMatchTheOpcodeTable() {
        for (key, ref) in C64AssemblySyntax.opcodeReference {
            // JAM never completes, so it has no meaningful count to compare.
            guard key != "JAM" else { continue }
            let encodings = describedEncodings(ref)
            XCTAssertFalse(encodings.isEmpty, "\(key) has no encodings")

            let low = encodings.map(\.cycles).min()!
            let high = encodings.map(maxCycles).max()!
            let expected = low == high ? "\(low)" : "\(low)-\(high)"
            XCTAssertEqual(ref.cycles, expected,
                           "\(key): cycles summary disagrees with the opcode table")
        }
    }

    /// The `addressingModes` summary must list exactly the modes the opcode
    /// table provides, in the order the encoding table displays them.
    func testAddressingModeSummariesMatchTheOpcodeTable() {
        for (key, ref) in C64AssemblySyntax.opcodeReference {
            let expected = describedEncodings(ref).map(\.mode).reduce(into: [AddressingMode]()) {
                if !$0.contains($1) { $0.append($1) }
            }
            let listed = ref.addressingModes.components(separatedBy: ", ").map {
                Self.modeSpelling[$0]
            }
            XCTAssertFalse(listed.contains(where: { $0 == nil }),
                           "\(key): unrecognised mode spelling in '\(ref.addressingModes)'")
            XCTAssertEqual(listed.compactMap { $0 }, expected,
                           "\(key): addressing modes disagree with the opcode table")
        }
    }

    // ── Completeness of the prose fields ───────────────────

    func testEveryEntryHasDescriptionExampleAndNotes() {
        for (key, ref) in C64AssemblySyntax.opcodeReference {
            XCTAssertFalse(ref.description.isEmpty, "\(key) has no description")
            XCTAssertFalse(ref.fullName.isEmpty, "\(key) has no full name")
            XCTAssertFalse(ref.flags.isEmpty, "\(key) has no flags field")
            XCTAssertFalse(ref.example?.isEmpty ?? true, "\(key) has no example")
            XCTAssertFalse(ref.notes?.isEmpty ?? true, "\(key) has no notes")
        }
    }

    func testEntriesAreKeyedByTheirOwnMnemonic() {
        for (key, ref) in C64AssemblySyntax.opcodeReference {
            XCTAssertEqual(key, ref.mnemonic, "Entry '\(key)' is keyed under another mnemonic")
        }
    }

    /// Every unstable instruction has to say so where a reader will see it.
    /// These produce chip-dependent results and must never be recommended.
    func testUnstableInstructionsCarryAWarning() {
        for mnemonic in ["XAA", "TAS", "SHA", "SHX", "SHY"] {
            guard let ref = C64AssemblySyntax.lookup(mnemonic) else {
                return XCTFail("\(mnemonic) has no reference entry")
            }
            XCTAssertTrue(ref.notes?.contains("UNSTABLE") ?? false,
                          "\(mnemonic) must be marked unstable in its notes")
        }
        // LAX is stable except in immediate mode, which its notes call out.
        XCTAssertTrue(C64AssemblySyntax.lookup("LAX")?.notes?.contains("UNSTABLE") ?? false)
    }

    // ── Encodings ──────────────────────────────────────────

    func testEncodingsCoverEveryOpcodeByteExactlyOnce() {
        var seen: [UInt8: String] = [:]
        for ref in C64AssemblySyntax.opcodeReference.values {
            for e in ref.encodings {
                if let other = seen[e.opcode], other != ref.mnemonic {
                    XCTFail(String(format: "Opcode $%02X claimed by both %@ and %@",
                                   e.opcode, other, ref.mnemonic))
                }
                seen[e.opcode] = ref.mnemonic
            }
        }
        XCTAssertEqual(seen.count, 256, "Every opcode byte should appear in some entry")
    }

    func testEncodingLengthsMatchTheirAddressingMode() {
        for ref in C64AssemblySyntax.opcodeReference.values {
            for e in ref.encodings {
                XCTAssertEqual(e.bytes, e.mode.instructionSize,
                               "\(ref.mnemonic) \(e.mode.displayName) has the wrong length")
                XCTAssertTrue((1...3).contains(e.bytes))
            }
        }
    }

    /// Branch encodings spell their penalty out as two conditional cycles;
    /// indexed reads as one. Getting these backwards in the UI would quietly
    /// mislead anyone counting cycles for a raster routine.
    func testCycleTextExplainsConditionalPenalties() {
        let bne = C64AssemblySyntax.encodings(for: "BNE").first!
        XCTAssertEqual(bne.cycleText, "2 cycles (+1 if taken, +1 more if page crossed)")

        let ldaAbsX = C64AssemblySyntax.encodings(for: "LDA").first { $0.mode == .absoluteX }!
        XCTAssertEqual(ldaAbsX.cycleText, "4 cycles (+1 if page crossed)")

        // Indexed *stores* never take the shortcut, so they have no penalty.
        let staAbsX = C64AssemblySyntax.encodings(for: "STA").first { $0.mode == .absoluteX }!
        XCTAssertEqual(staAbsX.cycleText, "5 cycles")
    }

    /// Spot-check byte values against ca65's own output for the instructions
    /// whose numbering is easiest to get wrong.
    func testKnownOpcodeBytes() {
        let expected: [(String, AddressingMode, UInt8)] = [
            ("LDA", .immediate, 0xA9), ("JMP", .indirect, 0x6C), ("BRK", .implied, 0x00),
            ("SBX", .immediate, 0xCB), ("SAX", .zeroPage, 0x87), ("XAA", .immediate, 0x8B),
            ("ISB", .zeroPage, 0xE7), ("SHA", .indirectY, 0x93), ("SHX", .absoluteY, 0x9E),
            ("SHY", .absoluteX, 0x9C), ("TAS", .absoluteY, 0x9B), ("LAS", .absoluteY, 0xBB),
            ("ALR", .immediate, 0x4B), ("ARR", .immediate, 0x6B), ("ANC", .immediate, 0x0B),
            ("LAX", .immediate, 0xAB),
        ]
        for (mnemonic, mode, byte) in expected {
            let found = C64AssemblySyntax.encodings(for: mnemonic).first { $0.mode == mode }
            XCTAssertEqual(found?.opcode, byte,
                           String(format: "%@ %@ should be $%02X", mnemonic, mode.displayName, byte))
        }
    }

    // ── Aliases and highlighting ───────────────────────────

    /// ca65 spells three of these differently from the Disassembler window.
    /// Both spellings must find the same entry, or the panel is useless to
    /// someone holding output from one and writing input for the other.
    func testCa65SpellingsResolveToTheSameEntry() {
        for (ca65Name, ourName) in [("ISC", "ISB"), ("ANE", "XAA"), ("AXS", "SBX")] {
            XCTAssertEqual(C64AssemblySyntax.lookup(ca65Name)?.mnemonic, ourName,
                           "\(ca65Name) should resolve to \(ourName)")
            XCTAssertEqual(C64AssemblySyntax.encodings(for: ca65Name).map(\.opcode),
                           C64AssemblySyntax.encodings(for: ourName).map(\.opcode))
        }
    }

    func testEveryAliasResolves() {
        for (alias, canonical) in C64AssemblySyntax.mnemonicAliases {
            XCTAssertNotNil(C64AssemblySyntax.opcodeReference[canonical],
                            "Alias \(alias) points at missing entry \(canonical)")
            XCTAssertEqual(C64AssemblySyntax.lookup(alias)?.mnemonic, canonical)
        }
    }

    func testLookupIsCaseInsensitive() {
        XCTAssertEqual(C64AssemblySyntax.lookup("lda")?.mnemonic, "LDA")
        XCTAssertEqual(C64AssemblySyntax.lookup("slo")?.mnemonic, "SLO")
    }

    /// The editor must colour undocumented mnemonics as instructions rather
    /// than leaving them as plain text.
    func testHighlighterRecognisesUndocumentedMnemonics() {
        for mnemonic in C64AssemblySyntax.illegalOpcodes {
            XCTAssertTrue(C64AssemblySyntax.opcodes.contains(mnemonic),
                          "\(mnemonic) should be highlighted as an opcode")
        }
        let tokens = C64AssemblySyntax.tokenize("  LAX ($FB),Y   ; load A and X")
        XCTAssertTrue(tokens.contains { $0.type == .opcode && $0.text.uppercased() == "LAX" },
                      "LAX should tokenize as an opcode")
    }

    func testEveryDocumentedAndUndocumentedMnemonicHasAnEntry() {
        for mnemonic in C64AssemblySyntax.officialOpcodes.union(C64AssemblySyntax.illegalOpcodes) {
            XCTAssertNotNil(C64AssemblySyntax.lookup(mnemonic), "\(mnemonic) has no entry")
        }
    }
}
