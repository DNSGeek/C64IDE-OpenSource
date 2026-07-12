// MARK: - BasicFixRegressionTests.swift
//
// Regression tests for the 2026-07 fix batch:
//   1. Lexer no longer uppercases string literals / DATA items
//   2. Renumber applies reference replacements in position order
//   3. Renumber no longer mixes String.Index between two strings
//      (covered implicitly by 2's tests; the rewrite removed the pattern)
//   4. BasicKeywordMatcher letter-boundary guard only fires for siblings
//      that continue with a letter
//   5. isTokenizedBASIC accepts PET ($0401) load addresses
//   6. TI/ST pseudo-keywords no longer split identifiers at their start;
//      TI$ lexes as a string variable instead of eating the '$'
//   -  scanNumber exponent lookahead: 5END lexes as 5 + END
//   -  Tokenizer dedupes duplicate line numbers, last definition wins
//
// (Fixes 7 and 8 are pure performance changes with unchanged behavior;
// the existing shortcut-expander and tokenizer suites cover them.)

import XCTest
@testable import C64IDE

final class BasicFixRegressionTests: XCTestCase {

    // Helper: strips the trailing .eof token
    private func tok(_ line: String) -> [BasicToken] {
        var result = tokenize(line)
        if result.last == .eof { result.removeLast() }
        return result
    }

    // ═══════════════════════════════════════════════════════
    // MARK: 1. Lexer case preservation
    // ═══════════════════════════════════════════════════════

    func test_string_literal_preserves_case() {
        XCTAssertEqual(tok("\"Hello, World\""), [.stringLiteral("Hello, World")])
    }

    func test_print_string_preserves_case_keywords_still_match() {
        XCTAssertEqual(tok("print \"MiXeD case\""),
                       [.keyword("PRINT"), .stringLiteral("MiXeD case")])
    }

    func test_data_unquoted_items_preserve_case() {
        XCTAssertEqual(tok("DATA Hello,World"), [
            .keyword("DATA"), .stringLiteral("Hello"),
            .comma, .stringLiteral("World")
        ])
    }

    func test_lowercase_identifiers_normalised_uppercase() {
        XCTAssertEqual(tok("px=1"), [.identifier("PX"), .op("="), .integer(1)])
    }

    func test_lowercase_scientific_exponent() {
        XCTAssertEqual(tok("1e3"), [.float(1000.0)])
    }

    // ═══════════════════════════════════════════════════════
    // MARK: Lexer exponent lookahead
    // ═══════════════════════════════════════════════════════

    func test_5END_is_number_then_keyword() {
        // The E only starts an exponent when digits follow; otherwise the
        // keyword cruncher gets it, as on real hardware.
        XCTAssertEqual(tok("5END"), [.integer(5), .keyword("END")])
    }

    func test_5EXP_is_number_then_keyword() {
        XCTAssertEqual(tok("5EXP(2)"), [
            .integer(5), .keyword("EXP"), .lparen, .integer(2), .rparen
        ])
    }

    func test_real_exponents_still_work() {
        XCTAssertEqual(tok("1E3"),    [.float(1000.0)])
        XCTAssertEqual(tok("2.5E-2"), [.float(0.025)])
        XCTAssertEqual(tok("1E+6"),   [.float(1_000_000.0)])
    }

    // ═══════════════════════════════════════════════════════
    // MARK: 6. TI/ST boundary guard
    // ═══════════════════════════════════════════════════════

    func test_identifier_starting_with_ST_not_split() {
        XCTAssertEqual(tok("STAR=5"),
                       [.identifier("STAR"), .op("="), .integer(5)])
    }

    func test_identifier_starting_with_TI_not_split() {
        XCTAssertEqual(tok("TIP=1"),
                       [.identifier("TIP"), .op("="), .integer(1)])
    }

    func test_TI_dollar_lexes_as_string_variable() {
        // Previously: keyword TI followed by a silently discarded '$'.
        XCTAssertEqual(tok("TI$"), [.identifierStr("TI$")])
    }

    func test_bare_TI_and_ST_still_keywords() {
        XCTAssertEqual(tok("TI"), [.keyword("TI")])
        XCTAssertEqual(tok("ST"), [.keyword("ST")])
    }

    // ═══════════════════════════════════════════════════════
    // MARK: 2. Renumber replacement ordering
    // ═══════════════════════════════════════════════════════

