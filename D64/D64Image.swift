import Foundation

// ═══════════════════════════════════════════════════════════
// MARK: - D64 Disk Image  (Commodore 1541 — 35 tracks)
// ═══════════════════════════════════════════════════════════

/// Represents a Commodore 1541 disk image in D64 format.
/// 35 tracks, 683 sectors, 256 bytes/sector = 174,848 bytes.
class D64Image: DiskImage {

    // MARK: State

    private(set) var data: Data
    var isModified = false
    var fileURL: URL?

    // MARK: Format Constants

    static let standardSize     = 174_848
    static let trackCount       = 35
    static let dirTrack         = 18
    static let bamTrack         = 18
    static let bamSector        = 0

    /// Sectors per track (1-indexed; index 0 unused).
    /// 1541 tracks have varying sector counts.
    static let sectorsPerTrack: [Int] = [
        0,
        21,21,21,21,21,21,21,21,21,21,21,21,21,21,21,21,21,  // 1–17
        19,19,19,19,19,19,19,                                  // 18–24
        18,18,18,18,18,18,                                     // 25–30
        17,17,17,17,17,                                        // 31–35
    ]

    // MARK: - Init

    /// Create a new, blank formatted D64.
    init(diskName: String = "NEW DISK", diskID: String = "C6") {
        data = Data(count: Self.standardSize)
        formatDisk(name: diskName, id: diskID)
    }

    /// Load an existing D64 file.
    init(contentsOf url: URL) throws {
        data = try Data(contentsOf: url)
        guard data.count >= Self.standardSize else {
            throw DiskImageError.invalidSize(data.count, expected: Self.standardSize)
        }
        fileURL = url
    }

    // MARK: - Sector Access

    func offset(track: Int, sector: Int) -> Int? {
        guard track >= 1, track <= Self.trackCount else { return nil }
        guard sector >= 0, sector < Self.sectorsPerTrack[track] else { return nil }
        var off = 0
        for t in 1..<track { off += Self.sectorsPerTrack[t] * 256 }
        off += sector * 256
        return off
    }

    func readSector(track: Int, sector: Int) -> [UInt8]? {
        guard let off = offset(track: track, sector: sector) else { return nil }
        guard off + 256 <= data.count else { return nil }
        return Array(data[off..<off + 256])
    }

    func writeSector(track: Int, sector: Int, bytes: [UInt8]) {
        guard bytes.count == 256, let off = offset(track: track, sector: sector) else { return }
        guard off + 256 <= data.count else { return }
        data.replaceSubrange(off..<off + 256, with: bytes)
        isModified = true
    }

    // MARK: - BAM

    /// BAM (Block Allocation Map) is stored in the first sector of track 18.
    /// Header: bytes 0-3 (link/version). Bytes 4-139: 34 track entries (4 bytes each).
    var diskName: String {
        guard let bam = readSector(track: Self.bamTrack, sector: Self.bamSector) else { return "" }
        return petsciiToString(Array(bam[0x90...0x9F]))
    }

    var diskID: String {
        guard let bam = readSector(track: Self.bamTrack, sector: Self.bamSector) else { return "" }
        return petsciiToString(Array(bam[0xA2...0xA3]))
    }

    var dosType: String {
        guard let bam = readSector(track: Self.bamTrack, sector: Self.bamSector) else { return "" }
        return petsciiToString(Array(bam[0xA5...0xA6]))
    }

    var freeBlocks: Int {
        guard let bam = readSector(track: Self.bamTrack, sector: Self.bamSector) else { return 0 }
        var free = 0
        for track in 1...Self.trackCount {
            if track == Self.dirTrack { continue }
            free += Int(bam[4 + (track - 1) * 4])
        }
        return free
    }

    func isSectorFree(track: Int, sector: Int) -> Bool {
        guard track >= 1, track <= Self.trackCount else { return false }
        guard let bam = readSector(track: Self.bamTrack, sector: Self.bamSector) else { return false }
        let bamOffset = 4 + (track - 1) * 4
        let byteIndex = 1 + sector / 8
        let bitIndex  = sector % 8
        return bam[bamOffset + byteIndex] & (1 << bitIndex) != 0
    }

