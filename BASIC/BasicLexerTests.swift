// MARK: - BasicLexerTests.swift
//
// Unit tests for the BASIC V2 lexical analyzer.
// Verifies tokenization rules, greedy keyword matching, REM handling,
// and real-world program compatibility.
//
// Test Philosophy:
//   Each test validates a single lexical rule. Integration-style tests
//   use actual BASIC lines to catch regressions in real-world patterns.

import XCTest
@testable import C64IDE

final class BasicLexerTests: XCTestCase {

    // Helper: strips the trailing .eof token for cleaner test assertions
    private func tok(_ line: String) -> [BasicToken] {
        var result = tokenize(line)
        if result.last == .eof { result.removeLast() }
        return result
    }

    // MARK: - Numeric Literals

    func test_integer_zero() {
        XCTAssertEqual(tok("0"), [.integer(0)])
    }

    func test_integer_byte() {
        XCTAssertEqual(tok("255"), [.integer(255)])
    }

    func test_integer_word() {
        XCTAssertEqual(tok("53248"), [.integer(53248)])
    }

    func test_integer_large() {
        XCTAssertEqual(tok("12288"), [.integer(12288)])
    }

    func test_float_decimal() {
        XCTAssertEqual(tok("3.14"), [.float(3.14)])
    }

    func test_float_leading_dot() {
        XCTAssertEqual(tok(".5"), [.float(0.5)])
    }

    func test_float_scientific() {
        XCTAssertEqual(tok("1E3"), [.float(1000.0)])
    }

    func test_float_scientific_negative_exponent() {
        XCTAssertEqual(tok("2.5E-2"), [.float(0.025)])
    }

    func test_float_scientific_explicit_positive_exponent() {
        XCTAssertEqual(tok("1E+6"), [.float(1_000_000.0)])
    }

    func test_number_followed_immediately_by_keyword() {
        XCTAssertEqual(tok("62TO"), [.integer(62), .keyword("TO")])
    }

    // MARK: - String Literals

    func test_string_empty() {
        XCTAssertEqual(tok("\"\""), [.stringLiteral("")])
    }

    func test_string_simple() {
        XCTAssertEqual(tok("\"HELLO\""), [.stringLiteral("HELLO")])
    }

    func test_string_with_spaces() {
        XCTAssertEqual(tok("\"SOLO INVADER!\""), [.stringLiteral("SOLO INVADER!")])
    }

    func test_string_unterminated_is_legal() {
        XCTAssertEqual(tok("\"OOPS"), [.stringLiteral("OOPS")])
    }

    func test_string_followed_by_semicolon() {
        XCTAssertEqual(tok("\"HI\";"), [.stringLiteral("HI"), .semicolon])
    }

    func test_string_preserves_case() {
        XCTAssertEqual(tok("\"hello\""), [.stringLiteral("hello")])
    }

    // MARK: - Identifiers

    func test_identifier_single_char() {
        XCTAssertEqual(tok("X"), [.identifier("X")])
    }

    func test_identifier_two_chars() {
        XCTAssertEqual(tok("EX"), [.identifier("EX")])
    }

    func test_identifier_long_name() {
        XCTAssertEqual(tok("PLAYER"), [.identifier("PLAYER")])
    }

    func test_identifier_containing_keyword_splits() {
        // Commodore BASIC tokenizes keywords wherever they appear, including
        // inside what looks like a variable name — which is exactly why
        // SCORE=0 gives ?SYNTAX ERROR on real hardware. The lexer is faithful
        // to that: SCORE is SC, OR, E.
        XCTAssertEqual(tok("SCORE"), [.identifier("SC"), .keyword("OR"), .identifier("E")])
    }

    func test_identifier_string_var() {
        XCTAssertEqual(tok("A$"), [.identifierStr("A$")])
    }

    func test_identifier_string_var_two_chars() {
        XCTAssertEqual(tok("K$"), [.identifierStr("K$")])
        XCTAssertEqual(tok("NA$"), [.identifierStr("NA$")])
    }

    func test_identifier_integer_var() {
        XCTAssertEqual(tok("A%"), [.identifierInt("A%")])
        XCTAssertEqual(tok("COUNT%"), [.identifierInt("COUNT%")])
    }

    func test_identifier_with_digits() {
        XCTAssertEqual(tok("V0"), [.identifier("V0")])
        XCTAssertEqual(tok("V7"), [.identifier("V7")])
    }

    // MARK: - Keywords — Basic Recognition

