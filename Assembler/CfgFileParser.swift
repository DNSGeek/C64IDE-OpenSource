//  CfgFileParser.swift
//  C64 IDE
//
//  Parses cc65 / ld65 linker configuration (.cfg) files.
//  Extracts MEMORY region definitions and SEGMENTS mappings to render
//  the *planned* memory layout in the Memory Map window.

import Foundation

/// Represents a MEMORY region definition from a `.cfg` file.
struct CfgMemoryRegion {
    let name: String

    /// Resolved start address: either a plain literal, or the result of
    /// evaluating the raw expression against the config's `FEATURES` and
    /// `SYMBOLS` blocks. `nil` only when evaluation failed.
    let start: UInt32?

    /// Resolved size, same rules as `start`.
    let size: UInt32?

    let rawStart: String     // raw text for tooltips
    let rawSize: String
    let file: String?        // %O = main output, "" = none, or a literal name

    /// True when `rawStart` is a plain numeric literal. Only literals can be
    /// rewritten in place by `CfgFileEditor`; expressions are read-only.
    let isStartLiteral: Bool
    let isSizeLiteral: Bool

    /// True when the value was computed from an expression rather than read
    /// verbatim. The Memory Map draws these with a dashed outline.
    var isStartDerived: Bool { start != nil && !isStartLiteral }
    var isSizeDerived:  Bool { size  != nil && !isSizeLiteral }
}

/// Represents a SEGMENTS mapping from a `.cfg` file.
struct CfgSegmentMapping {
    let name: String
    let load: String         // memory region name
    let run: String?
    let type: String?
}

/// Parsed metadata for a linker configuration file.
struct CfgFileInfo {
    let memory: [CfgMemoryRegion]
    let segments: [CfgSegmentMapping]
    let sourceURL: URL?

    /// The value `%S` resolved to while parsing (`FEATURES { STARTADDRESS: … }`).
    let startAddress: UInt32?

    /// Regions whose `start` could not be resolved at all. These cannot be
    /// plotted, so the window reports them instead of dropping them silently.
    var unresolvedRegions: [CfgMemoryRegion] { memory.filter { $0.start == nil } }
}

// ═══════════════════════════════════════════════════════════
// MARK: - Expression Evaluation
// ═══════════════════════════════════════════════════════════

/// Symbol values available while evaluating `.cfg` expressions.
struct CfgSymbolEnvironment {
    /// Value of `%S` — the link start address.
    var startAddress: UInt32?

    /// Values from `SYMBOLS { name: value = …; }`.
    var symbols: [String: UInt32] = [:]
}

/// Evaluates the small arithmetic subset that appears in real cc65 configs:
/// numeric literals, `%S`, `SYMBOLS` names, `+ - * /` and parentheses.
///
/// Anything outside that subset (`%O`, bit operators, unknown identifiers)
/// evaluates to `nil`, which callers treat as "unknown".
enum CfgExpression {

    static func evaluate(_ raw: String, in env: CfgSymbolEnvironment) -> UInt32? {
        var parser = Parser(text: raw, env: env)
        guard let value = parser.parseExpression(), parser.atEnd else { return nil }
        guard value >= 0, value <= Int64(UInt32.max) else { return nil }
        return UInt32(value)
    }

    /// Recursive-descent evaluator over `Int64` so intermediate results may go
    /// negative (`%S - 2` with a small `%S`) without trapping.
    private struct Parser {
        let chars: [Character]
        let env: CfgSymbolEnvironment
        var i = 0

        init(text: String, env: CfgSymbolEnvironment) {
            self.chars = Array(text)
            self.env = env
        }

        var atEnd: Bool {
            mutating get { skipSpaces(); return i >= chars.count }
        }

        mutating func skipSpaces() {
            while i < chars.count, chars[i].isWhitespace { i += 1 }
        }

