// MARK: - AsmSyntaxCheckerTests.swift
//
// Tests for the ca65 line-level syntax checker.

import XCTest
@testable import C64IDE

final class AsmSyntaxCheckerTests: XCTestCase {

    private func check(_ source: String) -> [SyntaxDiagnostic] {
        AsmSyntaxChecker().check(source)
    }

    private func messages(_ source: String) -> [String] {
        check(source).map(\.message)
    }

    // MARK: - Clean code

    func test_clean_program_has_no_diagnostics() {
        let src = """
                .org $0801
                .byte $0B, $08, $0A, $00, $9E, "2061", $00, $00, $00
        BORDER  = $D020
        start:
                lda #$00        ; black
                sta BORDER
                ldx #<msg
                ldy #>msg
        @loop:  lda msg,x
                beq done
                jsr $FFD2
                inx
                bne @loop
        done:   jmp ($FFFC)
                asl
                asl a
                lda (ptr),y
                sta (ptr,x)
                stx $10,y
                ldx $D000,y
                lda foo::bar,x
                bne :+
        :       rts
        msg:    .asciiz "HELLO"
        ptr:    .res 2
        """
        XCTAssertEqual(messages(src), [])
    }

    func test_comment_only_and_blank_lines() {
        XCTAssertEqual(messages("; a comment\n\n   ; another\n"), [])
    }

    // MARK: - Addressing modes

    func test_store_immediate_is_invalid() {
        let diags = check("  sta #1")
        XCTAssertEqual(diags.count, 1)
        XCTAssertTrue(diags[0].message.contains("immediate"), diags[0].message)
        XCTAssertEqual(diags[0].column, 6)
    }

    func test_ldx_indirect_y_is_invalid() {
        XCTAssertEqual(check("  ldx ($10),y").count, 1)
    }

    func test_jsr_indirect_is_invalid() {
        XCTAssertEqual(check("  jsr ($1000)").count, 1)
    }

    func test_inc_accumulator_is_invalid_on_6502() {
        XCTAssertEqual(check("  inc a").count, 1)
    }

    func test_bare_lda_needs_operand() {
        XCTAssertEqual(messages("  lda"), ["LDA needs an operand"])
    }

    func test_wrong_paren_placement_gets_hint() {
        XCTAssertTrue(messages("  lda ($10),x")[0].contains("(addr,X)"))
        XCTAssertTrue(messages("  lda ($10,y)")[0].contains("(addr),Y"))
    }

    func test_z_index_needs_other_cpu() {
        XCTAssertTrue(messages("  lda ($10),z")[0].contains("6502"))
    }

    // MARK: - Ranges

    func test_immediate_over_255() {
        XCTAssertTrue(messages("  lda #$100")[0].contains("byte"))
        XCTAssertTrue(messages("  lda #256")[0].contains("byte"))
        XCTAssertEqual(messages("  lda #%11111111"), [])
        XCTAssertEqual(messages("  lda #'A'"), [])
    }

    func test_zero_page_only_indexed_mode_with_absolute_literal() {
        XCTAssertTrue(messages("  stx $D000,y")[0].contains("zero-page"))
        XCTAssertTrue(messages("  sty $D000,x")[0].contains("zero-page"))
        XCTAssertEqual(messages("  ldx $D000,y"), [])
    }

    func test_indirect_with_absolute_literal() {
        XCTAssertTrue(messages("  lda ($1000),y")[0].contains("zero-page"))
    }

    func test_address_beyond_ffff() {
        XCTAssertTrue(messages("  lda $10000")[0].contains("$FFFF"))
    }

    func test_symbolic_operands_are_not_range_checked() {
        XCTAssertEqual(messages("  lda #<label\n  lda #>label\n  stx label,y"), [])
    }

    // MARK: - CPUs

    func test_undocumented_opcode_requires_6502x() {
        XCTAssertTrue(messages("  slo $10")[0].contains("6502X"))
        XCTAssertEqual(messages("  .setcpu \"6502X\"\n  slo $10"), [])
    }

    func test_65c02_mnemonic_on_6502() {
        XCTAssertEqual(check("  phx").count, 1)
        XCTAssertEqual(messages("  .pc02\n  phx\n  stz $10"), [])
    }

    func test_other_cpu_disables_mode_checks() {
        XCTAssertEqual(messages("  .setcpu \"4510\"\n  lda ($10),z\n  inc a\n  bra done"), [])
    }

    // MARK: - Labels, macros, unknown words

    func test_label_without_colon_at_column_zero() {
        let msgs = messages("start lda #1")
        XCTAssertEqual(msgs.count, 1)
        XCTAssertTrue(msgs[0].contains("add ':'"), msgs[0])
    }

    func test_label_without_colon_feature() {
        XCTAssertEqual(messages(".feature labels_without_colons\nstart lda #1\nloop\n  jmp loop"), [])
    }

    func test_unknown_word_is_silent_when_file_includes_others() {
        XCTAssertEqual(messages("  .include \"macros.inc\"\n  setborder 1"), [])
        XCTAssertEqual(messages("  .macpack generic\n  add #1"), [])
    }

    func test_unknown_word_reported_without_includes() {
        XCTAssertEqual(check("  setborder 1").count, 1)
    }

    func test_macro_defined_in_file_is_known() {
        let src = """
        .macro setborder color
          lda #color
          sta $D020
        .endmacro
          setborder 2
        .define WIDTH 40
        """
        XCTAssertEqual(messages(src), [])
    }

    func test_enum_and_struct_members_are_not_instructions() {
        let src = """
        .enum Colors
          black
          white = 1
        .endenum
        .struct Point
          xcoord .byte
          ycoord .byte
        .endstruct
          lda #Colors::white
        """
        XCTAssertEqual(messages(src), [])
    }

    func test_symbol_assignments() {
        XCTAssertEqual(messages("foo = 5\nbar := $D020\nbaz .set 3"), [])
    }

    func test_acme_style_pc_assignment() {
        XCTAssertTrue(messages("* = $0801")[0].contains(".org"))
    }

    // MARK: - Directives and lexical problems

    func test_unknown_directive() {
        XCTAssertEqual(messages("  .bogus 1"), ["Unknown directive .bogus"])
        XCTAssertEqual(messages("  .rodata\n  .zeropage\n  .segment \"CODE\""), [])
    }

    func test_unterminated_string() {
        let diags = check("  .byte \"abc")
        XCTAssertEqual(diags.map(\.message), ["Unterminated string"])
        XCTAssertEqual(diags[0].column, 8)
    }

    func test_semicolon_inside_string_is_not_a_comment() {
        XCTAssertEqual(messages("  .byte \"a;b\"  ; real comment"), [])
    }

    func test_malformed_numbers() {
        XCTAssertEqual(messages("  lda $zz"), ["Malformed hex number"])
        XCTAssertEqual(messages("  lda #%102"), ["Malformed binary number"])
        XCTAssertEqual(messages("  .feature dollar_is_pc\n  jmp $"), [])
    }

    func test_unbalanced_parens() {
        XCTAssertEqual(messages("  lda ($10,x"), ["Missing closing parenthesis"])
        XCTAssertEqual(messages("  lda $10)"), ["Unmatched closing parenthesis"])
    }
}
