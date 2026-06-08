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

    /// Decodes a group of exactly 19 pulses into a single byte.
    /// Layout: [marker] [bit0_p1 bit0_p2] ... [bit7_p1 bit7_p2] [parity_p1 parity_p2]
    private func decodeByteGroup(_ g: [UInt32]) -> UInt8? {
        guard g.count == 19 else { return nil }
        var result: UInt8 = 0
        for bit in 0..<8 {
            let p1 = classify(g[1 + bit * 2])
            let p2 = classify(g[2 + bit * 2])
            switch (p1, p2) {
            case (.short,  .medium): break                    // bit = 0
            case (.medium, .short):  result |= (1 << bit)    // bit = 1
            default:                 return nil               // malformed
            }
        }
        return result
    }

    // MARK: - Parser

    /// Main parsing loop: finds pilots, decodes byte streams, and processes blocks.
    private func parse() {
        log("TAP v\(version)  \(platformName)  \(pulses.count) pulses")
        log("Timing — S≤\(timing.shortMax)  M≤\(timing.mediumMax)  pilot≥\(timing.minPilotPulses)")

        let groups = makeGroups()
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
            processBlock(byteStream, fileIndex: &fileIdx)
        }

        log("Done — \(entries.count) file(s)\(hasTurboBlocks ? ", turbo block(s) present" : "")")
    }

    // MARK: - Block Processor

    /// Processes a decoded byte stream (pilot + header + data) to extract file information.
    private func processBlock(_ bytes: [UInt8], fileIndex: inout Int) {
        guard let syncStart = bytes.firstIndex(of: 0x89) else {
            log("  ⚠ No sync bytes found")
            return
        }

        var pos = syncStart
        var expected: UInt8 = 0x89
        // Verify sync sequence: 0x89, 0x88, ..., 0x81
        while pos < bytes.count && bytes[pos] == expected { expected -= 1; pos += 1 }
        guard expected == 0x80 else {
            log("  ⚠ Incomplete sync (stopped at 0x\(String(format: "%02X", expected + 1)))")
            return
        }

        guard pos < bytes.count else { return }
        let blockType = bytes[pos]; pos += 1

        switch blockType {
        case 0x09:  // Relocatable program header
            guard pos + 5 <= bytes.count else { return }
            let load = UInt16(bytes[pos + 1]) | (UInt16(bytes[pos + 2]) << 8)
            let end  = UInt16(bytes[pos + 3]) | (UInt16(bytes[pos + 4]) << 8)
            let nameEnd = min(pos + 5 + 16, bytes.count)
            let name = petsciiToString(Array(bytes[(pos + 5)..<nameEnd]))
            let sz   = end > load ? Int(end - load) : 0
            entries.append(TAPEntry(index: fileIndex, name: name,
                                    loadAddress: load, endAddress: end,
                                    kind: .program, sizeBytes: sz))
            log("  Header(09): \"\(name)\" PRG \(String(format: "$%04X–$%04X", load, end)) (\(sz)b)")
            fileIndex += 1

        case 0x03:  // Non-relocatable header
            guard pos + 4 <= bytes.count else { return }
            let load = UInt16(bytes[pos])     | (UInt16(bytes[pos + 1]) << 8)
            let end  = UInt16(bytes[pos + 2]) | (UInt16(bytes[pos + 3]) << 8)
            let nameEnd = min(pos + 4 + 16, bytes.count)
            let name = petsciiToString(Array(bytes[(pos + 4)..<nameEnd]))
            let sz   = end > load ? Int(end - load) : 0
            entries.append(TAPEntry(index: fileIndex, name: name,
                                    loadAddress: load, endAddress: end,
                                    kind: .program, sizeBytes: sz))
            log("  Header(03): \"\(name)\" PRG \(String(format: "$%04X–$%04X", load, end)) (\(sz)b)")
            fileIndex += 1

        case 0x05:
            log("  End-of-tape marker")

        default:
            log("  Data/unknown block type 0x\(String(format: "%02X", blockType))")
        }
    }

    // MARK: - Inter-block Pilot Threshold

    /// Minimum number of SHORT pulses required to identify an inter-block pilot tone.
    /// Main pilots are longer; verify-copy pilots are shorter.
    private let interBlockPilotMin = 40

    // MARK: - PRG Extraction

    /// Extracts the raw PRG data (including load address header) for a specific entry.
    func extractPRG(for entry: TAPEntry) -> Data? {
        let groups = makeGroups()
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

            // Decode block type from sync
            guard let syncStart = byteStream.firstIndex(of: 0x89) else { continue }
            var pos = syncStart
            var expected: UInt8 = 0x89
            while pos < byteStream.count && byteStream[pos] == expected { expected -= 1; pos += 1 }
            guard expected == 0x80, pos < byteStream.count else { continue }

            let blockType = byteStream[pos]; pos += 1
            guard blockType == 0x09 || blockType == 0x03 else { continue }

            // Extract load address — offset differs by block type
            let load: UInt16
            if blockType == 0x09 {
                guard pos + 2 < byteStream.count else { continue }
                load = UInt16(byteStream[pos + 1]) | (UInt16(byteStream[pos + 2]) << 8)
            } else {  // 0x03
                guard pos + 1 < byteStream.count else { continue }
                load = UInt16(byteStream[pos]) | (UInt16(byteStream[pos + 1]) << 8)
            }

            if fileIdx == entry.index {
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

                        // Find and consume sync in data block
                        guard let ds = dataBytes.firstIndex(of: 0x89) else { return nil }
                        var dp = ds
                        var de: UInt8 = 0x89
                        while dp < dataBytes.count && dataBytes[dp] == de { de -= 1; dp += 1 }
                        guard de == 0x80, dp < dataBytes.count else { return nil }
                        dp += 1  // skip block type byte — don't care what it is

                        // Payload follows immediately
                        let available = dataBytes.count - dp
                        let take = min(entry.sizeBytes, available)
                        guard take > 0 else { return nil }

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

// MARK: - TAP Image Extension (Saving)

extension TAPImage {
    /// Encodes raw bytes into TAP pulse stream format.
    /// This is a synthetic encoder for creating TAP files programmatically.
    private func encodePulses(for data: Data) -> Data {
        var pulses = Data()
        let short = UInt32(timing.shortMax)
        let medium = UInt32(timing.mediumMax)

        for byte in data {
            // 19 pulses: marker + 8 bit-pairs + parity
            pulses.append(UInt8(short)) // marker
            for bit in 0..<8 {
                let isOne = (byte >> bit) & 1 == 1
                if isOne {
                    pulses.append(UInt8(medium)); pulses.append(UInt8(short))
                } else {
                    pulses.append(UInt8(short)); pulses.append(UInt8(medium))
                }
            }
            pulses.append(UInt8(short)); pulses.append(UInt8(medium)) // parity
            pulses.append(UInt8(timing.mediumMax + 1)) // LONG separator
        }
        return pulses
    }

    /// Packs pulses into TAP's 0x00 compression format.
    private func compressPulses(_ pulses: Data) -> Data {
        var compressed = Data()
        var i = 0
        while i < pulses.count {
            let val = UInt32(pulses[i])
            if val > 255 {
                // Use 0x00 + 3-byte LE value (divided by 8 per decoder)
                compressed.append(0x00)
                let enc = val * 8
                compressed.append(UInt8(enc & 0xFF))
                compressed.append(UInt8((enc >> 8) & 0xFF))
                compressed.append(UInt8((enc >> 16) & 0xFF))
                i += 1
            } else {
                compressed.append(UInt8(val))
                i += 1
            }
        }
        return compressed
    }

    /// Saves the archive to a TAP file.
    /// Note: This generates a synthetic TAP file structure. It is not a standard TAP writer
    /// but rather a browser convenience for exporting PRGs back to tape format.
    func save(to url: URL, addingFile name: String, loadAddress: UInt16, endAddress: UInt16, data: Data) throws {
        var tapData = Data()

        // Header
        tapData.append(Data("C64-TAPE-RAW".utf8))
        tapData.append(Data([version, platform]))
        tapData.append(Data(repeating: 0, count: 4)) // length placeholder

        // Block builder
        func makeBlock(data: Data, isHeader: Bool, pilotCount: Int) -> Data {
            var block = Data()
            for _ in 0..<pilotCount { block.append(UInt8(timing.shortMax)) }
            for i in stride(from: 0x89, through: 0x81, by: -1) { block.append(UInt8(i)) }
            block.append(isHeader ? UInt8(0x09) : UInt8(0x08))
            if isHeader {
                block.append(UInt8(0x02)) // sub-type
                block.append(UInt8(loadAddress & 0xFF))
                block.append(UInt8(loadAddress >> 8))
                block.append(UInt8(endAddress & 0xFF))
                block.append(UInt8(endAddress >> 8))
                block.append(Data(name.petsciiPadded(to: 16)))
            } else {
                block.append(data)
            }
            return block
        }

        // Tape structure
        tapData.append(makeBlock(data: Data(), isHeader: true, pilotCount: timing.minPilotPulses)) // Main pilot
        tapData.append(makeBlock(data: Data(), isHeader: true, pilotCount: timing.minPilotPulses)) // Header block
        tapData.append(makeBlock(data: Data(), isHeader: true, pilotCount: 40)) // Verify pilot
        tapData.append(makeBlock(data: Data(), isHeader: true, pilotCount: timing.minPilotPulses)) // Verify header
        tapData.append(makeBlock(data: Data(), isHeader: true, pilotCount: interBlockPilotMin)) // Inter-block pilot
        tapData.append(makeBlock(data: data, isHeader: false, pilotCount: timing.minPilotPulses)) // Data block

        // Update header length
        let length = UInt32(tapData.count - 20)
        tapData[16] = UInt8(length & 0xFF)
        tapData[17] = UInt8((length >> 8) & 0xFF)
        tapData[18] = UInt8((length >> 16) & 0xFF)
        tapData[19] = UInt8((length >> 24) & 0xFF)

        // Safe write
        let compressed = compressPulses(tapData)
        let tempURL = url.deletingLastPathComponent().appendingPathComponent(".tmp_\(url.lastPathComponent)")
        try compressed.write(to: tempURL)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: tempURL, to: url)
    }
}

