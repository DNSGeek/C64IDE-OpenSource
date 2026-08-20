import XCTest
// Replace with your actual open-source module name
@testable import C64IDE

// MARK: - BasicShortcutExpanderTests

final class BasicShortcutExpanderTests: XCTestCase {

    // ── Helpers ────────────────────────────────────────────

    private func expand(_ src: String, dialect: BasicDialect? = nil) -> String {
        BasicShortcutExpander.expand(src, dialect: dialect)
    }

    /// Builds a minimal `BasicDialect` with just a shortcuts table for override tests.
    /// Relies on `BasicDialect` conforming to a standard JSON schema.
    private func dialectWithShortcuts(
        _ shortcuts: [BasicShortcutExpander.Shortcut]
    ) -> BasicDialect {
        let shortcutsJSON = shortcuts
            .map { "{\"shortcut\":\"\($0.shortcut)\",\"keyword\":\"\($0.keyword)\"}" }
            .joined(separator: ",")
        let json = """
        {
            "name": "Test",
            "keywords": [],
            "shortcuts": [\(shortcutsJSON)]
        }
        """
        return try! JSONDecoder().decode(BasicDialect.self, from: Data(json.utf8))
    }

    // ═══════════════════════════════════════════════════════
    // MARK: 1. Basic ? → PRINT Expansion
    // ═══════════════════════════════════════════════════════

    func test_question_at_start_of_line() {
        XCTAssertEqual(expand("10 ?\"HI\""), "10 PRINT\"HI\"")
    }

    func test_question_after_colon() {
        XCTAssertEqual(expand("10 A=1:?A"), "10 A=1:PRINT A")
    }

    func test_question_followed_by_variable_inserts_space() {
        XCTAssertEqual(expand("10 ?X"), "10 PRINT X")
    }

    func test_question_followed_by_number_inserts_space() {
        XCTAssertEqual(expand("10 ?42"), "10 PRINT 42")
    }

    func test_question_followed_by_operator_no_space() {
        XCTAssertEqual(expand("10 ?-1"), "10 PRINT-1")
    }

    func test_question_followed_by_string_no_space() {
        XCTAssertEqual(expand("10 ?\"HI\""), "10 PRINT\"HI\"")
    }

    func test_question_followed_by_space_preserved() {
        XCTAssertEqual(expand("10 ? X"), "10 PRINT X")
    }

    func test_empty_source() {
        XCTAssertEqual(expand(""), "")
    }

    func test_source_with_no_shortcuts() {
        let src = "10 PRINT \"HELLO\"\n20 GOTO 10"
        XCTAssertEqual(expand(src), src)
    }

    // ═══════════════════════════════════════════════════════
    // MARK: 2. Multi-line Preservation
    // ═══════════════════════════════════════════════════════

    func test_multiline_expansion() {
        let src = """
        10 ?\"A\"
        20 ?\"B\"
        30 ?\"C\"
        """
        let expected = """
        10 PRINT\"A\"
        20 PRINT\"B\"
        30 PRINT\"C\"
        """
        XCTAssertEqual(expand(src), expected)
    }

    func test_preserves_blank_lines() {
        let src = "10 ?A\n\n20 ?B"
        XCTAssertEqual(expand(src), "10 PRINT A\n\n20 PRINT B")
    }

    func test_preserves_leading_whitespace() {
        XCTAssertEqual(expand("    10 ?X"), "    10 PRINT X")
    }

    // ═══════════════════════════════════════════════════════
    // MARK: 3. String Literal Protection
    // ═══════════════════════════════════════════════════════

    func test_question_inside_string_preserved() {
        XCTAssertEqual(
            expand("10 PRINT \"WHAT IS YOUR NAME?\""),
            "10 PRINT \"WHAT IS YOUR NAME?\""
        )
    }

    func test_question_mark_string_preserved_with_expansion_after() {
        XCTAssertEqual(
            expand("10 ?\"WHO?\":?\"ME\""),
            "10 PRINT\"WHO?\":PRINT\"ME\""
        )
    }

    func test_multiple_strings_with_question_marks() {
        XCTAssertEqual(
            expand("10 ?\"A?\";\"B?\";\"C?\""),
            "10 PRINT\"A?\";\"B?\";\"C?\""
        )
    }

    func test_unclosed_string_at_end_of_line_resets() {
        // Line ends while string still open — newline forces reset
        // so the next line's ? can still expand.
        XCTAssertEqual(
            expand("10 PRINT \"OOPS\n20 ?X"),
            "10 PRINT \"OOPS\n20 PRINT X"
        )
    }

    // ═══════════════════════════════════════════════════════
    // MARK: 4. REM Protection
    // ═══════════════════════════════════════════════════════