    private func allocateSector(track: Int, sector: Int) {
        guard track >= 1, track <= Self.trackCount else { return }
        guard var bam = readSector(track: Self.bamTrack, sector: Self.bamSector) else { return }
        let bamOffset = 4 + (track - 1) * 4
        bam[bamOffset] -= 1
        let byteIndex = 1 + sector / 8
        let bitIndex  = sector % 8
        bam[bamOffset + byteIndex] &= ~(1 << bitIndex)
        writeSector(track: Self.bamTrack, sector: Self.bamSector, bytes: bam)
    }

    private func freeSector(track: Int, sector: Int) {
        guard track >= 1, track <= Self.trackCount else { return }
        guard var bam = readSector(track: Self.bamTrack, sector: Self.bamSector) else { return }
        let bamOffset = 4 + (track - 1) * 4
        bam[bamOffset] += 1
        let byteIndex = 1 + sector / 8
        let bitIndex  = sector % 8
        bam[bamOffset + byteIndex] |= (1 << bitIndex)
        writeSector(track: Self.bamTrack, sector: Self.bamSector, bytes: bam)
    }

    private func findFreeSector() -> (track: Int, sector: Int)? {
        // Interleaved search order for optimal seek time on 1541
        let trackOrder = [17,19,16,20,15,21,14,22,13,23,12,24,11,25,
                          10,26, 9,27, 8,28, 7,29, 6,30, 5,31, 4,32, 3,33, 2,34, 1,35]
        for track in trackOrder {
            for sector in 0..<Self.sectorsPerTrack[track] {
                if isSectorFree(track: track, sector: sector) { return (track, sector) }
            }
        }
        return nil
    }

    private func findFreeSectorOnTrack(_ track: Int) -> (Int, Int)? {
        for sector in 0..<Self.sectorsPerTrack[track] {
            if isSectorFree(track: track, sector: sector) { return (track, sector) }
        }
        return nil
    }

    // MARK: - Directory

    func readDirectory() -> [CBMDirectoryEntry] {
        var entries: [CBMDirectoryEntry] = []
        var track  = Self.dirTrack
        var sector = 1
        var visited = Set<String>()

        while track != 0 {
            let key = "\(track)/\(sector)"
            guard !visited.contains(key) else { break }
            visited.insert(key)
            guard let sectorData = readSector(track: track, sector: sector) else { break }

            for i in 0..<8 {
                let base     = i * 32
                let fileType = sectorData[base + 2]
                guard fileType != 0 else { continue }

                entries.append(CBMDirectoryEntry(
                    fileType:       fileType,
                    dataTrack:      Int(sectorData[base + 3]),
                    dataSector:     Int(sectorData[base + 4]),
                    filename:       Array(sectorData[base + 5...base + 20]),
                    fileSizeBlocks: Int(sectorData[base + 30]) | (Int(sectorData[base + 31]) << 8),
                    dirTrack:       track,
                    dirSector:      sector,
                    dirEntryIndex:  i
                ))
            }

            track  = Int(sectorData[0])
            sector = Int(sectorData[1])
        }

        return entries
    }

    // MARK: - File Write