    func test_keyword_for() { XCTAssertEqual(tok("FOR"), [.keyword("FOR")]) }
    func test_keyword_next() { XCTAssertEqual(tok("NEXT"), [.keyword("NEXT")]) }
    func test_keyword_goto() { XCTAssertEqual(tok("GOTO"), [.keyword("GOTO")]) }
    func test_keyword_print() { XCTAssertEqual(tok("PRINT"), [.keyword("PRINT")]) }
    func test_keyword_poke() { XCTAssertEqual(tok("POKE"), [.keyword("POKE")]) }
    func test_keyword_peek_as_function() { XCTAssertEqual(tok("PEEK"), [.keyword("PEEK")]) }
    func test_keyword_if_then() {
        XCTAssertEqual(tok("IF"), [.keyword("IF")])
        XCTAssertEqual(tok("THEN"), [.keyword("THEN")])
    }
    func test_keyword_and_or() {
        XCTAssertEqual(tok("AND"), [.keyword("AND")])
        XCTAssertEqual(tok("OR"),  [.keyword("OR")])
    }
    func test_keyword_lowercase_input_uppercased() {
        XCTAssertEqual(tok("print"), [.keyword("PRINT")])
        XCTAssertEqual(tok("goto"),  [.keyword("GOTO")])
    }
    func test_keyword_chr_dollar() { XCTAssertEqual(tok("CHR$"), [.keyword("CHR$")]) }
    func test_keyword_left_dollar() { XCTAssertEqual(tok("LEFT$"), [.keyword("LEFT$")]) }
    func test_keyword_mid_dollar() { XCTAssertEqual(tok("MID$"), [.keyword("MID$")]) }
    func test_keyword_right_dollar() { XCTAssertEqual(tok("RIGHT$"), [.keyword("RIGHT$")]) }
    func test_keyword_str_dollar() { XCTAssertEqual(tok("STR$"), [.keyword("STR$")]) }

    // MARK: - Keywords — Greedy No-Space Matching (C64 ROM Behavior)

    func test_noSpace_poke_address_value() {
        XCTAssertEqual(tok("POKE53281,0"),
                       [.keyword("POKE"), .integer(53281), .comma, .integer(0)])
    }

    func test_noSpace_goto_lineno() {
        XCTAssertEqual(tok("GOTO87"), [.keyword("GOTO"), .integer(87)])
    }

    func test_noSpace_for_loop() {
        XCTAssertEqual(tok("FORI=0TO62"), [
            .keyword("FOR"), .identifier("I"), .op("="), .integer(0),
            .keyword("TO"), .integer(62)
        ])
    }

    func test_noSpace_next_var() {
        XCTAssertEqual(tok("NEXTN"), [.keyword("NEXT"), .identifier("N")])
    }

    func test_noSpace_if_then() {
        XCTAssertEqual(tok("IFA=1THEN"),
                       [.keyword("IF"), .identifier("A"), .op("="), .integer(1), .keyword("THEN")])
    }

    func test_noSpace_print_hash() {
        XCTAssertEqual(tok("PRINT#1"), [.keyword("PRINT#"), .integer(1)])
    }

    func test_noSpace_input_hash() {
        XCTAssertEqual(tok("INPUT#2"), [.keyword("INPUT#"), .integer(2)])
    }

    func test_keyword_greedy_splits_fort() {
        XCTAssertEqual(tok("FORT"), [.keyword("FOR"), .identifier("T")])
    }

    func test_keyword_greedy_splits_total() {
        XCTAssertEqual(tok("TOTAL"), [.keyword("TO"), .identifier("TAL")])
    }

    func test_keyword_greedy_splits_order() {
        XCTAssertEqual(tok("ORDER"), [.keyword("OR"), .identifier("DER")])
    }

    // MARK: - REM Handling

    func test_rem_produces_no_tokens() {
        XCTAssertEqual(tok("REM THIS IS A COMMENT"), [])
    }

    func test_rem_after_colon_swallows_rest() {
        XCTAssertEqual(tok("POKE 1,2 : REM anything here"),
                       [.keyword("POKE"), .integer(1), .comma, .integer(2), .colon])
    }

    func test_rem_with_keywords_inside_not_tokenised() {
        XCTAssertEqual(tok("REM FOR NEXT GOTO POKE"), [])
    }

    // MARK: - Operators and Punctuation

    func test_op_plus_minus() {
        XCTAssertEqual(tok("A+B"), [.identifier("A"), .op("+"), .identifier("B")])
        XCTAssertEqual(tok("A-B"), [.identifier("A"), .op("-"), .identifier("B")])
    }

