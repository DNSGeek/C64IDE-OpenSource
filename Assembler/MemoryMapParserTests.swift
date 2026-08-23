import XCTest
@testable import C64IDE

// ═══════════════════════════════════════════════════════════
// MARK: - MemoryMapParserTests
// ═══════════════════════════════════════════════════════════

/// Covers the three files behind the Memory Map window: `CfgFileParser`,
/// `CfgFileEditor` and `MapFileParser`.
///
/// Test philosophy:
///   • Pin the behaviours that make the window *useful*: the stock cc65 config
///     places every region relative to `%S`, so expression resolution is not a
///     nicety — without it the planned column is empty.
///   • Pin the behaviours that make it *safe*: unsigned address arithmetic
///     traps on underflow, so anything that could produce `end < start` or an
///     address above $FFFF gets an explicit test.
///   • Pin the formatting the surgical editor must survive: real `.cfg` files
///     are hand-written, with tabs and wrapped lines.
final class MemoryMapParserTests: XCTestCase {

    // ═══════════════════════════════════════════════════════
    // MARK: - CfgFileParser: expression resolution
    // ═══════════════════════════════════════════════════════

    /// The exact config `BuildManager` ships for a standard C64 `.prg` build.
    private let stockPrgConfig = """
    # C64 IDE — Standard C64 .prg linker configuration

    FEATURES {
        STARTADDRESS: default = $0801;
    }

    SYMBOLS {
        __LOADADDR__: type = import;
    }

    MEMORY {
        ZP:      file = "", start = $0002, size = $001A, type = rw, define = yes;
        LOADADDR: file = %O, start = %S - 2, size = $0002;
        MAIN:    file = %O, start = %S, size = $D000 - %S, define = yes;
    }

    SEGMENTS {
        ZEROPAGE: load = ZP,       type = zp;
        LOADADDR: load = LOADADDR, type = ro;
        CODE:     load = MAIN,     type = ro,  define = yes;
        BSS:      load = MAIN,     type = bss, define = yes;
    }
    """

    private func region(_ name: String, in info: CfgFileInfo) -> CfgMemoryRegion? {
        info.memory.first { $0.name == name }
    }

    func test_stock_config_resolves_every_region() {
        let info = CfgFileParser.parse(text: stockPrgConfig)
        // Regression guard: these used to be dropped, leaving the planned
        // column showing only the 26-byte ZP region.
        XCTAssertEqual(info.memory.count, 3)
        XCTAssertTrue(info.unresolvedRegions.isEmpty)
    }

    func test_startaddress_feature_supplies_percent_s() {
        let info = CfgFileParser.parse(text: stockPrgConfig)
        XCTAssertEqual(info.startAddress, 0x0801)
        XCTAssertEqual(region("MAIN", in: info)?.start, 0x0801)
    }

    func test_subtraction_expression_resolves() {
        let info = CfgFileParser.parse(text: stockPrgConfig)
        XCTAssertEqual(region("LOADADDR", in: info)?.start, 0x07FF)   // %S - 2
        XCTAssertEqual(region("MAIN", in: info)?.size, 0xC7FF)        // $D000 - %S
    }

    func test_literals_are_flagged_editable_and_expressions_are_not() {
        let info = CfgFileParser.parse(text: stockPrgConfig)
        XCTAssertEqual(region("ZP", in: info)?.isStartLiteral, true)
        XCTAssertEqual(region("MAIN", in: info)?.isStartLiteral, false)
        // Resolved-from-expression is distinct from unresolved: MAIN has a
        // start we can draw, just not one we can rewrite in place.
        XCTAssertEqual(region("MAIN", in: info)?.isStartDerived, true)
    }

    func test_startaddress_defaults_when_features_block_absent() {
        let info = CfgFileParser.parse(text: "MEMORY { M: start = %S, size = $100; }")
        XCTAssertEqual(info.startAddress, CfgFileParser.defaultStartAddress)
        XCTAssertEqual(region("M", in: info)?.start, 0x0801)
    }

