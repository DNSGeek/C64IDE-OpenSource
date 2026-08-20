// MARK: - License
// MIT License
//
// Copyright (c) [Year] [Your Name]
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import XCTest
// Note: For open-source distribution, replace 'C64IDE' with your actual package/module name
@testable import C64IDE

// MARK: - BasicParserTests

/// Comprehensive test suite for `BasicParser`.
///
/// Test philosophy:
///   • One assertion per behavior. Avoid parsing entire programs in a single
///     `XCTAssert` to isolate failures.
///   • Helpers parse a single line and return the first statement, enabling
///     tests to read like: `XCTAssertEqual(stmt("10 POKE 1,2"), .pokeStmt(...))`
///   • We validate the AST shape, not the intermediate token stream.
final class BasicParserTests: XCTestCase {

    // MARK: - Helpers

    private func parse(_ source: String) -> [ParsedLine] {
        var p = BasicParser()
        return p.parse(source)
    }

    /// Parses a single line and returns its parsed statements.
    private func stmts(_ source: String) -> [Stmt] {
        parse(source).first?.stmts ?? []
    }

    /// Parses a single line and returns the first statement, if present.
    private func first(_ source: String) -> Stmt? {
        stmts(source).first
    }

    /// Parses a single line and asserts exactly one statement was produced.
    private func one(_ source: String) -> Stmt {
        let s = stmts(source)
        XCTAssertEqual(s.count, 1, "Expected 1 statement, got \(s.count): \(s)")
        return s.first ?? .remStmt
    }

    /// Parses a single line and asserts zero parse errors occurred.
    private func parseClean(_ source: String) -> [ParsedLine] {
        var p = BasicParser()
        let lines = p.parse(source)
        XCTAssertTrue(p.errors.isEmpty, "Unexpected parse errors: \(p.errors)")
        return lines
    }

    // MARK: Line Number Extraction

    func test_lineNumber_extracted() {
        let lines = parse("10 END")
        XCTAssertEqual(lines.first?.number, 10)
    }

    func test_lineNumber_large() {
        let lines = parse("63999 END")
        XCTAssertEqual(lines.first?.number, 63999)
    }

    func test_lineNumber_above_hardware_max_is_rejected() {
        // 63999 is the highest line number a C64 accepts; beyond that the
        // parser drops the line rather than letting it vanish silently.
        var p = BasicParser()
        let lines = p.parse("65000 END")
        XCTAssertTrue(lines.isEmpty)
        XCTAssertFalse(p.errors.isEmpty, "Out-of-range line number must be reported")
    }

    func test_lineNumber_zero() {
        let lines = parse("0 REM start")
        XCTAssertEqual(lines.first?.number, 0)
    }

    func test_multiple_lines_ordered() {
        let lines = parse("10 END\n20 STOP\n30 CLR")
        XCTAssertEqual(lines.map(\.number), [10, 20, 30])
    }

    func test_blank_lines_skipped() {
        let lines = parse("10 END\n\n\n20 STOP")
        XCTAssertEqual(lines.count, 2)
    }

    // MARK: Simple Statements

    func test_end()     { XCTAssertEqual(one("10 END"),     .endStmt) }
    func test_stop()    { XCTAssertEqual(one("10 STOP"),    .stopStmt) }
    func test_clr()     { XCTAssertEqual(one("10 CLR"),     .clrStmt) }
    func test_return()  { XCTAssertEqual(one("10 RETURN"),  .returnStmt) }
    func test_restore() { XCTAssertEqual(one("10 RESTORE"), .restoreStmt) }
    // A REM carries no executable content, so the parser emits no statement
    // for it — there is nothing for the code generator to lower.
    func test_rem()     { XCTAssertTrue(stmts("10 REM anything here").isEmpty) }

    // MARK: GOTO / GOSUB

    func test_goto() {
        XCTAssertEqual(one("10 GOTO 100"), .gotoStmt(100))
    }

    func test_goto_nospace() {
        // C64 BASIC tolerates omitted spaces around keywords/numbers
        XCTAssertEqual(one("10 GOTO100"), .gotoStmt(100))
    }

