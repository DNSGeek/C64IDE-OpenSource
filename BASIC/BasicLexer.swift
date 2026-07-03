// MARK: - BasicLexer.swift
//
// Lexical analyzer for Commodore BASIC V2 source lines.
// Converts logical lines (line numbers stripped) into a stream of typed tokens.
// Implements greedy keyword matching and C64 ROM-compatible tokenization rules.

import Foundation

// MARK: - Token

/// A single lexical token from a BASIC V2 source line.
enum BasicToken: Equatable {
    // Literals
    case integer(Int)
    case float(Double)
    case stringLiteral(String)

    // Identifiers
    case identifier(String)
    case identifierStr(String)
    case identifierInt(String)

    // Reserved words
    case keyword(String)

    // Operators
    case op(String)

    // Punctuation
    case lparen, rparen, comma, semicolon, colon, hash

    // Sentinels
    case eof
}

extension BasicToken: CustomStringConvertible {
    var description: String {
        switch self {
        case .integer(let n):       return "INT(\(n))"
        case .float(let f):         return "FLT(\(f))"
        case .stringLiteral(let s): return "STR(\"\(s)\")"
        case .identifier(let s):    return "ID(\(s))"
        case .identifierStr(let s): return "IDS(\(s))"
        case .identifierInt(let s): return "IDI(\(s))"
        case .keyword(let s):       return "KW(\(s))"
        case .op(let s):            return "OP(\(s))"
        case .lparen:               return "LPAREN"
        case .rparen:               return "RPAREN"
        case .comma:                return "COMMA"
        case .semicolon:            return "SEMI"
        case .colon:                return "COLON"
        case .hash:                 return "HASH"
        case .eof:                  return "EOF"
        }
    }
}

// MARK: - LexError (Reserved for future validation)
struct LexError: Error, CustomStringConvertible {
    let message: String
    let column: Int
    var description: String { "Lex error at col \(column): \(message)" }
}

// MARK: - BasicLexer

/// Converts a single logical BASIC line into a token stream.
///
/// Key Behaviors:
///   • Input is uppercased on entry.
///   • Keywords are matched greedily using the unified keyword table.
///   • REM consumes the remainder of the line without tokenization.
///   • Scientific notation and leading-dot floats are supported.
///   • Only ASCII space (32) is treated as whitespace; other characters are skipped.

struct BasicLexer {

    private let source: String
    private var idx: String.Index
    private let matcher: BasicKeywordMatcher

    init(_ line: String) {
        self.source = line.uppercased()
        self.idx = source.startIndex
        self.matcher = BasicKeywordMatcher(
            keywords: BasicDialectManager.shared.unifiedKeywordStrings
        )
    }

    /// Returns the complete token stream, including a trailing `.eof`.
    mutating func tokenize() -> [BasicToken] {
        var tokens: [BasicToken] = []

        while !atEnd {
            skipSpaces()
            guard !atEnd else { break }

            if current == "\"" {
                tokens.append(scanString())
                continue
            }

            if current.isNumber || (current == "." && nextChar?.isNumber == true) {
                tokens.append(scanNumber())
                continue
            }

            if current.isLetter {
                if let kw = tryKeyword() {
                    if kw == "REM" {
                        idx = source.endIndex
                    } else {
                        tokens.append(.keyword(kw))
                    }
                } else {
                    tokens.append(scanIdentifier())
                }
                continue
            }

            switch current {
            case "+", "-", "*", "/", "^":
                tokens.append(.op(String(current))); advance()
            case "=":
                tokens.append(.op("=")); advance()
            case "<":
                advance()
                if !atEnd && current == "=" { tokens.append(.op("<=")); advance() }
                else if !atEnd && current == ">" { tokens.append(.op("<>")); advance() }
                else { tokens.append(.op("<")) }
            case ">":
                advance()
                if !atEnd && current == "=" { tokens.append(.op(">=")); advance() }
                else { tokens.append(.op(">")) }
            case "(": tokens.append(.lparen);    advance()
            case ")": tokens.append(.rparen);    advance()
            case ",": tokens.append(.comma);     advance()
            case ";": tokens.append(.semicolon); advance()
            case ":": tokens.append(.colon);     advance()
            case "#": tokens.append(.hash);      advance()
            default:
                advance() // Skip unknown characters
            }
        }

        tokens.append(.eof)
        return tokens
    }

