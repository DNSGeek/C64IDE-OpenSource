//  MapFileParser.swift
//  C64 IDE
//
//  Parses the human-readable .map file produced by ld65's --mapfile flag.
//  Extracts segment names, start addresses, end addresses, and sizes for
//  the Memory Map window visualization.

import Foundation

/// Represents a single segment entry from an ld65 map file.
struct MapFileSegment {
    let name: String
    let start: UInt32
    let end: UInt32
    let size: UInt32
}

/// Parsed metadata for a linker map file.
struct MapFileInfo {
    let segments: [MapFileSegment]
    let sourceURL: URL?
}

/// Parser for ld65 `--mapfile` output.
enum MapFileParser {

    /// Parses a map file from disk.
    static func parse(contentsOf url: URL) -> MapFileInfo? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return MapFileInfo(segments: parseSegments(text), sourceURL: url)
    }

    /// Extracts the segment list from the map file body.
    ///
    /// The map file contains several sections. We only consume the **Segment list**,
    /// as it provides absolute addresses required for the Memory Map view.
    ///
    /// Example slice:
    /// ```
    /// Segment list:
    /// -------------
    /// Name                   Start     End    Size  Align
    /// ----------------------------------------------------
    /// LOADADDR              000801   000802  000002  00001
    /// CODE                  00080F   00081C  00000E  00001
    /// ```
    static func parseSegments(_ text: String) -> [MapFileSegment] {
        var result: [MapFileSegment] = []
        var inSegmentList = false
        var sawHeader = false

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if !inSegmentList {
                if line.hasPrefix("Segment list") {
                    inSegmentList = true
                    sawHeader = false
                }
                continue
            }

            // Inside the section. Skip the dashed rule and the column header.
            if line.isEmpty {
                if sawHeader { break }     // blank line *after* the table = section end
                continue
            }
            if line.hasPrefix("-") { continue }
            if line.hasPrefix("Name") { sawHeader = true; continue }

            // Stop if a new section starts ("Exports list by name:", etc.)
            if line.hasSuffix(":") {
                break
            }

            // Five whitespace-separated columns: name start end size align
            let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard cols.count >= 4 else { continue }

            let name = String(cols[0])
            guard let start = UInt32(cols[1], radix: 16),
                  let end   = UInt32(cols[2], radix: 16),
                  let size  = UInt32(cols[3], radix: 16) else { continue }

            // Empty segments still appear in the map; keep them so the user can
            // see their declared placement, but skip ones we obviously can't plot.
            if size == 0 && start == 0 { continue }

            // ld65 prints `End = Start + Size - 1`, so a zero-size segment has
            // End one *below* Start. Normalise so `end >= start` always holds —
            // downstream code does unsigned `end - start` arithmetic, which
            // traps on underflow.
            result.append(MapFileSegment(name: name, start: start,
                                         end: max(end, start), size: size))
        }

        return result
    }
}

