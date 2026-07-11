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

    /// Multicolor registers ($D022, $D023) — optional, for multicolor charset mode
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
        self.width = width
        self.height = height
        self.layers = [MapLayer(name: "Background", width: width, height: height)]
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
        width = newWidth
        height = newHeight
        for layer in layers {
            layer.resize(to: newWidth, height: newHeight)
        }
    }

    // MARK: - Serialization

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }

    public enum MapDocumentError: LocalizedError {
        case unsupportedFormatVersion(Int)

        public var errorDescription: String? {
            switch self {
            case .unsupportedFormatVersion(let v):
                return "This map file uses format version \(v), but this build "
                     + "only supports up to version \(MapDocument.formatVersion). "
                     + "Please update the application."
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
        return doc
    }

    // MARK: - Export

    /// Exports the flattened (all visible layers composited) tile data as raw bytes.
    /// Returns (screenRAM: Data, colorRAM: Data).
    public func exportFlattened() -> (screen: Data, color: Data) {
        var screenBytes = Array(repeating: UInt8(0x20), count: width * height)
        var colorBytes = Array(repeating: UInt8(14), count: width * height)

        for layer in layers where layer.isVisible {
            for row in 0..<height {
                for col in 0..<width {
                    let tile = layer.tiles[row][col]
                    let color = layer.colors[row][col]
                    // Skip "empty" tiles (space char $20) on upper layers so lower layers show through
                    if tile != 0x20 || layer === layers.first {
                        let idx = row * width + col
                        screenBytes[idx] = tile
                        colorBytes[idx] = color & 0x0F
                    }
                }
            }
        }

        return (Data(screenBytes), Data(colorBytes))
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

        // Reuse the export compositor so this can never drift from what
        // actually gets exported.
        let (screen, _) = exportFlattened()

        for tile in screen {
            guard tile != 0x20 else { continue }   // skip spaces
            if tile < 0x80 { hasBank0 = true }
            else            { hasBank1 = true }
            if hasBank0 && hasBank1 { return .mixed }  // short-circuit
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
        asm += "\(label)_bgcolor = \(backgroundColor)\n\n"

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

