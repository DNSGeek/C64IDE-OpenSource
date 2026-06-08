import Foundation

// ═══════════════════════════════════════════════════════════
// MARK: - D81 Disk Image  (Commodore 1581 — 80 tracks)
// ═══════════════════════════════════════════════════════════
//
// Physical layout:
//   80 tracks × 40 sectors × 256 bytes = 819,200 bytes
//
// Key locations:
//   Header sector :  track 40, sector 0  (disk name, ID, DOS type)
//   BAM sector 1  :  track 40, sector 1  (tracks  1–40)
//   BAM sector 2  :  track 40, sector 2  (tracks 41–80)
//   Directory     :  track 40, sector 3  (first sector; chain follows)
//
// BAM entry format (6 bytes per track):
//   [0]   free sector count for this track
//   [1–5] 40-bit bitmap, one bit per sector (bit 0 of byte 1 = sector 0)
//
// Each BAM sector covers 40 tracks and begins with:
//   [0][1]  link to next BAM sector (BAM1→40/2; BAM2→0/$FF)
//   [2]     disk version ($44 = 'D')
//   [3]     $BB (1581 magic)
//   [4][5]  disk ID (same as header)
//   [6]     $C0 (I/O byte)
//   [7]     $00 (auto-boot flag)
//   [8–15]  $00 padding (unused)
//   [16–255] 40 × 6-byte track entries  ← entries start at byte 16, NOT byte 8
//            16 + 40×6 = 256: fills the sector exactly
//
// Header sector layout:
//   [0][1]  link → first directory sector (40, 3)  ← used by 1581 ROM to find directory
//   [2]     DOS version ('D' = $44)
//   [3]     $00  ← NOT $BB; magic byte belongs in BAM sectors only
//   [$04–$13] disk name, 16 bytes, padded with $A0
//   [$14–$15] $A0 $A0
//   [$16–$17] disk ID (2 bytes)
//   [$18]   $A0
//   [$19]   '3' ($33)
//   [$1A]   'D' ($44)
//   [$1B–$FF] $A0 padding
//
// References:
//   https://vice-emu.sourceforge.io/vice_17.html#SEC350
//   https://ist.uwaterloo.ca/~schepers/formats/D81.TXT

class D81Image: DiskImage {

    // MARK: State

    private(set) var data: Data
    var isModified = false
    var fileURL: URL?

    // MARK: Format Constants

    static let standardSize  = 819_200
    static let trackCount    = 80
    static let sectorsPerTrack = 40   // Uniform across all tracks

    /// Header / BAM / directory are all on track 40
    static let systemTrack   = 40
    static let headerSector  = 0
    static let bam1Sector    = 1      // Covers tracks  1–40
    static let bam2Sector    = 2      // Covers tracks 41–80
    static let dirSector     = 3      // First directory sector

    // MARK: - Init

    /// Create a new, blank formatted D81.
    init(diskName: String = "NEW DISK", diskID: String = "C6") {
        data = Data(count: Self.standardSize)
        formatDisk(name: diskName, id: diskID)
    }

    /// Load an existing D81 file.
    init(contentsOf url: URL) throws {
        data = try Data(contentsOf: url)
        guard data.count >= Self.standardSize else {
            throw DiskImageError.invalidSize(data.count, expected: Self.standardSize)
        }
        fileURL = url
    }

    // MARK: - Sector Access