    func test_symbols_block_feeds_expressions() {
        let cfg = """
        SYMBOLS { __HIMEM__: type = weak, value = $D000; }
        MEMORY  { RAM: start = $0800, size = __HIMEM__ - $0800; }
        """
        XCTAssertEqual(region("RAM", in: CfgFileParser.parse(text: cfg))?.size, 0xC800)
    }

    func test_symbols_resolve_regardless_of_declaration_order() {
        let cfg = """
        SYMBOLS {
            __TOP__:  value = __BASE__ + $1000;
            __BASE__: value = $2000;
        }
        MEMORY { R: start = __TOP__, size = $10; }
        """
        XCTAssertEqual(region("R", in: CfgFileParser.parse(text: cfg))?.start, 0x3000)
    }

    func test_blocks_are_read_before_memory_regardless_of_file_order() {
        // FEATURES after MEMORY must still supply %S.
        let cfg = """
        MEMORY   { M: start = %S, size = $100; }
        FEATURES { STARTADDRESS: default = $C000; }
        """
        XCTAssertEqual(region("M", in: CfgFileParser.parse(text: cfg))?.start, 0xC000)
    }

    func test_parentheses_and_precedence() {
        let cfg = """
        MEMORY {
            A: start = ($100 + $10) * 2, size = $10;
            B: start = $100 + $10 * 2, size = $10;
        }
        """
        let info = CfgFileParser.parse(text: cfg)
        XCTAssertEqual(region("A", in: info)?.start, 0x220)
        XCTAssertEqual(region("B", in: info)?.start, 0x120)
    }

    func test_unresolvable_expression_is_reported_not_dropped() {
        let cfg = "MEMORY { M: start = __NEVER_DEFINED__, size = $100; }"
        let info = CfgFileParser.parse(text: cfg)
        XCTAssertEqual(info.memory.count, 1, "the region must survive parsing")
        XCTAssertNil(region("M", in: info)?.start)
        XCTAssertEqual(info.unresolvedRegions.map(\.name), ["M"])
    }

    func test_division_by_zero_does_not_resolve() {
        let info = CfgFileParser.parse(text: "MEMORY { M: start = $100 / 0, size = $10; }")
        XCTAssertNil(region("M", in: info)?.start)
    }

    func test_negative_result_does_not_resolve() {
        // $10 - $20 is negative, which is not a valid address.
        let info = CfgFileParser.parse(text: "MEMORY { M: start = $10 - $20, size = $10; }")
        XCTAssertNil(region("M", in: info)?.start)
    }

    // ═══════════════════════════════════════════════════════
    // MARK: - CfgFileParser: lexical handling
    // ═══════════════════════════════════════════════════════

    func test_comments_are_stripped() {
        let cfg = """
        # MEMORY { GHOST: start = $1, size = $1; }
        MEMORY { REAL: start = $10, size = $20; }  # trailing
        """
        XCTAssertEqual(CfgFileParser.parse(text: cfg).memory.map(\.name), ["REAL"])
    }

    func test_hash_inside_quoted_string_is_not_a_comment() {
        let cfg = #"MEMORY { M: file = "out#1.prg", start = $10, size = $20; }"#
        let info = CfgFileParser.parse(text: cfg)
        XCTAssertEqual(region("M", in: info)?.file, "out#1.prg")
        XCTAssertEqual(region("M", in: info)?.size, 0x20, "the entry must not be truncated")
    }

    func test_segments_map_to_regions() {
        let info = CfgFileParser.parse(text: stockPrgConfig)
        XCTAssertEqual(info.segments.first { $0.name == "CODE" }?.load, "MAIN")
        XCTAssertEqual(info.segments.first { $0.name == "BSS" }?.type, "bss")
    }