    func test_gosub() {
        XCTAssertEqual(one("10 GOSUB 500"), .gosubStmt(500))
    }

    func test_goto_dangling_line_allowed() {
        // Line 999 doesn't exist — validation is deferred to code generation/assembler
        XCTAssertEqual(one("10 GOTO 999"), .gotoStmt(999))
        var p = BasicParser()
        _ = p.parse("10 GOTO 999")
        XCTAssertTrue(p.errors.isEmpty, "Dangling GOTO should not be a parse error")
    }

    // MARK: POKE / SYS

    func test_poke_literals() {
        XCTAssertEqual(one("10 POKE 53281,0"),
                       .pokeStmt(.intLit(53281), .intLit(0)))
    }

    func test_poke_nospace() {
        XCTAssertEqual(one("10 POKE53281,0"),
                       .pokeStmt(.intLit(53281), .intLit(0)))
    }

    func test_poke_expression_address() {
        // C64 allows expressions as POKE addresses: POKE V+21,15
        XCTAssertEqual(one("10 POKE V+21,15"),
                       .pokeStmt(.binaryOp("+", .floatVar("V"), .intLit(21)),
                                  .intLit(15)))
    }

    func test_poke_variable_value() {
        XCTAssertEqual(one("10 POKE V0,EX"),
                       .pokeStmt(.floatVar("V0"), .floatVar("EX")))
    }

    func test_sys() {
        XCTAssertEqual(one("10 SYS 2048"), .sysStmt(.intLit(2048)))
    }

    // MARK: LET / Assignment

    func test_let_explicit() {
        XCTAssertEqual(one("10 LET X=5"), .letFloat("X", .intLit(5)))
    }

    func test_let_implicit() {
        // C64 BASIC allows implicit LET
        XCTAssertEqual(one("10 X=5"), .letFloat("X", .intLit(5)))
    }

    func test_let_string_var() {
        XCTAssertEqual(one("10 A$=\"HI\""), .letStr("A$", .strLit("HI")))
    }

    func test_let_integer_var() {
        XCTAssertEqual(one("10 A%=42"), .letInt("A%", .intLit(42)))
    }

    func test_let_expression() {
        XCTAssertEqual(one("10 PX=PX+8"),
                       .letFloat("PX", .binaryOp("+", .floatVar("PX"), .intLit(8))))
    }

    func test_let_two_char_var() {
        XCTAssertEqual(one("10 EX=120"), .letFloat("EX", .intLit(120)))
    }

    func test_let_multi_char_var() {
        XCTAssertEqual(one("10 PLAYER=0"), .letFloat("PLAYER", .intLit(0)))
    }

    func test_let_var_containing_keyword_is_not_one_assignment() {
        // SCORE lexes as SC, OR, E (see BasicLexerTests), so this is not an
        // assignment to a variable called SCORE — matching the C64, where
        // SCORE=0 is a syntax error rather than a store.
        XCTAssertNotEqual(stmts("10 SCORE=0").first, .letFloat("SCORE", .intLit(0)))
    }

    // MARK: Array Writes

    func test_array_write_1d() {
        XCTAssertEqual(one("10 A(3)=99"),
                       .arrayWrite("A", [.intLit(3)], .intLit(99)))
    }

    func test_array_write_2d() {
        XCTAssertEqual(one("10 B(I,J)=0"),
                       .arrayWrite("B", [.floatVar("I"), .floatVar("J")], .intLit(0)))
    }

    func test_array_write_string() {
        XCTAssertEqual(one("10 S$(0)=\"X\""),
                       .arrayWrite("S$", [.intLit(0)], .strLit("X")))
    }

    // MARK: FOR / NEXT

    func test_for_simple() {
        XCTAssertEqual(one("10 FOR N=0 TO 62"),
                       .forStmt("N", .intLit(0), .intLit(62), nil))
    }

    func test_for_with_step() {
        XCTAssertEqual(one("10 FOR I=10 TO 1 STEP -1"),
                       .forStmt("I", .intLit(10), .intLit(1),
                                 .unaryMinus(.intLit(1))))
    }

