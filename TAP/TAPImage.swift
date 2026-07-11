import Foundation

// ═══════════════════════════════════════════════════════════
// MARK: - TAP Timing Preset
// ═══════════════════════════════════════════════════════════

/// Defines the timing thresholds for decoding TAP (Tape Archive) files.
/// All threshold values are in TAP byte units, where 1 unit = 8 µs.
struct TAPTiming: Equatable {
    /// Upper bound for SHORT pulse duration (below this is considered noise).
    var shortMax: UInt32
    
    /// Upper bound for MEDIUM pulse duration (above this is considered LONG/separator).
    var mediumMax: UInt32
    
    /// Minimum number of SHORT pulses required to identify a valid pilot tone.
    var minPilotPulses: Int

    // MARK: - Named Presets

    /// Standard PAL C64 / C128 timing (Clock: 985,248 Hz).
    static let palC64 = TAPTiming(shortMax: 53, mediumMax: 79, minPilotPulses: 160)
    
    /// NTSC C64 timing (Clock: 1,022,727 Hz).
    static let ntscC64 = TAPTiming(shortMax: 50, mediumMax: 74, minPilotPulses: 160)
    
    /// C16 / Plus/4 / 116 timing.
    static let c16 = TAPTiming(shortMax: 57, mediumMax: 84, minPilotPulses: 100)
    
    /// VIC-20 (PAL) timing.
    static let vic20 = TAPTiming(shortMax: 55, mediumMax: 81, minPilotPulses: 160)

    /// Collection of all named presets for UI display.
    static let allPresets: [(name: String, timing: TAPTiming)] = [
        ("PAL C64 / C128", .palC64),
        ("NTSC C64",       .ntscC64),
        ("C16 / Plus/4",   .c16),
        ("VIC-20 (PAL)",   .vic20),
    ]
}

// MARK: - Pulse Classification

/// Classifies a pulse width into one of three categories based on timing thresholds.
private enum PulseKind {
    case short  // Pilot tone, 0-bit first pulse, 1-bit second pulse
    case medium // 1-bit first pulse, 0-bit second pulse
    case long_  // Byte separator (not part of the bit stream)
    case unknown
}

// ═══════════════════════════════════════════════════════════
// MARK: - TAP Image
// ═══════════════════════════════════════════════════════════

/// Represents a TAP (Tape Archive) file. TAP files store raw pulse-width modulation data
/// representing the magnetic state of a cassette tape.
class TAPImage: TapeArchive {

    // MARK: TapeArchive conformance

    var fileURL: URL?
    var formatTag: String { "TAP" }
    
    var archiveName: String {
        fileURL?.deletingPathExtension().lastPathComponent ?? "tape"
    }

    private(set) var entries: [TAPEntry] = []
    private(set) var parseLog: [String] = []

    // MARK: TAP-specific public state

    /// The TAP format version (usually 1).
    let version: UInt8
    
    /// The target platform indicator (0=C64, 1=VIC-20, 2=C16).
    let platform: UInt8
    
    /// Indicates if the tape contains non-standard blocks (e.g., turbo loaders)
    /// that could not be decoded into standard PRG files.
    private(set) var hasTurboBlocks: Bool = false

    /// Active timing configuration. Mutate this property and call `reparse()` to re-decode the tape.
    var timing: TAPTiming

    // MARK: Private

    /// The raw pulse stream decoded from the file.
    private let pulses: [UInt32]

    // MARK: - Initialization