    func test_numeric_literal_formats() {
        XCTAssertEqual(CfgFileParser.parseNumber("$C000"), 0xC000)
        XCTAssertEqual(CfgFileParser.parseNumber("0xC000"), 0xC000)
        XCTAssertEqual(CfgFileParser.parseNumber("49152"), 49152)
        XCTAssertNil(CfgFileParser.parseNumber("%S - 2"))
        XCTAssertNil(CfgFileParser.parseNumber(""))
    }

    // ═══════════════════════════════════════════════════════
    // MARK: - CfgFileEditor
    // ═══════════════════════════════════════════════════════

    func test_patch_replaces_only_the_named_region() throws {
        let cfg = """
        MEMORY {
            LOADADDR: file = %O, start = $0FFE, size = $0002;
            MAIN:     file = %O, start = $1000, size = $CF00;
        }
        """
        let out = try CfgFileEditor.applyPatch(to: cfg, regionName: "MAIN",
                                               newStart: 0xC000, newSize: 0x1000)
        XCTAssertTrue(out.contains("MAIN:     file = %O, start = $C000, size = $1000;"))
        XCTAssertTrue(out.contains("LOADADDR: file = %O, start = $0FFE, size = $0002;"),
                      "unrelated entries must be byte-identical")
    }

    func test_patch_preserves_comments_and_other_blocks() throws {
        let out = try CfgFileEditor.applyPatch(to: stockPrgConfig, regionName: "ZP",
                                               newStart: 0x0004)
        XCTAssertTrue(out.contains("# C64 IDE — Standard C64 .prg linker configuration"))
        XCTAssertTrue(out.contains("STARTADDRESS: default = $0801;"))
        XCTAssertTrue(out.contains("start = $0004"))
    }

    func test_patch_matches_the_original_literal_style() throws {
        let hex = try CfgFileEditor.applyPatch(to: "MEMORY { M: start = $0010, size = $20; }",
                                               regionName: "M", newStart: 0xC000)
        XCTAssertTrue(hex.contains("start = $C000"))

        let c = try CfgFileEditor.applyPatch(to: "MEMORY { M: start = 0x0010, size = $20; }",
                                             regionName: "M", newStart: 0xC000)
        XCTAssertTrue(c.contains("start = 0xC000"))

        let dec = try CfgFileEditor.applyPatch(to: "MEMORY { M: start = 16, size = $20; }",
                                               regionName: "M", newStart: 49152)
        XCTAssertTrue(dec.contains("start = 49152"))
    }

    /// Regression: only the literal space character used to be skipped, so a
    /// tab before the colon made the region unfindable.
    func test_patch_tolerates_tab_before_colon() throws {
        let out = try CfgFileEditor.applyPatch(to: "MEMORY {\n  M\t: start = $10, size = $20;\n}\n",
                                               regionName: "M", newStart: 0x30)
        XCTAssertTrue(out.contains("start = $30"))
    }

    /// Regression: a line break between an attribute name and its `=` used to
    /// throw `.attributeNotFound`.
    func test_patch_tolerates_wrapped_attribute() throws {
        let out = try CfgFileEditor.applyPatch(to: "MEMORY {\n  M: start\n = $10, size = $20;\n}\n",
                                               regionName: "M", newStart: 0x30)
        XCTAssertTrue(out.contains("$30"))
    }

    func test_patch_entry_range_stops_at_its_own_semicolon() throws {
        // `A` and `B` both have a `start`; patching A must not reach into B.
        let cfg = "MEMORY { A: start = $10, size = $20;B: start = $40, size = $20; }"
        let out = try CfgFileEditor.applyPatch(to: cfg, regionName: "A", newStart: 0x30)
        XCTAssertTrue(out.contains("A: start = $30"))
        XCTAssertTrue(out.contains("B: start = $40"))
    }

    func test_patch_rejects_expression_values() {
        XCTAssertThrowsError(
            try CfgFileEditor.applyPatch(to: stockPrgConfig, regionName: "MAIN", newStart: 0x1000)
        ) { error in
            guard case CfgEditorError.expressionNotEditable(let attr, _) = error else {
                return XCTFail("expected .expressionNotEditable, got \(error)")
            }
            XCTAssertEqual(attr, "start")
        }
    }