        mutating func parseExpression() -> Int64? {
            guard var lhs = parseTerm() else { return nil }
            while true {
                skipSpaces()
                guard i < chars.count, chars[i] == "+" || chars[i] == "-" else { return lhs }
                let op = chars[i]
                i += 1
                guard let rhs = parseTerm() else { return nil }
                // Report overflow rather than trapping on a hostile config.
                let (result, overflow) = op == "+"
                    ? lhs.addingReportingOverflow(rhs)
                    : lhs.subtractingReportingOverflow(rhs)
                if overflow { return nil }
                lhs = result
            }
        }

        mutating func parseTerm() -> Int64? {
            guard var lhs = parseFactor() else { return nil }
            while true {
                skipSpaces()
                guard i < chars.count, chars[i] == "*" || chars[i] == "/" else { return lhs }
                let op = chars[i]
                i += 1
                guard let rhs = parseFactor() else { return nil }
                if op == "/" {
                    guard rhs != 0 else { return nil }
                    lhs /= rhs
                } else {
                    let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
                    if overflow { return nil }
                    lhs = result
                }
            }
        }

        mutating func parseFactor() -> Int64? {
            skipSpaces()
            guard i < chars.count else { return nil }
            if chars[i] == "-" {
                i += 1
                guard let v = parseFactor() else { return nil }
                return -v
            }
            if chars[i] == "+" {
                i += 1
                return parseFactor()
            }
            return parsePrimary()
        }

        mutating func parsePrimary() -> Int64? {
            skipSpaces()
            guard i < chars.count else { return nil }

            if chars[i] == "(" {
                i += 1
                guard let v = parseExpression() else { return nil }
                skipSpaces()
                guard i < chars.count, chars[i] == ")" else { return nil }
                i += 1
                return v
            }

            // %S — the link start address. %O and friends are not numeric.
            if chars[i] == "%" {
                guard i + 1 < chars.count else { return nil }
                let flag = chars[i + 1]
                i += 2
                guard flag == "S" || flag == "s", let start = env.startAddress else { return nil }
                return Int64(start)
            }

            // $XXXX
            if chars[i] == "$" {
                i += 1
                return readDigits(radix: 16)
            }

            // 0xXXXX or decimal
            if chars[i].isNumber {
                if chars[i] == "0", i + 1 < chars.count, chars[i + 1] == "x" || chars[i + 1] == "X" {
                    i += 2
                    return readDigits(radix: 16)
                }
                return readDigits(radix: 10)
            }

            // Identifier — resolved from SYMBOLS.
            if chars[i].isLetter || chars[i] == "_" {
                let start = i
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" {
                    i += 1
                }
                let name = String(chars[start..<i])
                guard let value = env.symbols[name] else { return nil }
                return Int64(value)
            }

            return nil
        }

        mutating func readDigits(radix: Int) -> Int64? {
            let start = i
            while i < chars.count, chars[i].isHexDigit {
                // In base 10 stop at the first non-decimal digit so `$10 AND` etc.
                // do not silently absorb letters.
                if radix == 10, !chars[i].isNumber { break }
                i += 1
            }
            guard start < i else { return nil }
            return Int64(String(chars[start..<i]), radix: radix)
        }
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - Parser
// ═══════════════════════════════════════════════════════════

/// Parser for cc65 / ld65 linker configuration files.
///
/// Extracts the blocks the Memory Map needs:
///   * `MEMORY   { region: file=…, start=…, size=…, …; … }`
///   * `SEGMENTS { name:   load=region, run=region, type=…, …; … }`
///   * `FEATURES { STARTADDRESS: default = …; }`   — supplies `%S`
///   * `SYMBOLS  { name: value = …; }`             — supplies named constants
///
/// Values are read as either bare integers (`$1234` / `1234` / `0x1234`) or as
/// expressions. Expressions are evaluated against `FEATURES`/`SYMBOLS` where
/// possible — the stock cc65 C64 config places everything relative to `%S`, so
/// without this the planned column would show almost nothing. Values that still
/// cannot be resolved are reported through `CfgFileInfo.unresolvedRegions`.
enum CfgFileParser {