    func test_op_multiply_divide_power() {
        XCTAssertEqual(tok("A*B"), [.identifier("A"), .op("*"), .identifier("B")])
        XCTAssertEqual(tok("A/B"), [.identifier("A"), .op("/"), .identifier("B")])
        XCTAssertEqual(tok("A^B"), [.identifier("A"), .op("^"), .identifier("B")])
    }

    func test_op_equals() {
        XCTAssertEqual(tok("A=B"), [.identifier("A"), .op("="), .identifier("B")])
    }

    func test_op_less_greater() {
        XCTAssertEqual(tok("A<B"),  [.identifier("A"), .op("<"),  .identifier("B")])
        XCTAssertEqual(tok("A>B"),  [.identifier("A"), .op(">"),  .identifier("B")])
        XCTAssertEqual(tok("A<=B"), [.identifier("A"), .op("<="), .identifier("B")])
        XCTAssertEqual(tok("A>=B"), [.identifier("A"), .op(">="), .identifier("B")])
        XCTAssertEqual(tok("A<>B"), [.identifier("A"), .op("<>"), .identifier("B")])
    }

    func test_punctuation() {
        XCTAssertEqual(tok("("), [.lparen])
        XCTAssertEqual(tok(")"), [.rparen])
        XCTAssertEqual(tok(","), [.comma])
        XCTAssertEqual(tok(";"), [.semicolon])
        XCTAssertEqual(tok(":"), [.colon])
        XCTAssertEqual(tok("#"), [.hash])
    }

    // MARK: - Whitespace

    func test_spaces_between_tokens_ignored() {
        XCTAssertEqual(tok("FOR  N  =  0  TO  62"),
                       [.keyword("FOR"), .identifier("N"), .op("="),
                        .integer(0), .keyword("TO"), .integer(62)])
    }

    func test_leading_trailing_spaces_ignored() {
        XCTAssertEqual(tok("  PRINT  "), [.keyword("PRINT")])
    }

    // MARK: - Real BASIC Lines (Integration Checks)

    func test_line1_poke_and_print_chr() {
        let t = tok("POKE 53280,0: POKE 53281,0: POKE 646,1: PRINT CHR$(147)")
        XCTAssertEqual(t, [
            .keyword("POKE"), .integer(53280), .comma, .integer(0), .colon,
            .keyword("POKE"), .integer(53281), .comma, .integer(0), .colon,
            .keyword("POKE"), .integer(646),   .comma, .integer(1), .colon,
            .keyword("PRINT"), .keyword("CHR$"), .lparen, .integer(147), .rparen
        ])
    }

    func test_line2_multi_assignment() {
        let t = tok("JA=56320: V=53248: SC=53278: DE=500: S=1")
        XCTAssertEqual(t, [
            .identifier("JA"), .op("="), .integer(56320), .colon,
            .identifier("V"),  .op("="), .integer(53248), .colon,
            .identifier("SC"), .op("="), .integer(53278), .colon,
            .identifier("DE"), .op("="), .integer(500),   .colon,
            .identifier("S"),  .op("="), .integer(1)
        ])
    }

    func test_line19_for_read_poke() {
        let t = tok("FOR N=0 TO 62: READ B: POKE 12288+N,B: NEXT")
        XCTAssertEqual(t, [
            .keyword("FOR"), .identifier("N"), .op("="), .integer(0),
            .keyword("TO"), .integer(62), .colon,
            .keyword("READ"), .identifier("B"), .colon,
            .keyword("POKE"), .integer(12288), .op("+"), .identifier("N"),
            .comma, .identifier("B"), .colon,
            .keyword("NEXT")
        ])
    }

    func test_line87_get_if_goto() {
        let t = tok("GET K$: IF K$=\"\" THEN GOTO 87")
        XCTAssertEqual(t, [
            .keyword("GET"), .identifierStr("K$"), .colon,
            .keyword("IF"), .identifierStr("K$"), .op("="), .stringLiteral(""),
            .keyword("THEN"), .keyword("GOTO"), .integer(87)
        ])
    }

    func test_line103_for_w_loop() {
        let t = tok("FOR W=1 TO 1000")
        XCTAssertEqual(t, [
            .keyword("FOR"), .identifier("W"), .op("="),
            .integer(1), .keyword("TO"), .integer(1000)
        ])
    }

    func test_line127_if_or_joystick() {
        let t = tok("IF J=L OR A$=\"A\" THEN PX=PX-8")
        XCTAssertEqual(t, [
            .keyword("IF"),
            .identifier("J"), .op("="), .identifier("L"),
            .keyword("OR"),
            .identifierStr("A$"), .op("="), .stringLiteral("A"),
            .keyword("THEN"),
            .identifier("PX"), .op("="), .identifier("PX"), .op("-"), .integer(8)
        ])
    }

