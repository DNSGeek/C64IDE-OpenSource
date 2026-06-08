import Foundation

// ═══════════════════════════════════════════════════════════
// MARK: - C64 Bitmap Image
// ═══════════════════════════════════════════════════════════

/// Represents a Commodore 64 bitmap image in either hi-res (320×200) or multi-color (160×200) mode.
///
/// C64 Memory Layout Reference:
/// - Bitmap Data: 8000 bytes at $2000 (default)
/// - Screen RAM: 1000 bytes at $0400 (hi-nibble = foreground color, lo-nibble = background color)
/// - Color RAM: 1000 bytes at $D800 (multi-color only, stores the 3rd color per cell)
/// - Background Color: 1 byte at $D021 (multi-color only, shared across the entire screen)
///
/// Note: `cellForeground` and `cellBackground` store the raw color index (0–15). 
/// They are packed into Screen RAM bytes during export.
class C64Bitmap {

    /// Image dimensions
    static let width = 320
    static let height = 200
    static let cellCols = 40   // 320 / 8
    static let cellRows = 25   // 200 / 8

    /// Multi-color mode (160×200 with double-wide pixels)
    var isMultiColor: Bool = false

    /// Pixel data — indexed colors (0-15)
    /// In hi-res: 320×200, each pixel is 0 or 1 (mapped to cell colors)
    /// In multi-color: 160×200, each pixel is 0-3 (mapped to cell + global colors)
    var pixels: [[UInt8]]  // [y][x]

    /// Per-cell foreground color (hi-nibble of Screen RAM)
    var cellForeground: [[UInt8]]  // [cellRow][cellCol], C64 color 0-15

    /// Per-cell background color (lo-nibble of Screen RAM)
    var cellBackground: [[UInt8]]  // [cellRow][cellCol], C64 color 0-15

    /// Per-cell color RAM (multi-color mode, 3rd color)
    var cellColorRAM: [[UInt8]]    // [cellRow][cellCol], C64 color 0-15

    /// Global background color (multi-color mode, 4th color)
    var backgroundColor: UInt8 = 0  // C64 color 0-15

    /// Current drawing color index
    var drawColor: UInt8 = 1

    init() {
        let w = Self.width
        let h = Self.height
        pixels = Array(repeating: Array(repeating: 0, count: w), count: h)
        cellForeground = Array(repeating: Array(repeating: 1, count: Self.cellCols), count: Self.cellRows)
        cellBackground = Array(repeating: Array(repeating: 0, count: Self.cellCols), count: Self.cellRows)
        cellColorRAM = Array(repeating: Array(repeating: 2, count: Self.cellCols), count: Self.cellRows)
    }

    // MARK: - Pixel Access

    /// Result of a color-enforced draw attempt
    enum DrawPixelResult {
        /// Pixel was set successfully (possibly auto-assigned to a cell slot)
        case ok
        /// Draw rejected: cell already has 2 colors (hi-res) or 4 colors (multi-color) and
        /// the requested color doesn't match any. Carries the cell coordinates (col, row) for
        /// the flash animation, and — for multi-color only — the slot-replacement callback.
        case conflict(cellCol: Int, cellRow: Int, resolveMultiColor: ((_ replaceSlot: MultiColorSlot) -> Void)?)
    }

    /// Multi-color pixel slots (for conflict resolution UI)
    /// Maps directly to C64 VIC-II multi-color color assignment logic
    enum MultiColorSlot: Int, CaseIterable {
        case background = 0   // Global $D021 — shared across entire image
        case foreground = 1   // Screen RAM hi-nibble
        case cellBg     = 2   // Screen RAM lo-nibble
        case colorRAM   = 3   // Color RAM $D800

        var label: String {
            switch self {
            case .background: return "Slot 0 — Global Background ($D021)"
            case .foreground: return "Slot 1 — Cell Foreground (Screen RAM hi)"
            case .cellBg:     return "Slot 2 — Cell Background (Screen RAM lo)"
            case .colorRAM:   return "Slot 3 — Color RAM ($D800)"
            }
        }
    }

