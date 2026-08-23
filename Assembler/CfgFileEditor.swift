//  CfgFileEditor.swift
//  C64 IDE
//
//  Surgical editor for cc65 / ld65 linker configuration (.cfg) files.
//  Patched via pure text-span replacement to preserve all formatting,
//  comments, and unrelated syntax blocks.

import Foundation

// MARK: - Error Handling

/// Errors that can occur during linker config patching.
enum CfgEditorError: Error, LocalizedError {
    case fileNotReadable
    case memoryBlockNotFound
    case regionNotFound(String)
    case attributeNotFound(String)
    case expressionNotEditable(attribute: String, raw: String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileNotReadable:
            return "Could not read the linker config file."
        case .memoryBlockNotFound:
            return "No MEMORY { } block found in the linker config."
        case .regionNotFound(let n):
            return "Memory region '\(n)' was not found in the MEMORY block."
        case .attributeNotFound(let a):
            return "Attribute '\(a)' was not found in the region entry."
        case .expressionNotEditable(let a, let raw):
            return "'\(a)' uses an expression (\(raw)) that cannot be edited automatically."
        case .writeFailed(let s):
            return "Write failed: \(s)"
        }
    }
}

// MARK: - CfgFileEditor

/// Surgical editor for cc65 / ld65 linker configuration files.
///
/// Patches the `start` and/or `size` attributes of a named MEMORY region
/// while preserving every other byte, including comments, blank lines,
/// SEGMENTS/FILES/FEATURES blocks, and unrelated attributes.
///
/// **Approach**
/// Pure text-span replacement rather than AST serialization:
/// 1. Locate the `MEMORY { … }` block via brace-matching.
/// 2. Find the target region by name followed by a colon.
/// 3. Delimit the entry by its trailing semicolon.
/// 4. Replace numeric values after `start =` and/or `size =` using a
///    character-level scanner that respects quotes and parentheses.
/// 5. Write atomically to prevent corruption.
///
/// **Limitations (by design)**
/// * Only plain numeric literals (`$XXXX`, `0xXXXX`, decimal) are replaced.
///   Expression values like `$10000 - $0800` throw `.expressionNotEditable`.
/// * Attribute names are matched case-insensitively.
/// * The MEMORY block must use standard `{ … }` brace syntax.
enum CfgFileEditor {

    // MARK: - Public API

    /// Patch `start` and/or `size` for a named MEMORY region in a `.cfg` file.
    ///
    /// - Parameters:
    ///   - url:        The `.cfg` file to patch (written back atomically).
    ///   - regionName: Name exactly as it appears before the colon in `MEMORY { }`.
    ///   - newStart:   New start address, or `nil` to leave unchanged.
    ///   - newSize:    New size, or `nil` to leave unchanged.
    /// - Throws: `CfgEditorError` for any structural or IO problem.
    static func patch(
        url: URL,
        regionName: String,
        newStart: UInt32? = nil,
        newSize: UInt32?  = nil
    ) throws {
        guard newStart != nil || newSize != nil else { return }

        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            throw CfgEditorError.fileNotReadable
        }

        let patched = try applyPatch(
            to: source,
            regionName: regionName,
            newStart: newStart,
            newSize: newSize
        )

