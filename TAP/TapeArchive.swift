import Foundation

// ═══════════════════════════════════════════════════════════
// MARK: - Tape Archive Protocol  (read-only surface)
// ═══════════════════════════════════════════════════════════

/// Common interface for tape container formats (TAP, T64).
/// The browser works entirely through this protocol so it doesn't care which format is loaded.
protocol TapeArchive: AnyObject {
    /// The URL of the source file, if loaded from disk.
    var fileURL: URL? { get }
    
    /// Display name (tape label / filename).
    var archiveName: String { get }
    
    /// List of files contained in the archive.
    var entries: [TAPEntry] { get }
    
    /// Log of parsing events for debugging or display.
    var parseLog: [String] { get }
    
    /// Format tag ("TAP" or "T64").
    var formatTag: String { get }

    /// Extracts the raw PRG data (including load address header) for a specific entry.
    func extractPRG(for entry: TAPEntry) -> Data?
    
    /// Exports an entry to a disk image.
    func exportToDisk(_ entry: TAPEntry, disk: any DiskImage) -> Bool
}

// Default exportToDisk via extractPRG
extension TapeArchive {
    func exportToDisk(_ entry: TAPEntry, disk: any DiskImage) -> Bool {
        guard let prg = extractPRG(for: entry) else { return false }
        return disk.writeFile(name: String(entry.name.prefix(16)), type: 0x82, data: Array(prg))
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - Writable Tape Archive Protocol
// ═══════════════════════════════════════════════════════════

/// Implemented by formats that support full edit + save.
/// T64Image conforms. TAPImage does NOT — TAP writing is intentionally out of scope
/// for the core parser, though the browser provides synthetic write capabilities.
protocol WritableTapeArchive: TapeArchive {
    /// Append a new PRG entry. `prgData` must be a complete PRG including the
    /// 2-byte load-address header (matches the shape returned by `extractPRG`).
    func addEntry(name: String, prgData: Data) throws

    /// Remove an entry. Indices shift; remaining entries are re-numbered.
    func deleteEntry(at index: Int) throws

    /// Rename an entry. The new name is sanitised to ASCII printable and truncated to 16 chars.
    func renameEntry(at index: Int, to newName: String) throws

    /// Set the tape (archive) display name. Truncated to 24 chars.
    func setArchiveName(_ name: String)

    /// Persist to disk atomically. If `url` is nil, overwrites `fileURL`.
    func save(to url: URL?) throws
}

// ═══════════════════════════════════════════════════════════
// MARK: - Shared Entry Type
// ═══════════════════════════════════════════════════════════

/// Represents a file entry within a tape archive.
struct TAPEntry {
    enum FileKind: String {
        case program    = "PRG"
        case sequential = "SEQ"
        case snapshot   = "SNAP"
        case unknown    = "???"
    }

    let index:       Int
    let name:        String
    let loadAddress: UInt16
    let endAddress:  UInt16
    let kind:        FileKind
    let sizeBytes:   Int

    /// Calculates the number of 254-byte blocks required to store the payload.
    var blocks: Int { max(1, (sizeBytes + 253) / 254) }
}

// ═══════════════════════════════════════════════════════════
// MARK: - Tape Errors
// ═══════════════════════════════════════════════════════════

enum TapeError: Error, LocalizedError {
    case invalidSignature
    case truncatedHeader
    case unsupportedFormat
    case noFileURL
    case directoryFull(max: Int)
    case invalidIndex(Int)
    case payloadEmpty
    case payloadTooLarge(Int)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidSignature:       return "Not a valid tape image file (bad signature)"
        case .truncatedHeader:        return "File is too short to contain a valid header"
        case .unsupportedFormat:      return "Unrecognised tape image format"
        case .noFileURL:              return "No destination URL — call save(to:) explicitly."
        case .directoryFull(let m):   return "T64 directory is full (max \(m) entries)."
        case .invalidIndex(let i):    return "Invalid entry index: \(i)."
        case .payloadEmpty:           return "Payload is empty or missing PRG load-address header."
        case .payloadTooLarge(let n): return "Payload too large: \(n) bytes (must fit in 64K)."
        case .writeFailed(let s):     return "Write failed: \(s)"
        }
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - T64 Image
// ═══════════════════════════════════════════════════════════

/// Represents a T64 (Tape Compressed) image file.
/// T64 is a flat container archive — multiple files with a fixed-size directory and packed payloads.
///
/// Layout (per Schepers' canonical spec):
///   Header (64 bytes):
///     [0..31]  Signature, ASCII, $00-padded
///     [32..33] Version LE  ($0200)
///     [34..35] Max directory entries LE
///     [36..37] Used directory entries LE
///     [38..39] Reserved
///     [40..63] Tape display name, ASCII, $20-padded (24 bytes)
///
///   Directory entries (32 bytes each, starting at offset 64):
///     [0]      C64s file type (0=free, 1=normal PRG, 3=snapshot)
///     [1]      1541 file type ($82=PRG, $81=SEQ)
///     [2..3]   Load address LE
///     [4..5]   End address LE
///     [8..11]  Offset of file data within the container LE 32-bit
///     [16..31] Filename, PETSCII, $20-padded (16 bytes)
///
/// Payloads follow, packed back-to-back with 512-byte alignment padding.
final class T64Image: WritableTapeArchive {

    // MARK: TapeArchive conformance

    var fileURL: URL?
    var archiveName: String = ""
    private(set) var entries:  [TAPEntry] = []
    private(set) var parseLog: [String]   = []
    var formatTag: String { "T64" }

    // MARK: Internal state — payload cache parallel to `entries`

    /// Raw payload bytes for each entry (no PRG header).
    /// `payloads[i]` corresponds to `entries[i]`.
    private var payloads: [Data] = []

    // MARK: - Init (read existing T64)

    /// Loads a T64 file from the given URL.
    /// - Parameter url: The file URL to load.
    /// - Throws: `TapeError.invalidSignature` or `TapeError.truncatedHeader`.
    init(contentsOf url: URL) throws {
        let raw = try Data(contentsOf: url)
        fileURL = url
        guard raw.count >= 64 else { throw TapeError.truncatedHeader }

        // Validate signature
        let sigBytes = Array(raw[0..<32])
        let sig = String(bytes: sigBytes.filter { $0 != 0 }, encoding: .ascii) ?? ""
        guard sig.contains("C64") || sig.contains("c64") || sig.lowercased().contains("tape") else {
            throw TapeError.invalidSignature
        }

        let maxEntries  = Int(raw[34]) | (Int(raw[35]) << 8)
        let usedEntries = Int(raw[36]) | (Int(raw[37]) << 8)

        archiveName = Self.decodeName(Array(raw[40..<min(64, raw.count)]))
        if archiveName.isEmpty { archiveName = url.deletingPathExtension().lastPathComponent }

        log("T64 — \"\(archiveName)\"  max:\(maxEntries) used:\(usedEntries)")

        // Parse directory entries, capping at a sane upper bound.
        let limit = min(max(maxEntries, usedEntries, 1), 1024)
        for i in 0..<limit {
            let base = 64 + i * 32
            guard base + 32 <= raw.count else { break }

            let c64sType    = raw[base]
            let petsciiType = raw[base + 1]

            // c64s type 0 = end of directory.
            if c64sType == 0 { break }

            let loadAddr = UInt16(raw[base + 2]) | (UInt16(raw[base + 3]) << 8)
            let endAddr  = UInt16(raw[base + 4]) | (UInt16(raw[base + 5]) << 8)
            let dataOffset = Int(raw[base + 8])
                           | (Int(raw[base + 9])  << 8)
                           | (Int(raw[base + 10]) << 16)
                           | (Int(raw[base + 11]) << 24)
            let nameBytes = Array(raw[(base + 16)..<(base + 32)])
            let name = Self.decodeName(nameBytes)

            let declaredSize  = endAddr > loadAddr ? Int(endAddr - loadAddr) : 0
            let availableSize = dataOffset < raw.count ? raw.count - dataOffset : 0
            let sizeBytes     = declaredSize > 0 ? declaredSize : min(availableSize, 65535)

            let kind: TAPEntry.FileKind
            switch c64sType {
            case 3:
                kind = .snapshot
            default:
                switch petsciiType & 0x0F {
                case 1:   kind = .sequential
                default:  kind = .program
                }
            }

            // Slice payload (clamped to file extent).
            let take = min(sizeBytes, max(0, raw.count - dataOffset))
            let payload: Data
            if take > 0, dataOffset >= 0, dataOffset + take <= raw.count {
                payload = Data(raw[dataOffset..<(dataOffset + take)])
            } else {
                payload = Data()
            }

            entries.append(TAPEntry(
                index:       entries.count,
                name:        name,
                loadAddress: loadAddr,
                endAddress:  endAddr,
                kind:        kind,
                sizeBytes:   payload.count
            ))
            payloads.append(payload)

            log("  [\(i)] \"\(name)\" \(kind.rawValue) "
              + "\(String(format: "$%04X–$%04X", loadAddr, endAddr)) "
              + "(\(payload.count)b) @ \(String(format: "$%X", dataOffset))")
        }

        log("Done — \(entries.count) file(s)")
    }

    // MARK: - Init (new empty archive)

    /// Create a new empty T64 archive in memory. Call `save(to:)` to persist.
    /// - Parameter name: The tape display name (max 24 chars).
    init(emptyWithName name: String = "TAPE") {
        archiveName = Self.sanitise(name, maxLen: 24)
        fileURL = nil
        log("New empty T64 — \"\(archiveName)\"")
    }

    // MARK: - PRG extraction

    /// Extracts the raw PRG data (including load address header) for a specific entry.
    func extractPRG(for entry: TAPEntry) -> Data? {
        guard payloads.indices.contains(entry.index) else { return nil }
        let payload = payloads[entry.index]
        guard !payload.isEmpty else { return nil }
        var prg = Data([
            UInt8(entry.loadAddress & 0xFF),
            UInt8(entry.loadAddress >> 8)
        ])
        prg.append(payload)
        return prg
    }

    // MARK: - WritableTapeArchive

    func addEntry(name: String, prgData: Data) throws {
        guard prgData.count >= 2 else { throw TapeError.payloadEmpty }
        let payload = Data(prgData.dropFirst(2))
        guard payload.count > 0 else { throw TapeError.payloadEmpty }

        let loadAddr = UInt16(prgData[prgData.startIndex])
                     | (UInt16(prgData[prgData.startIndex + 1]) << 8)

        // Must fit in C64 address space.
        guard Int(loadAddr) + payload.count <= 0x10000 else {
            throw TapeError.payloadTooLarge(payload.count)
        }

        let cleanName = Self.sanitise(name, maxLen: 16)
        let endAddr   = UInt16(truncatingIfNeeded: Int(loadAddr) + payload.count)

        entries.append(TAPEntry(
            index:       entries.count,
            name:        cleanName,
            loadAddress: loadAddr,
            endAddress:  endAddr,
            kind:        .program,
            sizeBytes:   payload.count
        ))
        payloads.append(payload)

        log("Added [\(entries.count - 1)] \"\(cleanName)\" "
          + "\(String(format: "$%04X–$%04X", loadAddr, endAddr)) (\(payload.count)b)")
    }

    func deleteEntry(at index: Int) throws {
        guard entries.indices.contains(index) else { throw TapeError.invalidIndex(index) }
        let removed = entries[index].name
        entries.remove(at: index)
        payloads.remove(at: index)
        renumberEntries()
        log("Removed [\(index)] \"\(removed)\"")
    }

    func renameEntry(at index: Int, to newName: String) throws {
        guard entries.indices.contains(index) else { throw TapeError.invalidIndex(index) }
        let cleanName = Self.sanitise(newName, maxLen: 16)
        let e = entries[index]
        entries[index] = TAPEntry(
            index:       e.index,
            name:        cleanName,
            loadAddress: e.loadAddress,
            endAddress:  e.endAddress,
            kind:        e.kind,
            sizeBytes:   e.sizeBytes
        )
        log("Renamed [\(index)] → \"\(cleanName)\"")
    }

    func setArchiveName(_ name: String) {
        archiveName = Self.sanitise(name, maxLen: 24)
    }

    // MARK: - Save (atomic)

    /// Persists the archive to disk atomically.
    /// - Parameter url: Target URL. If nil, uses the original `fileURL`.
    /// - Throws: `TapeError.noFileURL`, `TapeError.directoryFull`, or `TapeError.writeFailed`.
    func save(to url: URL? = nil) throws {
        guard let target = url ?? fileURL else { throw TapeError.noFileURL }

        let count = entries.count
        guard count <= 1024 else { throw TapeError.directoryFull(max: 1024) }

        // Layout: 64-byte header + N × 32-byte directory entries + packed payloads.
        let dirSlots        = max(count, 1)
        let dirByteLen      = dirSlots * 32
        let firstDataOffset = 64 + dirByteLen

        var archive = Data()
        archive.reserveCapacity(firstDataOffset + payloads.reduce(0) { $0 + $1.count })

        // ── Header (64 bytes) ────────────────────────────────
        archive.append(buildHeader(usedEntries: count, maxEntries: dirSlots))

        // ── Directory entries & Payloads ───────────────────────
        var cursor = firstDataOffset
        for (i, entry) in entries.enumerated() {
            let payload = payloads[i]

            // Calculate 512-byte alignment padding (0 if already aligned)
            let padding = (512 - payload.count % 512) % 512
            let dataOffset = cursor // Points to the start of the actual file data

            archive.append(buildDirectoryEntry(
                entry:      entry,
                payload:    payload,
                dataOffset: dataOffset
            ))

            // Write payload, then alignment padding
            archive.append(payload)
            if padding > 0 {
                archive.append(Data(repeating: 0, count: padding))
            }

            // Advance cursor past payload + padding
            cursor = dataOffset + payload.count + padding
        }

        // Pad unused dir slots with zeros (c64s type 0 ⇒ end-of-directory).
        if count < dirSlots {
            archive.append(Data(repeating: 0, count: 32 * (dirSlots - count)))
        }

        // ── Atomic write ─────────────────────────────────────
        try Self.atomicWrite(archive, to: target)

        fileURL = target
        renumberEntries()
        log("Saved \(count) entr\(count == 1 ? "y" : "ies") "
          + "(\(archive.count) bytes) → \(target.lastPathComponent)")
    }

    // MARK: - Helpers (private)

    private func renumberEntries() {
        entries = entries.enumerated().map { (i, e) in
            TAPEntry(index:       i,
                     name:        e.name,
                     loadAddress: e.loadAddress,
                     endAddress:  e.endAddress,
                     kind:        e.kind,
                     sizeBytes:   e.sizeBytes)
        }
    }

    private func buildHeader(usedEntries: Int, maxEntries: Int) -> Data {
        var header = Data(repeating: 0, count: 64)
        // [0..31] Signature, ASCII, zero-padded.
        let sig = "C64 tape image file"
        for (i, b) in Array(sig.utf8).enumerated() where i < 32 {
            header[i] = b
        }
        // [32..33] Version $0200 LE
        header[32] = 0x00
        header[33] = 0x02
        // [34..35] Max entries LE
        header[34] = 0xFF // 255 max entries (standard)
        header[35] = 0x00
        // [36..37] Used entries LE
        header[36] = UInt8(usedEntries & 0xFF)
        header[37] = UInt8((usedEntries >> 8) & 0xFF)
        // [38..39] reserved (zero)
        // [40..63] Tape name, space-padded, 24 bytes
        let nameBytes = Self.encodeName(archiveName, length: 24, padByte: 0x20)
        for (i, b) in nameBytes.enumerated() where i < 24 {
            header[40 + i] = b
        }
        return header
    }

    private func buildDirectoryEntry(entry: TAPEntry,
                                     payload: Data,
                                     dataOffset: Int) -> Data {
        var d = Data(repeating: 0, count: 32)
        // [0]    c64s file type (1 = normal PRG, 3 = snapshot)
        d[0] = entry.kind == .snapshot ? 3 : 1
        // [1]    1541 file type ($82 PRG, $81 SEQ)
        d[1] = entry.kind == .sequential ? 0x81 : 0x82
        // [2..3] load address LE
        d[2] = UInt8(entry.loadAddress & 0xFF)
        d[3] = UInt8(entry.loadAddress >> 8)
        // [4..5] end address LE — recomputed from load + payload size for safety
        let endAddr = UInt16(truncatingIfNeeded: Int(entry.loadAddress) + payload.count)
        d[4] = UInt8(endAddr & 0xFF)
        d[5] = UInt8(endAddr >> 8)
        // [6..7] reserved (zero)
        // [8..11] data offset LE 32-bit
        d[8]  = UInt8(dataOffset & 0xFF)
        d[9]  = UInt8((dataOffset >> 8) & 0xFF)
        d[10] = UInt8((dataOffset >> 16) & 0xFF)
        d[11] = UInt8((dataOffset >> 24) & 0xFF)
        // [12..15] reserved (zero)
        // [16..31] filename, space-padded, 16 bytes
        let nameBytes = Self.encodeName(entry.name, length: 16, padByte: 0x20)
        for (j, b) in nameBytes.enumerated() where j < 16 {
            d[16 + j] = b
        }
        return d
    }

    private func log(_ msg: String) { parseLog.append(msg) }

    // MARK: - Static helpers (name encoding / atomic write)

    /// Decode a directory or tape-name byte field. Stops at $00,
    /// strips trailing spaces (0x20) and shifted-spaces (0xA0).
    private static func decodeName(_ bytes: [UInt8]) -> String {
        var end = bytes.count
        while end > 0 && (bytes[end - 1] == 0x20
                       || bytes[end - 1] == 0xA0
                       || bytes[end - 1] == 0x00) {
            end -= 1
        }
        var s = ""
        for i in 0..<end {
            let b = bytes[i]
            if b == 0x00 { break }
            if b >= 0x20 && b < 0x7F {
                s.append(Character(UnicodeScalar(b)))
            } else if b == 0xA0 {
                s.append(" ")
            }
            // Other bytes (PETSCII graphics, etc.) are dropped silently.
        }
        return s
    }

    /// Encode a string for storage in a fixed-length T64 name field.
    /// Emits ASCII printable chars; non-printable scalars become space.
    /// Padded with `padByte` to `length` bytes.
    private static func encodeName(_ s: String, length: Int, padByte: UInt8) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(length)
        for ch in s.unicodeScalars {
            if out.count >= length { break }
            let v = ch.value
            if v >= 0x20 && v < 0x7F {
                out.append(UInt8(v))
            } else {
                out.append(0x20)
            }
        }
        while out.count < length { out.append(padByte) }
        return out
    }

    /// Strip to printable ASCII and truncate to `maxLen`. Used for
    /// new entry names, archive name, etc.
    fileprivate static func sanitise(_ s: String, maxLen: Int) -> String {
        let cleaned = s.unicodeScalars.compactMap { sc -> Character? in
            let v = sc.value
            return (v >= 0x20 && v < 0x7F) ? Character(sc) : nil
        }
        return String(cleaned.prefix(maxLen))
    }

    /// Atomic write: temp file in destination directory, then rename.
    /// Uses `replaceItemAt` for safe in-place replacement when a file
    /// already exists at the target path.
    private static func atomicWrite(_ data: Data, to target: URL) throws {
        let dir  = target.deletingLastPathComponent()
        let temp = dir.appendingPathComponent(
            ".t64write.\(UUID().uuidString).\(target.lastPathComponent)")
        do {
            try data.write(to: temp, options: .atomic)
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: target)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw TapeError.writeFailed(error.localizedDescription)
        }
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - Factory
// ═══════════════════════════════════════════════════════════

enum TapeArchiveLoader {
    /// Load a TAP or T64 from a URL, detecting format by extension.
    /// - Parameter url: The file URL to load.
    /// - Returns: An instance conforming to `TapeArchive`.
    /// - Throws: `TapeError` if the file is invalid or unsupported.
    static func load(from url: URL) throws -> any TapeArchive {
        switch url.pathExtension.lowercased() {
        case "t64": return try T64Image(contentsOf: url)
        case "tap": return try TAPImage(contentsOf: url)
        default:
            // Fallback: peek at the signature
            let header = (try? Data(contentsOf: url))?.prefix(32) ?? Data()
            let sig    = String(bytes: header, encoding: .ascii) ?? ""
            if sig.contains("C64") || sig.lowercased().contains("tape") {
                return try T64Image(contentsOf: url)
            }
            return try TAPImage(contentsOf: url)
        }
    }
}

extension String {
    /// Pads/truncates string to `length` using PETSCII space (0x20).
    func petsciiPadded(to length: Int) -> [UInt8] {
        let utf8 = utf8.map { UInt8($0) }
        let padded = utf8 + Data(repeating: 0x20, count: max(0, length - utf8.count))
        return Array(padded.prefix(length))
    }
}