    func test_question_inside_rem_preserved() {
        XCTAssertEqual(
            expand("10 REM ? MEANS UNKNOWN"),
            "10 REM ? MEANS UNKNOWN"
        )
    }

    func test_rem_lowercase_also_protected() {
        XCTAssertEqual(
            expand("10 rem ? is skipped"),
            "10 rem ? is skipped"
        )
    }

    func test_rem_followed_by_letter_not_treated_as_rem() {
        // "REMARK" is a variable name, not REM.
        XCTAssertEqual(
            expand("10 REMARK=?"),
            "10 REMARK=PRINT"
        )
    }

    func test_rem_next_line_still_expands() {
        XCTAssertEqual(
            expand("10 REM ?\n20 ?X"),
            "10 REM ?\n20 PRINT X"
        )
    }

    // ═══════════════════════════════════════════════════════
    // MARK: 5. DATA Protection
    // ═══════════════════════════════════════════════════════

    func test_question_inside_data_preserved() {
        XCTAssertEqual(
            expand("10 DATA ?,HELLO,?"),
            "10 DATA ?,HELLO,?"
        )
    }

    func test_data_ends_at_colon() {
        // DATA body ends at the colon — the ? after it should expand.
        XCTAssertEqual(
            expand("10 DATA A,B,C:?X"),
            "10 DATA A,B,C:PRINT X"
        )
    }

    func test_data_followed_by_letter_not_treated_as_data() {
        // "DATABASE" is a variable (though truncated by BASIC V2).
        XCTAssertEqual(
            expand("10 DATABASE=?"),
            "10 DATABASE=PRINT"
        )
    }

    func test_data_with_quoted_strings() {
        XCTAssertEqual(
            expand("10 DATA \"?\",\"HELLO?\""),
            "10 DATA \"?\",\"HELLO?\""
        )
    }

    // ═══════════════════════════════════════════════════════
    // MARK: 6. Dialect Overrides
    // ═══════════════════════════════════════════════════════

    func test_dialect_can_override_universal() {
        let d = dialectWithShortcuts([
            .init(shortcut: "?", keyword: "PRINT#15,")
        ])
        XCTAssertEqual(
            expand("10 ?\"X\"", dialect: d),
            "10 PRINT#15,\"X\""
        )
    }

    func test_dialect_adds_new_shortcut() {
        let d = dialectWithShortcuts([
            .init(shortcut: "!", keyword: "INPUT")
        ])
        // Both `?` (universal) and `!` (dialect) work:
        XCTAssertEqual(
            expand("10 ?X:!Y", dialect: d),
            "10 PRINT X:INPUT Y"
        )
    }

    func test_nil_dialect_uses_only_universal() {
        XCTAssertEqual(expand("10 ?X", dialect: nil), "10 PRINT X")
    }

    func test_empty_dialect_shortcuts_uses_only_universal() {
        let d = dialectWithShortcuts([])
        XCTAssertEqual(expand("10 ?X", dialect: d), "10 PRINT X")
    }

    // ═══════════════════════════════════════════════════════
    // MARK: 7. Longest-First Ordering
    // ═══════════════════════════════════════════════════════

    func test_longer_shortcut_wins_over_shorter() {
        // If both `?` → PRINT and `??` → PRINT# existed, `??` should match.
        let d = dialectWithShortcuts([
            .init(shortcut: "??", keyword: "PRINT#")
        ])
        // The expander inserts a separating space when a shortcut is glued to
        // a following alphanumeric, so `??1` becomes `PRINT# 1`. The ROM
        // tokenizer accepts either form.
        XCTAssertEqual(
            expand("10 ??1,\"X\"", dialect: d),
            "10 PRINT# 1,\"X\""
        )
    }

    func test_shorter_shortcut_still_matches_on_its_own() {
        let d = dialectWithShortcuts([
            .init(shortcut: "??", keyword: "PRINT#")
        ])
        XCTAssertEqual(
            expand("10 ?X", dialect: d),
            "10 PRINT X"
        )
    }

    // ═══════════════════════════════════════════════════════
    // MARK: 8. Letter-Terminated Shortcut Lookahead Guard
    // ═══════════════════════════════════════════════════════

    func test_letter_shortcut_not_matched_inside_identifier() {
        // Hypothetical future shortcut `pO` → `POKE`.
        // `pO` in isolation expands; `pOst` does not (it's the var "POST").
        let d = dialectWithShortcuts([
            .init(shortcut: "pO", keyword: "POKE")
        ])
        XCTAssertEqual(
            expand("10 pO 53280,0", dialect: d),
            "10 POKE 53280,0"
        )
        XCTAssertEqual(
            expand("10 pOst=1", dialect: d),
            "10 pOst=1"
        )
    }

