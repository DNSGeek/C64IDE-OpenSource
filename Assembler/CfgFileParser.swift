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
    let start: UInt32?       // nil if start is an unresolved expression
    let size: UInt32?        // nil if size is an unresolved expression
    let rawStart: String     // raw text for tooltips
    let rawSize: String
    let file: String?        // %O = main output, "" = none, or a literal name
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
}

/// Parser for cc65 / ld65 linker configuration files.
///
/// Extracts two top-level blocks:
///   * `MEMORY  { region: file=…, start=…, size=…, …; … }`
///   * `SEGMENTS{ name:   load=region, run=region, type=…, …;   … }`
///
/// Values are read as either bare integers (`$1234` / `1234` / `0x1234`) or as
/// identifiers / expressions. Expressions are stored as raw text since we
/// can't evaluate them without a full link pass — the view renders such
/// regions with dashed outlines to indicate "unknown".
enum CfgFileParser {

    static func parse(contentsOf url: URL) -> CfgFileInfo? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(text: text, sourceURL: url)
    }

    static func parse(text: String, sourceURL: URL? = nil) -> CfgFileInfo {
        // Strip comments: cc65 cfg uses `#…` to end-of-line.
        let cleaned = text
            .components(separatedBy: "\n")
            .map { line -> String in
                if let hashIdx = line.firstIndex(of: "#") {
                    return String(line[line.startIndex..<hashIdx])
                }
                return line
            }
            .joined(separator: "\n")

        var memory: [CfgMemoryRegion] = []
        var segments: [CfgSegmentMapping] = []

        let blocks = topLevelBlocks(in: cleaned)
        for (name, body) in blocks {
            switch name.uppercased() {
            case "MEMORY":
                memory = parseEntries(body).map(toMemoryRegion(_:))
            case "SEGMENTS":
                segments = parseEntries(body).compactMap(toSegmentMapping(_:))
            default:
                continue   // FILES { … }, FEATURES { … }, SYMBOLS { … } — not needed yet.
            }
        }

        return CfgFileInfo(memory: memory, segments: segments, sourceURL: sourceURL)
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
            var val = String(piece[piece.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if val.hasPrefix("\"") && val.hasSuffix("\"") && val.count >= 2 {
                val = String(val.dropFirst().dropLast())
            }
            out[key.lowercased()] = val
        }
        return out
    }

    // MARK: - Conversion

    private static func toMemoryRegion(_ entry: (String, [String: String])) -> CfgMemoryRegion {
        let (name, attrs) = entry
        let rawStart = attrs["start"] ?? ""
        let rawSize  = attrs["size"]  ?? ""
        return CfgMemoryRegion(
            name: name,
            start: parseNumber(rawStart),
            size:  parseNumber(rawSize),
            rawStart: rawStart,
            rawSize: rawSize,
            file: attrs["file"]
        )
    }

    private static func toSegmentMapping(_ entry: (String, [String: String])) -> CfgSegmentMapping? {
        let (name, attrs) = entry
        guard let load = attrs["load"] else { return nil }
        return CfgSegmentMapping(name: name, load: load, run: attrs["run"], type: attrs["type"])
    }

    /// Parse a cfg numeric literal: `$XXXX`, `0xXXXX`, or decimal. Returns
    /// nil for expressions or anything we don't recognise.
    private static func parseNumber(_ raw: String) -> UInt32? {
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

