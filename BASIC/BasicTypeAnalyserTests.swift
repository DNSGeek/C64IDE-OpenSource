import XCTest
@testable import C64IDE

// ═══════════════════════════════════════════════════════════
// MARK: - BasicTypeAnalyserTests
// ═══════════════════════════════════════════════════════════

final class BasicTypeAnalyserTests: XCTestCase {

    // ── Helpers ────────────────────────────────────────────

    private func analyse(_ source: String) -> SymbolTable {
        var p = BasicParser()
        let lines = p.parse(source)
        return BasicTypeAnalyser().analyse(lines)
    }

    private func typeOf(_ name: String, in source: String) -> VarType {
        analyse(source)[name]
    }

    // ═══════════════════════════════════════════════════════
    // MARK: 1. VarType lattice
    // ═══════════════════════════════════════════════════════

    func test_lattice_byte_widens_to_word()   { XCTAssertEqual(VarType.byte.widened(to: .word),  .word)  }
    func test_lattice_word_widens_to_float()  { XCTAssertEqual(VarType.word.widened(to: .float), .float) }
    func test_lattice_float_does_not_shrink() { XCTAssertEqual(VarType.float.widened(to: .byte), .float) }
    func test_lattice_byte_plus_sbyte_is_signed_byte() {
        XCTAssertEqual(VarType.byte.widened(to: .sbyte), .sbyte)
    }
    func test_lattice_string_absorbs_numeric() {
        XCTAssertEqual(VarType.string.widened(to: .byte), .string)
        XCTAssertEqual(VarType.byte.widened(to: .string), .string)
    }
    func test_lattice_idempotent() {
        XCTAssertEqual(VarType.word.widened(to: .word), .word)
    }

    // ═══════════════════════════════════════════════════════
    // MARK: 2. SymbolTable
    // ═══════════════════════════════════════════════════════

    func test_unknown_var_defaults_to_float() {
        XCTAssertEqual(SymbolTable()["X"], .float)
    }

    func test_widen_records_change() {
        var t = SymbolTable()
        XCTAssertTrue(t.widen("X", to: .byte))
        XCTAssertEqual(t["X"], .byte)
    }

    func test_widen_narrower_returns_false() {
        var t = SymbolTable()
        t.widen("X", to: .word)
        XCTAssertFalse(t.widen("X", to: .byte))
        XCTAssertEqual(t["X"], .word)
    }

    // ═══════════════════════════════════════════════════════
    // MARK: 3. Literal seeding
    // ═══════════════════════════════════════════════════════

    func test_literal_0_is_byte()      { XCTAssertEqual(typeOf("X", in: "10 X=0"),     .byte)  }
    func test_literal_255_is_byte()    { XCTAssertEqual(typeOf("X", in: "10 X=255"),   .byte)  }
    func test_literal_256_is_word()    { XCTAssertEqual(typeOf("X", in: "10 X=256"),   .word)  }
    func test_literal_53248_is_word()  { XCTAssertEqual(typeOf("V", in: "10 V=53248"), .word)  }
    func test_literal_float_is_float() { XCTAssertEqual(typeOf("X", in: "10 X=3.14"),  .float) }
    func test_negative_1_is_sbyte()    { XCTAssertEqual(typeOf("X", in: "10 X=-1"),    .sbyte) }
    func test_string_var_is_string()   { XCTAssertEqual(typeOf("A$", in: "10 A$=\"H\""), .string) }
    func test_percent_var_at_least_word() {
        XCTAssertEqual(typeOf("A%", in: "10 A%=5").width, .word)
    }

    // ═══════════════════════════════════════════════════════
    // MARK: 4. Propagation
    // ═══════════════════════════════════════════════════════

    func test_word_propagates_to_assigned_var() {
        let t = analyse("10 V=53248\n20 V0=V")
        XCTAssertEqual(t["V0"].width, .word)
    }

    func test_byte_var_stays_byte() {
        let t = analyse("10 S=1\n20 X=S")
        XCTAssertEqual(t["X"].width, .byte)
    }