    // ═══════════════════════════════════════════════════════
    // MARK: 9. Edge Cases
    // ═══════════════════════════════════════════════════════

    func test_consecutive_question_marks_both_expand() {
        // `??` with no dialect override: two separate ? matches. Produces
        // `PRINTPRINT` — no space because the space-insertion rule only
        // fires before letters/digits, and `?` is neither. This is still
        // syntactically broken BASIC, but so was `??`; the expander's job
        // is faithful expansion, not error correction.
        XCTAssertEqual(expand("10 ??"), "10 PRINTPRINT")
    }

    func test_question_inside_deeply_nested_context() {
        let src = "10 IF A=1 THEN ?\"YES\":GOTO 20"
        let exp = "10 IF A=1 THEN PRINT\"YES\":GOTO 20"
        XCTAssertEqual(expand(src), exp)
    }

    func test_all_protected_contexts_together() {
        let src = """
        10 REM ? MEANS UNKNOWN
        20 DATA ?,?,?
        30 ?\"WHAT?\";
        40 ?X
        """
        let exp = """
        10 REM ? MEANS UNKNOWN
        20 DATA ?,?,?
        30 PRINT\"WHAT?\";
        40 PRINT X
        """
        XCTAssertEqual(expand(src), exp)
    }

    // ═══════════════════════════════════════════════════════
    // MARK: 10. Classic V2 Abbreviations
    // ═══════════════════════════════════════════════════════

    func test_gO_expands_to_GOTO() {
        XCTAssertEqual(expand("10 gO 100"), "10 GOTO 100")
    }

    func test_goS_expands_to_GOSUB_longer_wins() {
        // `goS` starts with `gO` but matcher must pick the longer entry.
        XCTAssertEqual(expand("10 goS 200"), "10 GOSUB 200")
    }

    func test_pO_expands_to_POKE_not_POS() {
        // POKE is what the ROM assigned `pO` to; POS has no abbreviation.
        XCTAssertEqual(expand("10 pO 53280,0"), "10 POKE 53280,0")
    }

    func test_pE_expands_to_PEEK() {
        XCTAssertEqual(expand("10 X=pE (53280)"), "10 X=PEEK (53280)")
    }

    func test_pR_expands_to_PRINT_hash() {
        XCTAssertEqual(expand("10 pR 1,X"), "10 PRINT# 1,X")
    }

    func test_fO_expands_to_FOR() {
        XCTAssertEqual(expand("10 fO I=1 tO 10"), "10 FOR I=1 tO 10")
        // Note: `tO` is not a V2 abbreviation — TO has no shortcut.
        // The test above deliberately leaves it alone to confirm.
    }

    func test_leF_expands_to_LEFT_dollar() {
        XCTAssertEqual(expand("10 A$=leF (B$,3)"), "10 A$=LEFT$ (B$,3)")
    }

    func test_stE_expands_to_STEP_not_STOP() {
        // `sT` → STOP, but `stE` (longer) → STEP should win.
        XCTAssertEqual(expand("10 fO I=1 tO 10 stE 2"), "10 FOR I=1 tO 10 STEP 2")
    }

    func test_uppercase_abbreviation_does_not_expand() {
        // Case-strict: `FO` (both uppercase) is not an abbreviation, should stay.
        XCTAssertEqual(expand("10 FO=5"), "10 FO=5")
    }

    func test_lowercase_abbreviation_does_not_expand() {
        // `fo` (both lowercase) is not an abbreviation either.
        XCTAssertEqual(expand("10 fo=5"), "10 fo=5")
    }

    func test_abbreviation_mid_identifier_protected_by_lookahead() {
        // `fOO` — first two chars match `fO` but next char is letter → no match.
        XCTAssertEqual(expand("10 fOO=5"), "10 fOO=5")
    }

    func test_abbreviation_inside_variable_context() {
        // `fO` at end of identifier: preceded by letter → not a keyword start.
        // The expander checks boundaries via `matchSkippedKeyword`.
        // At position of 'f', matcher tries `fO`, lookahead sees '+' (non-letter),
        // match succeeds → expands to FOR. Result: "X=FOR+1". Correct.
        XCTAssertEqual(expand("10 X=fO+1"), "10 X=FOR+1")
    }

    func test_full_abbreviated_program() {
        let src = """
        10 fO I=1 tO 10
        20 pO 1024+I,81
        30 nE I
        40 ? "DONE"
        """
        let exp = """
        10 FOR I=1 tO 10
        20 POKE 1024+I,81
        30 NEXT I
        40 PRINT "DONE"
        """
        XCTAssertEqual(expand(src), exp)
    }
}