    /// ld65's start address for the C64 target when the config does not say
    /// otherwise. `BuildManager` never passes `--start-addr`, so this is the
    /// value the linker actually uses.
    static let defaultStartAddress: UInt32 = 0x0801

    static func parse(contentsOf url: URL) -> CfgFileInfo? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(text: text, sourceURL: url)
    }

    static func parse(text: String, sourceURL: URL? = nil) -> CfgFileInfo {
        let cleaned = stripComments(text)

        // Collect every block first: FEATURES/SYMBOLS may follow MEMORY in the
        // file, but MEMORY's expressions depend on them.
        var memoryEntries:  [(String, [String: String])] = []
        var segmentEntries: [(String, [String: String])] = []
        var featureEntries: [(String, [String: String])] = []
        var symbolEntries:  [(String, [String: String])] = []

        for (name, body) in topLevelBlocks(in: cleaned) {
            switch name.uppercased() {
            case "MEMORY":   memoryEntries  = parseEntries(body)
            case "SEGMENTS": segmentEntries = parseEntries(body)
            case "FEATURES": featureEntries = parseEntries(body)
            case "SYMBOLS":  symbolEntries  = parseEntries(body)
            default:
                continue   // FILES { … } — not needed yet.
            }
        }

        let env = buildEnvironment(features: featureEntries, symbols: symbolEntries)

        return CfgFileInfo(
            memory:   memoryEntries.map  { toMemoryRegion($0, env: env) },
            segments: segmentEntries.compactMap(toSegmentMapping(_:)),
            sourceURL: sourceURL,
            startAddress: env.startAddress
        )
    }

    // MARK: - Environment

    /// Builds the `%S` / symbol table used to evaluate MEMORY expressions.
    private static func buildEnvironment(
        features: [(String, [String: String])],
        symbols:  [(String, [String: String])]
    ) -> CfgSymbolEnvironment {
        var env = CfgSymbolEnvironment()

        // FEATURES { STARTADDRESS: default = $0801; }
        for (name, attrs) in features where name.uppercased() == "STARTADDRESS" {
            if let raw = attrs["default"], let value = parseNumber(raw) {
                env.startAddress = value
            }
        }
        if env.startAddress == nil { env.startAddress = defaultStartAddress }

        // SYMBOLS { __X__: type = weak, value = $0800; }
        // Symbols may reference each other, so iterate to a fixed point rather
        // than assuming declaration order. Bounded so a cycle cannot spin.
        var pending = symbols.compactMap { entry -> (String, String)? in
            guard let value = entry.1["value"] else { return nil }
            return (entry.0, value)
        }
        for _ in 0..<8 {
            guard !pending.isEmpty else { break }
            var stillPending: [(String, String)] = []
            for (name, raw) in pending {
                if let value = CfgExpression.evaluate(raw, in: env) {
                    env.symbols[name] = value
                } else {
                    stillPending.append((name, raw))
                }
            }
            if stillPending.count == pending.count { break }   // no progress
            pending = stillPending
        }

        return env
    }

    // MARK: - Comment stripping

    /// cc65 configs use `#` to end-of-line. Quoted strings are respected so a
    /// `#` inside `file = "a#b"` does not truncate the line.
    private static func stripComments(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var inQuotes = false
        var inComment = false

        for ch in text {
            if ch == "\n" {
                inQuotes = false
                inComment = false
                out.append(ch)
                continue
            }
            if inComment { continue }
            if inQuotes {
                out.append(ch)
                if ch == "\"" { inQuotes = false }
                continue
            }
            switch ch {
            case "\"": inQuotes = true; out.append(ch)
            case "#":   inComment = true
            default:    out.append(ch)
            }
        }
        return out
    }

    // MARK: - Block extraction

    /// Pull `IDENT { … }` blocks from the top level. Returns (name, body).
    private static func topLevelBlocks(in text: String) -> [(String, String)] {
        var out: [(String, String)] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            while i < chars.count, chars[i].isWhitespace { i += 1 }
            if i >= chars.count { break }

            let nameStart = i
            while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" {
                i += 1
            }
            let name = String(chars[nameStart..<i])
            if name.isEmpty { i += 1; continue }

