// MARK: - SyntaxDiagnostic.swift
//
// One problem found by the live syntax checkers (`BasicSyntaxChecker`,
// `AsmSyntaxChecker`). Positions are in terms of the editor's text: a
// 0-based line index plus UTF-16 offsets within that line, which is what
// NSTextStorage and NSLayoutManager work in.

import Foundation

enum DiagnosticSeverity: Int, Comparable {
    case warning = 0
    case error = 1

    static func < (lhs: DiagnosticSeverity, rhs: DiagnosticSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .warning: return "Warning"
        case .error:   return "Error"
        }
    }
}

struct SyntaxDiagnostic: Equatable {
    /// 0-based index of the source text line.
    let line: Int
    /// UTF-16 offset within the line, or nil to mark the whole line.
    let column: Int?
    /// UTF-16 length of the marked text, or nil for the rest of the line.
    let length: Int?
    let severity: DiagnosticSeverity
    let message: String

    init(line: Int, column: Int? = nil, length: Int? = nil,
         severity: DiagnosticSeverity = .error, message: String) {
        self.line = line
        self.column = column
        self.length = length
        self.severity = severity
        self.message = message
    }

    /// Stable display order: by line, then column, errors before warnings.
    static func displayOrder(_ a: SyntaxDiagnostic, _ b: SyntaxDiagnostic) -> Bool {
        if a.line != b.line { return a.line < b.line }
        let ac = a.column ?? -1, bc = b.column ?? -1
        if ac != bc { return ac < bc }
        return a.severity > b.severity
    }
}