    func test_for_word_range() {
        XCTAssertEqual(one("10 FOR W=1 TO 1000"),
                       .forStmt("W", .intLit(1), .intLit(1000), nil))
    }

    func test_for_nospace() {
        // Relies on lexer's greedy keyword matching. C64 ROM is tolerant of
        // omitted spaces around operators and keywords.
        XCTAssertEqual(one("10 FORI=0TO62"),
                       .forStmt("I", .intLit(0), .intLit(62), nil))
    }

    func test_next_with_var() {
        XCTAssertEqual(one("10 NEXT N"), .nextStmt("N"))
    }

    func test_next_bare() {
        XCTAssertEqual(one("10 NEXT"), .nextStmt(nil))
    }

    func test_next_nospace() {
        XCTAssertEqual(one("10 NEXTN"), .nextStmt("N"))
    }

    // MARK: IF / THEN

    func test_if_goto_lineno() {
        // IF K$="" THEN GOTO 87
        // Two statements on the line: the GET, then the IF...GOTO.
        let both = stmts("87 GET K$: IF K$=\"\" THEN GOTO 87")
        XCTAssertEqual(both.count, 2)
        XCTAssertEqual(both[1], .ifGoto(.compareOp("=", .strVar("K$"), .strLit("")), 87))
        XCTAssertEqual(
            stmts("87 IF K$=\"\" THEN GOTO 87").first,
            .ifGoto(.compareOp("=", .strVar("K$"), .strLit("")), 87)
        )
    }

    func test_if_then_lineno_implicit_goto() {
        // C64 allows implicit GOTO after THEN
        XCTAssertEqual(
            one("10 IF K$=\"\" THEN 87"),
            .ifGoto(.compareOp("=", .strVar("K$"), .strLit("")), 87)
        )
    }

    func test_if_then_inline_stmt() {
        // IF J=L THEN PX=PX-8
        let s = one("10 IF J=L THEN PX=PX-8")
        XCTAssertEqual(s, .ifThen(
            .compareOp("=", .floatVar("J"), .floatVar("L")),
            [.letFloat("PX", .binaryOp("-", .floatVar("PX"), .intLit(8)))],
            nil
        ))
    }

    func test_if_compound_condition_and() {
        // IF TT>DE AND TF=0 THEN TX=EX+8
        let s = one("10 IF TT>DE AND TF=0 THEN TX=EX+8")
        XCTAssertEqual(s, .ifThen(
            .binaryOp("AND",
                .compareOp(">", .floatVar("TT"), .floatVar("DE")),
                .compareOp("=", .floatVar("TF"), .intLit(0))),
            [.letFloat("TX", .binaryOp("+", .floatVar("EX"), .intLit(8)))],
            nil
        ))
    }

    func test_if_condition_or() {
        // IF J=L OR A$="A" THEN PX=PX-8
        let s = one("10 IF J=L OR A$=\"A\" THEN PX=PX-8")
        XCTAssertEqual(s, .ifThen(
            .binaryOp("OR",
                .compareOp("=", .floatVar("J"), .floatVar("L")),
                .compareOp("=", .strVar("A$"), .strLit("A"))),
            [.letFloat("PX", .binaryOp("-", .floatVar("PX"), .intLit(8)))],
            nil
        ))
    }

    func test_if_bitmask_and() {
        // C64 supports parentheses and bitwise AND in expressions
        let s = one("10 IF SF=1 AND (C AND 5)=5 THEN PRINT \"ENEMY HIT\":SF=0")
        guard case .ifThen(let cond, let then, _) = s else {
            XCTFail("Expected .ifThen, got \(s)")
            return
        }
        XCTAssertEqual(cond, .binaryOp("AND",
            .compareOp("=", .floatVar("SF"), .intLit(1)),
            .compareOp("=",
                .binaryOp("AND", .floatVar("C"), .intLit(5)),
                .intLit(5))))
        XCTAssertFalse(then.isEmpty)
    }

    // MARK: PRINT