    func test_multi_keyword_line_renumbers_correctly() {
        // The motivating corruption case: GOSUB replacement is collected
        // AFTER the GOTO one but sits EARLIER in the line, and the new
        // target has a different digit count.
        let src = "10 GOSUB 900:GOTO 20\n20 X=1\n900 Y=1"
        let result = BasicRenumber.renumberAll(source: src, startLine: 100, step: 100)
        XCTAssertEqual(result.newSource,
                       "100 GOSUB 300:GOTO 200\n200 X=1\n300 Y=1")
    }

    func test_shrinking_target_multi_keyword() {
        let src = "10 GOSUB 900:GOTO 20\n20 X=1\n900 Y=1"
        let result = BasicRenumber.renumberAll(source: src, startLine: 1, step: 1)
        XCTAssertEqual(result.newSource,
                       "1 GOSUB 3:GOTO 2\n2 X=1\n3 Y=1")
    }

    func test_on_goto_list_renumbers() {
        let src = "10 ON X GOTO 20,30,40\n20 A=1\n30 A=2\n40 A=3"
        let result = BasicRenumber.renumberAll(source: src, startLine: 100, step: 100)
        XCTAssertEqual(result.newSource,
                       "100 ON X GOTO 200,300,400\n200 A=1\n300 A=2\n400 A=3")
    }

    func test_string_literal_references_untouched() {
        let src = "10 PRINT \"GOTO 10\"\n20 GOTO 10"
        let result = BasicRenumber.renumberAll(source: src, startLine: 100, step: 100)
        XCTAssertEqual(result.newSource,
                       "100 PRINT \"GOTO 10\"\n200 GOTO 100")
    }

    func test_spacing_after_target_preserved() {
        let src = "10 GOTO 20 :X=1\n20 REM"
        let result = BasicRenumber.renumberAll(source: src, startLine: 100, step: 100)
        XCTAssertEqual(result.newSource, "100 GOTO 200 :X=1\n200 REM")
    }

    // ═══════════════════════════════════════════════════════
    // MARK: 4. Keyword matcher letter-boundary guard
    // ═══════════════════════════════════════════════════════

    func test_PRINT_matches_before_letter_despite_PRINT_hash() {
        // PRINT# shares the prefix but continues with '#', which can never
        // match when a letter follows, so PRINT must not be suppressed.
        let m = BasicKeywordMatcher(keywords: BasicKeywordMatcher.basicV2Keywords)
        let src = "PRINTA"
        let match = m.match(in: src, at: src.startIndex)
        XCTAssertEqual(match?.keyword, "PRINT")
    }

    func test_INPUT_matches_before_letter_despite_INPUT_hash() {
        let m = BasicKeywordMatcher(keywords: BasicKeywordMatcher.basicV2Keywords)
        let src = "INPUTX"
        let match = m.match(in: src, at: src.startIndex)
        XCTAssertEqual(match?.keyword, "INPUT")
    }

    func test_guard_still_fires_for_letter_continuing_sibling() {
        // Dialect-style case: PRINTUSING extends PRINT with a letter, so
        // PRINT is correctly skipped when a letter follows.
        let m = BasicKeywordMatcher(keywords: ["PRINT", "PRINTUSING"])
        let src = "PRINTUP"
        XCTAssertNil(m.match(in: src, at: src.startIndex))
    }

    // ═══════════════════════════════════════════════════════
    // MARK: 5. isTokenizedBASIC accepts PET PRGs
    // ═══════════════════════════════════════════════════════

    func test_pet_prg_recognised() {
        let prg = BasicTokenizer.tokenize("10 PRINT",
                                          startAddress: BasicTokenizer.petStartAddress)
        XCTAssertTrue(BasicTokenizer.isTokenizedBASIC(prg))
    }

    func test_c64_prg_still_recognised() {
        let prg = BasicTokenizer.tokenize("10 PRINT")
        XCTAssertTrue(BasicTokenizer.isTokenizedBASIC(prg))
    }

    // ═══════════════════════════════════════════════════════
    // MARK: Tokenizer duplicate-line dedup
    // ═══════════════════════════════════════════════════════

    func test_duplicate_line_number_last_definition_wins() {
        let prg = BasicTokenizer.tokenize("10 A=1\n10 B=2")
        let listing = BasicTokenizer.detokenize(prg)
        XCTAssertEqual(listing, "10 B=2")
    }
}
