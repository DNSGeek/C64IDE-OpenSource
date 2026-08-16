import Foundation

/// Converts ASCII BASIC V2 source text into the tokenized PRG format
/// that the Commodore 64 (or compatible) loads into memory, and vice-versa.
///
/// PRG Format:
///   - 2 bytes: Load address (little-endian)
///   - Linked list of BASIC lines:
///     - 2 bytes: Pointer to next line (little-endian)
///     - 2 bytes: Line number (little-endian)
///     - tokenized content bytes
///     - 1 byte: $00 (end of line)
///   - 2 bytes: $0000 (end of program)
///
/// Extension token encoding:
///   - Single-byte: One byte in range $CC–$FE (dialect-defined)
///   - Two-byte:    Prefix byte (e.g., $CE or $FE) followed by secondary byte.
///                  The active dialect's tokenPrefixes list declares which bytes
///                  are prefixes to prevent ambiguity during detokenization.
public class BasicTokenizer {

    // MARK: - Load Addresses

    /// Default BASIC start address on the C64.
    public static let basicStartAddress: UInt16 = 0x0801

    /// BASIC V7 start address on the C128 (native mode).
    public static let c128StartAddress: UInt16 = 0x1C01

    /// BASIC V4 start address on the PET (native mode).
    public static let petStartAddress: UInt16 = 0x0401

    /// BASIC start address on the MEGA65 (in native BASIC 65 mode).
    public static let mega65StartAddress: UInt16 = 0x2001

    // MARK: - Token Table

    /// BASIC V2 token table — keyword to token byte mapping.
    /// The order here doesn't matter for matching (the unified table sorts
    /// longest-first), but the canonical ROM order is preserved for clarity
    /// and for the detokenizer's reverse lookup.
    public static let tokenTable: [(keyword: String, token: UInt8)] = [
        // $80–$CB in the order the C64 ROM defines them
        ("END",      0x80),
        ("FOR",      0x81),
        ("NEXT",     0x82),
        ("DATA",     0x83),
        ("INPUT#",   0x84),
        ("INPUT",    0x85),
        ("DIM",      0x86),
        ("READ",     0x87),
        ("LET",      0x88),
        ("GOTO",     0x89),
        ("RUN",      0x8A),
        ("IF",       0x8B),
        ("RESTORE",  0x8C),
        ("GOSUB",    0x8D),
        ("RETURN",   0x8E),
        ("REM",      0x8F),
        ("STOP",     0x90),
        ("ON",       0x91),
        ("WAIT",     0x92),
        ("LOAD",     0x93),
        ("SAVE",     0x94),
        ("VERIFY",   0x95),
        ("DEF",      0x96),
        ("POKE",     0x97),
        ("PRINT#",   0x98),
        ("PRINT",    0x99),
        ("CONT",     0x9A),
        ("LIST",     0x9B),
        ("CLR",      0x9C),
        ("CMD",      0x9D),
        ("SYS",      0x9E),
        ("OPEN",     0x9F),
        ("CLOSE",    0xA0),
        ("GET",      0xA1),
        ("NEW",      0xA2),
        ("TAB(",     0xA3),
        ("TO",       0xA4),
        ("FN",       0xA5),
        ("SPC(",     0xA6),
        ("THEN",     0xA7),
        ("NOT",      0xA8),
        ("STEP",     0xA9),
        ("+",        0xAA),
        ("-",        0xAB),
        ("*",        0xAC),
        ("/",        0xAD),
        ("^",        0xAE),
        ("AND",      0xAF),
        ("OR",       0xB0),
        (">",        0xB1),
        ("=",        0xB2),
        ("<",        0xB3),
        ("SGN",      0xB4),
        ("INT",      0xB5),
        ("ABS",      0xB6),
        ("USR",      0xB7),
        ("FRE",      0xB8),
        ("POS",      0xB9),
        ("SQR",      0xBA),
        ("RND",      0xBB),
        ("LOG",      0xBC),
        ("EXP",      0xBD),
        ("COS",      0xBE),
        ("SIN",      0xBF),
        ("TAN",      0xC0),
        ("ATN",      0xC1),
        ("PEEK",     0xC2),
        ("LEN",      0xC3),
        ("STR$",     0xC4),
        ("VAL",      0xC5),
        ("ASC",      0xC6),
        ("CHR$",     0xC7),
        ("LEFT$",    0xC8),
        ("RIGHT$",   0xC9),
        ("MID$",     0xCA),
        ("GO",       0xCB),
    ]