    func test_print_string_literal() {
        XCTAssertEqual(one("10 PRINT \"HELLO\""),
                       .printStmt([.expr(.strLit("HELLO"))]))
    }

    func test_print_no_newline_semicolon() {
        XCTAssertEqual(one("10 PRINT \"#\";"),
                       .printStmt([.expr(.strLit("#")), .noNewline]))
    }

    func test_print_chr() {
        XCTAssertEqual(one("10 PRINT CHR$(147)"),
                       .printStmt([.expr(.funcCall("CHR$", [.intLit(147)]))]))
    }

    func test_print_comma_tab() {
        let s = one("10 PRINT A,B")
        XCTAssertEqual(s, .printStmt([.expr(.floatVar("A")), .tab,
                                      .expr(.floatVar("B"))]))
    }

    func test_print_multiple_with_semicolons() {
        // PRINT CHR$(147);CHR$(5);"SOLO INVADER!"
        let s = one("10 PRINT CHR$(147);CHR$(5);\"SOLO INVADER!\"")
        guard case .printStmt(let items) = s else {
            XCTFail("Expected .printStmt, got \(s)")
            return
        }
        XCTAssertEqual(items.count, 5) // expr, noNewline, expr, noNewline, expr
    }

    // MARK: GET / INPUT

    func test_get_string_var() {
        XCTAssertEqual(one("10 GET K$"), .getStmt([.scalar("K$")]))
    }

    func test_input_no_prompt() {
        XCTAssertEqual(one("10 INPUT A$"), .inputStmt(nil, .scalar("A$")))
    }

    func test_input_with_prompt() {
        XCTAssertEqual(one("10 INPUT \"NAME\";A$"), .inputStmt("NAME", .scalar("A$")))
    }

    // MARK: DATA / READ / RESTORE

    func test_data_integers() {
        XCTAssertEqual(one("1001 DATA 0,0,0"),
                       .dataStmt([.integer(0), .integer(0), .integer(0)]))
    }

    func test_data_mixed() {
        XCTAssertEqual(one("10 DATA 6,0,96"),
                       .dataStmt([.integer(6), .integer(0), .integer(96)]))
    }

    func test_data_negative() {
        // The sign is folded into the value: DATA -5 parses as .integer(-5),
        // mirroring how the float path folds -1.5 to .float(-1.5).
        XCTAssertEqual(one("10 DATA -1,2,-3"),
                       .dataStmt([.integer(-1), .integer(2), .integer(-3)]))
    }

    func test_data_string() {
        XCTAssertEqual(one("10 DATA \"HELLO\",42"),
                       .dataStmt([.string("HELLO"), .integer(42)]))
    }

    func test_read_single() {
        XCTAssertEqual(one("10 READ B"), .readStmt([.scalar("B")]))
    }

    func test_read_multiple() {
        XCTAssertEqual(one("10 READ A,B,C"), .readStmt([.scalar("A"), .scalar("B"), .scalar("C")]))
    }

    // MARK: DIM

    func test_dim_float_array() {
        XCTAssertEqual(one("10 DIM A(10)"),
                       .dimStmt([DimEntry(name: "A", dims: [.intLit(10)])]))
    }

    func test_dim_integer_array() {
        XCTAssertEqual(one("10 DIM A%(10)"),
                       .dimStmt([DimEntry(name: "A%", dims: [.intLit(10)])]))
    }

    func test_dim_string_array() {
        XCTAssertEqual(one("10 DIM S$(5)"),
                       .dimStmt([DimEntry(name: "S$", dims: [.intLit(5)])]))
    }

    func test_dim_2d() {
        XCTAssertEqual(one("10 DIM C%(2,3)"),
                       .dimStmt([DimEntry(name: "C%", dims: [.intLit(2), .intLit(3)])]))
    }

    func test_dim_multiple_arrays() {
        XCTAssertEqual(one("10 DIM A(10),B$(5)"),
                       .dimStmt([DimEntry(name: "A",  dims: [.intLit(10)]),
                                 DimEntry(name: "B$", dims: [.intLit(5)])]))
    }

    // MARK: ON GOTO / ON GOSUB