    func test_word_plus_const_stays_word() {
        let t = analyse("10 V=53248\n20 V1=V+1")
        XCTAssertEqual(t["V1"].width, .word)
    }

    func test_propagation_chain() {
        let t = analyse("10 V=53248\n20 V0=V\n30 V1=V0+1")
        XCTAssertEqual(t["V"].width,  .word)
        XCTAssertEqual(t["V0"].width, .word)
        XCTAssertEqual(t["V1"].width, .word)
    }

    func test_multiple_assignments_widen() {
        let t = analyse("10 X=1\n20 X=1000")
        XCTAssertEqual(t["X"].width, .word)
    }

    func test_peek_always_returns_byte() {
        let t = analyse("10 JA=56320\n20 J=PEEK(JA)")
        XCTAssertEqual(t["J"].width, .byte)
    }

    func test_computed_word_address() {
        let t = analyse("10 PL=12288+64")
        XCTAssertEqual(t["PL"].width, .word)
    }

    // ═══════════════════════════════════════════════════════
    // MARK: 5. FOR loop bounds
    // ═══════════════════════════════════════════════════════

    func test_for_byte_loop() {
        XCTAssertEqual(analyse("10 FOR N=0 TO 62\n20 NEXT N")["N"].width, .byte)
    }

    func test_for_word_loop() {
        XCTAssertEqual(analyse("10 FOR W=1 TO 1000\n20 NEXT W")["W"].width, .word)
    }

    func test_for_negative_step_marks_signed() {
        XCTAssertTrue(analyse("10 FOR I=10 TO 1 STEP -1\n20 NEXT I")["I"].isSigned)
    }

    func test_for_positive_step_not_signed() {
        XCTAssertFalse(analyse("10 FOR N=0 TO 10 STEP 2\n20 NEXT N")["N"].isSigned)
    }

    // ═══════════════════════════════════════════════════════
    // MARK: 6. Function return types
    // ═══════════════════════════════════════════════════════

    func test_peek_returns_byte()   { XCTAssertEqual(analyse("10 X=PEEK(0)")["X"].width,   .byte)  }
    func test_asc_returns_byte()    { XCTAssertEqual(analyse("10 N=ASC(A$)")["N"].width,   .byte)  }
    func test_len_returns_word()    { XCTAssertEqual(analyse("10 N=LEN(A$)")["N"].width,   .word)  }
    func test_chr_returns_string()  { XCTAssertEqual(analyse("10 A$=CHR$(65)")["A$"],      .string) }
    func test_left_returns_string() { XCTAssertEqual(analyse("10 B$=LEFT$(A$,3)")["B$"],   .string) }
    func test_mid_returns_string()  { XCTAssertEqual(analyse("10 B$=MID$(A$,1,3)")["B$"], .string) }
    func test_right_returns_string(){ XCTAssertEqual(analyse("10 B$=RIGHT$(A$,1)")["B$"],  .string) }
    func test_str_returns_string()  { XCTAssertEqual(analyse("10 A$=STR$(X)")["A$"],       .string) }
    func test_int_returns_float()   { XCTAssertEqual(analyse("10 X=INT(3.7)")["X"],        .float)  }
    func test_abs_returns_float()   { XCTAssertEqual(analyse("10 X=ABS(Y)")["X"],          .float)  }

    // ═══════════════════════════════════════════════════════
    // MARK: 7. Signed inference
    // ═══════════════════════════════════════════════════════

    func test_unary_minus_marks_signed() {
        XCTAssertTrue(analyse("10 S=1\n20 ED=-S")["ED"].isSigned)
    }

    func test_subtraction_marks_signed() {
        XCTAssertTrue(analyse("10 X=A-B")["X"].isSigned)
    }

    func test_addition_not_signed() {
        XCTAssertFalse(analyse("10 X=1\n20 X=X+1")["X"].isSigned)
    }

    func test_comparison_returns_sword() {
        XCTAssertEqual(analyse("10 X=A=B")["X"], .sword)
    }

