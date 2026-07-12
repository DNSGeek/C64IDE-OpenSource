// MARK: - BasicKeywordMatcher.swift
//
// Shared keyword-matching engine for syntax highlighting and tokenization.
// Implements the C64 ROM $A57C tokeniser rules with an optional letter-boundary guard.

import Foundation

/// Matches BASIC keywords against source text.
///
/// Implements C64 ROM tokenizer behavior:
///   • Keywords are matched greedily, longest first.
///   • If a keyword ends with a letter and the next character is also a letter,
///     the match is rejected (prevents "FOR" from matching "FORT").
///   • Keywords ending in non-letters (e.g., "CHR$", "TAB(") always match.
///
/// Usage:
///   let m = BasicKeywordMatcher(keywords: BasicKeywordMatcher.basicV2Keywords)
///   if let match = m.match(in: "GOTO10", at: str.startIndex) { ... }

struct BasicKeywordMatcher {

    struct Match {
        let keyword: String
        let endIndex: String.Index
    }

    private let sorted: [String]
    var sortedKeywords: [String] { sorted }
    private let longerSiblings: Set<String>

    init(keywords: [String]) {
        self.sorted = keywords.sorted { $0.count > $1.count }
        // Precompute keywords that have a LONGER sibling starting with the
        // same prefix AND continuing with a letter. Only those siblings can
        // ever match when a letter follows the short keyword, so only they
        // justify skipping the short match. The old rule counted any longer
        // sibling: PRINT# put PRINT in the set, so "PRINTA" matched neither
        // PRINT# (wrong char) nor PRINT (guard fired) and the keyword went
        // unhighlighted — even though hardware crunches it as PRINT + A.
        // This mirrors BasicDialectManager.keywordsWithLongerLetterSibling.
        self.longerSiblings = Set(keywords.filter { kw in
            keywords.contains(where: { longer in
                guard longer.count > kw.count && longer.hasPrefix(kw) else { return false }
                let next = longer[longer.index(longer.startIndex, offsetBy: kw.count)]
                return next.isLetter
            })
        })
    }

    /// Attempts to match a keyword at `index` in the uppercased `source`.
    /// Returns the first valid match, or `nil` if no keyword matches.
    func match(in source: String, at index: String.Index) -> Match? {
        for kw in sorted {
            guard source[index...].hasPrefix(kw) else { continue }
            let afterKW = source.index(index, offsetBy: kw.count)

            // Letter-boundary guard: when a LONGER keyword in the table
            // shares this prefix (e.g. INPUT# vs INPUT, or a dialect's
            // PRINTUSING vs PRINT) and a letter follows, skip the short
            // match so the longer sibling gets its chance on a later
            // iteration of a wider scan. NOTE: this does NOT stop FOR
            // from matching inside "FORT" when no longer sibling exists -
            // and it must not, because the ROM tokeniser greedily crunches
            // keywords at every position ("FORT" really is FOR + T on
            // hardware).
            if let lastCh = kw.last, lastCh.isLetter,
               afterKW < source.endIndex, source[afterKW].isLetter,
               longerSiblings.contains(kw) {
                continue
            }

            return Match(keyword: kw, endIndex: afterKW)
        }
        return nil
    }

    // MARK: - Standard BASIC V2 Keywords

    static let basicV2Keywords: [String] = [
        // Statements
        "END", "FOR", "NEXT", "DATA", "INPUT#", "INPUT", "DIM", "READ",
        "LET", "GOTO", "RUN", "IF", "RESTORE", "GOSUB", "RETURN", "REM",
        "STOP", "ON", "WAIT", "LOAD", "SAVE", "VERIFY", "DEF", "POKE",
        "PRINT#", "PRINT", "CONT", "LIST", "CLR", "CMD", "SYS", "OPEN",
        "CLOSE", "GET", "NEW",
        // Clauses / modifiers
        "TAB(", "TO", "FN", "SPC(", "THEN", "NOT", "STEP",
        // Logical / relational operators
        "AND", "OR",
        // Functions
        "SGN", "INT", "ABS", "USR", "FRE", "POS", "SQR", "RND", "LOG",
        "EXP", "COS", "SIN", "TAN", "ATN", "PEEK", "LEN",
        "STR$", "VAL", "ASC", "CHR$", "LEFT$", "RIGHT$", "MID$",
        // Rarely-used
        "GO",
        // System variables
        "TI", "ST",
    ]
}