    /// Get pixel value at screen coordinates
    func getPixel(x: Int, y: Int) -> UInt8 {
        let px = isMultiColor ? x / 2 : x
        let maxX = isMultiColor ? 160 : 320
        guard px >= 0, px < maxX, y >= 0, y < Self.height else { return 0 }
        return pixels[y][px]
    }

    /// Set pixel value at screen coordinates (raw, no color enforcement — used by import/undo)
    func setPixel(x: Int, y: Int, value: UInt8) {
        let px = isMultiColor ? x / 2 : x
        let maxX = isMultiColor ? 160 : 320
        guard px >= 0, px < maxX, y >= 0, y < Self.height else { return }
        let maxVal: UInt8 = isMultiColor ? 3 : 1
        pixels[y][px] = min(value, maxVal)
    }

    /// Attempt to draw `color` at screen coordinate (x, y), enforcing per-cell color limits.
    ///
    /// **Hi-res:** Each 8×8 cell has two slots — background (pixel=0) and foreground (pixel=1).
    /// - If the color matches an existing slot, the pixel is set to that slot's value.
    /// - If a slot is unoccupied (no pixels in this cell currently use it), the color
    ///   is assigned there.
    /// - If both slots are occupied by different colors, returns `.conflict` (no pixel written).
    ///
    /// **Multi-color:** Each cell has four slots (0–3). Slot 0 is the global background shared
    /// across the whole image. Slots 1–3 are per-cell.
    /// - Matching and auto-assign work the same way.
    /// - If all four slots are taken and none match, returns `.conflict` with a `resolveMultiColor`
    ///   closure the caller can invoke after asking the user which slot to evict.
    @discardableResult
    func trySetPixel(x: Int, y: Int, color: UInt8) -> DrawPixelResult {
        let cellCol = x / 8
        let cellRow = y / 8
        guard cellCol < Self.cellCols, cellRow < Self.cellRows else { return .ok }

        if isMultiColor {
            return trySetPixelMultiColor(x: x, y: y, cellCol: cellCol, cellRow: cellRow, color: color)
        } else {
            return trySetPixelHiRes(x: x, y: y, cellCol: cellCol, cellRow: cellRow, color: color)
        }
    }

    // MARK: Hi-res enforcement

    private func trySetPixelHiRes(x: Int, y: Int, cellCol: Int, cellRow: Int, color: UInt8) -> DrawPixelResult {
        let fg = cellForeground[cellRow][cellCol]
        let bg = cellBackground[cellRow][cellCol]

        // Color already assigned to foreground slot
        if color == fg {
            setPixel(x: x, y: y, value: 1)
            return .ok
        }
        // Color already assigned to background slot
        if color == bg {
            setPixel(x: x, y: y, value: 0)
            return .ok
        }

        // Check whether a slot is effectively free (no pixels in this cell currently use it)
        let fgFree = !cellUsesSlot(cellCol: cellCol, cellRow: cellRow, slot: 1)
        let bgFree = !cellUsesSlot(cellCol: cellCol, cellRow: cellRow, slot: 0)

        if fgFree {
            cellForeground[cellRow][cellCol] = color
            setPixel(x: x, y: y, value: 1)
            return .ok
        }
        if bgFree {
            cellBackground[cellRow][cellCol] = color
            setPixel(x: x, y: y, value: 0)
            return .ok
        }

        // Both slots occupied by different colors — conflict
        return .conflict(cellCol: cellCol, cellRow: cellRow, resolveMultiColor: nil)
    }

    // MARK: Multi-color enforcement

