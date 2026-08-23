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
        // Build the four slot values for this cell.
        // Invariant: cellForeground/cellBackground/cellColorRAM store RAW
        // color indices (0-15). Nibble packing happens only in
        // generateScreenRAM at export time.
        let slotColors: [UInt8] = [
            backgroundColor,                     // slot 0 - global $D021
            cellForeground[cellRow][cellCol],    // slot 1 - screen RAM hi (raw)
            cellBackground[cellRow][cellCol],    // slot 2 - screen RAM lo (raw)
            cellColorRAM[cellRow][cellCol],      // slot 3 - color RAM
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
    /// Stores the RAW color index (0-15) in all three arrays; the hi/lo
    /// nibble packing into Screen RAM bytes happens only at export time
    /// (generateScreenRAM). Storing pre-shifted values here would corrupt
    /// exports and disagree with importKoala/importArtStudio, which store raw.
    private func assignMultiColorSlot(cellCol: Int, cellRow: Int, slot: Int, color: UInt8) {
        switch slot {
        case 1: cellForeground[cellRow][cellCol] = color & 0x0F
        case 2: cellBackground[cellRow][cellCol] = color & 0x0F
        case 3: cellColorRAM[cellRow][cellCol] = color & 0x0F
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
            case 1: return cellForeground[cellRow][cellCol]  // raw 0-15
            case 2: return cellBackground[cellRow][cellCol]  // raw 0-15
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
        // Always allocate the full hi-res width. In multi-color mode only
        // columns 0..<160 are meaningful (getPixel/setPixel clamp to that),
        // but keeping one fixed geometry means a mode switch can never leave
        // a short row behind for another code path to index into.
        pixels = Array(repeating: Array(repeating: UInt8(0), count: Self.width), count: Self.height)
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
    ///
    /// File layout (memory address = $0801 + file offset - 2):
    ///   $0801-$080C  BASIC stub: 10 SYS 2061
    ///   $080D-       display code (VIC-II setup + screen/color RAM copy + freeze)
    ///   ...          zero padding up to $2000
    ///   $2000-$3F3F  bitmap data (8000 bytes)
    ///   $3F40-$4327  screen RAM data (1000 bytes, copied to $0400 at runtime)
    ///   $4328-$470F  color RAM data (1000 bytes, multi-color only, copied to $D800)
    ///
    /// Screen/color RAM live below the load address ($0400/$D800), so they
    /// cannot be load-populated; the startup code copies them with unrolled
    /// four-page loops (1024 bytes each; the 24-byte overspill past the
    /// visible 1000 hits only unused screen bytes / sprite pointers and the
    /// unused tail of color RAM, both harmless with sprites off).
    func exportAsPRG() -> Data {
        var code: [UInt8] = []

        // Load address $0801
        code.append(contentsOf: [0x01, 0x08])

        // BASIC stub: 10 SYS 2061
        //   $0801: 0B 08        link to next line ($080B)
        //   $0803: 0A 00        line number 10
        //   $0805: 9E           SYS token
        //   $0806: 32 30 36 31  "2061" = $080D, first byte after the stub
        //   $080A: 00           end of line
        //   $080B: 00 00        end of program
        code.append(contentsOf: [0x0B, 0x08, 0x0A, 0x00, 0x9E,
                                 0x32, 0x30, 0x36, 0x31, 0x00, 0x00, 0x00])

        // -- Machine code, entry at $080D --

        code.append(0x78)                                        // SEI

        // $D011 = $3B: YSCROLL=3, 25 rows, screen on, bitmap mode (bit 5)
        code.append(contentsOf: [0xA9, 0x3B])                    // LDA #$3B
        code.append(contentsOf: [0x8D, 0x11, 0xD0])              // STA $D011

        // $D018 = $18: screen at $0400, bitmap at $2000
        code.append(contentsOf: [0xA9, 0x18])                    // LDA #$18
        code.append(contentsOf: [0x8D, 0x18, 0xD0])              // STA $D018

        if isMultiColor {
            code.append(contentsOf: [0xAD, 0x16, 0xD0])          // LDA $D016
            code.append(contentsOf: [0x09, 0x10])                // ORA #$10   (MC on)
            code.append(contentsOf: [0x8D, 0x16, 0xD0])          // STA $D016
            code.append(contentsOf: [0xA9, backgroundColor & 0x0F]) // LDA #bg
            code.append(contentsOf: [0x8D, 0x21, 0xD0])          // STA $D021
        } else {
            code.append(contentsOf: [0xAD, 0x16, 0xD0])          // LDA $D016
            code.append(contentsOf: [0x29, 0xEF])                // AND #$EF   (MC off)
            code.append(contentsOf: [0x8D, 0x16, 0xD0])          // STA $D016
        }

        // -- Copy screen (and color) data into place --
        // Unrolled X-indexed loop: each pass copies one byte per page pair,
        // X wraps after 256 iterations = 1024 bytes per destination block.
        let screenSrc = 0x3F40                    // $2000 + 8000
        let colorSrc  = screenSrc + 1000          // $4328

        var pagePairs: [(src: Int, dst: Int)] = (0..<4).map {
            (screenSrc + $0 * 0x100, 0x0400 + $0 * 0x100)
        }
        if isMultiColor {
            pagePairs += (0..<4).map {
                (colorSrc + $0 * 0x100, 0xD800 + $0 * 0x100)
            }
        }

        code.append(contentsOf: [0xA2, 0x00])                    // LDX #$00
        var loopBody: [UInt8] = []                               // loop:
        for (src, dst) in pagePairs {
            loopBody.append(contentsOf: [0xBD, UInt8(src & 0xFF), UInt8(src >> 8)])  // LDA src,X
            loopBody.append(contentsOf: [0x9D, UInt8(dst & 0xFF), UInt8(dst >> 8)])  // STA dst,X
        }
        loopBody.append(0xE8)                                    // INX
        // BNE loop: relative offset from the byte AFTER the operand back to
        // the loop start = -(bytes so far + 2 for the BNE itself).
        // Hi-res: -(4*6 + 1 + 2) = -27; multi-color: -(8*6 + 1 + 2) = -51.
        let branchBack = -(loopBody.count + 2)
        loopBody.append(contentsOf: [0xD0, UInt8(bitPattern: Int8(branchBack))])     // BNE loop
        code.append(contentsOf: loopBody)

        // Freeze: JMP to own address. Address of this instruction is
        // $0801 + (bytes emitted so far - 2 for the load address).
        let jmpAddr = 0x0801 + (code.count - 2)
        code.append(contentsOf: [0x4C,
                                 UInt8(jmpAddr & 0xFF),
                                 UInt8((jmpAddr >> 8) & 0xFF)])  // JMP jmpAddr

        // Pad so the bitmap's first byte lands at $2000
        while code.count < 0x2000 - 0x0801 + 2 {
            code.append(0x00)
        }

        // Data blocks (see layout comment above)
        code.append(contentsOf: generateBitmapData())            // $2000
        code.append(contentsOf: generateScreenRAM())             // $3F40
        if isMultiColor {
            code.append(contentsOf: generateColorRAM())          // $4328
        }

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

    /// Bytes of BASIC program RAM on a stock C64 ($0801-$9FFF).
    static let c64BasicRAM = 38911

    /// Largest BASIC listing worth exporting: `c64BasicRAM` less a little room
    /// above the program for variables and the string heap.
    static let basicSizeBudget = 38000

    /// Export as a runnable BASIC program that POKEs the image into place and
    /// displays it.
    ///
    /// The data lives in VIC bank 3 — bitmap at $E000 (under the KERNAL ROM,
    /// which the CPU still writes through) and screen RAM at $C000 — so it can
    /// never collide with the BASIC program itself, which occupies $0801
    /// upwards. An earlier version targeted the default bank ($2000/$0400);
    /// since 10,000 bytes of DATA statements tokenise to well past $2000, the
    /// loader used to overwrite the very DATA lines it was still READing.
    ///
    /// Ten thousand bytes is a lot to carry in DATA statements, so the blocks
    /// are run-length encoded whenever that comes out smaller than the raw
    /// listing. Even then the result can exceed available BASIC RAM; when it
    /// does, the program carries a warning header and
    /// `estimatedBASICProgramSize()` reports the overflow to the caller.
    func exportAsBASIC() -> String {
        let bitmapBytes = generateBitmapData()
        let screenBytes = generateScreenRAM()
        let colorBytes  = isMultiColor ? generateColorRAM() : []

        let blocks = [bitmapBytes, screenBytes, colorBytes].filter { !$0.isEmpty }

        // Pick raw or RLE for the whole listing, whichever emits fewer digits.
        // Mixing per block would need a flag the BASIC decoder has to track.
        let rawCost = blocks.reduce(0) { $0 + Self.digitCost($1) }
        let rleCost = blocks.reduce(0) { $0 + Self.digitCost(Self.rleEncode($1)) }
        let useRLE  = rleCost < rawCost

        var lines: [String] = [
            "10 REM C64 BITMAP IMAGE",
            "20 REM GENERATED BY C64 IDE",
            "30 REM MODE: \(isMultiColor ? "MULTI-COLOR" : "HI-RES")",
            "40 REM VIC BANK 3 - SCREEN $C000, BITMAP $E000",
            "50 RL=\(useRLE ? 1 : 0)",
            "60 GOTO 200",
            // -- Block loader: A = destination, N = byte count --
            "100 REM BLOCK LOADER: A=DEST, N=COUNT",
            "110 IF RL=1 THEN 150",
            "120 FOR I=0 TO N-1:READ B:POKE A+I,B:NEXT I",
            "130 RETURN",
            "150 I=0",
            "160 READ C,B",
            "170 FOR J=1 TO C:POKE A+I,B:I=I+1:NEXT J",
            "180 IF I<N THEN 160",
            "190 RETURN",
            // -- Main --
            "200 PRINT CHR$(147);\"LOADING IMAGE - PLEASE WAIT\"",
            "210 A=57344:N=8000:GOSUB 100 : REM BITMAP $E000",
            "220 A=49152:N=1000:GOSUB 100 : REM SCREEN $C000",
        ]
        if isMultiColor {
            lines.append("230 A=55296:N=1000:GOSUB 100 : REM COLOR $D800")
        }
        // Switch the VIC over only after every byte is in place, so the user
        // never watches uninitialised memory during the READ/POKE loops.
        lines.append("240 POKE 56576,PEEK(56576) AND 252 : REM VIC BANK 3")
        lines.append("250 POKE 53272,8 : REM SCREEN $C000, BITMAP $E000")
        if isMultiColor {
            lines.append("260 POKE 53270,PEEK(53270) OR 16 : REM MULTI-COLOR ON")
            lines.append("270 POKE 53281,\(backgroundColor & 0x0F) : REM BACKGROUND")
        }
        lines.append("280 POKE 53265,PEEK(53265) OR 32 : REM BITMAP MODE ON")
        lines.append("290 GET A$:IF A$=\"\" THEN 290")
        lines.append("300 POKE 53265,PEEK(53265) AND 223 : REM TEXT MODE")
        if isMultiColor {
            lines.append("310 POKE 53270,PEEK(53270) AND 239 : REM MULTI-COLOR OFF")
        }
        lines.append("320 POKE 56576,PEEK(56576) OR 3 : REM VIC BANK 0")
        lines.append("330 POKE 53272,21 : REM SCREEN $0400, CHARSET $1000")
        if isMultiColor {
            // Colour RAM is shared with the text screen; put it back.
            lines.append("340 FOR I=0 TO 999:POKE 55296+I,14:NEXT I")
        }
        lines.append("350 PRINT CHR$(147)")
        lines.append("360 END")

        // -- DATA blocks, in the order the loader READs them --
        var lineNum = 1000
        let names = isMultiColor
            ? ["BITMAP", "SCREEN", "COLOR"]
            : ["BITMAP", "SCREEN"]
        for (index, block) in blocks.enumerated() {
            let values = useRLE ? Self.rleEncode(block) : block
            lines.append("\(lineNum) REM \(names[index]) DATA (\(block.count) BYTES)")
            lineNum += 10
            for start in stride(from: 0, to: values.count, by: 16) {
                let chunk = values[start..<min(start + 16, values.count)]
                lines.append("\(lineNum) DATA \(chunk.map(String.init).joined(separator: ","))")
                lineNum += 10
            }
        }

        let size = lines.reduce(0) { $0 + Self.tokenizedLineSize($1) }
        if size > Self.basicSizeBudget {
            lines.insert("1 REM *** WARNING: \(size) BYTES - EXCEEDS THE \(Self.c64BasicRAM)", at: 0)
            lines.insert("2 REM *** BYTES OF BASIC RAM ON A STOCK C64.", at: 1)
            lines.insert("3 REM *** USE THE PRG EXPORT FOR A SELF-CONTAINED IMAGE.", at: 2)
        }

        return lines.joined(separator: "\n")
    }

    /// Approximate tokenised size, in bytes, that `listing` would occupy in a
    /// C64's BASIC RAM. Compare against `basicSizeBudget` to decide whether it
    /// is worth loading.
    static func tokenizedProgramSize(of listing: String) -> Int {
        listing.split(separator: "\n").reduce(0) { $0 + tokenizedLineSize(String($1)) }
    }

    /// Convenience for callers that do not already hold the listing.
    func estimatedBASICProgramSize() -> Int {
        Self.tokenizedProgramSize(of: exportAsBASIC())
    }

    /// Run-length encode as (count, value) pairs, counts capped at 255.
    private static func rleEncode(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while i < bytes.count {
            let value = bytes[i]
            var run = 1
            while i + run < bytes.count, bytes[i + run] == value, run < 255 { run += 1 }
            out.append(UInt8(run))
            out.append(value)
            i += run
        }
        return out
    }

    /// Characters a byte list costs once written out as comma-separated decimals.
    private static func digitCost(_ bytes: [UInt8]) -> Int {
        bytes.reduce(0) { $0 + ($1 < 10 ? 1 : ($1 < 100 ? 2 : 3)) + 1 }
    }

    /// Tokenised size of one program line: 2 bytes of link, 2 of line number,
    /// the body, and a terminating null. Keywords tokenise to one byte each;
    /// only DATA is modelled exactly, since the DATA lines dominate. Counting
    /// the rest verbatim over-estimates slightly, which is the safe direction
    /// for a capacity check.
    private static func tokenizedLineSize(_ line: String) -> Int {
        guard let space = line.firstIndex(of: " ") else { return line.count + 5 }
        let body = line[line.index(after: space)...]
        var size = body.count
        if body.hasPrefix("DATA ") { size -= 3 }   // "DATA " -> token + space
        return size + 5
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

