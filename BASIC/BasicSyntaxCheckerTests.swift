// MARK: - BasicSyntaxCheckerTests.swift
//
// Tests for the live BASIC syntax checker: line-number bookkeeping, the
// parser's positioned errors, undefined jump targets, and dialect
// tolerance (extension statements and functions must not be flagged).

import XCTest
@testable import C64IDE

final class BasicSyntaxCheckerTests: XCTestCase {

    private func check(_ source: String, dialect: BasicDialect? = nil) -> [SyntaxDiagnostic] {
        BasicSyntaxChecker(dialect: dialect).check(source)
    }

    private func messages(_ source: String, dialect: BasicDialect? = nil) -> [String] {
        check(source, dialect: dialect).map(\.message)
    }

    /// A dialect built from the same JSON shape the .c64basic plugins use.
    private func makeDialect(_ json: String) -> BasicDialect {
        try! JSONDecoder().decode(BasicDialect.self, from: Data(json.utf8))
    }

    private lazy var extendedDialect = makeDialect("""
    {
      "name": "TestBASIC",
      "keywords": [
        {"keyword": "CIRCLE", "type": "command", "token": 1},
        {"keyword": "USING",  "type": "command", "token": 2},
        {"keyword": "ELSE",   "type": "conditional", "token": 3},
        {"keyword": "JOY",    "type": "function", "token": 4},
        {"keyword": "HEX$",   "type": "string", "token": 5},
        {"keyword": "ERR$",   "type": "string", "token": 6},
        {"keyword": "TRAP",   "type": "command", "token": 7}
      ]
    }
    """)

    private lazy var inlineAsmDialect = makeDialect("""
    {
      "name": "AsmBASIC",
      "assemblerMnemonics": ["LDA", "STA", "RTS"],
      "keywords": [
        {"keyword": "ASSEM", "type": "command", "token": 1},
        {"keyword": "BASIC", "type": "command", "token": 2}
      ]
    }
    """)

    // MARK: - Clean programs

    func test_clean_program_has_no_diagnostics() {
        let src = """
        10 REM HELLO
        20 FOR I=1 TO 10: PRINT I;: NEXT I
        30 IF I>5 THEN 50
        40 GOSUB 100: GOTO 20
        50 A$=LEFT$("HELLO",2)+MID$("WORLD",2,3)
        60 ON X GOTO 20,30,40
        70 GO TO 100
        80 DATA 1,2,FOO,"BAR"
        90 END
        100 RETURN
        """
        XCTAssertEqual(messages(src), [])
    }

    func test_blank_lines_are_ignored() {
        XCTAssertEqual(messages("10 PRINT\n\n   \n20 END"), [])
    }

    // MARK: - Line numbers

    func test_missing_line_number() {
        let diags = check("10 PRINT\nPRINT \"OOPS\"\n30 END")
        XCTAssertEqual(diags.count, 1)
        XCTAssertEqual(diags[0].line, 1)
        XCTAssertEqual(diags[0].column, 0)
        XCTAssertEqual(diags[0].severity, .error)
        XCTAssertEqual(diags[0].message, "Missing line number")
    }

    func test_missing_line_number_reports_indented_text_position() {
        let diags = check("10 PRINT\n   PRINT \"OOPS\"")
        XCTAssertEqual(diags[0].column, 3)
        XCTAssertEqual(diags[0].length, 12)
    }

    func test_duplicate_line_number_is_warning_on_later_line() {
        let diags = check("10 PRINT\n20 PRINT\n10 END")
        XCTAssertEqual(diags.count, 1)
        XCTAssertEqual(diags[0].line, 2)
        XCTAssertEqual(diags[0].severity, .warning)
        XCTAssertTrue(diags[0].message.contains("Duplicate line number 10"))
    }

    func test_out_of_order_line_is_warning() {
        let diags = check("10 PRINT\n30 PRINT\n20 END")
        XCTAssertEqual(diags.count, 1)
        XCTAssertEqual(diags[0].line, 2)
        XCTAssertEqual(diags[0].severity, .warning)
        XCTAssertTrue(diags[0].message.contains("out of order"))
    }

    func test_line_number_over_maximum_is_positioned() {
        let diags = check("10 PRINT\n70000 END")
        XCTAssertEqual(diags.count, 1)
        XCTAssertEqual(diags[0].line, 1)
        XCTAssertEqual(diags[0].column, 0)
        XCTAssertEqual(diags[0].length, 5)
        XCTAssertTrue(diags[0].message.contains("63999"))
    }

    // MARK: - Jump targets

    func test_undefined_goto_target() {
        let diags = check("10 GOTO 100\n20 END")
        XCTAssertEqual(diags.count, 1)
        XCTAssertEqual(diags[0].message, "Line 100 does not exist")
        XCTAssertEqual(diags[0].line, 0)
        XCTAssertEqual(diags[0].column, 8)
        XCTAssertEqual(diags[0].length, 3)
    }

    func test_undefined_targets_in_on_goto_list() {
        let diags = check("10 ON X GOSUB 20,999,30\n20 RETURN\n30 RETURN")
        XCTAssertEqual(diags.map(\.message), ["Line 999 does not exist"])
        XCTAssertEqual(diags[0].column, 17)
    }

    func test_undefined_then_and_else_targets() {
        let msgs = messages("10 IF A THEN 500\n20 IF B THEN 20 ELSE 600\n30 END")
        XCTAssertEqual(msgs, ["Line 500 does not exist", "Line 600 does not exist"])
    }

    func test_undefined_go_to_target() {
        XCTAssertEqual(messages("10 GO TO 77"), ["Line 77 does not exist"])
    }

    func test_goto_target_defined_later_is_fine() {
        XCTAssertEqual(messages("10 GOTO 30\n20 END\n30 PRINT"), [])
    }

