import Foundation

// MARK: - Map Layer

/// A single layer in a map document.
/// Each layer has its own tile and color grids, plus visibility/opacity for compositing.
public final class MapLayer: Codable {
    public var name: String
    public var isVisible: Bool = true
    public var opacity: Float = 1.0  // 0.0–1.0, for editor display only

    /// Tile indices — one byte per cell (0–255 into the charset)
    public var tiles: [[UInt8]]

    /// Color RAM values — one nybble per cell (0–15, maps to $D800)
    public var colors: [[UInt8]]

    public init(name: String, width: Int, height: Int, fillTile: UInt8 = 0x20, fillColor: UInt8 = 14) {
        self.name = name
        tiles = Array(repeating: Array(repeating: fillTile, count: width), count: height)
        colors = Array(repeating: Array(repeating: fillColor, count: width), count: height)
    }

    /// Resizes the layer, preserving existing data where it overlaps.
    public func resize(to newWidth: Int, height newHeight: Int, fillTile: UInt8 = 0x20, fillColor: UInt8 = 14) {
        let oldHeight = tiles.count
        let oldWidth = tiles.first?.count ?? 0

        var newTiles = Array(repeating: Array(repeating: fillTile, count: newWidth), count: newHeight)
        var newColors = Array(repeating: Array(repeating: fillColor, count: newWidth), count: newHeight)

        for row in 0..<min(oldHeight, newHeight) {
            for col in 0..<min(oldWidth, newWidth) {
                newTiles[row][col] = tiles[row][col]
                newColors[row][col] = colors[row][col]
            }
        }

        tiles = newTiles
        colors = newColors
    }
}

// MARK: - Map Document

/// The top-level map document, serialized as JSON with a .c64map extension.
public final class MapDocument: Codable {
    /// File format version for forward compatibility
    public static let formatVersion = 1

    public var formatVersion: Int = MapDocument.formatVersion
    public var name: String = "Untitled Map"

    /// Map dimensions in characters
    public var width: Int
    public var height: Int

    /// Background color index (0–15, maps to VIC-II register $D021)
    public var backgroundColor: UInt8 = 6  // C64 blue

    /// Multicolor charset mode. When enabled, a cell whose color RAM value is
    /// 8–15 is drawn as four 2-bit pixel pairs (00 = background, 01 =
    /// extraColor1, 10 = extraColor2, 11 = colour RAM value & 7), exactly as
    /// the VIC-II does with bit 4 of $D016 set. Cells with colour 0–7 stay
    /// hi-res.
    public var isMultiColorMode: Bool = false

    /// Multicolor registers ($D022, $D023) — used when `isMultiColorMode` is on
    public var extraColor1: UInt8 = 1   // white
    public var extraColor2: UInt8 = 2   // red

    /// Ordered layers (bottom to top)
    public var layers: [MapLayer]

    /// Index of the currently active (editable) layer
    public var activeLayerIndex: Int = 0

    /// Path to the associated character set file, if any.
    /// When nil, the editor uses the built-in C64 ROM charset.
    public var charsetPath: String?

    /// Raw 2048-byte charset data (256 chars × 8 bytes each).
    /// Stored in the document so maps are self-contained even if the .chr file moves.
    public var charsetData: Data?

    // MARK: - Lifecycle

    public init(width: Int = 40, height: Int = 25) {
        let w = max(1, min(MapDocument.maxDimension, width))
        let h = max(1, min(MapDocument.maxDimension, height))
        self.width = w
        self.height = h
        self.layers = [MapLayer(name: "Background", width: w, height: h)]
    }

    // MARK: - Layer Management

    public var activeLayer: MapLayer? {
        guard activeLayerIndex >= 0, activeLayerIndex < layers.count else { return nil }
        return layers[activeLayerIndex]
    }

    @discardableResult
    public func addLayer(name: String? = nil) -> MapLayer {
        let layerName = name ?? "Layer \(layers.count + 1)"
        let layer = MapLayer(name: layerName, width: width, height: height,
                             fillTile: 0x20, fillColor: 14)
        layers.append(layer)
        activeLayerIndex = layers.count - 1
        return layer
    }

    /// Note for callers: removing or moving layers invalidates recorded undo
    /// history (actions store raw layer indices). Call
    /// MapUndoManager.clearHistory() afterwards.
    public func removeLayer(at index: Int) {
        guard layers.count > 1 else { return }  // always keep at least one layer
        guard index >= 0, index < layers.count else { return }
        layers.remove(at: index)
        if activeLayerIndex >= layers.count {
            activeLayerIndex = layers.count - 1
        }
    }

