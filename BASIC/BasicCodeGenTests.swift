// MARK: - BasicCodeGenTests.swift
//
// Unit tests for the BASIC-to-Assembly code generator.
// Verifies assembly output patterns, storage sizing, and type-driven code paths.
//
// Core Invariant:
//   Programs containing only byte/word variables must produce ZERO
//   ROM floating-point calls ($BBA2 MOVFM, $BBD4 MOVMF, $B867 FADD, etc.)

import XCTest
@testable import C64IDE

final class BasicCodeGenTests: XCTestCase {

    // MARK: - Helpers

    private func compile(_ source: String) -> String {
        let result = BasicCompilerV2.compile(source)
        return result.assembly ?? ""
    }

    private func asm(_ source: String) -> [String] {
        compile(source).components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func contains(_ source: String, _ pattern: String) -> Bool {
        compile(source).contains(pattern)
    }

    private func notContains(_ source: String, _ pattern: String) -> Bool {
        !compile(source).contains(pattern)
    }

    /// ROM addresses that indicate a floating-point operation.
    /// Used to verify that byte/word-only programs avoid the FAC entirely.
    private let floatROMPatterns = [
        "jsr $BBA2", "jsr $BBD4", "jsr $B867", "jsr $B850", "jsr $BA28",
        "jsr $BB0F", "jsr $BF7B", "jsr $BC5B", "jsr $B391", "jsr $B7F7",
        "jsr $BCCC"
    ]

    private func hasNoFloatCalls(_ source: String) -> Bool {
        let out = compile(source)
        return !floatROMPatterns.contains(where: { out.contains($0) })
    }

    // MARK: - Variable Storage Sizing

    func test_byte_var_gets_1_byte_storage() {
        let out = compile("10 X=5")
        XCTAssertTrue(out.contains("var_X: .res 1"), "Byte var should get 1-byte storage")
        XCTAssertFalse(out.contains("var_X: .res 5"), "Byte var must NOT get 5-byte float storage")
    }

    func test_word_var_gets_2_byte_storage() {
        let out = compile("10 V=53248")
        XCTAssertTrue(out.contains("var_V: .res 2"), "Word var should get 2-byte storage")
        XCTAssertFalse(out.contains("var_V: .res 5"), "Word var must NOT get 5-byte float storage")
    }

    func test_string_var_gets_256_byte_buffer() {
        let out = compile("10 GET K$")
        XCTAssertTrue(out.contains("var_K_str: .res 256"))
    }

    func test_float_var_gets_5_byte_storage() {
        let out = compile("10 X=3.14")
        XCTAssertTrue(out.contains("var_X: .res 5"), "Float var should get 5-byte storage")
    }

    // MARK: - Byte Assignment

    func test_byte_assign_literal_uses_lda_imm() {
        let out = compile("10 X=5")
        XCTAssertTrue(out.contains("lda #5"))
        XCTAssertTrue(out.contains("sta var_X"))
    }

    func test_byte_assign_no_float_calls() {
        XCTAssertTrue(hasNoFloatCalls("10 X=5"))
    }

    func test_byte_assign_variable_uses_lda() {
        let out = compile("10 S=1\n20 X=S")
        XCTAssertTrue(out.contains("lda var_S"))
        XCTAssertTrue(out.contains("sta var_X"))
    }

    // MARK: - Word Assignment

    func test_word_assign_uses_lo_hi() {
        let out = compile("10 V=53248")
        XCTAssertTrue(out.contains("lda #<53248") || out.contains("lda #<$D000"))
        XCTAssertTrue(out.contains("sta var_V"))
        XCTAssertTrue(out.contains("sta var_V+1") || out.contains("stx var_V+1"))
    }

    func test_word_assign_no_float_calls() {
        XCTAssertTrue(hasNoFloatCalls("10 V=53248"))
    }

    func test_word_propagation_no_float_calls() {
        XCTAssertTrue(hasNoFloatCalls("10 V=53248\n20 V0=V\n30 V1=V+1"))
    }

    // MARK: - POKE

    func test_poke_constant_addr_no_float_calls() {
        XCTAssertTrue(hasNoFloatCalls("10 POKE 53281,0"))
    }

    func test_poke_constant_addr_uses_sta() {
        let out = compile("10 POKE 53281,0")
        XCTAssertTrue(out.contains("sta $D081") || out.contains("sta 53281"))
    }

    func test_poke_variable_addr_uses_rt_poke() {
        let out = compile("10 V=53248\n20 POKE V,15")
        XCTAssertTrue(out.contains("jsr _rt_poke") || out.contains("_rt_poke"))
    }

    func test_poke_byte_value_no_float_calls() {
        XCTAssertTrue(hasNoFloatCalls("10 EX=120\n20 POKE 53248,EX"))
    }

    func test_poke_val_uses_byte_load() {
        let out = compile("10 EX=120\n20 POKE 53248,EX")
        XCTAssertTrue(out.contains("lda var_EX"))
        XCTAssertTrue(out.contains("sta _poke_val"))
    }

    // MARK: - GET

    func test_get_string_uses_getin() {
        let out = compile("10 GET K$")
        XCTAssertTrue(out.contains("jsr $FFE4"))
        XCTAssertTrue(out.contains("sta var_K_str"))
    }

    func test_get_string_no_float_calls() {
        XCTAssertTrue(hasNoFloatCalls("10 GET K$"))
    }

    func test_get_terminates_string() {
        let out = compile("10 GET K$")
        XCTAssertTrue(out.contains("sta var_K_str+1") ||
                      (out.contains("lda #0") && out.contains("var_K_str")))
    }

    // MARK: - Byte FOR/NEXT

    func test_byte_for_no_float_calls() {
        XCTAssertTrue(hasNoFloatCalls("10 FOR N=0 TO 62\n20 NEXT N"))
    }

    func test_byte_for_init_uses_lda_imm() {
        let out = compile("10 FOR N=0 TO 62\n20 NEXT N")
        XCTAssertTrue(out.contains("lda #0"))
        XCTAssertTrue(out.contains("sta var_N"))
    }

    func test_byte_for_next_uses_adc() {
        let out = compile("10 FOR N=0 TO 62\n20 NEXT N")
        XCTAssertTrue(out.contains("adc _for_step_N") || out.contains("inc var_N"))
        XCTAssertFalse(out.contains("jsr $B867"), "Byte NEXT must not use ROM FADD")
    }

    func test_byte_for_next_uses_cmp_not_fcomp() {
        let out = compile("10 FOR N=0 TO 62\n20 NEXT N")
        XCTAssertTrue(out.contains("cmp _for_limit_N"))
        XCTAssertFalse(out.contains("jsr $BC5B"), "Byte NEXT must not use ROM FCOMP")
    }

    func test_byte_for_stores_limit_as_byte() {
        let out = compile("10 FOR N=0 TO 62\n20 NEXT N")
        XCTAssertTrue(out.contains("_for_limit_N: .res 1"))
    }

    // MARK: - Word FOR/NEXT

    func test_word_for_no_float_calls() {
        XCTAssertTrue(hasNoFloatCalls("10 FOR W=1 TO 1000\n20 NEXT W"))
    }

    func test_word_for_stores_limit_as_word() {
        let out = compile("10 FOR W=1 TO 1000\n20 NEXT W")
        XCTAssertTrue(out.contains("_for_limit_W: .res 2"))
    }

    func test_word_for_uses_16bit_increment() {
        let out = compile("10 FOR W=1 TO 1000\n20 NEXT W")
        XCTAssertTrue(out.contains("adc _for_step_W"))
        XCTAssertTrue(out.contains("adc _for_step_W+1") || out.contains("var_W+1"))
    }

    func test_word_for_next_uses_word_compare() {
        let out = compile("10 FOR W=1 TO 1000\n20 NEXT W")
        XCTAssertTrue(out.contains("_for_limit_W+1") || out.contains("var_W+1"))
        XCTAssertFalse(out.contains("jsr $BC5B"), "Word NEXT must not use ROM FCOMP")
    }

    // MARK: - IF/THEN — Byte Comparison

    func test_if_byte_eq_uses_cmp_bne() {
        let out = compile("10 X=5\n20 IF X=5 THEN END")
        XCTAssertTrue(out.contains("lda var_X"))
        XCTAssertTrue(out.contains("cmp #5"))
        XCTAssertTrue(out.contains("bne "))
        XCTAssertFalse(out.contains("jsr $BC5B"), "Byte comparison must not use FCOMP")
    }

    func test_if_byte_comparison_no_float_calls() {
        XCTAssertTrue(hasNoFloatCalls("10 PX=120\n20 IF PX<24 THEN PX=24"))
    }

    func test_if_byte_var_as_bool_no_float() {
        XCTAssertTrue(hasNoFloatCalls("10 SF=0\n20 IF SF THEN END"))
    }

    func test_if_byte_var_bool_uses_lda_beq() {
        let out = compile("10 SF=0\n20 SF=1\n30 IF SF THEN END")
        XCTAssertTrue(out.contains("lda var_SF"))
        XCTAssertTrue(out.contains("beq "))
    }

    // MARK: - IF/THEN — String Comparison

    func test_if_string_eq_uses_strcmp() {
        let out = compile("10 GET K$\n20 IF K$=\"\" THEN GOTO 10")
        XCTAssertTrue(out.contains("jsr _rt_strcmp"))
        XCTAssertTrue(out.contains("bne "))
    }

    func test_if_string_comparison_no_float_calls() {
        XCTAssertTrue(hasNoFloatCalls("10 GET K$\n20 IF K$=\"\" THEN GOTO 10"))
    }

    // MARK: - IF/THEN — AND/OR Short-Circuit

    func test_if_and_short_circuits() {
        let out = compile("10 SF=1\n20 TF=0\n30 IF SF=1 AND TF=0 THEN END")
        XCTAssertTrue(out.contains("lda var_SF"))
        XCTAssertTrue(out.contains("lda var_TF"))
        XCTAssertFalse(out.contains("jsr $B391"), "AND must not use ROM INTFAC")
    }

    func test_if_or_short_circuits() {
        let out = compile("10 SF=0\n20 TF=1\n30 IF SF OR TF THEN END")
        XCTAssertTrue(out.contains("lda var_SF") || out.contains("lda var_TF"))
        XCTAssertFalse(out.contains("$B391"))
    }

    // MARK: - PRINT

    func test_print_string_literal_uses_print_str() {
        let out = compile("10 PRINT \"HELLO\"")
        XCTAssertTrue(out.contains("jsr _print_str"))
    }

    func test_print_chr_uses_chrout_directly() {
        let out = compile("10 PRINT CHR$(147)")
        XCTAssertTrue(out.contains("jsr $FFD2"))
        XCTAssertTrue(out.contains("lda #147") || out.contains("#$93"))
    }

    func test_print_no_newline_semicolon() {
        let out = compile("10 PRINT \"#\";")
        XCTAssertFalse(out.contains("lda #$0D"), "Trailing semicolon must suppress newline")
    }

    func test_print_with_newline_emits_cr() {
        let out = compile("10 PRINT \"HI\"")
        XCTAssertTrue(out.contains("lda #$0D"))
        XCTAssertTrue(out.contains("jsr $FFD2"))
    }

    // MARK: - DATA / READ

    func test_byte_data_stored_as_bytes_not_floats() {
        let out = compile("10 DATA 0,0,96\n20 READ B")
        XCTAssertTrue(out.contains("_data_table:"))
        XCTAssertTrue(out.contains(".byte 0") || out.contains(".byte 96"))
        XCTAssertFalse(out.contains(".byte $8E"), "Byte data must not use float encoding")
    }

    func test_byte_read_uses_indexed_access() {
        let out = compile("10 B=0\n20 DATA 42\n30 READ B")
        XCTAssertTrue(out.contains("lda _data_table,y") || out.contains("_data_table"))
        XCTAssertFalse(out.contains("jsr $BBA2"), "Byte READ must not use ROM MOVFM")
    }

    func test_data_ptr_advances_by_1_for_byte_data() {
        let out = compile("10 B=0\n20 DATA 1,2,3\n30 READ B")
        XCTAssertTrue(out.contains("inc _data_ptr"))
        XCTAssertFalse(out.contains("adc #5"), "Byte READ must not advance by 5")
    }

    // MARK: - GOTO / GOSUB

    func test_goto_emits_jmp() {
        let out = compile("10 GOTO 10")
        XCTAssertTrue(out.contains("jmp line_10"))
    }

    func test_gosub_emits_jsr() {
        let out = compile("10 GOSUB 100\n100 RETURN")
        XCTAssertTrue(out.contains("jsr line_100"))
    }

    func test_return_emits_rts() {
        let out = compile("10 RETURN")
        XCTAssertTrue(out.contains("rts"))
    }

    func test_dangling_goto_still_emits_jmp() {
        let out = compile("10 GOTO 999")
        XCTAssertTrue(out.contains("jmp line_999"))
    }

    // MARK: - ON GOTO / GOSUB

    func test_on_goto_emits_cmp_sequence() {
        let out = compile("10 X=1\n20 ON X GOTO 10,20,30")
        XCTAssertTrue(out.contains("cmp #1"))
        XCTAssertTrue(out.contains("jmp line_10") || out.contains("jmp line_20"))
    }

    // MARK: - SYS

    func test_sys_uses_rt_sys() {
        let out = compile("10 SYS 2048")
        XCTAssertTrue(out.contains("jsr _rt_sys"))
    }

    // MARK: - Full Program Verification (invader.bas pattern)

    func test_invader_zero_float_ROM_calls() {
        let source = """
        2 JA=56320: V=53248: SC=53278: DE=500: S=1
        3 V0=V:V1=V+1:V2=V+2:V3=V+3
        4 V4=V+4:V5=V+5:V6=V+6:V7=V+7
        13 R=247:L=251:U=254:D=253:F=239
        19 FOR N=0 TO 62: READ B: POKE 12288+N,B: NEXT
        21 PL=12288+64
        31 MS=PL+64
        41 ES=MS+64
        51 POKE V+21,15
        61 EX=120:EY=50
        62 PX=120:PY=150
        63 ED=S
        64 SF=0:TF=0
        65 SX=0:SY=255
        66 TX=0:TY=255
        67 TT=0
        87 GET K$: IF K$="" THEN GOTO 87
        103 FOR W=1 TO 1000
        106 PRINT "#";
        108 NEXT W
        117 J=PEEK(JA)
        118 GET A$
        127 IF J=L OR A$="A" THEN PX=PX-8
        129 IF J=R OR A$="D" THEN PX=PX+8
        131 IF PX<24 THEN PX=24
        132 IF PX>230 THEN PX=230
        142 IF (J=F OR A$=" ") AND SF=0 THEN SX=PX:SY=PY-8:SF=1
        151 IF SF=1 THEN SY=SY-8
        152 IF SY<20 THEN SF=0:SX=0:SY=255
        161 EX=EX+ED
        162 IF EX>220 THEN ED=-S
        163 IF EX<40 THEN ED=S
        171 TT=TT+1
        172 IF TT>DE AND TF=0 THEN TX=EX+8:TY=EY+26:TF=1:TT=0
        181 IF TF=1 THEN TY=TY+S
        182 IF TY>170 THEN TF=0:TX=0:TY=255
        191 POKE V0,EX: POKE V1,EY
        192 POKE V2,PX: POKE V3,PY
        193 POKE V4,SX: POKE V5,SY
        194 POKE V6,TX: POKE V7,TY
        207 C=0:IF SF OR TF THEN C=PEEK(SC)
        208 IF SF=1 AND (C AND 5)=5 THEN PRINT "ENEMY HIT":SF=0:SX=0:SY=255
        209 IF TF=1 AND (C AND 10)=10 THEN PRINT "PLAYER HIT":TF=0:TX=0:TY=255
        210 GOTO 110
        """

        let out = compile(source)

        for rom in ["$BBA2", "$BBD4", "$B867", "$B850", "$BA28",
                    "$BB0F", "$BC5B", "$B391", "$B7F7"] {
            XCTAssertFalse(out.contains(rom),
                "invader.bas must not use ROM float routine \(rom)")
        }

        XCTAssertTrue(out.contains("var_EX: .res 1"), "EX should be byte")
        XCTAssertTrue(out.contains("var_PX: .res 1"), "PX should be byte")
        XCTAssertTrue(out.contains("var_SF: .res 1"), "SF should be byte")
        XCTAssertTrue(out.contains("var_N: .res 1"),  "N should be byte")
        XCTAssertTrue(out.contains("var_B: .res 1"),  "B should be byte")

        XCTAssertTrue(out.contains("var_V: .res 2"),  "V should be word")
        XCTAssertTrue(out.contains("var_JA: .res 2"), "JA should be word")
        XCTAssertTrue(out.contains("var_DE: .res 2"), "DE should be word")
        XCTAssertTrue(out.contains("var_W: .res 2"),  "W should be word")

        XCTAssertFalse(out.contains(".byte $8E"),
            "Sprite DATA must use byte encoding, not 5-byte float")

        XCTAssertTrue(out.contains("_for_limit_N: .res 1"))
        XCTAssertTrue(out.contains("_for_limit_W: .res 2"))

        XCTAssertTrue(out.contains(".word $0801"))
        XCTAssertTrue(out.contains("_start:"))
    }

    // MARK: - Float Path Verification

    func test_float_var_uses_ROM_movmf() {
        let out = compile("10 X=3.14")
        XCTAssertTrue(out.contains("$BBD4") || out.contains("ROM_MOVMF"))
    }

    func test_print_float_uses_prntfac() {
        let out = compile("10 X=3.14\n20 PRINT X")
        XCTAssertTrue(out.contains("$BDCD") || out.contains("ROM_PRNTFAC"))
    }

    func test_float_arithmetic_uses_fadd() {
        let out = compile("10 X=3.14\n20 Y=X+1.5")
        XCTAssertTrue(out.contains("$B867") || out.contains("ROM_FADD"))
    }

    // MARK: - Runtime Library Presence

    func test_runtime_has_print_str() {
        XCTAssertTrue(compile("10 PRINT \"X\"").contains("_print_str:"))
    }

    func test_runtime_has_peek_byte() {
        XCTAssertTrue(compile("10 X=PEEK(0)").contains("_rt_peek_byte:"))
    }

    func test_runtime_has_poke() {
        XCTAssertTrue(compile("10 POKE 0,0").contains("_rt_poke:"))
    }

    // The self-modifying PEEK/POKE templates must stay 3 bytes wide. Without
    // the `a:` prefix ca65 folds $0000 into zero page, `sta @pk+2` then lands
    // on the following rts, and the first PEEK runs off into a BRK.
    func test_peek_template_forces_absolute() {
        XCTAssertTrue(compile("10 X=PEEK(53265)").contains("lda a:$0000"))
    }

    func test_poke_template_forces_absolute() {
        XCTAssertTrue(compile("10 POKE 53280,0").contains("sta a:$0000"))
    }

    // {$XX} escapes must reach the PRG as raw bytes, not as the five
    // characters `{`, `$`, `9`, `3`, `}`.
    func test_string_literal_decodes_petscii_escape() {
        let asm = compile("10 PRINT \"{$93}HI\"")
        XCTAssertTrue(asm.contains("$93, $48, $49, $00"))
        XCTAssertFalse(asm.contains("$7B, $24"))
    }

    func test_runtime_has_strcmp() {
        XCTAssertTrue(compile("10 GET K$: IF K$=\"\" THEN GOTO 10").contains("_rt_strcmp:"))
    }

    func test_runtime_has_data_table() {
        XCTAssertTrue(compile("10 DATA 1,2,3\n20 READ B").contains("_data_table:"))
    }

    // MARK: - Mixed String/Numeric DATA

    func test_mixed_data_emits_tagged_table_with_all_tags() {
        let out = compile("10 DATA \"SHIP\",120,500,3.5\n20 READ N$,X,W,F")
        XCTAssertTrue(out.contains("_data_table:"))
        XCTAssertTrue(out.contains(".byte $00,"), "byte item should carry tag $00")
        XCTAssertTrue(out.contains(".byte $01,"), "word item should carry tag $01")
        XCTAssertTrue(out.contains(".byte $02,"), "float item should carry tag $02")
        XCTAssertTrue(out.contains(".byte $03,"), "string item should carry tag $03")
    }

    func test_mixed_data_numeric_read_uses_tagged_reader() {
        let out = compile("10 DATA \"A\",7\n20 READ A$,X")
        XCTAssertTrue(out.contains("jsr _rt_data_read_num"),
                      "numeric READ from mixed DATA must call the tagged reader")
        XCTAssertTrue(out.contains("jsr _rt_data_read_str"))
        XCTAssertTrue(out.contains("_rt_data_read_num:"),
                      "tagged numeric reader must be emitted in the runtime")
    }

    func test_mixed_data_numeric_read_compiles_without_warning() {
        let result = BasicCompilerV2.compile("10 DATA \"A\",7\n20 READ A$,X")
        XCTAssertTrue(result.success)
        XCTAssertFalse(result.warnings.contains(where: { $0.contains("not supported") }),
                       "mixed READ must no longer emit the unsupported warning")
        XCTAssertFalse(result.assembly?.contains("READ of numeric") ?? true)
    }

    func test_mixed_data_byte_target_stores_via_ayint() {
        // Hint stays byte (only numeric DATA item is 7), so the store
        // path after the tagged reader is the AYINT lo-byte store.
        let out = compile("10 DATA \"A\",7\n20 READ A$,X")
        XCTAssertTrue(out.contains("jsr $B1BF"), "byte store from FAC uses AYINT")
    }

    func test_mixed_data_wide_item_widens_read_target_storage() {
        // DATA contains 500, so numeric READ targets must be at least
        // word-sized: the old byte seeding truncated 500 to 244.
        let out = compile("10 DATA \"E\",500\n20 READ A$,W")
        XCTAssertTrue(out.contains("var_W: .res 2"),
                      "READ target must widen to word when DATA holds a word item")
    }

    func test_pure_numeric_wide_data_widens_read_target() {
        // Same latent truncation existed without strings in the picture.
        let out = compile("10 DATA 500\n20 READ W")
        XCTAssertTrue(out.contains("var_W: .res 2"))
    }

    func test_byte_only_data_keeps_fast_path() {
        // Regression guard: all-byte DATA must not pay the tagged-stream
        // or float-table cost.
        let out = compile("10 DATA 1,2,3\n20 READ B")
        XCTAssertFalse(out.contains("_rt_data_read_num"))
        XCTAssertTrue(out.contains("lda _data_table,y"))
        XCTAssertTrue(out.contains("var_B: .res 1"))
    }

    // MARK: - Large Byte DATA Tables (16-bit data pointer)

    /// Builds a program with `count` byte DATA items split across lines
    /// (BASIC lines have length limits; 40 items per line is safe).
    private func byteDataProgram(count: Int, readLine: String) -> String {
        var lines: [String] = []
        var lineNo = 10
        var i = 0
        while i < count {
            let chunk = (i..<min(i + 40, count)).map { String($0 % 256) }
            lines.append("\(lineNo) DATA \(chunk.joined(separator: ","))")
            lineNo += 10
            i += 40
        }
        lines.append("\(lineNo) \(readLine)")
        return lines.joined(separator: "\n")
    }

    func test_small_byte_table_does_not_emit_wide_reader() {
        let out = compile(byteDataProgram(count: 256, readLine: "READ B"))
        XCTAssertFalse(out.contains("_rt_data_get_byte"),
                       "256 items or fewer must keep the Y-indexed fast path")
        XCTAssertTrue(out.contains("lda _data_table,y"))
    }

    func test_large_byte_table_uses_16bit_pointer() {
        let out = compile(byteDataProgram(count: 300, readLine: "READ B"))
        XCTAssertTrue(out.contains("jsr _rt_data_get_byte"),
                      "tables over 256 bytes must use the 16-bit reader")
        XCTAssertTrue(out.contains("_rt_data_get_byte:"),
                      "16-bit reader routine must be emitted")
        XCTAssertTrue(out.contains("inc _data_ptr+1"),
                      "pointer advance must carry into the high byte")
        XCTAssertFalse(out.contains("ldy _data_ptr"),
                       "large tables must not use low-byte-only indexing")
    }

    func test_large_byte_table_word_target_zero_extends() {
        let out = compile(byteDataProgram(count: 300, readLine: "READ W\n9000 W=W+1000"))
        XCTAssertTrue(out.contains("jsr _rt_data_get_byte"))
        XCTAssertTrue(out.contains("var_W: .res 2"))
    }

    func test_byte_table_float_target_converts_via_givayf() {
        // Propagation widens X to float; the byte table must convert
        // the fetched byte via GIVAYF, not misread raw bytes as MFLPT
        // floats (the old else-branch did exactly that, advancing by 5).
        let out = compile("10 DATA 10,20\n20 READ X\n30 X=X+0.5")
        XCTAssertTrue(out.contains("var_X: .res 5"), "X should be float-typed")
        XCTAssertTrue(out.contains("lda _data_table,y"), "fetch stays on the byte path")
        XCTAssertTrue(out.contains("jsr $B391"), "byte converts to FAC via GIVAYF")
        XCTAssertFalse(out.contains("adc #5"), "byte table must never advance by 5")
    }
}