    func test_on_goto() {
        XCTAssertEqual(one("10 ON X GOTO 100,200,300"),
                       .onGoto(.floatVar("X"), [100, 200, 300]))
    }

    func test_on_gosub() {
        XCTAssertEqual(one("10 ON X GOSUB 500,600"),
                       .onGosub(.floatVar("X"), [500, 600]))
    }

    // MARK: WAIT

    func test_wait_two_args() {
        XCTAssertEqual(one("10 WAIT 198,255"),
                       .waitStmt(.intLit(198), .intLit(255), nil))
    }

    func test_wait_three_args() {
        XCTAssertEqual(one("10 WAIT 198,255,64"),
                       .waitStmt(.intLit(198), .intLit(255), .intLit(64)))
    }

    // MARK: Expressions

    func test_expr_int_literal()   { XCTAssertEqual(one("10 X=42"),    .letFloat("X", .intLit(42))) }
    func test_expr_float_literal() { XCTAssertEqual(one("10 X=3.14"),  .letFloat("X", .floatLit(3.14))) }
    func test_expr_negative()      { XCTAssertEqual(one("10 X=-1"),    .letFloat("X", .unaryMinus(.intLit(1)))) }
    func test_expr_add()           { XCTAssertEqual(one("10 X=A+B"),   .letFloat("X", .binaryOp("+", .floatVar("A"), .floatVar("B")))) }
    func test_expr_subtract()      { XCTAssertEqual(one("10 X=A-8"),   .letFloat("X", .binaryOp("-", .floatVar("A"), .intLit(8)))) }
    func test_expr_multiply()      { XCTAssertEqual(one("10 X=A*2"),   .letFloat("X", .binaryOp("*", .floatVar("A"), .intLit(2)))) }
    func test_expr_divide()        { XCTAssertEqual(one("10 X=A/2"),   .letFloat("X", .binaryOp("/", .floatVar("A"), .intLit(2)))) }
    func test_expr_power()         { XCTAssertEqual(one("10 X=2^8"),   .letFloat("X", .binaryOp("^", .intLit(2), .intLit(8)))) }

    func test_expr_parenthesised() {
        XCTAssertEqual(one("10 X=(A+B)*2"),
                       .letFloat("X", .binaryOp("*",
                           .binaryOp("+", .floatVar("A"), .floatVar("B")),
                           .intLit(2))))
    }

    func test_expr_not() {
        XCTAssertEqual(one("10 X=NOT A"), .letFloat("X", .notOp(.floatVar("A"))))
    }

    func test_expr_peek() {
        XCTAssertEqual(one("10 J=PEEK(JA)"),
                       .letFloat("J", .funcCall("PEEK", [.floatVar("JA")])))
    }

    func test_expr_peek_nospace() {
        XCTAssertEqual(one("10 J=PEEK(56320)"),
                       .letFloat("J", .funcCall("PEEK", [.intLit(56320)])))
    }

    func test_expr_abs() {
        XCTAssertEqual(one("10 X=ABS(Y)"),
                       .letFloat("X", .funcCall("ABS", [.floatVar("Y")])))
    }

    func test_expr_int_func() {
        XCTAssertEqual(one("10 X=INT(Y)"),
                       .letFloat("X", .funcCall("INT", [.floatVar("Y")])))
    }

    func test_expr_chr_dollar() {
        XCTAssertEqual(one("10 A$=CHR$(65)"),
                       .letStr("A$", .funcCall("CHR$", [.intLit(65)])))
    }

    func test_expr_left_dollar() {
        XCTAssertEqual(one("10 B$=LEFT$(A$,3)"),
                       .letStr("B$", .funcCall("LEFT$", [.strVar("A$"), .intLit(3)])))
    }

    func test_expr_mid_dollar() {
        XCTAssertEqual(one("10 B$=MID$(A$,2,4)"),
                       .letStr("B$", .funcCall("MID$", [.strVar("A$"), .intLit(2), .intLit(4)])))
    }