    public func moveLayer(from: Int, to: Int) {
        guard from != to,
              from >= 0, from < layers.count,
              to >= 0, to < layers.count else { return }
        let layer = layers.remove(at: from)
        layers.insert(layer, at: to)
        activeLayerIndex = to
    }

    // MARK: - Tile Access (convenience for active layer)

    public func tile(atCol col: Int, row: Int) -> UInt8? {
        activeLayer?.tiles[safe: row]?[safe: col]
    }

    public func color(atCol col: Int, row: Int) -> UInt8? {
        activeLayer?.colors[safe: row]?[safe: col]
    }

    public func setTile(_ tile: UInt8, color: UInt8, atCol col: Int, row: Int) {
        guard let layer = activeLayer,
              row >= 0, row < height,
              col >= 0, col < width else { return }
        layer.tiles[row][col] = tile
        layer.colors[row][col] = color
    }

    // MARK: - Resize

    /// Note for callers: resizing invalidates any recorded undo history
    /// (stored coordinates may fall outside the new bounds). Call
    /// MapUndoManager.clearHistory() after this.
    public func resize(to newWidth: Int, height newHeight: Int) {
        let clampedWidth = max(1, min(MapDocument.maxDimension, newWidth))
        let clampedHeight = max(1, min(MapDocument.maxDimension, newHeight))
        width = clampedWidth
        height = clampedHeight
        for layer in layers {
            layer.resize(to: clampedWidth, height: clampedHeight)
        }
    }

    /// Upper bound on either map dimension. Screen RAM addressing is 16-bit,
    /// and a map this large already exceeds anything the C64 can display.
    public static let maxDimension = 256