    // MARK: - Tokenize

    /// Tokenizes a BASIC source file to PRG data.
    ///
    /// - Parameters:
    ///   - source: ASCII BASIC source text.
    ///   - startAddress: Load address. Pass `nil` to use the active dialect's
    ///                   declared load address, falling back to $0801.
    ///   - stripWhitespace: Remove unnecessary spaces to save bytes.
    /// - Returns: PRG file data including the 2-byte load address header.
    public static func tokenize(_ source: String,
                                startAddress: UInt16? = nil,
                                stripWhitespace: Bool = false) -> Data {
        // Resolve load address: explicit → dialect → default C64 address.
        let resolvedStart: UInt16
        if let explicit = startAddress {
            resolvedStart = explicit
        } else if let dialectAddr = BasicDialectManager.shared.activeDialect?.loadAddress {
            resolvedStart = UInt16(dialectAddr & 0xFFFF)
        } else {
            resolvedStart = basicStartAddress
        }

        var output = Data()

        // Load address header (little-endian).
        output.append(UInt8(resolvedStart & 0xFF))
        output.append(UInt8(resolvedStart >> 8))

        let lines = parseLines(source)
        var currentAddress = resolvedStart

        for line in lines {
            let content = stripWhitespace ? stripUnnecessarySpaces(line.content) : line.content
            let tokenizedContent = tokenizeLine(content)

            // 2 (next ptr) + 2 (line num) + content bytes + 1 (null terminator)
            let lineLength = 2 + 2 + tokenizedContent.count + 1
            // Compute in Int: currentAddress + UInt16(lineLength) TRAPS
            // once the program grows past $FFFF. A program that big cannot
            // exist in a C64 anyway, so stop emitting lines instead of
            // crashing the app.
            let next = Int(currentAddress) + lineLength
            guard next <= 0xFFFF else { break }
            let nextAddress = UInt16(next)

            output.append(UInt8(nextAddress & 0xFF))
            output.append(UInt8(nextAddress >> 8))
            output.append(UInt8(line.number & 0xFF))
            output.append(UInt8(line.number >> 8))
            output.append(contentsOf: tokenizedContent)
            output.append(0x00)

            currentAddress = nextAddress
        }

        output.append(0x00)
        output.append(0x00)

        return output
    }

    // MARK: - Line Parsing

    public struct BasicLine {
        public let number: UInt16
        public let content: String
    }

    private static func parseLines(_ source: String) -> [BasicLine] {
        var lines: [BasicLine] = []

        for rawLine in source.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            var numStr = ""
            var idx = trimmed.startIndex
            while idx < trimmed.endIndex && trimmed[idx].isNumber {
                numStr.append(trimmed[idx])
                idx = trimmed.index(after: idx)
            }

            guard let lineNum = UInt16(numStr), lineNum <= 63999 else { continue }

            while idx < trimmed.endIndex && trimmed[idx] == " " {
                idx = trimmed.index(after: idx)
            }

            lines.append(BasicLine(number: lineNum, content: String(trimmed[idx...])))
        }

        // Duplicate line numbers: last definition wins, matching both real
        // hardware (retyping a line number replaces the line) and
        // BasicParser.parse. Previously duplicates were kept and fed to a
        // sort that Swift does not guarantee to be stable, so which copy
        // came first in the PRG was nondeterministic.
        var indexByNumber: [UInt16: Int] = [:]
        var deduped: [BasicLine] = []
        for line in lines {
            if let i = indexByNumber[line.number] {
                deduped[i] = line
            } else {
                indexByNumber[line.number] = deduped.count
                deduped.append(line)
            }
        }