    // MARK: - Scanners

    private mutating func scanString() -> BasicToken {
        advance()
        var buf = ""
        while !atEnd && current != "\"" {
            buf.append(current)
            advance()
        }
        if !atEnd { advance() }
        return .stringLiteral(buf)
    }

    private mutating func scanNumber() -> BasicToken {
        var buf = ""
        var hasDot = false
        var hasExp = false

        while !atEnd && (current.isNumber || (current == "." && !hasDot)) {
            if current == "." { hasDot = true }
            buf.append(current); advance()
        }

        if !atEnd && current == "E" {
            hasExp = true
            buf.append(current); advance()
            if !atEnd && (current == "+" || current == "-") {
                buf.append(current); advance()
            }
            while !atEnd && current.isNumber {
                buf.append(current); advance()
            }
        }

        if !hasDot && !hasExp, let i = Int(buf) {
            return .integer(i)
        }
        return .float(Double(buf) ?? 0)
    }

    private mutating func scanIdentifier() -> BasicToken {
        var name = ""
        while !atEnd && (current.isLetter || current.isNumber) {
            // C64 ROM compatibility: the $A57C tokeniser looks for keywords
            // at EVERY character position, so an embedded keyword terminates
            // the variable name. "ATOB" lexes as A TO B and "BTHEN10" as
            // B THEN 10, exactly as on real hardware. (This also means
            // "LIFE" is L IF E and errors, again matching the hardware.)
            // The check is skipped for the first character because
            // tryKeyword() already failed there before we were called, and
            // for digits because no keyword starts with a digit.
            if !name.isEmpty && current.isLetter && keywordStartsHere() {
                break
            }
            name.append(current); advance()
        }
        if !atEnd && current == "$" {
            name.append(current); advance()
            return .identifierStr(name)
        }
        if !atEnd && current == "%" {
            name.append(current); advance()
            return .identifierInt(name)
        }
        return .identifier(name)
    }

    // IMPORTANT: Intentionally bypasses BasicKeywordMatcher.match().
    // The matcher applies a letter-lookahead guard for syntax highlighting,
    // but the C64 ROM tokeniser matches greedily without it. This ensures
    // "GOTO10" → [GOTO, 10] and "FORI" → [FOR, I] as on real hardware.
    private mutating func tryKeyword() -> String? {
        for kw in matcher.sortedKeywords {
            guard source[idx...].hasPrefix(kw) else { continue }
            let after = source.index(idx, offsetBy: kw.count)
            idx = after
            return kw
        }
        return nil
    }

    /// Pseudo-keywords that are NOT tokens in the C64 ROM's $A09E table.
    /// TI and ST are in our keyword list so the parser can recognize them
    /// as system variables at expression positions, but the ROM tokeniser
    /// never crunches them — "LAST" on real hardware is the variable LA,
    /// not LA + ST. They must therefore not split identifiers. (GO stays:
    /// it IS a real token, which is why "DRAGON" crunches to DRA GO N on
    /// actual hardware. Authenticity hurts sometimes.)
    private static let nonTokenKeywords: Set<String> = ["TI", "ST"]

    /// Non-consuming keyword probe used by scanIdentifier() to detect a
    /// keyword starting mid-identifier. Same greedy rules as tryKeyword(),
    /// but does not move the cursor and ignores non-token pseudo-keywords.
    private func keywordStartsHere() -> Bool {
        for kw in matcher.sortedKeywords {
            guard !BasicLexer.nonTokenKeywords.contains(kw) else { continue }
            if source[idx...].hasPrefix(kw) { return true }
        }
        return false
    }

    // MARK: - Cursor Helpers

    private var atEnd: Bool { idx >= source.endIndex }
    private var current: Character { source[idx] }
    private var nextChar: Character? {
        let next = source.index(after: idx)
        return next < source.endIndex ? source[next] : nil
    }
    private mutating func advance() {
        guard !atEnd else { return }
        idx = source.index(after: idx)
    }
    private mutating func skipSpaces() {
        while !atEnd && current == " " { advance() }
    }
}

// MARK: - Convenience Top-Level Function

/// Tokenises a single logical BASIC line (no line number prefix).
func tokenize(_ line: String) -> [BasicToken] {
    var lexer = BasicLexer(line)
    return lexer.tokenize()
}