    /// Loads a TAP file from the given URL.
    /// - Parameter url: The file URL to load.
    /// - Throws: `TapeError.invalidSignature` or `TapeError.truncatedHeader` if the file is invalid.
    init(contentsOf url: URL) throws {
        let raw = try Data(contentsOf: url)
        guard raw.count >= 20 else { throw TapeError.truncatedHeader }

        let sig = String(bytes: raw[0..<12], encoding: .ascii) ?? ""
        guard sig.hasPrefix("C64-TAPE-RAW") ||
              sig.hasPrefix("C16-TAPE-RAW") ||
              sig.hasPrefix("VIC-TAPE-RAW") else {
            throw TapeError.invalidSignature
        }

        version  = raw[12]
        platform = raw[13]
        fileURL  = url

        // Select default timing based on platform signature
        switch platform {
        case 1:  timing = .vic20
        case 2:  timing = .c16
        default: timing = .palC64
        }

        // Decode raw bytes → pulse array (all values in TAP units = 8 µs each)
        let dataLen  = Int(raw[16]) | (Int(raw[17]) << 8) | (Int(raw[18]) << 16) | (Int(raw[19]) << 24)
        let pulseEnd = min(20 + dataLen, raw.count)
        var decoded: [UInt32] = []
        decoded.reserveCapacity(pulseEnd - 20)

        var i = 20
        while i < pulseEnd {
            let byte = raw[i]; i += 1
            if byte != 0 {
                // Standard compression: byte value represents pulse length
                decoded.append(UInt32(byte))
            } else if version == 1 {
                // Extended compression: 0x00 followed by 3 bytes LE value / 8
                guard i &+ 3 <= pulseEnd else { break }
                let lo  = UInt32(raw[i])
                let mid = UInt32(raw[i + 1])
                let hi  = UInt32(raw[i + 2])
                i += 3
                decoded.append((lo | (mid << 8) | (hi << 16)) / 8)
            } else {
                // Fallback for unknown versions
                decoded.append(256)
            }
        }

        pulses = decoded
        parse()
    }

    // MARK: - Reparse

    /// Re-decodes the pulse stream using the current `timing` settings.
    func reparse() {
        groupsCache    = nil   // group boundaries depend on timing (LONG classification)
        entries        = []
        hasTurboBlocks = false
        parseLog       = []
        parse()
    }

    // MARK: - Pulse Classifier

    /// Classifies a pulse value into SHORT, MEDIUM, or LONG based on current timing.
    private func classify(_ v: UInt32) -> PulseKind {
        if v < 15                 { return .unknown }
        if v <= timing.shortMax   { return .short   }
        if v <= timing.mediumMax  { return .medium  }
        return .long_
    }

    // MARK: - Pulse-group Splitter

    /// Cached result of makeGroups(). The full pulse array can run to
    /// millions of entries, and extractPRG previously re-split it from
    /// scratch on every extraction. Invalidated by reparse(), since group
    /// boundaries depend on the timing thresholds.
    private var groupsCache: [[UInt32]]?

    /// Returns the pulse groups, computing and caching them on first use.
    private func groups() -> [[UInt32]] {
        if let cached = groupsCache { return cached }
        let g = makeGroups()
        groupsCache = g
        return g
    }

