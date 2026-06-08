import Foundation

// MARK: - BasicShortcutExpander

/// Expands C64 BASIC shortcut abbreviations (e.g., `?` → `PRINT`) to their
/// full keyword form at load/paste time.
///
/// ## Design
///
/// Expansion is a pure text transformation that runs in two places:
///   1. `C64Document` on file load, before content hits the editor buffer.
///   2. The editor's paste handler, before pasted text is inserted.
///
/// Once text is in the buffer, it is canonical — every `?` has already
/// become `PRINT`, and every future shortcut is resolved. The user sees
/// full keywords in the editor, which means syntax highlighting, code
/// completion, and the reference panel all work without shortcut-aware code.
///
/// ## Shortcut Sources
///
/// Two tables are merged at expansion time:
///   - `universalShortcuts`: Built-in table for conventions common across
///     C64-family BASICs.
///   - `dialect.shortcuts`: Optional per-dialect table from a plugin JSON.
///     Dialect entries override universal entries on collision.
///
/// Merged entries are sorted longest-first so that if two shortcuts share
/// a prefix (e.g., `?` and `??`), the longer one wins.
///
/// ## Safety
///
/// The expander walks the source with a state machine that skips three
/// contexts where a literal `?` must be preserved verbatim:
///   - Inside string literals: `PRINT "WHAT IS YOUR NAME?"`
///   - Inside REM comments:   `10 REM ? MEANS UNKNOWN`
///   - Inside DATA statements: `20 DATA ?,HELLO,?`
///
/// Colons and newlines reset REM/DATA context (but not string context —
/// a string literal continues across a colon because the quote is still open).
///
/// ## Friendliness
///
/// When a shortcut is glued to a following alphanumeric character (`?X=5`),
/// the expander inserts a single space (`PRINT X=5`). The C64 ROM tokenizer
/// accepts either form, but human readers expect visible separation.
public enum BasicShortcutExpander {

    // MARK: - Public API

