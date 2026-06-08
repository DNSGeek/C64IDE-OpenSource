import Foundation

// ═══════════════════════════════════════════════════════════
// MARK: - DiskImage Protocol
// ═══════════════════════════════════════════════════════════

/// Common interface for Commodore disk image formats (D64, D81, etc.).
/// All sector-chain file operations (read/write/delete) are format-agnostic
/// once the concrete type implements readSector/writeSector/offset correctly.
protocol DiskImage: AnyObject {

    // MARK: State

    var data: Data { get }
    var isModified: Bool { get set }
    var fileURL: URL? { get set }

    // MARK: Disk Metadata

    var diskName: String { get }
    var diskID: String { get }
    var dosType: String { get }
    var freeBlocks: Int { get }

    // MARK: Low-level Sector I/O

    func readSector(track: Int, sector: Int) -> [UInt8]?
    func writeSector(track: Int, sector: Int, bytes: [UInt8])
    func isSectorFree(track: Int, sector: Int) -> Bool

    // MARK: Directory

    func readDirectory() -> [CBMDirectoryEntry]

    // MARK: File Operations

    func readFile(_ entry: CBMDirectoryEntry) -> [UInt8]
    func extractPRG(_ entry: CBMDirectoryEntry) -> Data
    func writeFile(name: String, type: UInt8, data: [UInt8]) -> Bool
    func deleteFile(_ entry: CBMDirectoryEntry)
    func renameFile(_ entry: CBMDirectoryEntry, to newName: String) -> Bool

    // MARK: Persistence

    func save() throws
    func save(to url: URL) throws
}

// MARK: - Default implementations shared by all formats

extension DiskImage {

    /// Read a file's data by following the sector chain.
    /// Identical for D64 and D81 — sectors always start with [nextTrack, nextSector].
    func readFile(_ entry: CBMDirectoryEntry) -> [UInt8] {
        var fileData: [UInt8] = []
        var track = entry.dataTrack
        var sector = entry.dataSector
        var visited = Set<String>()

        while track != 0 {
            let key = "\(track)/\(sector)"
            guard !visited.contains(key) else { break }
            visited.insert(key)

            guard let sectorData = readSector(track: track, sector: sector),
                  sectorData.count >= 2 else { break }

            let nextTrack  = Int(sectorData[0])
            let nextSector = Int(sectorData[1])
            let payloadMax = sectorData.count   // typically 256

            if nextTrack == 0 {
                // Last sector — byte 1 is number of bytes used (including the two link bytes)
                let bytesUsed = min(max(nextSector, 2), payloadMax - 1)
                if bytesUsed > 1 {
                    fileData.append(contentsOf: sectorData[2..<(bytesUsed + 1)])
                }
            } else if payloadMax > 2 {
                fileData.append(contentsOf: sectorData[2..<payloadMax])
            }

            track  = nextTrack
            sector = nextSector
        }

        return fileData
    }

    /// Extract file as raw bytes (includes PRG load-address header if present).
    func extractPRG(_ entry: CBMDirectoryEntry) -> Data {
        Data(readFile(entry))
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - Directory Entry (format-agnostic)
// ═══════════════════════════════════════════════════════════

/// A single entry from a CBM disk directory.
/// Field layout is identical across D64 and D81.
struct CBMDirectoryEntry {
    let fileType: UInt8
    let dataTrack: Int
    let dataSector: Int
    let filename: [UInt8]       // 16 bytes, PETSCII
    let fileSizeBlocks: Int

    // Location in the directory (needed for delete / rename)
    let dirTrack: Int
    let dirSector: Int
    let dirEntryIndex: Int

    // MARK: Derived

    /// Human-readable filename (strips $A0 padding)
    var name: String {
        var result = ""
        for byte in filename {
            if byte == 0xA0 { break }
            if byte >= 0x20 && byte < 0x7F {
                result.append(Character(UnicodeScalar(byte)))
            }
        }
        return result
    }

    /// Type string shown in directory listings: PRG, SEQ, USR, REL, DEL
    var typeString: String {
        let closed   = fileType & 0x80 != 0
        let locked   = fileType & 0x40 != 0
        let baseType = fileType & 0x0F

        var str: String
        switch baseType {
        case 0: str = "DEL"
        case 1: str = "SEQ"
        case 2: str = "PRG"
        case 3: str = "USR"
        case 4: str = "REL"
        default: str = "???"
        }

        if !closed { str = "*" + str }
        if locked  { str += "<" }
        return str
    }

    var isPRG: Bool { (fileType & 0x0F) == 2 }

    var directoryLine: String {
        let blocks     = String(fileSizeBlocks).padding(toLength: 5, withPad: " ", startingAt: 0)
        let quotedName = "\"\(name)\"".padding(toLength: 18, withPad: " ", startingAt: 0)
        return "\(blocks)\(quotedName) \(typeString)"
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - Disk Info (returned by DiskImageService.info)
// ═══════════════════════════════════════════════════════════

/// Summary metadata for a disk image, format-agnostic.
struct DiskInfo {
    let diskName: String
    let diskID: String
    let dosType: String
    let freeBlocks: Int
    let format: DiskFormat
}

/// The on-disk container format.
enum DiskFormat: Codable {
    case d64    // Commodore 1541, 174,848 bytes
    case d81    // Commodore 1581, 819,200 bytes
}

// ═══════════════════════════════════════════════════════════
// MARK: - Shared Error Type
// ═══════════════════════════════════════════════════════════

enum DiskImageError: Error, LocalizedError {
    // Existing cases
    case invalidSize(Int, expected: Int)
    case noFileURL
    case diskFull
    case fileNotFound
    case unsupportedFormat

    // New cases required by DiskImageService
    /// The disk image file does not exist at the expected URL.
    /// The coordinator layer catches this and presents the Create / Locate / Cancel sheet.
    case imageNotFound(URL)
    /// The ASCII filename supplied by the caller exceeds the 16-character CBM limit.
    case filenameTooLong(String)
    /// The filename contains characters that have no valid PETSCII mapping.
    case invalidPETSCII(String)
    /// Two files would land on the disk with the same CBM name.
    case namingCollision(String)

    var errorDescription: String? {
        switch self {
        case .invalidSize(let got, let exp):
            return "Invalid disk image size: \(got) bytes (expected \(exp))"
        case .noFileURL:
            return "No file URL set — use Save As… first"
        case .diskFull:
            return "Disk full — no free sectors"
        case .fileNotFound:
            return "File not found on disk"
        case .unsupportedFormat:
            return "Unrecognised disk image format"
        case .imageNotFound(let url):
            return "Disk image not found: \(url.lastPathComponent)"
        case .filenameTooLong(let name):
            return "Filename \"\(name)\" exceeds the 16-character CBM limit"
        case .invalidPETSCII(let name):
            return "Filename \"\(name)\" contains characters that cannot be represented in PETSCII"
        case .namingCollision(let name):
            return "Two files would produce the same CBM name \"\(name)\" on disk"
        }
    }
}