    /// Splits the pulse stream into groups separated by LONG (separator) pulses.
    /// Data bytes are groups of exactly 19 short/medium pulses.
    private func makeGroups() -> [[UInt32]] {
        var groups: [[UInt32]] = []
        var current: [UInt32] = []
        for p in pulses {
            if classify(p) == .long_ {
                if !current.isEmpty { groups.append(current); current = [] }
            } else {
                current.append(p)
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    // MARK: - Byte Group Decoder

    /// Decodes a group of exactly 19 pulses into a single byte, verifying
    /// the trailing parity pair.
    /// Layout: [marker] [bit0_p1 bit0_p2] ... [bit7_p1 bit7_p2] [parity_p1 parity_p2]
    /// The KERNAL writes odd parity: the check bit starts at 1 and is EORed
    /// with each data bit, so a byte whose parity pair disagrees was
    /// misread (usually a pulse misclassified by borderline timing) and is
    /// rejected rather than silently accepted.
    private func decodeByteGroup(_ g: [UInt32]) -> UInt8? {
        guard g.count == 19 else { return nil }
        var result: UInt8 = 0
        var expectedParity: UInt8 = 1   // odd parity: check bit starts at 1
        for bit in 0..<8 {
            let p1 = classify(g[1 + bit * 2])
            let p2 = classify(g[2 + bit * 2])
            switch (p1, p2) {
            case (.short,  .medium):
                break                                       // bit = 0
            case (.medium, .short):
                result |= (1 << bit)                        // bit = 1
                expectedParity ^= 1
            default:
                return nil                                  // malformed pair
            }
        }
        // Parity pair at g[17], g[18], encoded like a data bit
        let parityBit: UInt8
        switch (classify(g[17]), classify(g[18])) {
        case (.short,  .medium): parityBit = 0
        case (.medium, .short):  parityBit = 1
        default:                 return nil                 // malformed pair
        }
        guard parityBit == expectedParity else { return nil }
        return result
    }

    // MARK: - Parser

    /// Main parsing loop: finds pilots, decodes byte streams, and processes blocks.
    private func parse() {
        log("TAP v\(version)  \(platformName)  \(pulses.count) pulses")
        log("Timing — S≤\(timing.shortMax)  M≤\(timing.mediumMax)  pilot≥\(timing.minPilotPulses)")

        let groups = self.groups()
        log("  \(groups.count) groups after splitting at LONG boundaries")

        var gi = 0
        var fileIdx = 0

        while gi < groups.count {
            let g = groups[gi]

            // Pilot detection: requires a run of SHORT pulses exceeding threshold
            guard g.count >= timing.minPilotPulses,
                  g.allSatisfy({ classify($0) == .short }) else {
                gi += 1
                continue
            }

            log("  Pilot at group \(gi): \(g.count) pulses")
            gi += 1

            // Collect all subsequent 19-pulse groups as a byte stream
            var byteStream: [UInt8] = []
            while gi < groups.count {
                guard groups[gi].count == 19,
                      let byte = decodeByteGroup(groups[gi]) else { break }
                byteStream.append(byte)
                gi += 1
            }

            guard !byteStream.isEmpty else {
                hasTurboBlocks = true
                log("  ⚠ No decodable bytes after pilot — possible turbo loader")
                continue
            }

            log("  Block: \(byteStream.count) raw bytes decoded")
            if !processBlock(byteStream, fileIndex: &fileIdx) {
                log("  Stopping at end-of-tape marker")
                break
            }
        }

        log("Done — \(entries.count) file(s)\(hasTurboBlocks ? ", turbo block(s) present" : "")")
    }

    // MARK: - Sync Countdown / Checksum (shared by parse and extractPRG)

    /// Walks the first-copy sync countdown $89, $88, ..., $81.
    /// Returns the index of the first byte after the countdown, or nil if
    /// the countdown is absent, incomplete, or has no content following it.
    /// (Repeat copies use $09..$01 and are intentionally not matched, so
    /// each recorded block is processed once.)
    private func consumeCountdown(in bytes: [UInt8]) -> Int? {
        guard let start = bytes.firstIndex(of: 0x89) else { return nil }
        var pos = start
        var expected: UInt8 = 0x89
        // Bound at $80: a corrupt stream continuing $80, $7F, ... must not
        // walk (or underflow) past the end of the countdown.
        while pos < bytes.count && expected > 0x80 && bytes[pos] == expected {
            expected -= 1
            pos += 1
        }
        guard expected == 0x80, pos < bytes.count else { return nil }
        return pos
    }

    /// XOR over a byte range. A block payload followed by its own XOR
    /// checksum reduces to zero, so `== 0` means the checksum verifies.
    private func xorReduce<S: Sequence>(_ bytes: S) -> UInt8 where S.Element == UInt8 {
        bytes.reduce(0, ^)
    }

    /// Content length of a standard header block after the countdown:
    /// 192 bytes (type + addresses + name + body) plus 1 checksum byte.
    private let headerContentPlusChecksum = 193

    // MARK: - Block Processor

    /// Processes a decoded byte stream (countdown + header content) to
    /// extract file information.
    /// Standard header types: $01 relocatable BASIC program, $02 data
    /// chunk, $03 non-relocatable (ML) program, $04 SEQ file header,
    /// $05 end-of-tape.
    /// Returns false when an end-of-tape marker is found, signalling the
    /// caller to stop parsing.
    private func processBlock(_ bytes: [UInt8], fileIndex: inout Int) -> Bool {
        guard let contentStart = consumeCountdown(in: bytes) else {
            log("  ! No valid sync countdown ($89..$81)")
            return true
        }

        // Verify the block checksum when the full standard header
        // (192 content bytes + 1 checksum) decoded. A failure usually means
        // marginal pulse timing; the entry is still listed so the user can
        // adjust the timing sliders and re-parse.
        if bytes.count >= contentStart + headerContentPlusChecksum {
            let ok = xorReduce(bytes[contentStart..<(contentStart + headerContentPlusChecksum)]) == 0
            log(ok ? "  Header checksum OK"
                   : "  ! Header checksum FAILED — data may be misread; try adjusting timing")
        } else {
            log("  ! Header truncated (\(bytes.count - contentStart) of \(headerContentPlusChecksum) bytes)")
        }

        var pos = contentStart
        let blockType = bytes[pos]; pos += 1

        switch blockType {
        case 0x01, 0x03:
            // Program header — $01 relocatable BASIC, $03 non-relocatable ML.
            // Identical layout: [type][loadL][loadH][endL][endH][name x16]...
            guard pos + 4 <= bytes.count else { return true }
            let load = UInt16(bytes[pos])     | (UInt16(bytes[pos + 1]) << 8)
            let end  = UInt16(bytes[pos + 2]) | (UInt16(bytes[pos + 3]) << 8)
            let nameEnd = min(pos + 4 + 16, bytes.count)
            let name = petsciiToString(Array(bytes[(pos + 4)..<nameEnd]))
            let sz   = end > load ? Int(end - load) : 0
            entries.append(TAPEntry(index: fileIndex, name: name,
                                    loadAddress: load, endAddress: end,
                                    kind: .program, sizeBytes: sz))
            let typeLabel = blockType == 0x01 ? "01/BASIC" : "03/ML"
            log("  Header(\(typeLabel)): \"\(name)\" PRG \(String(format: "$%04X-$%04X", load, end)) (\(sz)b)")
            fileIndex += 1

        case 0x04:
            // SEQ file header — same field layout; the data arrives later
            // in $02 chunks, which extractPRG does not reassemble.
            guard pos + 4 <= bytes.count else { return true }
            let load = UInt16(bytes[pos])     | (UInt16(bytes[pos + 1]) << 8)
            let end  = UInt16(bytes[pos + 2]) | (UInt16(bytes[pos + 3]) << 8)
            let nameEnd = min(pos + 4 + 16, bytes.count)
            let name = petsciiToString(Array(bytes[(pos + 4)..<nameEnd]))
            entries.append(TAPEntry(index: fileIndex, name: name,
                                    loadAddress: load, endAddress: end,
                                    kind: .sequential, sizeBytes: 0))
            log("  Header(04): \"\(name)\" SEQ (extraction not supported)")
            fileIndex += 1

        case 0x02:
            log("  Data chunk ($02) outside a SEQ context")

        case 0x05:
            log("  End-of-tape marker ($05)")
            return false

        default:
            log("  Data/unknown block type 0x\(String(format: "%02X", blockType))")
        }
        return true
    }

    // MARK: - Inter-block Pilot Threshold

    /// Minimum number of SHORT pulses required to identify an inter-block pilot tone.
    /// Main pilots are longer; verify-copy pilots are shorter.
    private let interBlockPilotMin = 40

    // MARK: - PRG Extraction

    /// Extracts the raw PRG data (including load address header) for a specific entry.
    func extractPRG(for entry: TAPEntry) -> Data? {
        guard entry.kind == .program else { return nil }

        let groups = self.groups()
        var gi = 0
        var fileIdx = 0

        while gi < groups.count {
            let g = groups[gi]

            // Main pilot: must meet the full minPilotPulses threshold
            guard g.count >= timing.minPilotPulses,
                  g.allSatisfy({ classify($0) == .short }) else {
                gi += 1; continue
            }
            gi += 1

            // Collect header block byte stream
            var byteStream: [UInt8] = []
            while gi < groups.count {
                guard groups[gi].count == 19,
                      let byte = decodeByteGroup(groups[gi]) else { break }
                byteStream.append(byte)
                gi += 1
            }
            guard !byteStream.isEmpty else { continue }

            // Walk the sync countdown; skip streams without one
            guard var pos = consumeCountdown(in: byteStream) else { continue }
            let blockType = byteStream[pos]; pos += 1

            // Header types that occupy directory slots — must mirror the
            // set that processBlock creates entries for, or fileIdx and
            // entry.index drift apart: $01/$03 programs, $04 SEQ.
            guard blockType == 0x01 || blockType == 0x03 || blockType == 0x04 else { continue }

            if fileIdx == entry.index {
                // SEQ data lives in $02 chunks; not reassembled here.
                guard blockType != 0x04 else { return nil }

                // Load address — same offsets for $01 and $03:
                // [type][loadL][loadH][endL][endH]...
                guard pos + 1 < byteStream.count else { return nil }
                let load = UInt16(byteStream[pos]) | (UInt16(byteStream[pos + 1]) << 8)

                // Skip verify copy of header:
                // advance past any inter-block pilot (>= interBlockPilotMin shorts)
                // and its following 19-pulse byte groups
                while gi < groups.count {
                    let vg = groups[gi]
                    if vg.count >= interBlockPilotMin, vg.allSatisfy({ classify($0) == .short }) {
                        gi += 1
                        while gi < groups.count && groups[gi].count == 19 { gi += 1 }
                        break
                    }
                    gi += 1
                }

                // Find data block pilot (may be preceded by a short transition group)
                while gi < groups.count {
                    let dg = groups[gi]
                    if dg.count >= interBlockPilotMin, dg.allSatisfy({ classify($0) == .short }) {
                        gi += 1

                        // Decode data block bytes
                        var dataBytes: [UInt8] = []
                        while gi < groups.count {
                            guard groups[gi].count == 19,
                                  let b = decodeByteGroup(groups[gi]) else { break }
                            dataBytes.append(b)
                            gi += 1
                        }

                        // If no bytes decoded, this was a transition group before the
                        // real data pilot (e.g. the short ~79-pulse run before a 5000+
                        // pulse main data pilot) — keep searching
                        guard !dataBytes.isEmpty else { continue }

                        // Consume the data block's sync countdown.
                        // The payload starts IMMEDIATELY after it — data
                        // blocks have no type byte (only header blocks do);
                        // the XOR checksum follows the payload at the end.
                        guard let dp = consumeCountdown(in: dataBytes) else { return nil }

                        let available = dataBytes.count - dp
                        let take = min(entry.sizeBytes, available)
                        guard take > 0 else { return nil }

                        // Verify the block checksum when it decoded:
                        // payload + checksum XORs to zero.
                        if available >= take + 1 {
                            let ok = xorReduce(dataBytes[dp..<(dp + take + 1)]) == 0
                            log(ok ? "Extract \"\(entry.name)\": data checksum OK"
                                   : "! Extract \"\(entry.name)\": data checksum FAILED — output may be corrupt")
                        } else {
                            log("! Extract \"\(entry.name)\": block shorter than declared size (\(available)/\(entry.sizeBytes)b)")
                        }

                        var prg = Data([UInt8(load & 0xFF), UInt8(load >> 8)])
                        prg.append(contentsOf: dataBytes[dp..<(dp + take)])
                        return prg
                    }
                    gi += 1
                }
                return nil  // couldn't find data block
            }
            fileIdx += 1
        }
        return nil
    }

    // MARK: - Helpers

    private var platformName: String {
        switch platform {
        case 0: return "C64/C128"
        case 1: return "VIC-20"
        case 2: return "C16/+4"
        default: return "platform \(platform)"
        }
    }

    private func log(_ msg: String) { parseLog.append(msg) }

    /// Converts PETSCII bytes to an ASCII string. Stops at null, $A0 (shift-space), or space padding.
    private func petsciiToString(_ bytes: [UInt8]) -> String {
        var s = ""
        for b in bytes {
            if b == 0x00 || b == 0xA0 { break }
            if b >= 0x20 && b < 0x7F { s.append(Character(UnicodeScalar(b))) }
        }
        return s.trimmingCharacters(in: .init(charactersIn: " "))
    }
}

// MARK: - TAP Writing (intentionally absent)
//
// A previous revision carried a synthetic TAP writer here. It was removed:
// it emitted raw file bytes as pulse widths (never routing them through a
// byte-to-pulse encoder), wrote an 18-byte header with the length field
// patched at the wrong offset, and was unreachable from the browser UI.
// A correct TAP writer (20-byte header, canonical $30/$42/$56 pulses, odd
// parity, block checksums, first + repeat copies) is a separate project;
// until one exists, TAPImage is read-only and TAP -> T64 or TAP -> PRG are
// the supported export paths.

