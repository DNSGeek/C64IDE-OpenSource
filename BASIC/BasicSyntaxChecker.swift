// MARK: - BasicSyntaxChecker.swift
//
// Live syntax checking for BASIC source in the editor. Runs the parser in
// its lenient, dialect-aware mode and adds the whole-program checks the
// parser cannot make on its own: missing, duplicate and out-of-order line
// numbers, and jumps to lines that do not exist (?UNDEF'D STATEMENT on
// hardware). Everything here is advisory - nothing feeds the compiler.

import Foundation

struct BasicSyntaxChecker {

    let dialect: BasicDialect?
    private let matcher: BasicKeywordMatcher
    /// Dialects with inline assembly (Vision BASIC) switch modes with
    /// ASSEM ... BASIC. Lines inside that region are 6502 mnemonics in
    /// brackets, which the BASIC parser must not see.
    private let hasInlineAssembly: Bool

    init(dialect: BasicDialect?) {
        self.dialect = dialect
        var keywords = BasicKeywordMatcher.basicV2Keywords
        if let dialect {
            let v2 = Set(keywords)
            for kw in dialect.keywords {
                let name = kw.keyword.uppercased()
                if !name.isEmpty && !v2.contains(name) { keywords.append(name) }
            }
        }
        self.matcher = BasicKeywordMatcher(keywords: keywords)
        let names = Set(dialect?.keywords.map { $0.keyword.uppercased() } ?? [])
        self.hasInlineAssembly = !(dialect?.assemblerMnemonics ?? []).isEmpty
            && names.contains("ASSEM") && names.contains("BASIC")
    }

    /// Keywords whose following integer literal(s) are line-number targets.
    /// TRAP/RESUME/RESTORE n are dialect forms; in pure V2 they are parse
    /// errors anyway, so listing them costs nothing.
    private static let targetKeywords: Set<String> = [
        "GOTO", "GOSUB", "THEN", "RUN", "RESTORE", "RESUME", "TRAP", "ELSE",
    ]

    // MARK: - Entry Point

    func check(_ source: String) -> [SyntaxDiagnostic] {
        let rawLines = source.components(separatedBy: "\n")
        var diagnostics: [SyntaxDiagnostic] = []

        // Pass 1: line numbers, and which lines the parser should see.
        var parserLines: [String] = []
        var definedLines = Set<Int>()
        var previousNumber: Int?
        var inAssembly = false

        for (index, raw) in rawLines.enumerated() {
            guard let parts = Self.split(raw) else {
                parserLines.append("")
                continue
            }
            guard let digits = parts.digits else {
                diagnostics.append(SyntaxDiagnostic(
                    line: index, column: parts.leading, length: parts.trimmedLength,
                    message: "Missing line number"))
                parserLines.append("")
                continue
            }
            if let number = Int(digits), number <= 63999 {
                if definedLines.contains(number) {
                    diagnostics.append(SyntaxDiagnostic(
                        line: index, column: parts.leading, length: digits.utf16.count,
                        severity: .warning,
                        message: "Duplicate line number \(number); this line replaces the earlier one"))
                } else if let prev = previousNumber, number < prev {
                    diagnostics.append(SyntaxDiagnostic(
                        line: index, column: parts.leading, length: digits.utf16.count,
                        severity: .warning,
                        message: "Line \(number) is out of order (it follows line \(prev)) and will run in sorted position"))
                }
                definedLines.insert(number)
                previousNumber = number
            }
            // (numbers above 63999 are reported by the parser, with position)

            var skip = false
            if hasInlineAssembly {
                var lexer = BasicLexer(parts.content, matcher: matcher)
                let tokens = lexer.tokenize()
                // Bracketed mnemonics can also appear on an ordinary line.
                if inAssembly || parts.content.contains("[") { skip = true }
                for token in tokens {
                    if token == .keyword("ASSEM") { inAssembly = true }
                    if token == .keyword("BASIC") { inAssembly = false }
                }
            }
            parserLines.append(skip ? "" : raw)
        }

        // Pass 2: the parser.
        var parser = BasicParser(dialect: dialect)
        _ = parser.parse(parserLines.joined(separator: "\n"))
        for error in parser.errors {
            guard let line = error.sourceLine else { continue }
            diagnostics.append(SyntaxDiagnostic(
                line: line, column: error.column, length: error.length,
                message: error.message))
        }

        // Pass 3: jump targets.
        for (index, raw) in parserLines.enumerated() {
            guard let parts = Self.split(raw), parts.digits != nil else { continue }
            var lexer = BasicLexer(parts.content, matcher: matcher)
            let tokens = lexer.tokenize()
            let spans = lexer.spans

            for (i, token) in tokens.enumerated() {
                var expectsTarget = false
                switch token {
                case .keyword(let kw) where Self.targetKeywords.contains(kw):
                    expectsTarget = true
                case .identifier("ELSE"):
                    expectsTarget = true
                case .keyword("TO"):
                    // GO TO, the two-word spelling.
                    if i > 0, tokens[i - 1] == .keyword("GO") { expectsTarget = true }
                default:
                    break
                }
                guard expectsTarget else { continue }

                // One target, or a comma-separated list (ON X GOTO 10,20,30).
                var j = i + 1
                while j < tokens.count, case .integer(let target) = tokens[j] {
                    if !definedLines.contains(target) {
                        diagnostics.append(SyntaxDiagnostic(
                            line: index,
                            column: parts.contentOffset + spans[j].lowerBound,
                            length: max(spans[j].count, 1),
                            message: "Line \(target) does not exist"))
                    }
                    j += 1
                    guard j < tokens.count, tokens[j] == .comma else { break }
                    j += 1
                }
            }
        }

        return diagnostics.sorted(by: SyntaxDiagnostic.displayOrder)
    }

    // MARK: - Line Splitting

    struct LineParts {
        /// UTF-16 count of leading whitespace.
        let leading: Int
        /// UTF-16 length of the line with surrounding whitespace removed.
        let trimmedLength: Int
        /// The leading line number's digits, or nil for an unnumbered line.
        let digits: String?
        /// UTF-16 offset of `content` within the raw line.
        let contentOffset: Int
        /// Statement text after the line number, trimmed.
        let content: String
    }

    /// Splits a raw source line the same way `BasicParser.parse` does, so
    /// positions computed here line up with the parser's. Nil for blank lines.
    static func split(_ raw: String) -> LineParts? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let leading = raw.prefix(while: { $0.isWhitespace }).utf16.count
        let digits = trimmed.prefix(while: { $0.isNumber })
        let afterNumber = trimmed.dropFirst(digits.count)
        let gap = afterNumber.prefix(while: { $0.isWhitespace }).utf16.count
        return LineParts(
            leading: leading,
            trimmedLength: trimmed.utf16.count,
            digits: digits.isEmpty ? nil : String(digits),
            contentOffset: leading + digits.utf16.count + gap,
            content: String(afterNumber).trimmingCharacters(in: .whitespaces))
    }
}