    // MARK: - Serialization

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }

    public enum MapDocumentError: LocalizedError {
        case unsupportedFormatVersion(Int)
        case invalidDimensions(width: Int, height: Int)

        public var errorDescription: String? {
            switch self {
            case .unsupportedFormatVersion(let v):
                return "This map file uses format version \(v), but this build "
                     + "only supports up to version \(MapDocument.formatVersion). "
                     + "Please update the application."
            case let .invalidDimensions(width, height):
                return "This map file declares an unusable size of \(width)×\(height) "
                     + "characters. Maps must be between 1×1 and "
                     + "\(MapDocument.maxDimension)×\(MapDocument.maxDimension)."
            }
        }
    }

    public static func load(from url: URL) throws -> MapDocument {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let doc = try decoder.decode(MapDocument.self, from: data)
        guard doc.formatVersion <= MapDocument.formatVersion else {
            throw MapDocumentError.unsupportedFormatVersion(doc.formatVersion)
        }
        try doc.normalize()
        return doc
    }

    /// Brings a freshly decoded document into a state the editor can rely on:
    /// positive dimensions, at least one layer, and every layer's grid exactly
    /// `height` × `width`. Rendering and editing index these arrays directly,
    /// so a hand-edited or truncated file would otherwise crash the editor.
    private func normalize() throws {
        guard width > 0, height > 0,
              width <= MapDocument.maxDimension, height <= MapDocument.maxDimension else {
            throw MapDocumentError.invalidDimensions(width: width, height: height)
        }
        if layers.isEmpty {
            layers = [MapLayer(name: "Background", width: width, height: height)]
        }
        for layer in layers where layer.tiles.count != height
            || layer.colors.count != height
            || layer.tiles.contains(where: { $0.count != width })
            || layer.colors.contains(where: { $0.count != width }) {
            layer.resize(to: width, height: height)
        }
        if activeLayerIndex < 0 || activeLayerIndex >= layers.count {
            activeLayerIndex = 0
        }
    }

    // MARK: - Export

    /// Exports the flattened (all visible layers composited) tile data as raw bytes.
    /// Returns (screenRAM: Data, colorRAM: Data).
    public func exportFlattened() -> (screen: Data, color: Data) {
        var screenBytes = Array(repeating: UInt8(0x20), count: width * height)
        var colorBytes = Array(repeating: UInt8(14), count: width * height)

        // The lowest visible layer paints every cell, including its spaces;
        // layers above it let their spaces show what is underneath.
        let baseLayer = layers.first(where: { $0.isVisible })

        for layer in layers where layer.isVisible {
            let isBase = layer === baseLayer
            for row in 0..<height {
                for col in 0..<width {
                    let tile = layer.tiles[row][col]
                    // Skip "empty" tiles (space char $20) on upper layers so lower layers show through
                    if tile != 0x20 || isBase {
                        let idx = row * width + col
                        screenBytes[idx] = tile
                        colorBytes[idx] = layer.colors[row][col] & 0x0F
                    }
                }
            }
        }

        return (Data(screenBytes), Data(colorBytes))
    }

    /// The tile visible at a cell once all visible layers are composited,
    /// following the same rule as `exportFlattened`.
    public func compositedTile(col: Int, row: Int) -> UInt8 {
        guard row >= 0, row < height, col >= 0, col < width else { return 0x20 }
        var result: UInt8 = 0x20
        var isBase = true
        for layer in layers where layer.isVisible {
            let tile = layer.tiles[row][col]
            if tile != 0x20 || isBase { result = tile }
            isBase = false
        }
        return result
    }

    // MARK: - Charset Bank Validation

    /// Describes which charset banks are used across all visible, composited layers.
    public enum CharsetBankStatus {
        case clean          // only one bank in use (or map is empty)
        case bankZeroOnly   // tiles $00–$7F only
        case bankOneOnly    // tiles $80–$FF only
        case mixed          // both banks present — C64 hardware conflict
    }

    /// Scans all visible layers (composited) and determines which charset banks are in use.
    /// Space chars ($20) are excluded because they display correctly from either bank.
    public func charsetBankStatus() -> CharsetBankStatus {
        var hasBank0 = false
        var hasBank1 = false

        // Composite per cell rather than calling exportFlattened(): this runs
        // after every edit, and allocating two full-map buffers each time is
        // pure overhead on a large map.
        for row in 0..<height {
            for col in 0..<width {
                let tile = compositedTile(col: col, row: row)
                guard tile != 0x20 else { continue }   // skip spaces
                if tile < 0x80 { hasBank0 = true }
                else            { hasBank1 = true }
                if hasBank0 && hasBank1 { return .mixed }  // short-circuit
            }
        }

        if hasBank0 { return .bankZeroOnly }
        if hasBank1 { return .bankOneOnly }
        return .clean
    }

    /// Sanitizes an arbitrary string into a valid ca65 identifier:
    /// ASCII letters, digits, and underscores only, not starting with a digit.
    public static func sanitizeAssemblyLabel(_ raw: String) -> String {
        var out = String(raw.map { ch -> Character in
            (ch.isASCII && (ch.isLetter || ch.isNumber)) || ch == "_" ? ch : "_"
        })
        if out.isEmpty { out = "map" }
        if out.first!.isNumber { out = "_" + out }
        return out
    }

    /// Exports as ca65-compatible assembly source.
    /// The label is sanitized, so any document name is safe to pass through.
    public func exportAsAssembly(label: String = "map") -> String {
        let label = MapDocument.sanitizeAssemblyLabel(label)
        let (screen, color) = exportFlattened()
        var asm = "; Map: \(name) (\(width)x\(height))\n"
        asm += "; Generated by C64 IDE Map Editor\n\n"

        asm += "\(label)_width = \(width)\n"
        asm += "\(label)_height = \(height)\n"
        asm += "\(label)_bgcolor = \(backgroundColor)        ; $D021\n"
        if isMultiColorMode {
            asm += "\(label)_mcolor1 = \(extraColor1)        ; $D022\n"
            asm += "\(label)_mcolor2 = \(extraColor2)        ; $D023\n"
            asm += "; multi-color text mode: set bit 4 of $D016\n"
        }
        asm += "\n"

        // Screen RAM
        asm += "\(label)_screen:\n"
        for row in 0..<height {
            let start = row * width
            let rowBytes = screen[start..<start + width]
            asm += "    .byte " + rowBytes.map { String(format: "$%02X", $0) }.joined(separator: ",") + "\n"
        }

        asm += "\n"

        // Color RAM
        asm += "\(label)_color:\n"
        for row in 0..<height {
            let start = row * width
            let rowBytes = color[start..<start + width]
            asm += "    .byte " + rowBytes.map { String(format: "$%02X", $0) }.joined(separator: ",") + "\n"
        }

        return asm
    }

    /// Exports as raw binary files (screen.bin + color.bin).
    public func exportBinary(screenURL: URL, colorURL: URL) throws {
        let (screen, color) = exportFlattened()
        try screen.write(to: screenURL, options: .atomic)
        try color.write(to: colorURL, options: .atomic)
    }
}

// MARK: - Safe Array Subscript

private extension Array {
    /// Returns the element at `index` if valid, otherwise `nil`.
    subscript(safe index: Int) -> Element? {
        guard index >= 0, index < count else { return nil }
        return self[index]
    }
}