    func test_not_returns_sword() {
        XCTAssertEqual(analyse("10 X=NOT A")["X"], .sword)
    }

    // ═══════════════════════════════════════════════════════
    // MARK: 8. POKE widening
    // ═══════════════════════════════════════════════════════

    func test_poke_address_var_widens_to_word() {
        XCTAssertEqual(analyse("10 POKE V,15")["V"].width, .word)
    }

    func test_poke_address_expression_widens_base_var() {
        XCTAssertEqual(analyse("10 POKE V+21,15")["V"].width, .word)
    }

    func test_poke_value_not_widened() {
        let t = analyse("10 EX=120\n20 POKE 53281,EX")
        XCTAssertEqual(t["EX"].width, .byte)
    }

    // ═══════════════════════════════════════════════════════
    // MARK: 9. Comparison-driven widening
    // ═══════════════════════════════════════════════════════

    func test_comparison_widens_narrow_var_to_match_wide_var() {
        // TT=0 (byte), DE=500 (word). "TT>DE" → TT must become word.
        let t = analyse("10 TT=0\n20 DE=500\n30 IF TT>DE THEN END")
        XCTAssertEqual(t["TT"].width, .word, "TT must be word to compare with DE=500")
        XCTAssertEqual(t["DE"].width, .word)
    }

    func test_comparison_does_not_over_widen_byte_vs_byte() {
        // PX<24 → both byte, no widening
        let t = analyse("10 PX=120\n20 IF PX<24 THEN PX=24")
        XCTAssertEqual(t["PX"].width, .byte)
    }

    func test_comparison_byte_literal_does_not_widen_var() {
        let t = analyse("10 EX=120\n20 IF EX>220 THEN END")
        XCTAssertEqual(t["EX"].width, .byte)
    }

    // ═══════════════════════════════════════════════════════
    // MARK: 10. GET / INPUT string vars
    // ═══════════════════════════════════════════════════════

    func test_get_string_var()           { XCTAssertEqual(analyse("10 GET K$")["K$"],        .string) }
    func test_input_string_var()         { XCTAssertEqual(analyse("10 INPUT A$")["A$"],       .string) }
    func test_input_with_prompt_string() { XCTAssertEqual(analyse("10 INPUT \"N\";A$")["A$"], .string) }

    // ═══════════════════════════════════════════════════════
    // MARK: 11. Edge cases
    // ═══════════════════════════════════════════════════════

    func test_empty_program() {
        XCTAssertTrue(analyse("").types.isEmpty)
    }

    func test_rem_only_program() {
        XCTAssertTrue(analyse("10 REM nothing").types.isEmpty)
    }

    func test_power_expression_is_float() {
        XCTAssertEqual(analyse("10 X=2^8")["X"], .float)
    }

    func test_ti_sysvar_is_word() {
        XCTAssertEqual(analyse("10 X=TI")["X"].width, .word)
    }

    func test_st_sysvar_is_byte() {
        XCTAssertEqual(analyse("10 X=ST")["X"].width, .byte)
    }

    func test_boolean_flag_stays_byte_unsigned() {
        let t = analyse("10 SF=0\n20 SF=1\n30 SF=0")
        XCTAssertEqual(t["SF"].width, .byte)
        XCTAssertFalse(t["SF"].isSigned)
    }

    // ═══════════════════════════════════════════════════════
    // MARK: 12. READ target seeding from DATA pool width
    // ═══════════════════════════════════════════════════════

    func test_read_from_byte_data_stays_byte() {
        let t = analyse("10 DATA 1,2,3\n20 READ B")
        XCTAssertEqual(t["B"].width, .byte)
    }

    func test_read_from_word_data_widens_to_word() {
        let t = analyse("10 DATA 500\n20 READ W")
        XCTAssertEqual(t["W"].width, .word)
    }

    func test_read_from_float_data_widens_to_float() {
        let t = analyse("10 DATA 3.5\n20 READ F")
        XCTAssertEqual(t["F"].width, .float)
    }