        deduped.sort { $0.number < $1.number }
        return deduped
    }

    // MARK: - Line Tokenization

    /// Tokenizes a single line's content (after the line number).
    ///
    /// Makes a single greedy pass through the unified keyword table
    /// (`BasicDialectManager.shared.unifiedKeywordTable`), which contains both
    /// BASIC V2 and active dialect keywords sorted longest-first. This means:
    ///
    ///   - A dialect keyword like `POKEW` (5 chars) is tried before `POKE` (4 chars),
    ///     so "POKEW $D020" correctly emits the dialect token, not POKE + W.
    ///   - The letter-boundary lookahead guard (same as C64 ROM $A57C behaviour)
    ///     is applied uniformly to every keyword in the table.
    ///   - `{$XX}` escape sequences allow raw byte pass-through.
    ///
    /// Token matching priority within the single pass (by keyword length):
    ///   1. Longest match wins — dialect and V2 keywords compete on equal footing.
    ///   2. `{$XX}` raw byte escape sequences.
    ///   3. Literal characters (passed through as PETSCII).
    private static func tokenizeLine(_ content: String) -> [UInt8] {
        var result: [UInt8] = []
        let upper = content.uppercased()
        var pos = upper.startIndex
        var inQuotes = false
        var inREM = false
        var inDATA = false

        // Snapshot the unified table once per line so a mid-tokenize dialect
        // change (pathological but possible) can't corrupt the output.
        let table = BasicDialectManager.shared.unifiedKeywordTable
        // Same for the letter-boundary guard set. This used to be read
        // inside the per-keyword match loop, and it was a computed property
        // that rebuilt an O(keywords^2) filtered set on EVERY access — an
        // enormous amount of redundant work per line. It is now precomputed
        // in rebuildKeywordSet and snapshotted here.
        let letterSiblings = BasicDialectManager.shared.keywordsWithLongerLetterSibling

        while pos < upper.endIndex {
            let ch = upper[pos]

            // ── Inside quotes — pass through as PETSCII ──────────────
            if inQuotes {
                if ch == "\"" {
                    inQuotes = false
                    result.append(asciiToPetscii(ch))
                    pos = upper.index(after: pos)
                    continue
                }
                if let escaped = tryEscapeSequence(upper, at: pos) {
                    result.append(escaped.byte)
                    pos = escaped.end
                    continue
                }
                result.append(asciiToPetscii(ch))
                pos = upper.index(after: pos)
                continue
            }

            // ── Inside REM — everything is literal ────────────────────
            if inREM {
                result.append(asciiToPetscii(ch))
                pos = upper.index(after: pos)
                continue
            }

            // ── Quote open ────────────────────────────────────────────
            if ch == "\"" {
                inQuotes = true
                result.append(asciiToPetscii(ch))
                pos = upper.index(after: pos)
                continue
            }
            
            // -- Inside DATA -- literal until ':' or end of line ------
            // The ROM cruncher sets a data-mode flag after tokenizing
            // DATA and copies bytes literally until a colon or EOL.
            // Without this, '-' in DATA crunched to $AB and READ threw
            // ?SYNTAX ERROR. Quote handling above means a colon inside
            // a quoted DATA item does not end data mode.
            if inDATA {
                if ch == ":" { inDATA = false }
                if let escaped = tryEscapeSequence(upper, at: pos) {
                    result.append(escaped.byte)
                    pos = escaped.end
                    continue
                }
                result.append(asciiToPetscii(ch))
                pos = upper.index(after: pos)
                continue
            }

            // ── Spaces are literal ────────────────────────────────────
            if ch == " " {
                result.append(asciiToPetscii(ch))
                pos = upper.index(after: pos)
                continue
            }

            // ── Unified keyword match (single greedy pass) ────────────
            //
            // The table is sorted longest-first, so the first match found is
            // always the longest possible keyword at this position. Dialect
            // keywords that extend V2 keywords (e.g. POKEW ⊃ POKE) are
            // encountered first and win without any special-casing.
            //
            // Letter-boundary guard: if a keyword ends with a letter and the
            // very next character is also a letter, the match is rejected —
            // preventing POKE from matching the start of POKER, for example.
            // Keywords ending in non-letter characters (CHR$, TAB() are always
            // accepted regardless of what follows.
            var matched = false

            for entry in table {
                guard upper[pos...].hasPrefix(entry.keyword) else { continue }

                let afterKW = upper.index(pos, offsetBy: entry.keyword.count)

                // Letter-boundary lookahead guard (C64 ROM $A57C behaviour).
                if let lastCh = entry.keyword.last, lastCh.isLetter,
                   afterKW < upper.endIndex, upper[afterKW].isLetter,
                   letterSiblings.contains(entry.keyword) {
                    continue
                }

                // Match accepted — emit the appropriate token bytes.
                switch entry.encoding {
                case .v2(let token):
                    result.append(token)
                    if token == 0x8F { inREM = true }   // REM — swallow rest of line
                    if token == 0x83 { inDATA = true }  // DATA -- literal until ':'

                case .extensionSingle(let token):
                    result.append(token)

                case .extensionPrefixed(let prefixes, let token):
                    for p in prefixes { result.append(p) }
                    result.append(token)
                }

                pos = afterKW
                matched = true
                break
            }

            if matched { continue }

            // ── {$XX} raw byte escape ──────────────────────────────────
            if let escaped = tryEscapeSequence(upper, at: pos) {
                result.append(escaped.byte)
                pos = escaped.end
                continue
            }

            // ── PI value token ──────────────────────────────────────────
            // PI crunches to $FF on real hardware. Skipped when the active
            // dialect declares $FF as a token prefix (MEGA65 BASIC 65
            // does); the character then falls through to the literal path.
            if ch == "\u{03C0}" && !BasicDialectManager.shared.isPrefixByte(0xFF) {
                result.append(0xFF)
                pos = upper.index(after: pos)
                continue
            }

            // ── Literal character ──────────────────────────────────────
            result.append(asciiToPetscii(ch))
            pos = upper.index(after: pos)
        }

        return result
    }

    // MARK: - Character Conversion

    /// Converts a Unicode `Character` to its PETSCII byte equivalent.
    ///
    /// Swift `String` is always Unicode, so by the time a character reaches
    /// this function it is already a proper Unicode scalar — not a raw UTF-8
    /// byte. The old implementation called `char.asciiValue`, which returns
    /// `nil` for anything outside 0x00–0x7F and then fell through to
    /// `return 0x20` (space). That silently corrupted every non-ASCII
    /// character: £ (UTF-8: C2 A3) arrived as a single Character (U+00A3)
    /// but was emitted as a space.
    ///
    /// This replacement handles three tiers:
    ///
    ///   1. **ASCII-compatible range** ($20–$5B, $5D): identical in PETSCII
    ///      and ASCII — pass straight through after the lower-case shift.
    ///
    ///   2. **Non-ASCII Unicode → PETSCII**: explicit switch covering every
    ///      standard-Unicode character in the C64 character set, sourced from
    ///      the authoritative Linus Walleij PETSCII↔Unicode mapping table
    ///      (petscii_c64en_uc.txt, licensed GPL v2).
    ///      Where a Unicode codepoint maps to two PETSCII codes (e.g. │ is
    ///      both $62 and $7D; ━ duplicates at $60/$63/$C0/$C3) the lowest
    ///      code in the unshifted ($60–$7F) bank is used.
    ///      Both U+2500 (─ light) and U+2501 (━ heavy) horizontal lines are
    ///      accepted and mapped to $60, since many fonts render them
    ///      identically and users can't easily tell them apart.
    ///
    ///   3. **Fallback**: unmappable characters (e.g. emoji, CJK, combining
    ///      marks, PETSCII CUS-only glyphs like $64–$68) emit $20 (space).
    ///      Users who need those CUS glyphs should use the `{$XX}` escape.
    ///
    /// - Note: This function is intentionally *not* called for `{$XX}` escape
    ///   sequences — those are already resolved to a raw byte before reaching
    ///   the character-conversion path.
    /// Internal (not private): BasicCodeGen shares this mapping for
    /// compiled string literals, so PRINT and the tokenizer agree on
    /// every character.
    static func asciiToPetscii(_ char: Character) -> UInt8 {

        // ── Tier 1: ASCII-compatible printable range ───────────────────────
        // PETSCII $20–$5B and $5D match ASCII exactly.
        // Lowercase letters ($61–$7A) shift down to uppercase ($41–$5A).
        // (The uppercase-only check in tokenizeLine has already uppercased
        //  keywords, but string literals and REMs are passed through the
        //  original casing, so we still need the shift here.)
        if let ascii = char.asciiValue {
            if ascii >= 0x61 && ascii <= 0x7A { return ascii - 0x20 } // a–z → A–Z
            return ascii
        }

        // ── Tier 2: Non-ASCII Unicode → PETSCII ───────────────────────────
        // Source: Linus Walleij, "PETSCII C64 English Uppercase to Unicode"
        // https://dflund.se/~triad/krad/recode/petscii_c64en_uc.txt
        switch char {

        // ── $5C–$5F: special chars in the ASCII punctuation band ──────────
        case "£":  return 0x5C  // U+00A3  POUND SIGN
        case "↑":  return 0x5E  // U+2191  UPWARDS ARROW
        case "←":  return 0x5F  // U+2190  LEFTWARDS ARROW

        // ── $60–$7F: PETSCII graphic characters (unshifted bank) ──────────
        // Horizontal lines — accept both light (U+2500) and heavy (U+2501);
        // the C64 ROM glyph looks heavier than Unicode "light" anyway.
        case "─":  return 0x60  // U+2500  BOX DRAWINGS LIGHT HORIZONTAL
        case "━":  return 0x60  // U+2501  BOX DRAWINGS HEAVY HORIZONTAL
        case "♠":  return 0x61  // U+2660  BLACK SPADE SUIT
        case "│":  return 0x62  // U+2502  BOX DRAWINGS LIGHT VERTICAL
        // $63 is also horizontal line (duplicate of $60) — no separate entry needed
        // $64–$68 have no standard Unicode (CUS only) — use {$XX} escape
        case "╮":  return 0x69  // U+256E  BOX DRAWINGS LIGHT ARC DOWN AND LEFT
        case "╰":  return 0x6A  // U+2570  BOX DRAWINGS LIGHT ARC UP AND RIGHT
        case "╯":  return 0x6B  // U+256F  BOX DRAWINGS LIGHT ARC UP AND LEFT
        // $6C has no standard Unicode (CUS) — use {$6C} escape
        case "╲":  return 0x6D  // U+2572  BOX DRAWINGS LIGHT DIAGONAL UPPER LEFT TO LOWER RIGHT
        case "╱":  return 0x6E  // U+2571  BOX DRAWINGS LIGHT DIAGONAL UPPER RIGHT TO LOWER LEFT
        // $6F–$70 have no standard Unicode (CUS) — use {$6F}/{$70} escape
        case "●":  return 0x71  // U+25CF  BLACK CIRCLE
        // $72 has no standard Unicode (CUS) — use {$72} escape
        case "♥":  return 0x73  // U+2665  BLACK HEART SUIT
        // $74 has no standard Unicode (CUS) — use {$74} escape
        case "╭":  return 0x75  // U+256D  BOX DRAWINGS LIGHT ARC DOWN AND RIGHT
        case "╳":  return 0x76  // U+2573  BOX DRAWINGS LIGHT DIAGONAL CROSS
        case "○":  return 0x77  // U+25CB  WHITE CIRCLE
        case "♣":  return 0x78  // U+2663  BLACK CLUB SUIT
        // $79 has no standard Unicode (CUS) — use {$79} escape
        case "♦":  return 0x7A  // U+2666  BLACK DIAMOND SUIT
        case "┼":  return 0x7B  // U+253C  BOX DRAWINGS LIGHT VERTICAL AND HORIZONTAL
        // $7C has no standard Unicode (CUS) — use {$7C} escape
        // $7D is also BOX DRAWINGS LIGHT VERTICAL — duplicate of $62, no separate entry
        case "π":  return 0x7E  // U+03C0  GREEK SMALL LETTER PI
        case "◥":  return 0x7F  // U+25E5  BLACK UPPER RIGHT TRIANGLE

        // ── $A0–$BF: block elements and box-drawing corners ───────────────
        case "\u{00A0}": return 0xA0  // NO-BREAK SPACE
        case "▌":  return 0xA1  // U+258C  LEFT HALF BLOCK
        case "▄":  return 0xA2  // U+2584  LOWER HALF BLOCK
        case "▔":  return 0xA3  // U+2594  UPPER ONE EIGHTH BLOCK
        case "▁":  return 0xA4  // U+2581  LOWER ONE EIGHTH BLOCK
        case "▏":  return 0xA5  // U+258F  LEFT ONE EIGHTH BLOCK
        case "▒":  return 0xA6  // U+2592  MEDIUM SHADE
        case "▕":  return 0xA7  // U+2595  RIGHT ONE EIGHTH BLOCK
        // $A8 has no standard Unicode (CUS) — use {$A8} escape
        case "◤":  return 0xA9  // U+25E4  BLACK UPPER LEFT TRIANGLE
        // $AA has no standard Unicode (CUS) — use {$AA} escape
        case "├":  return 0xAB  // U+251C  BOX DRAWINGS LIGHT VERTICAL AND RIGHT
        // $AC has no standard Unicode (CUS) — use {$AC} escape
        case "└":  return 0xAD  // U+2514  BOX DRAWINGS LIGHT UP AND RIGHT
        case "┐":  return 0xAE  // U+2510  BOX DRAWINGS LIGHT DOWN AND LEFT
        case "▂":  return 0xAF  // U+2582  LOWER ONE QUARTER BLOCK
        case "┌":  return 0xB0  // U+250C  BOX DRAWINGS LIGHT DOWN AND RIGHT
        case "┴":  return 0xB1  // U+2534  BOX DRAWINGS LIGHT UP AND HORIZONTAL
        case "┬":  return 0xB2  // U+252C  BOX DRAWINGS LIGHT DOWN AND HORIZONTAL
        case "┤":  return 0xB3  // U+2524  BOX DRAWINGS LIGHT VERTICAL AND LEFT
        case "▎":  return 0xB4  // U+258E  LEFT ONE QUARTER BLOCK
        case "▍":  return 0xB5  // U+258D  LEFT THREE EIGHTHS BLOCK
        // $B6–$B8 have no standard Unicode (CUS) — use {$B6}/{$B7}/{$B8} escape
        case "▃":  return 0xB9  // U+2583  LOWER THREE EIGHTHS BLOCK
        // $BA–$BC have no standard Unicode (CUS) — use {$BA}/{$BB}/{$BC} escape
        case "┘":  return 0xBD  // U+2518  BOX DRAWINGS LIGHT UP AND LEFT
        // $BE–$BF have no standard Unicode (CUS) — use {$BE}/{$BF} escape

        // ── Fallback ───────────────────────────────────────────────────────
        // Emoji, CJK, combining marks, and other unmappable characters.
        // PETSCII CUS glyphs ($64–$68, $6C, $6F–$70, $72, $74, $79, $7C,
        // $A8, $AA, $AC, $B6–$B8, $BA–$BC, $BE–$BF) can only be entered
        // using the `{$XX}` raw-byte escape syntax in the source file.
        default:
            return 0x20
        }
    }

    /// Tries to match a `{$XX}` escape sequence at `pos`. Returns the byte value
    /// and index after the closing `}`, or `nil` if no match.
    private static func tryEscapeSequence(_ str: String, at pos: String.Index)
        -> (byte: UInt8, end: String.Index)? {
        guard str[pos] == "{" else { return nil }
        let remaining = str[pos...]
        guard remaining.count >= 5,
              remaining.hasPrefix("{$") else { return nil }
        let hexStart = str.index(pos, offsetBy: 2)
        let hexEnd   = str.index(pos, offsetBy: 4)
        guard hexEnd < str.endIndex, str[hexEnd] == "}" else { return nil }
        let hexStr = String(str[hexStart..<hexEnd])
        guard let byte = UInt8(hexStr, radix: 16) else { return nil }
        return (byte: byte, end: str.index(after: hexEnd))
    }

    /// Converts a source-level string literal to PETSCII bytes, honouring the
    /// same `{$XX}` raw-byte escapes the tokenizer accepts.
    ///
    /// The compiler needs this too: emitting `s.map(asciiToPetscii)` sent the
    /// literal characters `{`, `$`, `9`, `3`, `}` to the screen instead of the
    /// clear-screen code, so every control code in a PRINT died.
    static func petsciiBytes(_ str: String) -> [UInt8] {
        var result: [UInt8] = []
        var pos = str.startIndex
        while pos < str.endIndex {
            if let escaped = tryEscapeSequence(str, at: pos) {
                result.append(escaped.byte)
                pos = escaped.end
                continue
            }
            result.append(asciiToPetscii(str[pos]))
            pos = str.index(after: pos)
        }
        return result
    }

    // MARK: - Write PRG File

    /// Tokenizes a BASIC source file and writes it to a URL.
    public static func tokenizeToFile(_ source: String,
                                      outputURL url: URL,
                                      startAddress: UInt16? = nil,
                                      stripWhitespace: Bool = false) throws {
        let data = tokenize(source, startAddress: startAddress, stripWhitespace: stripWhitespace)
        try data.write(to: url)
    }

    // MARK: - Whitespace Stripping

    private static func stripUnnecessarySpaces(_ content: String) -> String {
        var result = ""
        var inQuotes = false
        var inREM = false
        let upper = content.uppercased()
        var i = upper.startIndex

        while i < upper.endIndex {
            let ch = upper[i]

            if inREM {
                result.append(content[i])
                i = upper.index(after: i)
                continue
            }

            if inQuotes {
                result.append(content[i])
                if ch == "\"" { inQuotes = false }
                i = upper.index(after: i)
                continue
            }

            if ch == "\"" {
                inQuotes = true
                result.append(content[i])
                i = upper.index(after: i)
                continue
            }

            if upper[i...].hasPrefix("REM") {
                inREM = true
                result.append(contentsOf: content[i...].prefix(3))
                i = upper.index(i, offsetBy: 3)
                continue
            }

            if ch == " " {
                let prevIsAlnum = i > upper.startIndex && {
                    let prev = upper[upper.index(before: i)]
                    return prev.isLetter || prev.isNumber || prev == "$" || prev == "%"
                }()
                var next = upper.index(after: i)
                while next < upper.endIndex && upper[next] == " " {
                    next = upper.index(after: next)
                }
                let nextIsAlnum = next < upper.endIndex && {
                    let n = upper[next]
                    return n.isLetter || n.isNumber
                }()
                if prevIsAlnum && nextIsAlnum { result.append(" ") }
                i = next
                continue
            }

            result.append(content[i])
            i = upper.index(after: i)
        }

        return result
    }

    // MARK: - Detokenizer

    private static let reverseTokenTable: [UInt8: String] = {
        var table: [UInt8: String] = [:]
        for (keyword, token) in tokenTable { table[token] = keyword }
        return table
    }()

    /// Checks if the provided data conforms to the structure of a tokenized BASIC PRG file.
    public static func isTokenizedBASIC(_ data: Data) -> Bool {
        guard data.count >= 6 else { return false }
        // All arithmetic in Int: the old UInt16(data.count) TRAPPED for
        // any file over 64KB, crashing the app on the one input this
        // function exists to reject gracefully.
        let loadAddr = Int(data[0]) | (Int(data[1]) << 8)
        // Lower bound covers the PET ($0401) and VIC-20 ($1001/$1201)
        // BASIC start addresses; the old 0x0800 floor rejected every PET
        // PRG despite petStartAddress support elsewhere in this class.
        guard loadAddr >= 0x0401 && loadAddr <= 0x2100 else { return false }
        let nextLine = Int(data[2]) | (Int(data[3]) << 8)
        guard nextLine > loadAddr && nextLine < loadAddr + data.count else { return false }
        return true
    }

    /// Detokenizes a PRG file back to readable BASIC source.
    ///
    /// Handles:
    ///   - Standard BASIC V2 tokens ($80–$CB)
    ///   - Single-byte dialect extension tokens
    ///   - Two-byte prefixed dialect extension tokens
    ///     (prefix bytes are declared in the active dialect's `tokenPrefixes`)
    public static func detokenize(_ prgData: Data) -> String? {
        guard prgData.count >= 4 else { return nil }

        let manager = BasicDialectManager.shared
        let bytes = Array(prgData.dropFirst(2))
        var offset = 0
        var lines: [String] = []

        while offset + 4 < bytes.count {
            let nextLinePtr = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
            if nextLinePtr == 0 { break }

            let lineNum = UInt16(bytes[offset + 2]) | (UInt16(bytes[offset + 3]) << 8)
            offset += 4

            var lineContent = ""
            var inQuotes = false
            var inREM = false
            var inDATA = false

            while offset < bytes.count && bytes[offset] != 0x00 {
                let byte = bytes[offset]

                // ── REM literal mode ────────────────────────────────────
                // The ROM never tokenizes anything after REM, so bytes to
                // end of line are literal text. Decoding them as tokens
                // turned innocent comment bytes into keyword soup.
                if inREM {
                    if byte >= 0x20 && byte <= 0x7E && byte != 0x7B {
                        lineContent.append(Character(UnicodeScalar(byte)))
                    } else {
                        lineContent.append(String(format: "{$%02X}", byte))
                    }
                    offset += 1
                    continue
                }

                if inQuotes {
                    if byte == 0x22 {
                        inQuotes = false
                        lineContent.append("\"")
                    } else if byte >= 0x20 && byte <= 0x7E && byte != 0x7B {
                        lineContent.append(Character(UnicodeScalar(byte)))
                    } else {
                        lineContent.append(String(format: "{$%02X}", byte))
                    }
                    offset += 1
                    continue
                }

                if byte == 0x22 {
                    inQuotes = true
                    lineContent.append("\"")
                    offset += 1
                    continue
                }
                
                // -- DATA literal mode: bytes are text until ':' ------
                if inDATA {
                    if byte == 0x3A {
                        inDATA = false
                        lineContent.append(":")
                    } else if byte >= 0x20 && byte <= 0x7E && byte != 0x7B {
                        lineContent.append(Character(UnicodeScalar(byte)))
                    } else {
                        lineContent.append(String(format: "{$%02X}", byte))
                    }
                    offset += 1
                    continue
                }

                // ── Standard BASIC V2 token ($80–$CB) ─────────────────
                if byte >= 0x80 && byte <= 0xCB {
                    if let keyword = reverseTokenTable[byte] {
                        lineContent.append(keyword)
                        if byte == 0x8F { inREM = true }   // REM: rest is literal
                        if byte == 0x83 { inDATA = true }  // DATA: literal until ':'
                    } else {
                        lineContent.append(String(format: "{$%02X}", byte))
                    }
                    offset += 1
                    continue
                }

                // ── Possible prefix byte or single-byte extension ─────
                if byte > 0xCB {
                    // Check if this is a declared prefix byte — consume the full chain.
                    if manager.isPrefixByte(byte) {
                        var collectedPrefixes: [UInt8] = [byte]
                        var scanOffset = offset + 1

                        // Keep consuming prefix bytes as long as they're declared prefixes.
                        while scanOffset < bytes.count && manager.isPrefixByte(bytes[scanOffset]) {
                            collectedPrefixes.append(bytes[scanOffset])
                            scanOffset += 1
                        }

                        if scanOffset < bytes.count {
                            let tokenByte = bytes[scanOffset]
                            if let kw = manager.lookupPrefixedToken(prefixes: collectedPrefixes, token: tokenByte) {
                                lineContent.append(kw.keyword)
                                offset = scanOffset + 1
                                continue
                            } else {
                                // Unknown sequence — emit all bytes as escapes.
                                for b in collectedPrefixes {
                                    lineContent.append(String(format: "{$%02X}", b))
                                }
                                lineContent.append(String(format: "{$%02X}", tokenByte))
                                offset = scanOffset + 1
                                continue
                            }
                        }
                    }

                    // Not a prefix byte — try single-byte extension lookup.
                    if let kw = manager.lookupSingleByteToken(byte) {
                        lineContent.append(kw.keyword)
                    } else if byte == 0xFF {
                        // PI value token. Reached only when no dialect
                        // claims $FF as a prefix or extension, so the
                        // MEGA65 case is handled by the checks above.
                        lineContent.append("\u{03C0}")
                    } else {
                        lineContent.append(String(format: "{$%02X}", byte))
                    }
                    offset += 1
                    continue
                }

                // ── Regular character ──────────────────────────────────
                if byte < 0x20 {
                    // Control codes outside quotes cannot round-trip as
                    // raw text; escape them.
                    lineContent.append(String(format: "{$%02X}", byte))
                } else {
                    lineContent.append(petsciiToChar(byte))
                }
                offset += 1
            }

            if offset < bytes.count { offset += 1 } // skip null terminator

            lines.append("\(lineNum) \(lineContent)")
        }

        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private static func petsciiToChar(_ byte: UInt8) -> Character {
        if byte >= 0x20 && byte <= 0x7E { return Character(UnicodeScalar(byte)) }
        if byte >= 0xC1 && byte <= 0xDA { return Character(UnicodeScalar(byte - 0x80)) }
        return Character(UnicodeScalar(byte))
    }

    /// Detokenizes a PRG file at a specific URL.
    public static func detokenizeFile(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return detokenize(data)
    }
}