    /// Universal shortcuts that apply to every BASIC dialect.
    ///
    /// Includes the full Commodore BASIC V2 keyword abbreviation set
    /// transcribed from the C64-Wiki "BASIC keyword abbreviation" reference,
    /// plus the `?` → `PRINT` shorthand.
    ///
    /// ## Case Convention
    ///
    /// Each abbreviation is lowercase except the final letter, which is
    /// uppercase — matching the "type these letters, then SHIFT the last one"
    /// convention used by the C64 ROM tokenizer. Matching is case-strict:
    /// `fO` expands, but `FO` and `fo` do not. This protects users with
    /// variables spelled in other casings from unwanted substitution.
    ///
    /// ## Precedence
    ///
    /// The expander sorts by length descending so longer abbreviations win
    /// over shorter prefixes. `goS` → GOSUB beats `gO` → GOTO, `leF` → LEFT$
    /// beats `lE` → LET, etc.
    ///
    /// ## Dialect Caveats
    ///
    /// These abbreviations are correct for V2 and Vision BASIC. On C128
    /// BASIC 7 and MEGA65 BASIC 65, several resolve to different keywords
    /// because those ROMs renumbered the token table. Override conflicting
    /// entries in the dialect plugin's `shortcuts` array where they take
    /// precedence.
    ///
    /// ## Keywords Without Abbreviations
    ///
    /// The following V2 keywords intentionally have no entry because they
    /// have no abbreviation on real hardware: COS, FN, GET#, IF, INPUT,
    /// INT, LEN, LOG, NEW, ON, OR, POS, REM, STATUS, TAN.
    public static let universalShortcuts: [Shortcut] = [
        // The one-character classic
        Shortcut(shortcut: "?",    keyword: "PRINT"),

        // Two-letter abbreviations
        Shortcut(shortcut: "aB",   keyword: "ABS"),
        Shortcut(shortcut: "aN",   keyword: "AND"),
        Shortcut(shortcut: "aS",   keyword: "ASC"),
        Shortcut(shortcut: "aT",   keyword: "ATN"),
        Shortcut(shortcut: "cH",   keyword: "CHR$"),
        Shortcut(shortcut: "cL",   keyword: "CLR"),
        Shortcut(shortcut: "cM",   keyword: "CMD"),
        Shortcut(shortcut: "cO",   keyword: "CONT"),
        Shortcut(shortcut: "dA",   keyword: "DATA"),
        Shortcut(shortcut: "dE",   keyword: "DEF"),
        Shortcut(shortcut: "dI",   keyword: "DIM"),
        Shortcut(shortcut: "eN",   keyword: "END"),
        Shortcut(shortcut: "eX",   keyword: "EXP"),
        Shortcut(shortcut: "fO",   keyword: "FOR"),
        Shortcut(shortcut: "fR",   keyword: "FRE"),
        Shortcut(shortcut: "gE",   keyword: "GET"),
        Shortcut(shortcut: "gO",   keyword: "GOTO"),
        Shortcut(shortcut: "iN",   keyword: "INPUT#"),
        Shortcut(shortcut: "lE",   keyword: "LET"),
        Shortcut(shortcut: "lI",   keyword: "LIST"),
        Shortcut(shortcut: "lO",   keyword: "LOAD"),
        Shortcut(shortcut: "mI",   keyword: "MID$"),
        Shortcut(shortcut: "nE",   keyword: "NEXT"),
        Shortcut(shortcut: "nO",   keyword: "NOT"),
        Shortcut(shortcut: "oP",   keyword: "OPEN"),
        Shortcut(shortcut: "pE",   keyword: "PEEK"),
        Shortcut(shortcut: "pO",   keyword: "POKE"),
        Shortcut(shortcut: "pR",   keyword: "PRINT#"),
        Shortcut(shortcut: "rE",   keyword: "READ"),
        Shortcut(shortcut: "rI",   keyword: "RIGHT$"),
        Shortcut(shortcut: "rN",   keyword: "RND"),
        Shortcut(shortcut: "rU",   keyword: "RUN"),
        Shortcut(shortcut: "sA",   keyword: "SAVE"),
        Shortcut(shortcut: "sG",   keyword: "SGN"),
        Shortcut(shortcut: "sI",   keyword: "SIN"),
        Shortcut(shortcut: "sP",   keyword: "SPC("),
        Shortcut(shortcut: "sQ",   keyword: "SQR"),
        Shortcut(shortcut: "sT",   keyword: "STOP"),
        Shortcut(shortcut: "sY",   keyword: "SYS"),
        Shortcut(shortcut: "tA",   keyword: "TAB("),
        Shortcut(shortcut: "tH",   keyword: "THEN"),
        Shortcut(shortcut: "uS",   keyword: "USR"),
        Shortcut(shortcut: "vA",   keyword: "VAL"),
        Shortcut(shortcut: "vE",   keyword: "VERIFY"),
        Shortcut(shortcut: "wA",   keyword: "WAIT"),

        // Three-letter abbreviations
        Shortcut(shortcut: "clO",  keyword: "CLOSE"),
        Shortcut(shortcut: "goS",  keyword: "GOSUB"),
        Shortcut(shortcut: "leF",  keyword: "LEFT$"),
        Shortcut(shortcut: "reS",  keyword: "RESTORE"),
        Shortcut(shortcut: "reT",  keyword: "RETURN"),
        Shortcut(shortcut: "stE",  keyword: "STEP"),
        Shortcut(shortcut: "stR",  keyword: "STR$"),
    ]

    /// One shortcut mapping. Matches the plugin JSON schema exactly so
    /// the same type round-trips through `Codable`.
    public struct Shortcut: Codable, Equatable {
        public let shortcut: String
        public let keyword: String
    }

    /// Expands every shortcut in `source`, skipping string literals,
    /// REM comment bodies, and DATA statement bodies.
    ///
    /// - Parameters:
    ///   - source: The raw BASIC source text (as typed, pasted, or loaded).
    ///   - dialect: Optional active dialect. When provided, its `shortcuts`
    ///              array is merged with the universal table. Dialect entries
    ///              override universal entries on exact shortcut match.
    /// - Returns: Source with all shortcuts expanded to full keywords.
    ///            Lines, indentation, and non-shortcut content are preserved.
    static func expand(_ source: String, dialect: BasicDialect? = nil) -> String {
        let table = buildTable(dialect: dialect)
        guard !table.isEmpty else { return source }
        return expand(source, using: table)
    }

    // MARK: - Table Assembly

    /// Merges universal + dialect shortcuts into a single longest-first list.
    /// Dialect entries override universal on exact shortcut collision.
    private static func buildTable(dialect: BasicDialect?) -> [Shortcut] {
        var merged: [String: String] = [:]
        for s in universalShortcuts {
            merged[s.shortcut] = s.keyword
        }
        if let dialectShortcuts = dialect?.shortcuts {
            for s in dialectShortcuts {
                merged[s.shortcut] = s.keyword  // Dialect wins on collision
            }
        }
        return merged
            .map { Shortcut(shortcut: $0.key, keyword: $0.value) }
            .sorted { $0.shortcut.count > $1.shortcut.count }  // Longest first
    }

    // MARK: - Core Expansion

