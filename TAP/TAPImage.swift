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
        //
        // The header's length field is advisory: some tools write 0, and
        // others a value past the end of the file. Trusting it blindly meant a
        // zero there produced an empty directory from an image whose pulse
        // data was sitting right after the header.
        let declaredLen = Int(raw[16]) | (Int(raw[17]) << 8)
                        | (Int(raw[18]) << 16) | (Int(raw[19]) << 24)
        let availableLen = raw.count - 20
        let dataLen  = (declaredLen > 0 && declaredLen <= availableLen) ? declaredLen : availableLen
        let pulseEnd = 20 + dataLen
        var decoded: [UInt32] = []
        decoded.reserveCapacity(dataLen)

        // Versions 1 and 2 both escape an over-long pulse as $00 followed by a
        // 24-bit little-endian length. Only v1 used to be handled, so a v2
        // image had those three length bytes read back as pulses of their own.
        let hasExtendedPulses = (version >= 1)

        var i = 20
        while i < pulseEnd {
            let byte = raw[i]; i += 1
            if byte != 0 {
                // Standard compression: byte value represents pulse length
                decoded.append(UInt32(byte))
            } else if hasExtendedPulses {
                // Extended compression: 0x00 followed by 3 bytes LE value / 8
                guard i &+ 3 <= pulseEnd else { break }
                let lo  = UInt32(raw[i])
                let mid = UInt32(raw[i + 1])
                let hi  = UInt32(raw[i + 2])
                i += 3
                decoded.append((lo | (mid << 8) | (hi << 16)) / 8)
            } else {
                // Version 0: $00 means "longer than 255 units", length unrecorded.
                decoded.append(256)
            }
        }

        pulses = decoded
        parse()
    }

    // MARK: - Reparse

    /// Re-decodes the pulse stream using the current `timing` settings.
    func reparse() {
        groupsCache     = nil   // group boundaries depend on timing (LONG classification)
        blocksCache     = nil   // blocks are built from groups
        entries         = []
        payloadsByIndex = [:]
        hasTurboBlocks  = false
        parseLog        = []
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
    /// millions of entries, and the tape walk would otherwise re-split it
    /// from scratch. Invalidated by reparse(), since group boundaries depend
    /// on the timing thresholds.
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

    // MARK: - Pilot Detection

    /// Proportion of a group's pulses that must be SHORT for it to count as a
    /// pilot tone, as a percentage.
    ///
    /// Requiring *every* pulse to be SHORT made a single bad sample — one
    /// dropout on a decades-old cassette — hide an entire file from the
    /// directory, with nothing logged and the turbo flag left clear. No
    /// timing adjustment could recover it, because the test was unanimity
    /// rather than a threshold.
    private let pilotShortPercent = 95

    /// True when a group is a pilot tone of at least `minPulses` pulses.
    ///
    /// Byte groups can't be mistaken for pilots: they are 19 pulses long, far
    /// below any pilot threshold, and roughly half their pulses are MEDIUM.
    private func isPilot(_ g: [UInt32], minPulses: Int) -> Bool {
        guard g.count >= minPulses else { return false }
        var shorts = 0
        for p in g where classify(p) == .short { shorts += 1 }
        return shorts * 100 >= g.count * pilotShortPercent
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

    // MARK: - Recorded Blocks

    /// One recorded block: a pilot tone plus the bytes that follow it.
    private struct TapeBlock {
        /// Index of the pilot group in the group array, for log messages.
        let pilotIndex: Int
        /// Bytes decoded from the 19-pulse groups after the pilot. Empty when
        /// nothing decoded, which is the signature of a turbo loader.
        let bytes: [UInt8]
    }

    /// Cached tape walk. Invalidated by reparse() along with the groups.
    private var blocksCache: [TapeBlock]?

    /// Splits the tape into pilot-led blocks.
    ///
    /// This is the single walk of the tape. `parse()` and PRG extraction were
    /// previously two independent walks that each counted files their own
    /// way, and they disagreed about malformed blocks — a header the parser
    /// skipped was still counted during extraction, so their file indices
    /// drifted and a listed file could not be extracted. One walk removes the
    /// possibility.
    private func blocks() -> [TapeBlock] {
        if let cached = blocksCache { return cached }

        let groups = self.groups()
        var out: [TapeBlock] = []
        var gi = 0

        while gi < groups.count {
            guard isPilot(groups[gi], minPulses: timing.minPilotPulses) else {
                gi += 1
                continue
            }
            let pilotIndex = gi
            gi += 1

            var byteStream: [UInt8] = []
            while gi < groups.count,
                  groups[gi].count == 19,
                  let byte = decodeByteGroup(groups[gi]) {
                byteStream.append(byte)
                gi += 1
            }
            out.append(TapeBlock(pilotIndex: pilotIndex, bytes: byteStream))
        }

        blocksCache = out
        return out
    }

    // MARK: - Sync Countdown / Checksum

    /// Walks the first-copy sync countdown $89, $88, ..., $81.
    /// Returns the index of the first byte after the countdown, or nil if
    /// the countdown is absent, incomplete, or has no content following it.
    /// (Repeat copies use $09..$01 and are intentionally not matched, so
    /// each recorded block is processed once.)
    ///
    /// Retries at the next $89 when a run doesn't complete: a stray $89 ahead
    /// of the real countdown used to make the whole block unreadable.
    private func consumeCountdown(in bytes: [UInt8]) -> Int? {
        var searchFrom = 0
        while searchFrom < bytes.count,
              let start = bytes[searchFrom...].firstIndex(of: 0x89) {
            var pos = start
            var expected: UInt8 = 0x89
            // Bound at $80: a corrupt stream continuing $80, $7F, ... must not
            // walk (or underflow) past the end of the countdown.
            while pos < bytes.count && expected > 0x80 && bytes[pos] == expected {
                expected -= 1
                pos += 1
            }
            if expected == 0x80 && pos < bytes.count { return pos }
            searchFrom = start + 1
        }
        return nil
    }

    /// XOR over a byte range. A block payload followed by its own XOR
    /// checksum reduces to zero, so `== 0` means the checksum verifies.
    private func xorReduce<S: Sequence>(_ bytes: S) -> UInt8 where S.Element == UInt8 {
        bytes.reduce(0, ^)
    }

    /// Content length of a standard header block after the countdown:
    /// 192 bytes (type + addresses + name + body) plus 1 checksum byte.
    private let headerContentPlusChecksum = 193

    /// Header block types that occupy a directory slot.
    private let directoryBlockTypes: Set<UInt8> = [0x01, 0x03, 0x04]

    /// True when a block's content looks like a standard header rather than
    /// file data. Used to notice that a file's data block is missing, so its
    /// successor's header isn't consumed as payload.
    private func looksLikeHeader(_ content: ArraySlice<UInt8>) -> Bool {
        content.count == headerContentPlusChecksum
            && content.first.map { (0x01...0x05).contains($0) } == true
    }

    // MARK: - Parser

    /// Main parsing loop: walks the recorded blocks, building directory
    /// entries and capturing each program's payload as it goes.
    private func parse() {
        log("TAP v\(version)  \(platformName)  \(pulses.count) pulses")
        log("Timing — S≤\(timing.shortMax)  M≤\(timing.mediumMax)  pilot≥\(timing.minPilotPulses)")

        let blocks = self.blocks()
        log("  \(groups().count) groups after splitting at LONG boundaries")
        log("  \(blocks.count) pilot-led block(s)")

        var fileIdx = 0
        var i = 0

        while i < blocks.count {
            let block = blocks[i]

            guard !block.bytes.isEmpty else {
                hasTurboBlocks = true
                log("  ⚠ Pilot at group \(block.pilotIndex) with no decodable bytes — possible turbo loader")
                i += 1
                continue
            }

            // Blocks without a first-copy countdown are the repeat copies
            // ($09..$01) that follow every recorded block. Skipping them here
            // is what stops each file being listed twice.
            guard let contentStart = consumeCountdown(in: block.bytes) else {
                i += 1
                continue
            }

            log("  Block at group \(block.pilotIndex): \(block.bytes.count) raw bytes decoded")
            verifyHeaderChecksum(block.bytes, contentStart: contentStart)

            let blockType = block.bytes[contentStart]
            let fieldStart = contentStart + 1

            switch blockType {
            case 0x01, 0x03:
                // Program header — $01 relocatable BASIC, $03 non-relocatable ML.
                // Identical layout: [type][loadL][loadH][endL][endH][name x16]...
                guard let fields = headerFields(block.bytes, from: fieldStart) else {
                    log("  ! Program header truncated — not listed")
                    i += 1
                    continue
                }
                let sz = fields.end > fields.load ? Int(fields.end - fields.load) : 0
                entries.append(TAPEntry(index: fileIdx, name: fields.name,
                                        loadAddress: fields.load, endAddress: fields.end,
                                        kind: .program, sizeBytes: sz))
                let typeLabel = blockType == 0x01 ? "01/BASIC" : "03/ML"
                log("  Header(\(typeLabel)): \"\(fields.name)\" PRG "
                  + "\(String(format: "$%04X-$%04X", fields.load, fields.end)) (\(sz)b)")

                // The data block is the next block carrying a first-copy
                // countdown; the header's own repeat copy in between has
                // $09..$01 and is skipped by consumeCountdown.
                i += 1
                i = capturePayload(from: blocks, startingAt: i,
                                   fileIndex: fileIdx, declaredSize: sz, name: fields.name)
                fileIdx += 1

            case 0x04:
                // SEQ file header — same field layout; the data arrives later
                // in $02 chunks, which are not reassembled.
                guard let fields = headerFields(block.bytes, from: fieldStart) else {
                    log("  ! SEQ header truncated — not listed")
                    i += 1
                    continue
                }
                entries.append(TAPEntry(index: fileIdx, name: fields.name,
                                        loadAddress: fields.load, endAddress: fields.end,
                                        kind: .sequential, sizeBytes: 0))
                log("  Header(04): \"\(fields.name)\" SEQ (extraction not supported)")
                fileIdx += 1
                i += 1

            case 0x05:
                log("  End-of-tape marker ($05)")
                log("Done — \(entries.count) file(s)\(hasTurboBlocks ? ", turbo block(s) present" : "")")
                return

            case 0x02:
                log("  Data chunk ($02) outside a SEQ context")
                i += 1

            default:
                log("  Data/unknown block type 0x\(String(format: "%02X", blockType))")
                i += 1
            }
        }

        log("Done — \(entries.count) file(s)\(hasTurboBlocks ? ", turbo block(s) present" : "")")
    }

    /// Logs whether a header block's XOR checksum verifies.
    ///
    /// A failure usually means marginal pulse timing; the entry is still
    /// listed so the user can adjust the timing sliders and re-parse.
    private func verifyHeaderChecksum(_ bytes: [UInt8], contentStart: Int) {
        guard bytes.count >= contentStart + headerContentPlusChecksum else {
            log("  ! Header truncated (\(bytes.count - contentStart) of \(headerContentPlusChecksum) bytes)")
            return
        }
        let ok = xorReduce(bytes[contentStart..<(contentStart + headerContentPlusChecksum)]) == 0
        log(ok ? "  Header checksum OK"
               : "  ! Header checksum FAILED — data may be misread; try adjusting timing")
    }

    /// Reads the load address, end address and name shared by header types
    /// $01, $03 and $04.
    private func headerFields(_ bytes: [UInt8],
                              from pos: Int) -> (load: UInt16, end: UInt16, name: String)? {
        guard pos + 4 <= bytes.count else { return nil }
        let load = UInt16(bytes[pos])     | (UInt16(bytes[pos + 1]) << 8)
        let end  = UInt16(bytes[pos + 2]) | (UInt16(bytes[pos + 3]) << 8)
        let nameEnd = min(pos + 4 + 16, bytes.count)
        let name = PETSCII.decodeName(Array(bytes[(pos + 4)..<nameEnd]))
        return (load, end, name)
    }

    /// Captures the payload of the data block belonging to the header just
    /// read, and returns the block index to continue from.
    ///
    /// Resolving payloads during the parse is what lets `extractPRG` be a
    /// lookup rather than a second, independently-counted walk of the tape.
    private func capturePayload(from blocks: [TapeBlock],
                                startingAt start: Int,
                                fileIndex: Int,
                                declaredSize: Int,
                                name: String) -> Int {
        var i = start
        while i < blocks.count {
            let candidate = blocks[i]
            guard !candidate.bytes.isEmpty,
                  let dp = consumeCountdown(in: candidate.bytes) else {
                i += 1
                continue
            }

            // A following header means this file's data block never recorded.
            if looksLikeHeader(candidate.bytes[dp...]) {
                log("  ! \"\(name)\": no data block found — cannot extract")
                return i
            }

            // Data blocks have no type byte; the payload starts immediately
            // after the countdown, with the XOR checksum at the end.
            let available = candidate.bytes.count - dp
            let take = min(declaredSize, available)
            guard take > 0 else {
                log("  ! \"\(name)\": data block empty")
                return i + 1
            }

            if available >= take + 1 {
                let ok = xorReduce(candidate.bytes[dp..<(dp + take + 1)]) == 0
                log(ok ? "  \"\(name)\": data checksum OK"
                       : "  ! \"\(name)\": data checksum FAILED — extracted data may be corrupt")
            } else {
                log("  ! \"\(name)\": block shorter than declared size (\(available)/\(declaredSize)b)")
            }

            payloadsByIndex[fileIndex] = Data(candidate.bytes[dp..<(dp + take)])
            return i + 1
        }

        log("  ! \"\(name)\": tape ends before its data block")
        return i
    }

    // MARK: - PRG Extraction

    /// Payload bytes per directory index, captured during `parse()`.
    /// No load-address header — `extractPRG` prepends it.
    private var payloadsByIndex: [Int: Data] = [:]

    /// Extracts the raw PRG data (including load address header) for a specific entry.
    func extractPRG(for entry: TAPEntry) -> Data? {
        guard entry.kind == .program,
              let payload = payloadsByIndex[entry.index],
              !payload.isEmpty else { return nil }

        var prg = Data([UInt8(entry.loadAddress & 0xFF), UInt8(entry.loadAddress >> 8)])
        prg.append(payload)
        return prg
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