    func writeFile(name: String, type: UInt8 = 0x82, data fileData: [UInt8]) -> Bool {
        let upperName = name.uppercased()
        // Delete any existing file with the same name
        for entry in readDirectory() {
            if entry.name.uppercased() == upperName { deleteFile(entry) }
        }

        guard let dirSlot = findFreeDirectorySlot() else { return false }

        var remaining = fileData
        var firstTrack = 0, firstSector = 0
        var prevOffset: Int? = nil
        var blocksUsed = 0

        while !remaining.isEmpty {
            guard let (track, sector) = findFreeSector() else { return false }

            if firstTrack == 0 { firstTrack = track; firstSector = sector }

            if let prevOff = prevOffset {
                data[prevOff]     = UInt8(track)
                data[prevOff + 1] = UInt8(sector)
            }

            var sectorBytes = [UInt8](repeating: 0, count: 256)
            if remaining.count <= 254 {
                sectorBytes[0] = 0
                sectorBytes[1] = UInt8(remaining.count + 1)
                for (i, byte) in remaining.enumerated() { sectorBytes[2 + i] = byte }
                remaining = []
            } else {
                sectorBytes[0] = 0; sectorBytes[1] = 0
                for i in 0..<254 { sectorBytes[2 + i] = remaining[i] }
                remaining = Array(remaining.dropFirst(254))
            }

            writeSector(track: track, sector: sector, bytes: sectorBytes)
            allocateSector(track: track, sector: sector)
            prevOffset = offset(track: track, sector: sector)
            blocksUsed += 1
        }

        guard var dirSector = readSector(track: dirSlot.track, sector: dirSlot.sector) else { return false }
        let base = dirSlot.index * 32
        dirSector[base + 2] = type
        dirSector[base + 3] = UInt8(firstTrack)
        dirSector[base + 4] = UInt8(firstSector)
        let nameBytes = stringToPetscii(upperName, length: 16)
        for i in 0..<16 { dirSector[base + 5 + i] = nameBytes[i] }
        dirSector[base + 30] = UInt8(blocksUsed & 0xFF)
        dirSector[base + 31] = UInt8(blocksUsed >> 8)
        writeSector(track: dirSlot.track, sector: dirSlot.sector, bytes: dirSector)
        isModified = true
        return true
    }

    // MARK: - Rename

    func renameFile(_ entry: CBMDirectoryEntry, to newName: String) -> Bool {
        let upperName = newName.uppercased().prefix(16)
        for existing in readDirectory() {
            if existing.name.uppercased() == upperName &&
               !(existing.dirTrack == entry.dirTrack &&
                 existing.dirSector == entry.dirSector &&
                 existing.dirEntryIndex == entry.dirEntryIndex) { return false }
        }
        guard var dirSector = readSector(track: entry.dirTrack, sector: entry.dirSector) else { return false }
        let nameBytes = stringToPetscii(String(upperName), length: 16)
        let base = entry.dirEntryIndex * 32
        for i in 0..<16 { dirSector[base + 5 + i] = nameBytes[i] }
        writeSector(track: entry.dirTrack, sector: entry.dirSector, bytes: dirSector)
        isModified = true
        return true
    }

    // MARK: - Delete

    func deleteFile(_ entry: CBMDirectoryEntry) {
        var track  = entry.dataTrack
        var sector = entry.dataSector
        var visited = Set<String>()

        while track != 0 {
            let key = "\(track)/\(sector)"
            guard !visited.contains(key) else { break }
            visited.insert(key)
            guard let sectorData = readSector(track: track, sector: sector) else { break }
            freeSector(track: track, sector: sector)
            track  = Int(sectorData[0])
            sector = Int(sectorData[1])
        }

        guard var dirSector = readSector(track: entry.dirTrack, sector: entry.dirSector) else { return }
        dirSector[entry.dirEntryIndex * 32 + 2] = 0
        writeSector(track: entry.dirTrack, sector: entry.dirSector, bytes: dirSector)
        isModified = true
    }

    // MARK: - Directory Slot

    private func findFreeDirectorySlot() -> (track: Int, sector: Int, index: Int)? {
        var track  = Self.dirTrack
        var sector = 1
        var visited = Set<String>()

        while track != 0 {
            let key = "\(track)/\(sector)"
            guard !visited.contains(key) else { break }
            visited.insert(key)
            guard let sectorData = readSector(track: track, sector: sector) else { break }

            for i in 0..<8 {
                if sectorData[i * 32 + 2] == 0 { return (track, sector, i) }
            }

            let nextTrack  = Int(sectorData[0])
            let nextSector = Int(sectorData[1])

            if nextTrack == 0 {
                if let (newTrack, newSector) = findFreeSectorOnTrack(Self.dirTrack) {
                    var updated = sectorData
                    updated[0] = UInt8(newTrack)
                    updated[1] = UInt8(newSector)
                    writeSector(track: track, sector: sector, bytes: updated)

                    var newSectorData = [UInt8](repeating: 0, count: 256)
                    newSectorData[0] = 0
                    newSectorData[1] = 0xFF
                    writeSector(track: newTrack, sector: newSector, bytes: newSectorData)
                    allocateSector(track: newTrack, sector: newSector)
                    return (newTrack, newSector, 0)
                }
                return nil
            }

            track  = nextTrack
            sector = nextSector
        }

        return nil
    }