    func test_patch_reports_missing_region_and_block() {
        XCTAssertThrowsError(
            try CfgFileEditor.applyPatch(to: "MEMORY { A: start = $10, size = $20; }",
                                         regionName: "NOPE", newStart: 1)
        )
        XCTAssertThrowsError(
            try CfgFileEditor.applyPatch(to: "SEGMENTS { CODE: load = MAIN; }",
                                         regionName: "A", newStart: 1)
        ) { error in
            guard case CfgEditorError.memoryBlockNotFound = error else {
                return XCTFail("expected .memoryBlockNotFound, got \(error)")
            }
        }
    }

    /// A patch must round-trip: reparsing the output yields the new values.
    func test_patch_round_trips_through_the_parser() throws {
        let out = try CfgFileEditor.applyPatch(to: stockPrgConfig, regionName: "ZP",
                                               newStart: 0x0004, newSize: 0x0010)
        let reparsed = CfgFileParser.parse(text: out)
        XCTAssertEqual(region("ZP", in: reparsed)?.start, 0x0004)
        XCTAssertEqual(region("ZP", in: reparsed)?.size, 0x0010)
    }

    // ═══════════════════════════════════════════════════════
    // MARK: - MapFileParser
    // ═══════════════════════════════════════════════════════

    private let sampleMap = """
    Modules list:
    -------------
    build/main.o:
        CODE              Offs = 000000  Size = 00000E  Align = 00001

    Segment list:
    -------------
    Name                   Start     End    Size  Align
    ----------------------------------------------------
    LOADADDR              000801  000802  000002  00001
    CODE                  00080F  00081C  00000E  00001
    BSS                   00081D  00081D  000001  00001

    Exports list by name:
    ---------------------
    __LOADADDR__      000801 RLA
    """

    func test_parses_segment_table() {
        let segs = MapFileParser.parseSegments(sampleMap)
        XCTAssertEqual(segs.map(\.name), ["LOADADDR", "CODE", "BSS"])
        XCTAssertEqual(segs[1].start, 0x080F)
        XCTAssertEqual(segs[1].end, 0x081C)
        XCTAssertEqual(segs[1].size, 0x0E)
    }

    func test_stops_before_the_exports_section() {
        // "__LOADADDR__ 000801 RLA" would otherwise parse as a segment.
        XCTAssertFalse(MapFileParser.parseSegments(sampleMap).contains { $0.name.hasPrefix("__") })
    }

    func test_ignores_the_modules_section() {
        XCTAssertEqual(MapFileParser.parseSegments(sampleMap).count, 3)
    }

    /// Regression: ld65 writes `End = Start - 1` for an empty segment. Leaving
    /// that through produced `end < start`, and the unsigned `end - start` in
    /// the drawing code traps on underflow.
    func test_zero_size_segment_never_yields_end_below_start() {
        let map = """
        Segment list:
        -------------
        Name                   Start     End    Size  Align
        ----------------------------------------------------
        EMPTY                 001000  000FFF  000000  00001
        """
        for seg in MapFileParser.parseSegments(map) {
            XCTAssertGreaterThanOrEqual(seg.end, seg.start)
        }
    }

    func test_malformed_rows_are_skipped() {
        let map = """
        Segment list:
        -------------
        Name                   Start     End    Size  Align
        ----------------------------------------------------
        GOOD                  001000  001001  000002  00001
        BROKEN                zzzzzz  001001  000002  00001
        SHORT                 001000
        """
        XCTAssertEqual(MapFileParser.parseSegments(map).map(\.name), ["GOOD"])
    }

    func test_empty_input_yields_no_segments() {
        XCTAssertTrue(MapFileParser.parseSegments("").isEmpty)
        XCTAssertTrue(MapFileParser.parseSegments("Nothing to see here\n").isEmpty)
    }
}
