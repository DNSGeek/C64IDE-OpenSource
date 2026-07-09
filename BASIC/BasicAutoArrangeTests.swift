// MARK: - BasicAutoArrangeTests.swift
//
// Unit tests for BasicRenumber.autoArrangeAction and the nextLineNumber
// no-gap regression (the Return-key recursion crash).
//
// Note: uses the same module as BasicLexerTests; adjust the @testable
// import if BasicRenumber lives elsewhere in your project layout.

import XCTest
@testable import C64IDE

final class BasicAutoArrangeTests: XCTestCase {

    // ── Helpers ────────────────────────────────────────────

    /// UTF-16 offset of the first occurrence of `needle` in `source`,
    /// matching the NSRange offsets used by parseLines and the editor.
    private func offset(of needle: String, in source: String) -> Int {
        let r = (source as NSString).range(of: needle)
        XCTAssertNotEqual(r.location, NSNotFound, "test setup: \(needle) not found")
        return r.location
    }

    // ═══════════════════════════════════════════════════════
    // MARK: 1. nextLineNumber — the no-gap crash regression
    // ═══════════════════════════════════════════════════════

    func test_noGap_returnsNil() {
        // Editing 790 with 791 directly below. This nil used to feed an
        // insertText("\n") that re-entered the Return delegate and recursed
        // until the stack overflowed.
        XCTAssertNil(BasicRenumber.nextLineNumber(after: 790, beforeLine: 791))
    }

    func test_gapOfTwo_bisects() {
        XCTAssertEqual(BasicRenumber.nextLineNumber(after: 790, beforeLine: 792), 791)
    }

    func test_wideGap_bisects() {
        XCTAssertEqual(BasicRenumber.nextLineNumber(after: 790, beforeLine: 800), 795)
    }

    func test_roomForDefaultStep_usesIt() {
        XCTAssertEqual(BasicRenumber.nextLineNumber(after: 790, beforeLine: 40000), 800)
    }

    func test_noFollowingLine_addsStep() {
        XCTAssertEqual(BasicRenumber.nextLineNumber(after: 790, beforeLine: nil), 800)
    }

    // ═══════════════════════════════════════════════════════
    // MARK: 2. autoArrangeAction — classification
    // ═══════════════════════════════════════════════════════

    func test_inOrderLine_isNone() {
        let src = "10 A=1\n20 B=2\n30 C=3\n"
        XCTAssertEqual(
            BasicRenumber.autoArrangeAction(source: src, lineStart: offset(of: "20", in: src)),
            .none
        )
    }

    func test_singleLine_isNone() {
        XCTAssertEqual(
            BasicRenumber.autoArrangeAction(source: "100 A=1\n", lineStart: 0),
            .none
        )
    }

    func test_unnumberedLineStart_isNil() {
        let src = "10 A=1\nREM X\n"
        XCTAssertNil(
            BasicRenumber.autoArrangeAction(source: src, lineStart: offset(of: "REM", in: src))
        )
    }

    func test_offsetNotAtLineStart_isNil() {
        // Mid-line offsets are not line starts; parseLines won't match them.
        let src = "10 A=1\n20 B=2\n"
        XCTAssertNil(BasicRenumber.autoArrangeAction(source: src, lineStart: 3))
    }

    // ═══════════════════════════════════════════════════════
    // MARK: 3. autoArrangeAction — out-of-order moves
    // ═══════════════════════════════════════════════════════

    func test_lineTypedAtBottom_movesBeforeFirstGreater() {
        // The motivating scenario: 800 typed after 40000.
        let src = "10 REM TOP\n790 A=1\n40000 END\n800 X=5\n"
        let action = BasicRenumber.autoArrangeAction(
            source: src, lineStart: offset(of: "800 X=5", in: src)
        )
        XCTAssertEqual(action, .move(targetOffset: offset(of: "40000", in: src)))
    }

    func test_prevGreater_movesBeforeFirstGreaterInFileOrder() {
        // 800 sits after 950; the first line with a greater number in file
        // order is 950 itself, so 800 moves in front of it.
        let src = "10 A\n950 B\n800 C\n990 D\n"
        let action = BasicRenumber.autoArrangeAction(
            source: src, lineStart: offset(of: "800", in: src)
        )
        XCTAssertEqual(action, .move(targetOffset: offset(of: "950", in: src)))
    }

    func test_lineTypedAtTop_belongsAtEnd_movesAfterLastLine() {
        // 900 at the top of a file that ends without a trailing newline.
        // Target is one past the last line's range; the editor clamps and
        // prepends a newline when inserting.
        let src = "900 Z=9\n10 A=1\n20 B=2"
        let action = BasicRenumber.autoArrangeAction(source: src, lineStart: 0)
        let last = (src as NSString).range(of: "20 B=2")
        XCTAssertEqual(action, .move(targetOffset: NSMaxRange(last) + 1))
    }

    // ═══════════════════════════════════════════════════════
    // MARK: 4. autoArrangeAction — duplicates
    // ═══════════════════════════════════════════════════════

    func test_duplicateNumber_reportsExistingLine() {
        let src = "10 A=1\n800 OLD\n40000 END\n800 NEW\n"
        let action = BasicRenumber.autoArrangeAction(
            source: src, lineStart: offset(of: "800 NEW", in: src)
        )
        XCTAssertEqual(action, .duplicate(existingLineStart: offset(of: "800 OLD", in: src)))
    }

    func test_duplicateBeatsOutOfOrder() {
        // The committed line is BOTH out of order and a duplicate; the
        // collision must win, since a sorted position is meaningless until
        // the number is unique.
        let src = "10 A=1\n20 B=2\n10 DUP\n"
        let action = BasicRenumber.autoArrangeAction(
            source: src, lineStart: offset(of: "10 DUP", in: src)
        )
        XCTAssertEqual(action, .duplicate(existingLineStart: 0))
    }

    func test_leadingWhitespace_lineStillClassified() {
        // parseLines trims for number extraction but keeps the raw range.
        let src = "10 A=1\n   20 B=2\n30 C=3\n"
        let action = BasicRenumber.autoArrangeAction(
            source: src, lineStart: offset(of: "   20", in: src)
        )
        XCTAssertEqual(action, .none)
    }
}