    /// Byte offset for a given track/sector.
    func offset(track: Int, sector: Int) -> Int? {
        guard track >= 1, track <= Self.trackCount else { return nil }
        guard sector >= 0, sector < Self.sectorsPerTrack else { return nil }
        let linearSector = (track - 1) * Self.sectorsPerTrack + sector
        return linearSector * 256
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

    // MARK: - BAM Helpers

    /// Which BAM sector covers a given track, and the index of that track's entry within it.
    /// BAM sector 1 covers tracks 1–40 (entries 0–39, starting at byte 16).
    /// BAM sector 2 covers tracks 41–80 (entries 0–39, starting at byte 16).
    private func bamLocation(forTrack track: Int) -> (bamSector: Int, entryIndex: Int)? {
        guard track >= 1, track <= Self.trackCount else { return nil }
        if track <= 40 {
            return (Self.bam1Sector, track - 1)
        } else {
            return (Self.bam2Sector, track - 41)
        }
    }

    /// Byte offset of a track's BAM entry within its BAM sector.
    /// The BAM sector header occupies bytes 0–15; entries start at byte 16, each 6 bytes.
    /// 16 + 40 × 6 = 256 — fills the sector exactly with no padding.
    private func bamEntryOffset(entryIndex: Int) -> Int {
        return 16 + entryIndex * 6
    }

    // MARK: - Disk Metadata

    var diskName: String {
        guard let hdr = readSector(track: Self.systemTrack, sector: Self.headerSector) else { return "" }
        return petsciiToString(Array(hdr[0x04...0x13]))
    }

    var diskID: String {
        guard let hdr = readSector(track: Self.systemTrack, sector: Self.headerSector) else { return "" }
        return petsciiToString(Array(hdr[0x16...0x17]))
    }

    var dosType: String {
        guard let hdr = readSector(track: Self.systemTrack, sector: Self.headerSector) else { return "" }
        return petsciiToString(Array(hdr[0x19...0x1A]))
    }

    var freeBlocks: Int {
        var free = 0
        for track in 1...Self.trackCount {
            if track == Self.systemTrack { continue }
            guard let (bamSector, entryIndex) = bamLocation(forTrack: track),
                  let bam = readSector(track: Self.systemTrack, sector: bamSector) else { continue }
            free += Int(bam[bamEntryOffset(entryIndex: entryIndex)])
        }
        return free
    }

    func isSectorFree(track: Int, sector: Int) -> Bool {
        guard sector >= 0, sector < Self.sectorsPerTrack else { return false }
        guard let (bamSector, entryIndex) = bamLocation(forTrack: track),
              let bam = readSector(track: Self.systemTrack, sector: bamSector) else { return false }
        let entryOff = bamEntryOffset(entryIndex: entryIndex)
        // Bitmap starts at entryOff + 1 (5 bytes, 40 bits)
        let byteIndex = 1 + sector / 8
        let bitIndex  = sector % 8
        return bam[entryOff + byteIndex] & (1 << bitIndex) != 0
    }

    private func allocateSector(track: Int, sector: Int) {
        guard let (bamSector, entryIndex) = bamLocation(forTrack: track),
              var bam = readSector(track: Self.systemTrack, sector: bamSector) else { return }
        let entryOff = bamEntryOffset(entryIndex: entryIndex)
        bam[entryOff] -= 1
        let byteIndex = 1 + sector / 8
        let bitIndex  = sector % 8
        bam[entryOff + byteIndex] &= ~(1 << bitIndex)
        writeSector(track: Self.systemTrack, sector: bamSector, bytes: bam)
    }

    private func freeSector(track: Int, sector: Int) {
        guard let (bamSector, entryIndex) = bamLocation(forTrack: track),
              var bam = readSector(track: Self.systemTrack, sector: bamSector) else { return }
        let entryOff = bamEntryOffset(entryIndex: entryIndex)
        bam[entryOff] += 1
        let byteIndex = 1 + sector / 8
        let bitIndex  = sector % 8
        bam[entryOff + byteIndex] |= (1 << bitIndex)
        writeSector(track: Self.systemTrack, sector: bamSector, bytes: bam)
    }

    /// Search for a free sector, spiraling outward from track 40.
    private func findFreeSector() -> (track: Int, sector: Int)? {
        // Build interleaved search order: 39,41,38,42,...,1,79,80
        var order: [Int] = []
        let mid = Self.systemTrack
        var lo = mid - 1, hi = mid + 1
        while lo >= 1 || hi <= Self.trackCount {
            if lo >= 1    { order.append(lo); lo -= 1 }
            if hi <= Self.trackCount { order.append(hi); hi += 1 }
        }

        for track in order {
            for sector in 0..<Self.sectorsPerTrack {
                if isSectorFree(track: track, sector: sector) { return (track, sector) }
            }
        }
        return nil
    }

    private func findFreeSectorOnTrack(_ track: Int) -> (Int, Int)? {
        for sector in 0..<Self.sectorsPerTrack {
            if isSectorFree(track: track, sector: sector) { return (track, sector) }
        }
        return nil
    }

    // MARK: - Directory

    func readDirectory() -> [CBMDirectoryEntry] {
        var entries: [CBMDirectoryEntry] = []
        var track  = Self.systemTrack
        var sector = Self.dirSector
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
        for entry in readDirectory() {
            if entry.name.uppercased() == upperName { deleteFile(entry) }
        }

        guard let dirSlot = findFreeDirectorySlot() else { return false }

        var remaining = fileData
        var firstTrack = 0, firstSector = 0
        var prevTrack = 0, prevSector = 0
        var blocksUsed = 0

        while !remaining.isEmpty {
            guard let (track, sector) = findFreeSector() else { return false }

            if firstTrack == 0 { firstTrack = track; firstSector = sector }

            // Patch the previous sector's chain link now that we know this sector's address
            if prevTrack != 0 {
                guard var prevBytes = readSector(track: prevTrack, sector: prevSector) else { return false }
                prevBytes[0] = UInt8(track)
                prevBytes[1] = UInt8(sector)
                writeSector(track: prevTrack, sector: prevSector, bytes: prevBytes)
            }

            var sectorBytes = [UInt8](repeating: 0, count: 256)
            if remaining.count <= 254 {
                sectorBytes[0] = 0
                sectorBytes[1] = UInt8(remaining.count + 1)
                for (i, byte) in remaining.enumerated() { sectorBytes[2 + i] = byte }
                remaining = []
            } else {
                for i in 0..<254 { sectorBytes[2 + i] = remaining[i] }
                remaining = Array(remaining.dropFirst(254))
            }

            writeSector(track: track, sector: sector, bytes: sectorBytes)
            allocateSector(track: track, sector: sector)
            prevTrack = track; prevSector = sector
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
        var track  = Self.systemTrack
        var sector = Self.dirSector
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
                // Extend directory chain — preferably stay on track 40
                if let (newTrack, newSector) = findFreeSectorOnTrack(Self.systemTrack) {
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
        let idBytes = stringToPetscii(id.uppercased(), length: 2)

        // ── Header sector (40/0) ─────────────────────────────
        var hdr = [UInt8](repeating: 0xA0, count: 256)
        hdr[0x00] = UInt8(Self.systemTrack)  // Link → first directory sector
        hdr[0x01] = UInt8(Self.dirSector)    // The 1581 ROM uses this to find the directory
        hdr[0x02] = 0x44  // 'D' — DOS version
        hdr[0x03] = 0x00  // 0x00 in header (0xBB magic belongs in BAM sectors only)

        let nameBytes = stringToPetscii(name.uppercased(), length: 16)
        for i in 0..<16 { hdr[0x04 + i] = nameBytes[i] }
        hdr[0x14] = 0xA0; hdr[0x15] = 0xA0

        hdr[0x16] = idBytes[0]; hdr[0x17] = idBytes[1]
        hdr[0x18] = 0xA0
        hdr[0x19] = 0x33  // '3'
        hdr[0x1A] = 0x44  // 'D'

        writeSector(track: Self.systemTrack, sector: Self.headerSector, bytes: hdr)

        // ── BAM sector 1 (40/1) — tracks 1–40 ───────────────
        writeBamSector(sector: Self.bam1Sector, tracksStart: 1, tracksEnd: 40, idBytes: idBytes)

        // ── BAM sector 2 (40/2) — tracks 41–80 ──────────────
        writeBamSector(sector: Self.bam2Sector, tracksStart: 41, tracksEnd: 80, idBytes: idBytes)

        // ── First directory sector (40/3) ────────────────────
        var dirSec = [UInt8](repeating: 0, count: 256)
        dirSec[0] = 0; dirSec[1] = 0xFF  // End of chain
        writeSector(track: Self.systemTrack, sector: Self.dirSector, bytes: dirSec)

        isModified = true
    }

    /// Write one of the two BAM sectors covering `tracksStart...tracksEnd`.
    private func writeBamSector(sector: Int, tracksStart: Int, tracksEnd: Int, idBytes: [UInt8]) {
        var bam = [UInt8](repeating: 0, count: 256)

        // BAM sector header (bytes 0–15)
        // Bytes 0–7: documented fields. Bytes 8–15: unused/zero padding.
        // 16 + 40×6 = 256 — entries fill the remainder of the sector exactly.
        bam[0] = (sector == Self.bam1Sector) ? UInt8(Self.systemTrack) : 0
        bam[1] = (sector == Self.bam1Sector) ? UInt8(Self.bam2Sector)  : 0xFF
        bam[2] = 0x44   // 'D'
        bam[3] = 0xBB   // 1581 magic
        bam[4] = idBytes[0]
        bam[5] = idBytes[1]
        bam[6] = 0xC0   // I/O byte
        bam[7] = 0x00   // Auto-boot flag
        // bam[8…15] remain 0x00 (padding)

        // One 6-byte entry per track: [freeCount, b0, b1, b2, b3, b4]
        for track in tracksStart...tracksEnd {
            let entryIndex = track - tracksStart
            let off = bamEntryOffset(entryIndex: entryIndex)

            if track == Self.systemTrack {
                // Mark header, bam1, bam2, and dir sector as used
                // Sectors 0–3 used → bits 0–3 clear in byte 1
                bam[off]     = UInt8(Self.sectorsPerTrack - 4)
                bam[off + 1] = 0xF0  // Sectors 0–3 used (bits 0–3 = 0)
                bam[off + 2] = 0xFF
                bam[off + 3] = 0xFF
                bam[off + 4] = 0xFF
                bam[off + 5] = 0xFF
            } else {
                // All 40 sectors free
                bam[off]     = UInt8(Self.sectorsPerTrack)
                bam[off + 1] = 0xFF
                bam[off + 2] = 0xFF
                bam[off + 3] = 0xFF
                bam[off + 4] = 0xFF
                bam[off + 5] = 0xFF
            }
        }

        writeSector(track: Self.systemTrack, sector: sector, bytes: bam)
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