    func test_line172_compound_condition() {
        let t = tok("IF TT>DE AND TF=0 THEN TX=EX+8:TY=EY+26:TF=1:TT=0")
        XCTAssertEqual(t, [
            .keyword("IF"),
            .identifier("TT"), .op(">"), .identifier("DE"),
            .keyword("AND"),
            .identifier("TF"), .op("="), .integer(0),
            .keyword("THEN"),
            .identifier("TX"), .op("="), .identifier("EX"), .op("+"), .integer(8), .colon,
            .identifier("TY"), .op("="), .identifier("EY"), .op("+"), .integer(26), .colon,
            .identifier("TF"), .op("="), .integer(1), .colon,
            .identifier("TT"), .op("="), .integer(0)
        ])
    }

    func test_line207_bitwise_and_in_condition() {
        let t = tok("C=0:IF SF OR TF THEN C=PEEK(SC)")
        XCTAssertEqual(t, [
            .identifier("C"), .op("="), .integer(0), .colon,
            .keyword("IF"), .identifier("SF"), .keyword("OR"), .identifier("TF"),
            .keyword("THEN"),
            .identifier("C"), .op("="), .keyword("PEEK"),
            .lparen, .identifier("SC"), .rparen
        ])
    }

    func test_line208_and_with_bitmask() {
        let t = tok("IF SF=1 AND (C AND 5)=5 THEN PRINT \"ENEMY HIT\":SF=0")
        XCTAssertEqual(t, [
            .keyword("IF"),
            .identifier("SF"), .op("="), .integer(1),
            .keyword("AND"),
            .lparen, .identifier("C"), .keyword("AND"), .integer(5), .rparen,
            .op("="), .integer(5),
            .keyword("THEN"),
            .keyword("PRINT"), .stringLiteral("ENEMY HIT"), .colon,
            .identifier("SF"), .op("="), .integer(0)
        ])
    }

    func test_dim_integer_array() {
        XCTAssertEqual(tok("DIM A%(10)"), [
            .keyword("DIM"), .identifierInt("A%"), .lparen, .integer(10), .rparen
        ])
    }

    func test_dim_string_array() {
        XCTAssertEqual(tok("DIM S$(5)"), [
            .keyword("DIM"), .identifierStr("S$"), .lparen, .integer(5), .rparen
        ])
    }

    func test_sys_statement() {
        XCTAssertEqual(tok("SYS 2048"), [.keyword("SYS"), .integer(2048)])
    }

    func test_on_goto() {
        XCTAssertEqual(tok("ON X GOTO 100,200,300"), [
            .keyword("ON"), .identifier("X"), .keyword("GOTO"),
            .integer(100), .comma, .integer(200), .comma, .integer(300)
        ])
    }

    func test_string_functions() {
        XCTAssertEqual(tok("LEFT$(A$,3)"), [
            .keyword("LEFT$"), .lparen, .identifierStr("A$"),
            .comma, .integer(3), .rparen
        ])
        XCTAssertEqual(tok("MID$(A$,2,4)"), [
            .keyword("MID$"), .lparen, .identifierStr("A$"),
            .comma, .integer(2), .comma, .integer(4), .rparen
        ])
        XCTAssertEqual(tok("RIGHT$(A$,1)"), [
            .keyword("RIGHT$"), .lparen, .identifierStr("A$"),
            .comma, .integer(1), .rparen
        ])
        XCTAssertEqual(tok("LEN(A$)"), [
            .keyword("LEN"), .lparen, .identifierStr("A$"), .rparen
        ])
        XCTAssertEqual(tok("ASC(A$)"), [
            .keyword("ASC"), .lparen, .identifierStr("A$"), .rparen
        ])
        XCTAssertEqual(tok("STR$(X)"), [
            .keyword("STR$"), .lparen, .identifier("X"), .rparen
        ])
        XCTAssertEqual(tok("VAL(A$)"), [
            .keyword("VAL"), .lparen, .identifierStr("A$"), .rparen
        ])
    }

    // MARK: - EOF Handling

    func test_eof_always_present() {
        XCTAssertEqual(tokenize("").last, .eof)
    }

    func test_eof_only_token_for_empty_line() {
        XCTAssertEqual(tokenize(""), [.eof])
    }

    func test_eof_only_token_for_whitespace_line() {
        XCTAssertEqual(tokenize("   "), [.eof])
    }
}