    // MARK: - Format

    private func formatDisk(name: String, id: String) {
        var bam = [UInt8](repeating: 0, count: 256)

        // BAM Header (bytes 0-3)
        bam[0] = 18;   bam[1] = 1    // First directory sector
        bam[2] = 0x41; bam[3] = 0x00 // DOS version 'A' (1541 DOS 2.5), single-sided

        // Track entries start at byte 4
        for track in 1...Self.trackCount {
            let maxSectors = Self.sectorsPerTrack[track]
            let bamOffset  = 4 + (track - 1) * 4

            if track == Self.dirTrack {
                // Directory track: sectors 0 and 1 are used by the directory itself
                bam[bamOffset]     = UInt8(maxSectors - 2)
                bam[bamOffset + 1] = 0xFC // Sectors 0,1 used
                bam[bamOffset + 2] = 0xFF
                bam[bamOffset + 3] = maxSectors > 16 ? 0x07 : 0xFF
            } else {
                // Data track: all sectors free
                bam[bamOffset] = UInt8(maxSectors)
                var bitmap: [UInt8] = [0xFF, 0xFF, 0xFF]
                // Clear unused sectors in the last byte if track has < 24 sectors
                if maxSectors < 24 {
                    for bit in maxSectors..<24 {
                        bitmap[bit / 8] &= ~(1 << (bit % 8))
                    }
                }
                bam[bamOffset + 1] = bitmap[0]
                bam[bamOffset + 2] = bitmap[1]
                bam[bamOffset + 3] = bitmap[2]
            }
        }

        // Disk Name (bytes 0x90-0x9F)
        let nameBytes = stringToPetscii(name.uppercased(), length: 16)
        for i in 0..<16 { bam[0x90 + i] = nameBytes[i] }

        // Separator
        bam[0xA0] = 0xA0; bam[0xA1] = 0xA0

        // Disk ID (bytes 0xA2-0xA3)
        let idStr = id.uppercased().prefix(2)
        bam[0xA2] = idStr.count > 0 ? UInt8(idStr.first!.asciiValue ?? 0x30) : 0x30
        bam[0xA3] = idStr.count > 1 ? UInt8(idStr.dropFirst().first!.asciiValue ?? 0x30) : 0x30

        // DOS Type (bytes 0xA5-0xA6)
        bam[0xA4] = 0xA0; bam[0xA5] = 0x32; bam[0xA6] = 0x41 // "2A"
        bam[0xA7] = 0xA0; bam[0xA8] = 0xA0; bam[0xA9] = 0xA0; bam[0xAA] = 0xA0

        writeSector(track: Self.bamTrack, sector: Self.bamSector, bytes: bam)

        var dirSector = [UInt8](repeating: 0, count: 256)
        dirSector[0] = 0; dirSector[1] = 0xFF
        writeSector(track: Self.dirTrack, sector: 1, bytes: dirSector)

        isModified = true
    }

    // MARK: - Save

    func save() throws {
        guard let url = fileURL else { throw DiskImageError.noFileURL }
        try data.write(to: url)
        isModified = false
    }

    func save(to url: URL) throws {
        try data.write(to: url)
        fileURL = url
        isModified = false
    }

    // MARK: - PETSCII

    private func petsciiToString(_ bytes: [UInt8]) -> String {
        var result = ""
        for byte in bytes {
            if byte == 0xA0 { break }
            if byte >= 0x20 && byte < 0x7F {
                result.append(Character(UnicodeScalar(byte)))
            } else {
                result.append("?")
            }
        }
        return result
    }

    private func stringToPetscii(_ string: String, length: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0xA0, count: length)
        for (i, char) in string.uppercased().prefix(length).enumerated() {
            if let ascii = char.asciiValue { bytes[i] = ascii }
        }
        return bytes
    }
}