            while i < chars.count, chars[i].isWhitespace { i += 1 }
            guard i < chars.count, chars[i] == "{" else { continue }

            var depth = 1
            i += 1
            let bodyStart = i
            while i < chars.count, depth > 0 {
                if chars[i] == "{" { depth += 1 }
                else if chars[i] == "}" { depth -= 1 }
                if depth > 0 { i += 1 }
            }
            let body = String(chars[bodyStart..<i])
            if i < chars.count { i += 1 }
            out.append((name, body))
        }
        return out
    }

    // MARK: - Entry parsing

    /// Parse `name: key = value, key = value;` repetitions out of a block body.
    private static func parseEntries(_ body: String) -> [(String, [String: String])] {
        var result: [(String, [String: String])] = []
        for raw in body.components(separatedBy: ";") {
            let entry = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if entry.isEmpty { continue }
            guard let colon = entry.firstIndex(of: ":") else { continue }
            let name = String(entry[entry.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let attrs = String(entry[entry.index(after: colon)...])
            result.append((name, parseAttributes(attrs)))
        }
        return result
    }

    /// `key=value, key=value, key="quoted"` → dictionary.
    /// Tracks parenthesis depth so commas inside expressions stay attached
    /// to the value they belong to.
    private static func parseAttributes(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        var depth = 0
        var inQuotes = false
        var current = ""
        var pieces: [String] = []
        for ch in s {
            if ch == "\"" {
                inQuotes.toggle()
                current.append(ch)
            } else if !inQuotes && (ch == "(" || ch == "[") {
                depth += 1; current.append(ch)
            } else if !inQuotes && (ch == ")" || ch == "]") {
                depth -= 1; current.append(ch)
            } else if !inQuotes && depth == 0 && ch == "," {
                pieces.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            pieces.append(current)
        }

        for piece in pieces {
            guard let eq = piece.firstIndex(of: "=") else { continue }
            let key = String(piece[piece.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            var val = String(piece[piece.index(after: eq)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if val.hasPrefix("\"") && val.hasSuffix("\"") && val.count >= 2 {
                val = String(val.dropFirst().dropLast())
            }
            out[key.lowercased()] = val
        }
        return out
    }

    // MARK: - Conversion

    private static func toMemoryRegion(
        _ entry: (String, [String: String]),
        env: CfgSymbolEnvironment
    ) -> CfgMemoryRegion {
        let (name, attrs) = entry
        let rawStart = attrs["start"] ?? ""
        let rawSize  = attrs["size"]  ?? ""

        let literalStart = parseNumber(rawStart)
        let literalSize  = parseNumber(rawSize)

        return CfgMemoryRegion(
            name: name,
            start: literalStart ?? CfgExpression.evaluate(rawStart, in: env),
            size:  literalSize  ?? CfgExpression.evaluate(rawSize,  in: env),
            rawStart: rawStart,
            rawSize: rawSize,
            file: attrs["file"],
            isStartLiteral: literalStart != nil,
            isSizeLiteral:  literalSize  != nil
        )
    }

    private static func toSegmentMapping(_ entry: (String, [String: String])) -> CfgSegmentMapping? {
        let (name, attrs) = entry
        guard let load = attrs["load"] else { return nil }
        return CfgSegmentMapping(name: name, load: load, run: attrs["run"], type: attrs["type"])
    }

    /// Parse a cfg numeric literal: `$XXXX`, `0xXXXX`, or decimal. Returns
    /// nil for expressions or anything we don't recognise.
    static func parseNumber(_ raw: String) -> UInt32? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }
        if s.hasPrefix("$") {
            return UInt32(s.dropFirst(), radix: 16)
        }
        if s.hasPrefix("0x") || s.hasPrefix("0X") {
            return UInt32(s.dropFirst(2), radix: 16)
        }
        return UInt32(s)
    }
}