    /// Walks the source character-by-character, expanding shortcuts only
    /// in "normal" context. Skips string / REM / DATA bodies.
    private static func expand(_ source: String, using table: [Shortcut]) -> String {
        var out = ""
        out.reserveCapacity(source.count + 32)

        // Context state
        var inString = false
        var inSkippedStmt = false     // True inside REM or DATA body
        var i = source.startIndex

        while i < source.endIndex {
            let ch = source[i]

            // ── Newline: always resets all stateful contexts ──────────
            if ch == "\n" {
                inString = false
                inSkippedStmt = false
                out.append(ch)
                i = source.index(after: i)
                continue
            }

            // ── Inside a string literal: pass through until closing " ─
            if inString {
                out.append(ch)
                if ch == "\"" { inString = false }
                i = source.index(after: i)
                continue
            }

            // ── Inside REM/DATA body: pass through until : or \n ──────
            // Colons end DATA/REM on the C64. BASIC V2's REM actually
            // consumes colons too, but DATA ends at a colon. We take the
            // conservative position: a colon ends the skipped context.
            // This matches DATA behavior exactly, and is safe for REM
            // because text after a colon is no longer a comment on any
            // sensible BASIC dialect.
            if inSkippedStmt {
                if ch == ":" {
                    inSkippedStmt = false
                    out.append(ch)
                    i = source.index(after: i)
                    continue
                }
                out.append(ch)
                i = source.index(after: i)
                continue
            }

            // ── Entering a string ─────────────────────────────────────
            if ch == "\"" {
                inString = true
                out.append(ch)
                i = source.index(after: i)
                continue
            }

            // ── Detect REM or DATA keyword starting here ──────────────
            if let after = matchSkippedKeyword(in: source, at: i, prevChar: out.last) {
                out.append(contentsOf: source[i..<after])
                inSkippedStmt = true
                i = after
                continue
            }

            // ── Try a shortcut match ──────────────────────────────────
            if let m = matchShortcut(in: source, at: i, table: table) {
                out.append(m.keyword)
                // Friendliness: if the next char is alphanumeric, insert
                // a space so the editor shows `PRINT X` not `PRINTX`.
                if m.endIndex < source.endIndex,
                   source[m.endIndex].isLetter || source[m.endIndex].isNumber {
                    out.append(" ")
                }
                i = m.endIndex
                continue
            }

            // ── Ordinary character: pass through ──────────────────────
            out.append(ch)
            i = source.index(after: i)
        }

        return out
    }

    // MARK: - REM / DATA Detection

    /// If a REM or DATA keyword starts at `index`, returns the index
    /// immediately after the keyword. Otherwise `nil`.
    ///
    /// Matching rules:
    ///   - Case-insensitive
    ///   - Must not be preceded by a letter (so `FOREM` doesn't trigger)
    ///   - Must not be followed by a letter (so `DATABASE` doesn't trigger)
    private static func matchSkippedKeyword(
        in source: String, at index: String.Index, prevChar: Character?
    ) -> String.Index? {
        // Boundary check: the character before must not be a letter.
        if let prev = prevChar, prev.isLetter { return nil }

        for kw in ["REM", "DATA"] {
            guard source[index...].uppercased().hasPrefix(kw) else { continue }
            let after = source.index(index, offsetBy: kw.count)
            if after < source.endIndex, source[after].isLetter { continue }
            return after
        }
        return nil
    }

    // MARK: - Shortcut Matching

    private struct ShortcutMatch {
        let keyword: String
        let endIndex: String.Index
    }

    /// Tries every shortcut at `index` in longest-first order.
    /// For shortcuts ending in a letter, applies a lookahead guard:
    /// rejects if the next character is also a letter. Non-letter
    /// shortcuts (`?`) skip the guard.
    private static func matchShortcut(
        in source: String, at index: String.Index, table: [Shortcut]
    ) -> ShortcutMatch? {
        for entry in table {
            guard source[index...].hasPrefix(entry.shortcut) else { continue }
            let after = source.index(index, offsetBy: entry.shortcut.count)

            // Letter-lookahead guard for letter-terminated shortcuts.
            if let lastCh = entry.shortcut.last, lastCh.isLetter,
               after < source.endIndex, source[after].isLetter {
                continue
            }

            return ShortcutMatch(keyword: entry.keyword, endIndex: after)
        }
        return nil
    }
}

// MARK: - External Dependency
// Note: `BasicDialect` is expected to be defined in your host application
// or a separate plugin module. It must contain a `shortcuts: [Shortcut]` property.
// protocol BasicDialect { var shortcuts: [BasicShortcutExpander.Shortcut]? { get } }