    func test_expr_right_dollar() {
        XCTAssertEqual(one("10 B$=RIGHT$(A$,1)"),
                       .letStr("B$", .funcCall("RIGHT$", [.strVar("A$"), .intLit(1)])))
    }

    func test_expr_len() {
        XCTAssertEqual(one("10 N=LEN(A$)"),
                       .letFloat("N", .funcCall("LEN", [.strVar("A$")])))
    }

    func test_expr_asc() {
        XCTAssertEqual(one("10 N=ASC(A$)"),
                       .letFloat("N", .funcCall("ASC", [.strVar("A$")])))
    }

    func test_expr_str_dollar() {
        XCTAssertEqual(one("10 A$=STR$(X)"),
                       .letStr("A$", .funcCall("STR$", [.floatVar("X")])))
    }

    func test_expr_val() {
        XCTAssertEqual(one("10 X=VAL(A$)"),
                       .letFloat("X", .funcCall("VAL", [.strVar("A$")])))
    }

    func test_expr_ti_sysvar() {
        XCTAssertEqual(one("10 X=TI"), .letFloat("X", .tiVar))
    }

    func test_expr_array_read() {
        XCTAssertEqual(one("10 X=A(3)"),
                       .letFloat("X", .arrayRead("A", [.intLit(3)])))
    }

    func test_expr_array_read_2d() {
        XCTAssertEqual(one("10 X=B(I,J)"),
                       .letFloat("X", .arrayRead("B", [.floatVar("I"), .floatVar("J")])))
    }

    func test_expr_compare_eq()  { XCTAssertEqual(one("10 X=A=B"),   .letFloat("X", .compareOp("=",  .floatVar("A"), .floatVar("B")))) }
    func test_expr_compare_lt()  { XCTAssertEqual(one("10 X=A<B"),   .letFloat("X", .compareOp("<",  .floatVar("A"), .floatVar("B")))) }
    func test_expr_compare_gt()  { XCTAssertEqual(one("10 X=A>B"),   .letFloat("X", .compareOp(">",  .floatVar("A"), .floatVar("B")))) }
    func test_expr_compare_lte() { XCTAssertEqual(one("10 X=A<=B"),  .letFloat("X", .compareOp("<=", .floatVar("A"), .floatVar("B")))) }
    func test_expr_compare_gte() { XCTAssertEqual(one("10 X=A>=B"),  .letFloat("X", .compareOp(">=", .floatVar("A"), .floatVar("B")))) }
    func test_expr_compare_ne()  { XCTAssertEqual(one("10 X=A<>B"),  .letFloat("X", .compareOp("<>", .floatVar("A"), .floatVar("B")))) }

    // MARK: Operator Precedence

    func test_precedence_mul_before_add() {
        // C64 follows standard math precedence: A + B*C → A + (B*C)
        XCTAssertEqual(one("10 X=A+B*C"),
                       .letFloat("X", .binaryOp("+",
                           .floatVar("A"),
                           .binaryOp("*", .floatVar("B"), .floatVar("C")))))
    }

    func test_precedence_power_right_assoc() {
        // C64's ^ operator is right-associative: 2^3^4 → 2^(3^4)
        XCTAssertEqual(one("10 X=2^3^4"),
                       .letFloat("X", .binaryOp("^",
                           .intLit(2),
                           .binaryOp("^", .intLit(3), .intLit(4)))))
    }

    // MARK: Multi-Statement Lines

    func test_colon_separates_statements() {
        let s = stmts("10 X=1:Y=2:Z=3")
        XCTAssertEqual(s.count, 3)
        XCTAssertEqual(s[0], .letFloat("X", .intLit(1)))
        XCTAssertEqual(s[1], .letFloat("Y", .intLit(2)))
        XCTAssertEqual(s[2], .letFloat("Z", .intLit(3)))
    }

    func test_poke_multiple_on_one_line() {
        // Line 1 from the classic "Space Invaders" BASIC port
        let s = stmts("1 POKE 53280,0: POKE 53281,0: POKE 646,1: PRINT CHR$(147)")
        XCTAssertEqual(s.count, 4)
        XCTAssertEqual(s[0], .pokeStmt(.intLit(53280), .intLit(0)))
        XCTAssertEqual(s[1], .pokeStmt(.intLit(53281), .intLit(0)))
        XCTAssertEqual(s[2], .pokeStmt(.intLit(646), .intLit(1)))
    }