    func test_number_in_data_is_not_a_target() {
        XCTAssertEqual(messages("10 DATA 100,200\n20 READ A,B"), [])
    }

    // MARK: - Statement errors from the parser

    func test_misspelled_keyword_is_reported_at_the_word() {
        let diags = check("10 PRNT \"HI\"")
        XCTAssertEqual(diags.count, 1)
        XCTAssertEqual(diags[0].column, 3)
        XCTAssertEqual(diags[0].length, 4)
        XCTAssertTrue(diags[0].message.contains("PRNT"), diags[0].message)
    }

    func test_misspelled_keyword_does_not_cascade() {
        // Only the unknown word is reported, not the string after it.
        XCTAssertEqual(check("10 PRNT \"HI\"; X").count, 1)
    }

    func test_missing_close_paren() {
        let diags = check("10 PRINT (1+2")
        XCTAssertEqual(diags.map(\.message), ["Expected ')'"])
    }

    func test_if_without_then() {
        XCTAssertEqual(messages("10 IF A=1 PRINT \"X\""),
                       ["Expected THEN (or GOTO) after IF condition"])
    }

    func test_if_goto_form_is_legal() {
        XCTAssertEqual(messages("10 IF A=1 GOTO 20\n20 END"), [])
    }

    func test_wrong_argument_count_for_builtin() {
        let diags = check("10 A$=LEFT$(B$)")
        XCTAssertEqual(diags.map(\.message), ["LEFT$ takes 2 arguments, not 1"])
        XCTAssertEqual(diags[0].column, 6)
    }

    func test_mid_accepts_two_or_three_arguments() {
        XCTAssertEqual(messages("10 A$=MID$(B$,2)+MID$(B$,2,3)"), [])
        XCTAssertEqual(messages("10 A$=MID$(B$)"), ["MID$ takes 2 or 3 arguments, not 1"])
    }

    func test_trailing_garbage_after_statement() {
        let msgs = messages("10 POKE 53280,0 5")
        XCTAssertEqual(msgs.count, 1)
        XCTAssertTrue(msgs[0].hasPrefix("Unexpected number 5"), msgs[0])
    }

    func test_statement_keyword_in_expression() {
        XCTAssertEqual(messages("10 PRINT TO"), ["Unexpected TO in expression"])
    }

    func test_direct_mode_commands_are_accepted_by_checker() {
        XCTAssertEqual(messages("10 RUN\n20 LIST\n30 NEW"), [])
    }

    func test_direct_mode_commands_are_rejected_by_compiler_parser() {
        var parser = BasicParser()
        _ = parser.parse("10 RUN")
        XCTAssertEqual(parser.errors.map(\.message), ["RUN is not supported by the compiler"])
    }

    func test_integer_for_counter_is_v2_error() {
        XCTAssertEqual(messages("10 FOR I%=1 TO 3: NEXT"), ["Expected variable name after FOR"])
    }

    // MARK: - Positions

    func test_error_position_accounts_for_leading_whitespace_and_number() {
        let diags = check("  100  PRINT (1")
        XCTAssertEqual(diags.count, 1)
        // "  100  PRINT (1": content starts at 7, '(' at 13, error at end of line (15)
        XCTAssertEqual(diags[0].column, 15)
    }

    // MARK: - Dialects

    func test_dialect_statement_is_not_an_error() {
        XCTAssertEqual(messages("10 CIRCLE 1,100,100,50", dialect: extendedDialect), [])
    }

    func test_dialect_statement_is_error_without_dialect() {
        let msgs = messages("10 CIRCLE 1,100,100,50")
        XCTAssertEqual(msgs.count, 1)
        XCTAssertTrue(msgs[0].contains("CIRCLE"), msgs[0])
    }

    func test_dialect_statement_paren_balance_is_checked() {
        XCTAssertEqual(messages("10 CIRCLE 1,(100,100,50", dialect: extendedDialect),
                       ["Missing ')' in CIRCLE"])
    }

    func test_dialect_function_in_expression() {
        XCTAssertEqual(messages("10 X=JOY(1): A$=HEX$(255): B$=ERR$", dialect: extendedDialect), [])
    }

    func test_dialect_modifier_inside_v2_statement_is_tolerated() {
        XCTAssertEqual(messages("10 PRINT USING \"##.#\";X", dialect: extendedDialect), [])
    }

    func test_dialect_else_keyword() {
        XCTAssertEqual(messages("10 IF A THEN 20 ELSE 30\n20 END\n30 END", dialect: extendedDialect), [])
    }

    func test_dialect_trap_target_is_checked() {
        XCTAssertEqual(messages("10 TRAP 900", dialect: extendedDialect), ["Line 900 does not exist"])
    }

    func test_integer_for_counter_accepted_by_dialect() {
        XCTAssertEqual(messages("10 FOR I%=1 TO 3: NEXT", dialect: extendedDialect), [])
    }

    func test_v2_errors_still_reported_with_dialect() {
        XCTAssertEqual(messages("10 PRINT (1", dialect: extendedDialect), ["Expected ')'"])
    }

    func test_inline_assembly_region_is_skipped() {
        let src = """
        10 ASSEM
        20 [LDA #1: STA 53280]
        30 [RTS]
        40 BASIC
        50 PRINT "DONE"
        """
        XCTAssertEqual(messages(src, dialect: inlineAsmDialect), [])
    }

    func test_inline_assembly_line_numbers_still_tracked() {
        let src = """
        10 ASSEM
        20 [LDA #1: STA 53280]
        30 BASIC
        40 GOTO 20
        """
        XCTAssertEqual(messages(src, dialect: inlineAsmDialect), [])
    }
}