    func test_read_from_negative_data_is_signed() {
        let t = analyse("10 DATA -5\n20 READ X")
        XCTAssertTrue(t["X"].isSigned)
    }

    func test_mixed_string_numeric_data_read_types() {
        let t = analyse("10 DATA \"SHIP\",120,500\n20 READ N$,X,W")
        XCTAssertEqual(t["N$"], .string)
        XCTAssertEqual(t["X"].width, .word, "widest numeric DATA item governs all numeric READs")
        XCTAssertEqual(t["W"].width, .word)
    }

    func test_string_data_items_do_not_widen_numeric_reads() {
        let t = analyse("10 DATA \"HELLO\",7\n20 READ A$,X")
        XCTAssertEqual(t["X"].width, .byte)
    }

    // ═══════════════════════════════════════════════════════
    // MARK: 13. Full invader.bas integration
    // ═══════════════════════════════════════════════════════

    func test_invader_full_program() {
        let source = """
        2 JA=56320: V=53248: SC=53278: DE=500: S=1
        3 V0=V:V1=V+1:V2=V+2:V3=V+3
        4 V4=V+4:V5=V+5:V6=V+6:V7=V+7
        13 R=247:L=251:U=254:D=253:F=239
        19 FOR N=0 TO 62: READ B: POKE 12288+N,B: NEXT
        21 PL=12288+64
        31 MS=PL+64
        41 ES=MS+64
        61 EX=120:EY=50
        62 PX=120:PY=150
        63 ED=S
        64 SF=0:TF=0
        65 SX=0:SY=255
        66 TX=0:TY=255
        67 TT=0
        87 GET K$: IF K$="" THEN GOTO 87
        103 FOR W=1 TO 1000
        108 NEXT W
        117 J=PEEK(JA)
        118 GET A$
        162 IF EX>220 THEN ED=-S
        163 IF EX<40 THEN ED=S
        171 TT=TT+1
        172 IF TT>DE AND TF=0 THEN TX=EX+8:TY=EY+26:TF=1:TT=0
        207 C=0:IF SF OR TF THEN C=PEEK(SC)
        """
        let t = analyse(source)

        // Word variables
        for (name, label) in [("JA","JA=56320"),("V","V=53248"),("SC","SC=53278"),
                               ("DE","DE=500"),("PL","PL=12288+64"),("MS","MS=PL+64"),
                               ("ES","ES=MS+64"),("W","FOR W=1 TO 1000"),
                               ("TT","TT compared vs DE=500"),
                               // TX is assigned EX+8 on line 172. Any addition
                               // widens to word (byte + byte can carry past
                               // 255), so TX is word despite only ever holding
                               // a sprite coordinate.
                               ("TX","TX=EX+8 — addition widens to word"),
                               ("TY","TY=EY+26 — addition widens to word")] {
            XCTAssertEqual(t[name].width, .word, "\(label) should be word")
        }
        for i in 0...7 {
            XCTAssertEqual(t["V\(i)"].width, .word, "V\(i) should be word")
        }

        // Byte variables
        for (name, label) in [("S","S=1"),("R","R=247"),("L","L=251"),("F","F=239"),
                               ("EX","EX=120"),("EY","EY=50"),("PX","PX=120"),("PY","PY=150"),
                               ("SF","SF=0/1"),("TF","TF=0/1"),("SX","SX=0"),("SY","SY=255"),
                               ("N","FOR N=0 TO 62"),
                               ("J","J=PEEK()"),("C","C=PEEK() or 0")] {
            XCTAssertEqual(t[name].width, .byte, "\(label) should be byte")
        }

        // Signed
        XCTAssertTrue(t["ED"].isSigned, "ED can be -S, must be signed")

        // Strings
        XCTAssertEqual(t["K$"], .string)
        XCTAssertEqual(t["A$"], .string)

        // THE KEY RESULT: zero float variables
        let floatVars = t.types.filter { $0.value.width == .float }
        XCTAssertTrue(floatVars.isEmpty,
            "invader.bas needs ZERO float variables. Got: \(floatVars.keys.sorted())")
    }
}

