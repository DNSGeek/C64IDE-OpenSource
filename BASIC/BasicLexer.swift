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
///   • The original line is kept verbatim; keyword and identifier matching is
///     case-insensitive (ASCII only), but string literals and DATA items keep
///     the case the user typed. The old implementation uppercased the whole
///     line on entry, which destroyed case inside string literals — PRINT
///     "hello" compiled as PRINT "HELLO". Identifiers are still normalised to
///     uppercase in their tokens, matching BASIC's case-insensitive variables.
///   • Keywords are matched greedily using the unified keyword table.
///   • REM consumes the remainder of the line without tokenization.
///   • Scientific notation and leading-dot floats are supported.
///   • Only ASCII space (32) is treated as whitespace; other characters are skipped.

struct BasicLexer {

    private let source: String
    private var idx: String.Index
    private let matcher: BasicKeywordMatcher

    /// ASCII-only uppercase for match comparisons. Deliberately NOT
    /// Character.uppercased(): that can change length (ß → SS) and returns
    /// a String. Non-ASCII characters pass through unchanged, so positions
    /// in the original line always stay valid.
    private static func upperChar(_ ch: Character) -> Character {
        if let a = ch.asciiValue, a >= 0x61, a <= 0x7A {
            return Character(UnicodeScalar(a - 0x20))
        }
        return ch
    }

    /// Case-insensitive test for keyword `kw` (uppercase ASCII) starting at
    /// `start` in the original source. Compares character-by-character so
    /// no uppercased copy of the line is ever made.
    private func hasKeywordPrefix(_ kw: String, at start: String.Index) -> Bool {
        var i = start
        for k in kw {
            guard i < source.endIndex, BasicLexer.upperChar(source[i]) == k else {
                return false
            }
            i = source.index(after: i)
        }
        return true
    }

    /// The compiler targets BASIC V2 exclusively, so the lexer matches the
    /// pure V2 keyword set. Previously this pulled the active dialect's
    /// unified table, which made COMPILATION depend on which dialect plugin
    /// happened to be selected in the tokenizer: a dialect keyword could
    /// split a perfectly valid V2 identifier mid-scan. Built once; matcher
    /// construction sorts the table and precomputes the sibling set, which
    /// was previously repeated for every single line.
    private static let v2Matcher = BasicKeywordMatcher(
        keywords: BasicKeywordMatcher.basicV2Keywords
    )

    init(_ line: String) {
        self.source = line          // original case preserved; see header note
        self.idx = source.startIndex
        self.matcher = BasicLexer.v2Matcher
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

            // PI is a value token on real hardware, and Swift considers
            // the character a letter, so intercept it before the
            // identifier branch swallows it into a variable name.
            if current == "\u{03C0}" {
                tokens.append(.float(Double.pi))
                advance()
                continue
            }

            if current.isLetter {
                if let kw = tryKeyword() {
                    if kw == "REM" {
                        idx = source.endIndex
                    } else if kw == "DATA" {
                        tokens.append(.keyword(kw))
                        scanDataItems(into: &tokens)
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

    /// Scans DATA statement contents in raw mode, called immediately after
    /// the DATA keyword. The ROM tokeniser never crunches keywords inside
    /// DATA ($A5AC skips to the next colon or quote), so DATA FORREST,HELLO
    /// stores two strings. Before this, the lexer shredded unquoted items
    /// into keyword tokens (FOR + REST) that parseData silently dropped.
    ///
    /// Produces value and comma tokens; stops before a statement-separating
    /// colon. Quoted items keep embedded commas and colons. Unquoted items
    /// have leading spaces skipped (as the ROM does via CHRGET) and are
    /// pre-classified: integer if Int() parses (sign included), float if
    /// Double() parses (handles 1E3, -.5), otherwise a string literal.
    private mutating func scanDataItems(into tokens: inout [BasicToken]) {
        while !atEnd {
            skipSpaces()
            guard !atEnd else { return }
            if current == ":" { return }        // next statement; caller emits it
            if current == "," {
                tokens.append(.comma)
                advance()
                continue
            }
            if current == "\"" {
                tokens.append(scanString())
                continue
            }
            // Unquoted item: raw text up to the next comma or colon.
            var raw = ""
            while !atEnd && current != "," && current != ":" {
                raw.append(current)
                advance()
            }
            let item = String(raw.drop(while: { $0 == " " }))
            let trimmed = item.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                tokens.append(.stringLiteral(""))
            } else if let i = Int(trimmed) {
                tokens.append(.integer(i))      // sign folded in: DATA -5 works
            } else if let d = Double(trimmed) {
                tokens.append(.float(d))
            } else {
                tokens.append(.stringLiteral(item))
            }
        }
    }

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

        // Exponent: only commit to the E if a digit (optionally signed)
        // actually follows. Consuming it unconditionally turned "5END"
        // into float(0) + identifier ND; on real hardware the tokeniser
        // crunches END first, so it must lex as 5 + END. Same for 5EXP(2).
        if !atEnd && (current == "E" || current == "e") {
            var look = source.index(after: idx)
            if look < source.endIndex,
               source[look] == "+" || source[look] == "-" {
                look = source.index(after: look)
            }
            if look < source.endIndex, source[look].isNumber {
                hasExp = true
                buf.append("E"); advance()
                if !atEnd && (current == "+" || current == "-") {
                    buf.append(current); advance()
                }
                while !atEnd && current.isNumber {
                    buf.append(current); advance()
                }
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
            // PI is a token on real hardware, so it terminates an
            // identifier just like an embedded keyword does. Without this
            // break, Swift's isLetter would absorb it into the name.
            if current == "\u{03C0}" { break }
            name.append(BasicLexer.upperChar(current)); advance()
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
            guard hasKeywordPrefix(kw, at: idx) else { continue }

            // TI and ST are pseudo-keywords, not ROM tokens, so they must
            // only match as standalone system variables. Without this
            // guard, STAR lexed as ST + AR, TIP as TI + P, and TI$ as TI
            // followed by a silently-dropped '$'. When the next character
            // continues an identifier, fall through to scanIdentifier.
            if BasicLexer.nonTokenKeywords.contains(kw) {
                let after = source.index(idx, offsetBy: kw.count)
                if after < source.endIndex {
                    let n = source[after]
                    if n.isLetter || n.isNumber || n == "$" || n == "%" {
                        continue
                    }
                }
            }

            idx = source.index(idx, offsetBy: kw.count)
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
            if hasKeywordPrefix(kw, at: idx) { return true }
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