    // MARK: Real-World C64 BASIC Lines (Space Invaders)

    func test_invader_line2() {
        // "JA=56320: V=53248: SC=53278: DE=500: S=1"
        let s = stmts("2 JA=56320: V=53248: SC=53278: DE=500: S=1")
        XCTAssertEqual(s.count, 5)
        XCTAssertEqual(s[0], .letFloat("JA", .intLit(56320)))
        XCTAssertEqual(s[4], .letFloat("S",  .intLit(1)))
    }

    func test_invader_line19_for_read_poke() {
        // "FOR N=0 TO 62: READ B: POKE 12288+N,B: NEXT"
        let s = stmts("19 FOR N=0 TO 62: READ B: POKE 12288+N,B: NEXT")
        XCTAssertEqual(s.count, 4)
        XCTAssertEqual(s[0], .forStmt("N", .intLit(0), .intLit(62), nil))
        XCTAssertEqual(s[1], .readStmt([.scalar("B")]))
        XCTAssertEqual(s[2], .pokeStmt(
            .binaryOp("+", .intLit(12288), .floatVar("N")),
            .floatVar("B")))
        XCTAssertEqual(s[3], .nextStmt(nil))
    }

    func test_invader_line87_get_if() {
        // "GET K$: IF K$=\"\" THEN GOTO 87"
        let s = stmts("87 GET K$: IF K$=\"\" THEN GOTO 87")
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s[0], .getStmt([.scalar("K$")]))
        XCTAssertEqual(s[1], .ifGoto(
            .compareOp("=", .strVar("K$"), .strLit("")), 87))
    }

    func test_invader_line103_for_w() {
        XCTAssertEqual(one("103 FOR W=1 TO 1000"),
                       .forStmt("W", .intLit(1), .intLit(1000), nil))
    }

    func test_invader_line161_enemy_move() {
        // "EX=EX+ED"
        XCTAssertEqual(one("161 EX=EX+ED"),
                       .letFloat("EX", .binaryOp("+", .floatVar("EX"), .floatVar("ED"))))
    }

    func test_invader_line191_poke_positions() {
        // "POKE V0,EX: POKE V1,EY"
        let s = stmts("191 POKE V0,EX: POKE V1,EY")
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s[0], .pokeStmt(.floatVar("V0"), .floatVar("EX")))
        XCTAssertEqual(s[1], .pokeStmt(.floatVar("V1"), .floatVar("EY")))
    }

    func test_invader_line207_sprite_collision() {
        // "C=0:IF SF OR TF THEN C=PEEK(SC)"
        let s = stmts("207 C=0:IF SF OR TF THEN C=PEEK(SC)")
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s[0], .letFloat("C", .intLit(0)))
        XCTAssertEqual(s[1], .ifThen(
            .binaryOp("OR", .floatVar("SF"), .floatVar("TF")),
            [.letFloat("C", .funcCall("PEEK", [.floatVar("SC")]))],
            nil))
    }

    func test_invader_line210_goto() {
        XCTAssertEqual(one("210 GOTO 110"), .gotoStmt(110))
    }

    // MARK: Error Recovery

    func test_error_recorded_on_bad_for() {
        var p = BasicParser()
        _ = p.parse("10 FOR 99")   // 99 is not an identifier
        XCTAssertFalse(p.errors.isEmpty)
        XCTAssertEqual(p.errors.first?.line, 10)
    }

    func test_error_includes_line_number() {
        var p = BasicParser()
        _ = p.parse("500 FOR BAD")
        XCTAssertEqual(p.errors.first?.line, 500)
    }

    func test_parse_continues_after_error() {
        // C64 BASIC continues execution after syntax errors. Parser mimics this.
        var p = BasicParser()
        let lines = p.parse("10 FOR 99\n20 END")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[1].stmts.first, .endStmt)
    }
}

