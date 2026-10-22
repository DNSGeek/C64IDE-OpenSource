// MARK: - DiagnosticUnderlineTests.swift
//
// Tests for the ranges the editor underlines for a syntax diagnostic. The
// rule that matters: a tab is never underlined, because its zero-width
// dotted underline is an empty draw call that trips Xcode's Metal API
// Validation (seen as "instanceCount(0) must be non-zero" after typing a
// line like "10 pri<Tab>" with the live checker on).

import XCTest
@testable import C64IDE

final class DiagnosticUnderlineTests: XCTestCase {

    /// Ranges for a diagnostic on the first line of `text` (so offsets are
    /// line-relative), as (location, length) pairs.
    private func ranges(_ text: String, column: Int?, length: Int?) -> [[Int]] {
        let ns = text as NSString
        let lineEnd = ns.range(of: "\n").location == NSNotFound ? ns.length : ns.range(of: "\n").location
        let diagnostic = SyntaxDiagnostic(line: 0, column: column, length: length, message: "x")
        return EditorViewController.underlineRanges(for: diagnostic, lineStart: 0, lineEnd: lineEnd, in: ns)
            .map { [$0.location, $0.length] }
    }

    func testEndOfLineErrorMarksTheLastVisibleCharacterNotATrailingTab() {
        XCTAssertEqual(ranges("10 pri\t", column: 7, length: 0), [[5, 1]])
        XCTAssertEqual(ranges("10 pri\t\n20 END", column: 7, length: 0), [[5, 1]])
        XCTAssertEqual(ranges("10 pri   ", column: 9, length: nil), [[5, 1]])
        XCTAssertEqual(ranges("10 PRINT \"A", column: 11, length: 0), [[10, 1]])
    }

    func testEndOfLineErrorOnAnOrdinaryLineStillMarksTheLastCharacter() {
        XCTAssertEqual(ranges("10 PRINT (1", column: 11, length: 0), [[10, 1]])
        XCTAssertEqual(ranges("10 PRINT (1", column: 99, length: 0), [[10, 1]])
    }

    func testErrorAtTheStartOfALineMarksItsFirstNonTabCharacter() {
        XCTAssertEqual(ranges("PRINT", column: 0, length: 0), [[0, 1]])
        XCTAssertEqual(ranges("\t\tPRINT", column: 0, length: 0), [[2, 1]])
        XCTAssertEqual(ranges("   ", column: 0, length: 0), [[0, 1]])
        XCTAssertEqual(ranges("\t\t", column: 0, length: 0), [])
        XCTAssertEqual(ranges("", column: nil, length: nil), [])
    }

    func testRangesAreSplitAroundTabs() {
        XCTAssertEqual(ranges("10 pri\t", column: 3, length: 4), [[3, 3]])
        XCTAssertEqual(ranges("10 a\tb", column: 3, length: 3), [[3, 1], [5, 1]])
        XCTAssertEqual(ranges("\t\t", column: 0, length: 2), [])
        XCTAssertEqual(ranges("a\t\tb\t", column: 0, length: 5), [[0, 1], [3, 1]])
    }

    func testWholeLineMarksSkipLeadingWhitespaceAndTrailingTabs() {
        XCTAssertEqual(ranges("  PRINT X", column: nil, length: nil), [[2, 7]])
        XCTAssertEqual(ranges("\tPRINT X\t", column: nil, length: nil), [[1, 7]])
        XCTAssertEqual(ranges("  PRINT X\n20 END", column: nil, length: nil), [[2, 7]])
    }

    func testExplicitRangesAreClampedToTheLine() {
        XCTAssertEqual(ranges("10 END\n20 X", column: 3, length: 50), [[3, 3]])
        XCTAssertEqual(ranges("10 END", column: 3, length: 3), [[3, 3]])
        XCTAssertEqual(ranges("10 GOTO 10", column: 8, length: 2), [[8, 2]])
    }
}