    private func trySetPixelMultiColor(x: Int, y: Int, cellCol: Int, cellRow: Int, color: UInt8) -> DrawPixelResult {
        // Build the four slot values for this cell
        let slotColors: [UInt8] = [
            backgroundColor,                        // slot 0 — global
            cellForeground[cellRow][cellCol] >> 4,  // slot 1 — screen RAM hi
            cellBackground[cellRow][cellCol] & 0x0F, // slot 2 — screen RAM lo
            cellColorRAM[cellRow][cellCol],          // slot 3 — color RAM
        ]

        // Match existing slot
        for slot in 0..<4 {
            if slotColors[slot] == color {
                setPixel(x: x, y: y, value: UInt8(slot))
                return .ok
            }
        }

        // Try to auto-assign a free per-cell slot (1–3; slot 0 is global, don't auto-reassign)
        for slot in 1..<4 {
            if !cellUsesSlot(cellCol: cellCol, cellRow: cellRow, slot: UInt8(slot)) {
                assignMultiColorSlot(cellCol: cellCol, cellRow: cellRow, slot: slot, color: color)
                setPixel(x: x, y: y, value: UInt8(slot))
                return .ok
            }
        }

        // All slots occupied — return conflict with resolution closure
        let capturedX = x, capturedY = y
        let resolve: (MultiColorSlot) -> Void = { [weak self] replacedSlot in
            guard let self else { return }
            // Slot 0 replacement changes the global background — affects the entire image
            if replacedSlot == .background {
                self.backgroundColor = color
            } else {
                self.assignMultiColorSlot(cellCol: cellCol, cellRow: cellRow,
                                          slot: replacedSlot.rawValue, color: color)
            }
            self.setPixel(x: capturedX, y: capturedY, value: UInt8(replacedSlot.rawValue))
        }
        return .conflict(cellCol: cellCol, cellRow: cellRow, resolveMultiColor: resolve)
    }

    // MARK: Slot helpers

    /// Returns true if any pixel in the given 8×8 cell currently uses `slot` as its value.
    private func cellUsesSlot(cellCol: Int, cellRow: Int, slot: UInt8) -> Bool {
        let maxX = isMultiColor ? 160 : 320
        let startX = cellCol * (isMultiColor ? 4 : 8)
        let endX   = min(startX + (isMultiColor ? 4 : 8), maxX)
        let startY = cellRow * 8
        let endY   = min(startY + 8, Self.height)
        for y in startY..<endY {
            for x in startX..<endX {
                if pixels[y][x] == slot { return true }
            }
        }
        return false
    }

    /// Write a color into the specified multi-color per-cell slot register.
    private func assignMultiColorSlot(cellCol: Int, cellRow: Int, slot: Int, color: UInt8) {
        switch slot {
        case 1: cellForeground[cellRow][cellCol] = color << 4
        case 2: cellBackground[cellRow][cellCol] = color & 0x0F
        case 3: cellColorRAM[cellRow][cellCol] = color
        default: break
        }
    }

    /// Get the display color (C64 palette index) for a pixel
    func displayColor(x: Int, y: Int) -> UInt8 {
        let cellCol = x / 8
        let cellRow = y / 8
        guard cellCol < Self.cellCols, cellRow < Self.cellRows else { return 0 }

        let pixVal = getPixel(x: x, y: y)

        if isMultiColor {
            switch pixVal {
            case 0: return backgroundColor
            case 1: return cellForeground[cellRow][cellCol] >> 4  // Screen RAM hi-nibble
            case 2: return cellBackground[cellRow][cellCol] & 0x0F  // Screen RAM lo-nibble
            case 3: return cellColorRAM[cellRow][cellCol]
            default: return 0
            }
        } else {
            return pixVal == 0 ? cellBackground[cellRow][cellCol] : cellForeground[cellRow][cellCol]
        }
    }

    /// Set cell colors for the cell containing pixel (x, y) — used by import only.
    func setCellForeground(x: Int, y: Int, color: UInt8) {
        let cellCol = x / 8
        let cellRow = y / 8
        guard cellCol < Self.cellCols, cellRow < Self.cellRows else { return }
        cellForeground[cellRow][cellCol] = color
    }

    // MARK: - Clear

    func clear() {
        let w = isMultiColor ? 160 : Self.width
        pixels = Array(repeating: Array(repeating: UInt8(0), count: w), count: Self.height)
    }