        try atomicWrite(patched, to: url)
    }

    /// Pure-function variant for testing: takes and returns raw text.
    static func applyPatch(
        to source: String,
        regionName: String,
        newStart: UInt32? = nil,
        newSize: UInt32?  = nil
    ) throws -> String {
        let chars = Array(source)
        // `chars[n]` and `indices[n]` describe the same character, so value
        // spans can be converted to `String.Index` in O(1) instead of walking
        // the string from the start for every attribute.
        let indices = Array(source.indices)

        // 1. Find the MEMORY { … } block
        guard let memoryRange = findBlock(named: "MEMORY", in: chars) else {
            throw CfgEditorError.memoryBlockNotFound
        }

        // 2. Find the region entry within the MEMORY block
        guard let entryRange = findEntry(named: regionName, in: chars, within: memoryRange) else {
            throw CfgEditorError.regionNotFound(regionName)
        }

        // 3. Apply attribute replacements
        var result = source
        var pendingReplacements: [(attribute: String, newValue: UInt32)] = []
        if let v = newStart { pendingReplacements.append(("start", v)) }
        if let v = newSize  { pendingReplacements.append(("size",  v)) }

        var spans: [(range: Range<String.Index>, replacement: String)] = []

        for (attr, newVal) in pendingReplacements {
            let valueRange = try findAttributeValueRange(
                attribute: attr,
                in: chars,
                within: entryRange,
                indices: indices,
                endIndex: source.endIndex
            )
            let currentRaw = String(source[valueRange]).trimmingCharacters(in: .whitespaces)
            guard isPlainNumericLiteral(currentRaw) else {
                throw CfgEditorError.expressionNotEditable(attribute: attr, raw: currentRaw)
            }
            let formatted = formatValue(newVal, matching: currentRaw)
            spans.append((valueRange, formatted))
        }

        // Sort descending by position to avoid offset drift during replacement
        spans.sort { $0.range.lowerBound > $1.range.lowerBound }
        for (range, replacement) in spans {
            result.replaceSubrange(range, with: replacement)
        }

        return result
    }

    // MARK: - Block / Entry Location

    /// Find the body range (inside braces) of a top-level named block,
    /// ignoring `#`-comments to prevent false matches.
    private static func findBlock(named blockName: String, in chars: [Character]) -> Range<Int>? {
        let upper = blockName.uppercased()
        var i = 0
        while i < chars.count {
            if chars[i] == "#" {
                while i < chars.count && chars[i] != "\n" { i += 1 }
                continue
            }
            if chars[i].isLetter {
                let nameStart = i
                while i < chars.count && (chars[i].isLetter || chars[i].isNumber || chars[i] == "_") {
                    i += 1
                }
                let name = String(chars[nameStart..<i]).uppercased()
                var j = i
                while j < chars.count && chars[j].isWhitespace { j += 1 }
                if name == upper && j < chars.count && chars[j] == "{" {
                    let bodyStart = j + 1
                    var depth = 1
                    var k = bodyStart
                    while k < chars.count && depth > 0 {
                        if chars[k] == "{" { depth += 1 }
                        else if chars[k] == "}" { depth -= 1 }
                        k += 1
                    }
                    return bodyStart..<(k - 1)
                }
                continue
            }
            i += 1
        }
        return nil
    }

    /// Find the character range of a named entry (`regionName : … ;`) within
    /// a block body. Covers from the name start up to and including the semicolon.
    private static func findEntry(
        named entryName: String,
        in chars: [Character],
        within blockRange: Range<Int>
    ) -> Range<Int>? {
        var i = blockRange.lowerBound
        while i < blockRange.upperBound {
            if chars[i] == "#" {
                while i < blockRange.upperBound && chars[i] != "\n" { i += 1 }
                continue
            }
            if chars[i].isWhitespace { i += 1; continue }

            if chars[i].isLetter || chars[i] == "_" {
                let nameStart = i
                while i < blockRange.upperBound &&
                      (chars[i].isLetter || chars[i].isNumber || chars[i] == "_") {
                    i += 1
                }
                let name = String(chars[nameStart..<i])

                // Any whitespace may separate the entry name from its colon,
                // including a line break in a wrapped config.
                while i < blockRange.upperBound && chars[i].isWhitespace { i += 1 }
                guard i < blockRange.upperBound && chars[i] == ":" else { continue }
                i += 1

                if name == entryName {
                    guard let semiOffset = chars[i..<blockRange.upperBound].firstIndex(of: ";") else {
                        return nil
                    }
                    // Range is half-open, so `+ 1` includes the semicolon itself.
                    return nameStart..<(semiOffset + 1)
                } else {
                    if let semiOffset = chars[i..<blockRange.upperBound].firstIndex(of: ";") {
                        i = semiOffset + 1
                    } else {
                        break
                    }
                }
                continue
            }
            i += 1
        }
        return nil
    }

    /// Find the range of just the *value* text for a given attribute within
    /// an entry span. Returns a `Range<String.Index>` ready for `String.replaceSubrange`.
    private static func findAttributeValueRange(
        attribute: String,
        in chars: [Character],
        within entryRange: Range<Int>,
        indices: [String.Index],
        endIndex: String.Index
    ) throws -> Range<String.Index> {
        /// `indices` has one entry per character; `chars.count` maps to the end.
        func stringIndex(_ offset: Int) -> String.Index {
            offset < indices.count ? indices[offset] : endIndex
        }

        let attrLower = attribute.lowercased()
        var i = entryRange.lowerBound

        while i < entryRange.upperBound {
            if chars[i] == "#" {
                while i < entryRange.upperBound && chars[i] != "\n" { i += 1 }
                continue
            }
            if chars[i].isWhitespace { i += 1; continue }

            if chars[i].isLetter || chars[i] == "_" {
                let tokStart = i
                while i < entryRange.upperBound &&
                      (chars[i].isLetter || chars[i].isNumber || chars[i] == "_") {
                    i += 1
                }
                let token = String(chars[tokStart..<i]).lowercased()

                // Whitespace (including line breaks) may surround the `=`.
                while i < entryRange.upperBound && chars[i].isWhitespace { i += 1 }
                guard i < entryRange.upperBound && chars[i] == "=" else { continue }
                i += 1

                while i < entryRange.upperBound && chars[i].isWhitespace { i += 1 }

                if token == attrLower {
                    let valueStart = i
                    var depth = 0
                    var inQuotes = false
                    while i < entryRange.upperBound {
                        let ch = chars[i]
                        if ch == "\"" { inQuotes.toggle() }
                        else if !inQuotes && (ch == "(" || ch == "[") { depth += 1 }
                        else if !inQuotes && (ch == ")" || ch == "]") { depth -= 1 }
                        else if !inQuotes && depth == 0 && (ch == "," || ch == ";" || ch == "\n") {
                            break
                        }
                        i += 1
                    }
                    var valueEnd = i
                    while valueEnd > valueStart && chars[valueEnd - 1].isWhitespace {
                        valueEnd -= 1
                    }
                    return stringIndex(valueStart)..<stringIndex(valueEnd)
                } else {
                    var depth = 0
                    var inQuotes = false
                    while i < entryRange.upperBound {
                        let ch = chars[i]
                        if ch == "\"" { inQuotes.toggle() }
                        else if !inQuotes && (ch == "(" || ch == "[") { depth += 1 }
                        else if !inQuotes && (ch == ")" || ch == "]") { depth -= 1 }
                        else if !inQuotes && depth == 0 && (ch == "," || ch == ";") { break }
                        i += 1
                    }
                }
                continue
            }
            i += 1
        }
        throw CfgEditorError.attributeNotFound(attribute)
    }

    // MARK: - Value Helpers

    /// Returns true if the value is a plain numeric literal we can safely replace.
    private static func isPlainNumericLiteral(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return false }
        if s.hasPrefix("$") { return UInt32(s.dropFirst(), radix: 16) != nil }
        if s.hasPrefix("0x") || s.hasPrefix("0X") { return UInt32(s.dropFirst(2), radix: 16) != nil }
        return UInt32(s) != nil
    }

    /// Format a new value using the same style as the original.
    private static func formatValue(_ value: UInt32, matching original: String) -> String {
        let s = original.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("$") {
            let digits = s.dropFirst().count
            return String(format: "$%0\(digits)X", value)
        }
        if s.hasPrefix("0x") || s.hasPrefix("0X") {
            let digits = s.dropFirst(2).count
            let prefix = s.hasPrefix("0X") ? "0X" : "0x"
            return String(format: "\(prefix)%0\(digits)X", value)
        }
        return String(value)
    }

    // MARK: - Atomic Write

    private static func atomicWrite(_ text: String, to url: URL) throws {
        let dir  = url.deletingLastPathComponent()
        let temp = dir.appendingPathComponent(
            ".cfgedit.\(UUID().uuidString).\(url.lastPathComponent)")
        do {
            try text.write(to: temp, atomically: false, encoding: .utf8)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw CfgEditorError.writeFailed(error.localizedDescription)
        }
    }
}