    // MARK: - Undo / Redo

    struct UndoState {
        let pixels: [[UInt8]]
        let cellForeground: [[UInt8]]
        let cellBackground: [[UInt8]]
        let cellColorRAM: [[UInt8]]
        let backgroundColor: UInt8
        let isMultiColor: Bool
    }

    private var undoStack: [UndoState] = []
    private var redoStack: [UndoState] = []
    private let maxUndo = 50

    private func captureState() -> UndoState {
        return UndoState(
            pixels: pixels.map { $0 },
            cellForeground: cellForeground.map { $0 },
            cellBackground: cellBackground.map { $0 },
            cellColorRAM: cellColorRAM.map { $0 },
            backgroundColor: backgroundColor,
            isMultiColor: isMultiColor
        )
    }

    private func restoreState(_ state: UndoState) {
        pixels = state.pixels
        cellForeground = state.cellForeground
        cellBackground = state.cellBackground
        cellColorRAM = state.cellColorRAM
        backgroundColor = state.backgroundColor
        isMultiColor = state.isMultiColor
    }

    func saveUndo() {
        undoStack.append(captureState())
        if undoStack.count > maxUndo { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() -> Bool {
        guard let state = undoStack.popLast() else { return false }
        redoStack.append(captureState())
        restoreState(state)
        return true
    }

    func redo() -> Bool {
        guard let state = redoStack.popLast() else { return false }
        undoStack.append(captureState())
        restoreState(state)
        return true
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // MARK: - Import: Koala Painter (.kla)

    /// Import Koala Painter format (multi-color)
    /// Format: 2-byte load addr + 8000 bitmap + 1000 screen + 1000 color + 1 background = 10003 bytes
    func importKoala(_ data: Data) -> Bool {
        // Accept with or without 2-byte load address
        let offset: Int
        if data.count == 10003 { offset = 2 }       // with load address
        else if data.count == 10001 { offset = 0 }  // without
        else { return false }

        let bytes = Array(data)
        isMultiColor = true

        // Resize pixel array for multicolor (160 wide)
        pixels = Array(repeating: Array(repeating: UInt8(0), count: 160), count: Self.height)

        // Parse 8000 bytes of bitmap data
        for cellRow in 0..<Self.cellRows {
            for cellCol in 0..<Self.cellCols {
                for row in 0..<8 {
                    let byteIdx = offset + (cellRow * Self.cellCols + cellCol) * 8 + row
                    guard byteIdx < bytes.count else { continue }
                    let byte = bytes[byteIdx]
                    for pair in 0..<4 {
                        let x = cellCol * 4 + pair
                        let val = (byte >> (6 - pair * 2)) & 0x03
                        if x < 160 { pixels[cellRow * 8 + row][x] = val }
                    }
                }
            }
        }

        // Screen RAM: 1000 bytes at offset+8000
        let screenBase = offset + 8000
        for row in 0..<Self.cellRows {
            for col in 0..<Self.cellCols {
                let idx = screenBase + row * Self.cellCols + col
                guard idx < bytes.count else { continue }
                cellForeground[row][col] = bytes[idx] >> 4
                cellBackground[row][col] = bytes[idx] & 0x0F
            }
        }

        // Color RAM: 1000 bytes at offset+9000
        let colorBase = offset + 9000
        for row in 0..<Self.cellRows {
            for col in 0..<Self.cellCols {
                let idx = colorBase + row * Self.cellCols + col
                guard idx < bytes.count else { continue }
                cellColorRAM[row][col] = bytes[idx] & 0x0F
            }
        }

        // Background color: 1 byte at offset+10000
        let bgIdx = offset + 10000
        if bgIdx < bytes.count { backgroundColor = bytes[bgIdx] & 0x0F }

        return true
    }

    // MARK: - Import: Art Studio (.art)

    /// Import Art Studio format (hi-res)
    /// Format: 2-byte load addr + 8000 bitmap + 1000 screen = 9002 bytes
    func importArtStudio(_ data: Data) -> Bool {
        let offset: Int
        if data.count == 9002 { offset = 2 }
        else if data.count == 9000 { offset = 0 }
        else { return false }

        let bytes = Array(data)
        isMultiColor = false

        pixels = Array(repeating: Array(repeating: UInt8(0), count: Self.width), count: Self.height)

        // Parse 8000 bytes of bitmap data
        for cellRow in 0..<Self.cellRows {
            for cellCol in 0..<Self.cellCols {
                for row in 0..<8 {
                    let byteIdx = offset + (cellRow * Self.cellCols + cellCol) * 8 + row
                    guard byteIdx < bytes.count else { continue }
                    let byte = bytes[byteIdx]
                    for bit in 0..<8 {
                        let x = cellCol * 8 + bit
                        pixels[cellRow * 8 + row][x] = (byte >> (7 - bit)) & 1
                    }
                }
            }
        }

        // Screen RAM: 1000 bytes at offset+8000
        let screenBase = offset + 8000
        for row in 0..<Self.cellRows {
            for col in 0..<Self.cellCols {
                let idx = screenBase + row * Self.cellCols + col
                guard idx < bytes.count else { continue }
                cellForeground[row][col] = bytes[idx] >> 4
                cellBackground[row][col] = bytes[idx] & 0x0F
            }
        }

        return true
    }

    // MARK: - Export: Koala Painter (.kla)

    /// Export as Koala Painter format (multi-color only)
    /// Format: $6000 load addr + 8000 bitmap + 1000 screen + 1000 color + 1 background
    func exportKoala() -> Data {
        var data = Data()
        data.append(contentsOf: [0x00, 0x60])  // Load address $6000
        data.append(contentsOf: generateBitmapData())
        data.append(contentsOf: generateScreenRAM())
        data.append(contentsOf: generateColorRAM())
        data.append(backgroundColor)
        return data
    }

    // MARK: - Export: Art Studio (.art)

    /// Export as Art Studio format (hi-res)
    /// Format: $2000 load addr + 8000 bitmap + 1000 screen
    func exportArtStudio() -> Data {
        var data = Data()
        data.append(contentsOf: [0x00, 0x20])  // Load address $2000
        data.append(contentsOf: generateBitmapData())
        data.append(contentsOf: generateScreenRAM())
        return data
    }

    // MARK: - Export: Raw Binary

    func exportRawBinary() -> Data {
        var data = Data()
        data.append(contentsOf: generateBitmapData())
        data.append(contentsOf: generateScreenRAM())
        if isMultiColor {
            data.append(contentsOf: generateColorRAM())
            data.append(backgroundColor)
        }
        return data
    }

    // MARK: - Export: PRG (self-displaying program)

    /// Export as a self-contained PRG that loads at $0801 and displays the image.
    /// Note: This generates a direct memory dump. The file will be padded to $2000
    /// so that bitmap data lands at the correct VIC-II address.
    func exportAsPRG() -> Data {
        // Generate a small 6502 program that sets up the VIC-II and displays the image
        var code: [UInt8] = []

        // Load address $0801
        code.append(contentsOf: [0x01, 0x08])

        // BASIC stub: 10 SYS 2064
        code.append(contentsOf: [0x0B, 0x08, 0x0A, 0x00, 0x9E, 0x32, 0x30, 0x36, 0x34, 0x00, 0x00, 0x00])

        // Machine code at $0810
        let bitmap = generateBitmapData()

        // SEI
        code.append(0x78)

        // Set bitmap mode: LDA #$3B : STA $D011
        // $D011 bit 5 enables bitmap mode
        code.append(contentsOf: [0xA9, 0x3B, 0x8D, 0x11, 0xD0])

        // Set VIC memory: LDA #$18 : STA $D018 (bitmap at $2000, screen at $0400)
        code.append(contentsOf: [0xA9, 0x18, 0x8D, 0x18, 0xD0])

        if isMultiColor {
            // Enable multi-color: LDA $D016 : ORA #$10 : STA $D016
            // $D016 bit 4 enables multi-color mode
            code.append(contentsOf: [0xAD, 0x16, 0xD0, 0x09, 0x10, 0x8D, 0x16, 0xD0])
            // Set background: LDA #bg : STA $D021
            code.append(contentsOf: [0xA9, backgroundColor, 0x8D, 0x21, 0xD0])
        }

        // Infinite loop: JMP *
        let loopAddr = 0x0810 + code.count - 2
        code.append(0x4C)
        code.append(UInt8(loopAddr & 0xFF))
        code.append(UInt8(loopAddr >> 8))

        // Pad to $2000 for bitmap data (direct memory dump strategy)
        while code.count < 0x2000 - 0x0801 + 2 {
            code.append(0x00)
        }

        // Bitmap at $2000
        code.append(contentsOf: bitmap)

        return Data(code)
    }

    // MARK: - Export: Assembly Source

    func exportAsAssembly() -> String {
        var lines = [
            "; C64 bitmap image — generated by C64 IDE",
            "; Mode: \(isMultiColor ? "Multi-Color (160×200)" : "Hi-Res (320×200)")",
            "",
            "bitmap_data:",
        ]

        let bitmap = generateBitmapData()
        for row in 0..<(bitmap.count / 8) {
            let start = row * 8
            let bytes = bitmap[start..<min(start + 8, bitmap.count)]
            let hex = bytes.map { String(format: "$%02X", $0) }.joined(separator: ", ")
            lines.append("    .byte \(hex)")
        }

        lines.append("")
        lines.append("screen_data:")
        let screen = generateScreenRAM()
        for row in 0..<(screen.count / 40) {
            let start = row * 40
            let bytes = screen[start..<start + 40]
            let hex = bytes.map { String(format: "$%02X", $0) }.joined(separator: ", ")
            lines.append("    .byte \(hex)")
        }

        if isMultiColor {
            lines.append("")
            lines.append("color_data:")
            let color = generateColorRAM()
            for row in 0..<(color.count / 40) {
                let start = row * 40
                let bytes = color[start..<start + 40]
                let hex = bytes.map { String(format: "$%02X", $0) }.joined(separator: ", ")
                lines.append("    .byte \(hex)")
            }
            lines.append("")
            lines.append("background_color: .byte \(backgroundColor)")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Export: BASIC DATA

    func exportAsBASIC() -> String {
        var lines = [
            "10 REM C64 BITMAP IMAGE",
            "20 REM GENERATED BY C64 IDE",
            "30 REM MODE: \(isMultiColor ? "MULTI-COLOR" : "HI-RES")",
        ]

        let bitmap = generateBitmapData()
        let screen = generateScreenRAM()
        let color = isMultiColor ? generateColorRAM() : []

        var lineNum = 100

        // Bitmap data (8000 bytes)
        lines.append("\(lineNum) REM BITMAP DATA (8000 BYTES)")
        lineNum += 10
        for i in stride(from: 0, to: bitmap.count, by: 8) {
            let chunk = bitmap[i..<min(i + 8, bitmap.count)]
            let values = chunk.map { String($0) }.joined(separator: ",")
            lines.append("\(lineNum) DATA \(values)")
            lineNum += 10
        }

        // Screen RAM (1000 bytes)
        lines.append("\(lineNum) REM SCREEN DATA (1000 BYTES)")
        lineNum += 10
        for i in stride(from: 0, to: screen.count, by: 8) {
            let chunk = screen[i..<min(i + 8, screen.count)]
            let values = chunk.map { String($0) }.joined(separator: ",")
            lines.append("\(lineNum) DATA \(values)")
            lineNum += 10
        }

        if isMultiColor {
            // Color RAM (1000 bytes)
            lines.append("\(lineNum) REM COLOR DATA (1000 BYTES)")
            lineNum += 10
            for i in stride(from: 0, to: color.count, by: 8) {
                let chunk = color[i..<min(i + 8, color.count)]
                let values = chunk.map { String($0) }.joined(separator: ",")
                lines.append("\(lineNum) DATA \(values)")
                lineNum += 10
            }

            lines.append("\(lineNum) REM BACKGROUND COLOR")
            lineNum += 10
            lines.append("\(lineNum) DATA \(backgroundColor)")
            lineNum += 10
        }

        // Loader routine
        lines.append("\(lineNum) REM LOADER")
        lineNum += 10
        // POKE 53272 ($D038) OR 8 enables bitmap data at $2000
        lines.append("\(lineNum) POKE 53272,PEEK(53272) OR 8 : REM BITMAP AT $2000")
        lineNum += 10
        // POKE 53265 ($D011) OR 32 enables bitmap mode (bit 5)
        lines.append("\(lineNum) POKE 53265,PEEK(53265) OR 32 : REM BITMAP MODE ON")
        lineNum += 10
        if isMultiColor {
            // POKE 53270 ($D016) OR 16 enables multi-color mode (bit 4)
            lines.append("\(lineNum) POKE 53270,PEEK(53270) OR 16 : REM MULTI-COLOR ON")
            lineNum += 10
        }
        lines.append("\(lineNum) FOR I=0 TO 7999:READ B:POKE 8192+I,B:NEXT I")
        lineNum += 10
        lines.append("\(lineNum) FOR I=0 TO 999:READ B:POKE 1024+I,B:NEXT I")
        lineNum += 10
        if isMultiColor {
            lines.append("\(lineNum) FOR I=0 TO 999:READ B:POKE 55296+I,B:NEXT I")
            lineNum += 10
            lines.append("\(lineNum) READ B:POKE 53281,B")
            lineNum += 10
        }
        lines.append("\(lineNum) GET A$:IF A$=\"\" THEN \(lineNum)")
        lineNum += 10
        lines.append("\(lineNum) POKE 53265,PEEK(53265) AND 223 : REM TEXT MODE")

        return lines.joined(separator: "\n")
    }

    /// Generate 8000 bytes of bitmap data (organized by 8×8 cells)
    private func generateBitmapData() -> [UInt8] {
        var bitmap: [UInt8] = []

        for cellRow in 0..<Self.cellRows {
            for cellCol in 0..<Self.cellCols {
                // Each cell = 8 bytes (8 rows of 8 pixels)
                for row in 0..<8 {
                    let y = cellRow * 8 + row
                    var byte: UInt8 = 0

                    if isMultiColor {
                        // 4 pixel-pairs per byte (2 bits each)
                        for pair in 0..<4 {
                            let x = cellCol * 4 + pair
                            let val = x < 160 && y < 200 ? pixels[y][x] & 0x03 : 0
                            byte |= val << (6 - pair * 2)
                        }
                    } else {
                        // 8 pixels per byte (1 bit each, MSB first)
                        for bit in 0..<8 {
                            let x = cellCol * 8 + bit
                            if x < 320 && y < 200 && pixels[y][x] != 0 {
                                byte |= 1 << (7 - bit)
                            }
                        }
                    }

                    bitmap.append(byte)
                }
            }
        }

        return bitmap
    }

    /// Generate 1000 bytes of screen RAM (foreground/background per cell)
    private func generateScreenRAM() -> [UInt8] {
        var screen: [UInt8] = []
        for row in 0..<Self.cellRows {
            for col in 0..<Self.cellCols {
                let fg = cellForeground[row][col] & 0x0F
                let bg = cellBackground[row][col] & 0x0F
                screen.append((fg << 4) | bg)
            }
        }
        return screen
    }

    /// Generate 1000 bytes of color RAM (multi-color 3rd color per cell)
    private func generateColorRAM() -> [UInt8] {
        var color: [UInt8] = []
        for row in 0..<Self.cellRows {
            for col in 0..<Self.cellCols {
                color.append(cellColorRAM[row][col] & 0x0F)
            }
        }
        return color
    }
}

