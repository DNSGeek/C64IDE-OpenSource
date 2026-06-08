import Cocoa

// MARK: - C64 Color Palette

/// The standard C64 color palette (VIC-II colors 0–15).
public struct C64Palette {
    public static let colors: [NSColor] = [
        NSColor(red: 0.000, green: 0.000, blue: 0.000, alpha: 1), // 0  Black
        NSColor(red: 1.000, green: 1.000, blue: 1.000, alpha: 1), // 1  White
        NSColor(red: 0.533, green: 0.200, blue: 0.200, alpha: 1), // 2  Red
        NSColor(red: 0.400, green: 0.733, blue: 0.733, alpha: 1), // 3  Cyan
        NSColor(red: 0.533, green: 0.267, blue: 0.600, alpha: 1), // 4  Purple
        NSColor(red: 0.333, green: 0.600, blue: 0.267, alpha: 1), // 5  Green
        NSColor(red: 0.200, green: 0.133, blue: 0.533, alpha: 1), // 6  Blue
        NSColor(red: 0.800, green: 0.800, blue: 0.467, alpha: 1), // 7  Yellow
        NSColor(red: 0.533, green: 0.333, blue: 0.133, alpha: 1), // 8  Orange
        NSColor(red: 0.333, green: 0.200, blue: 0.000, alpha: 1), // 9  Brown
        NSColor(red: 0.733, green: 0.467, blue: 0.467, alpha: 1), // 10 Light Red
        NSColor(red: 0.267, green: 0.267, blue: 0.267, alpha: 1), // 11 Dark Grey
        NSColor(red: 0.467, green: 0.467, blue: 0.467, alpha: 1), // 12 Grey
        NSColor(red: 0.600, green: 0.867, blue: 0.533, alpha: 1), // 13 Light Green
        NSColor(red: 0.467, green: 0.400, blue: 0.733, alpha: 1), // 14 Light Blue
        NSColor(red: 0.667, green: 0.667, blue: 0.667, alpha: 1), // 15 Light Grey
    ]

    /// Returns the NSColor corresponding to a VIC-II color index (0–15).
    public static func nsColor(for index: UInt8) -> NSColor {
        colors[Int(index) & 0x0F]
    }
}

// MARK: - Editing Tool

/// Represents the active editing mode in the map grid.
public enum MapEditorTool {
    case paint
    case fill       // rectangular fill
    case floodFill  // bucket fill (connected region)
    case select     // rectangular selection
    case eyedropper // pick tile+color from map
}

// MARK: - Delegate Protocol

/// Protocol for handling map grid interactions.
public protocol MapGridViewDelegate: AnyObject {
    /// The user painted/clicked at a map coordinate.
    func mapGridView(_ view: MapGridView, didPaintAt col: Int, row: Int)

    /// The user dragged across cells (for paint stroke).
    func mapGridView(_ view: MapGridView, didDragTo col: Int, row: Int)

    /// The user completed a rectangular fill from origin to end.
    func mapGridView(_ view: MapGridView, didFillFrom origin: MapPoint, to end: MapPoint)

    /// The user flood-filled at a coordinate.
    func mapGridView(_ view: MapGridView, didFloodFillAt col: Int, row: Int)

    /// The user selected a rectangular region.
    func mapGridView(_ view: MapGridView, didSelectFrom origin: MapPoint, to end: MapPoint)

    /// The user picked a tile+color with the eyedropper.
    func mapGridView(_ view: MapGridView, didPickAt col: Int, row: Int)

    /// The cursor moved over a cell (for status bar coordinate display).
    func mapGridView(_ view: MapGridView, cursorAt col: Int, row: Int)
}

// MARK: - Map Grid View

/// A custom NSView that renders the map grid with charset glyphs and C64 colors.
/// Supports zooming, scrolling, grid overlay, and mouse-driven editing tools.
public final class MapGridView: NSView {

    // MARK: - Properties

    public weak var delegate: MapGridViewDelegate?
    public var document: MapDocument? { didSet { invalidateCharsetCache(); needsDisplay = true } }

    /// The currently active editing tool.
    public var currentTool: MapEditorTool = .paint

    /// Current zoom level (pixels per C64 pixel). Clamped between 0.5x and 8x.
    public var zoom: CGFloat = 2.0 {
        didSet {
            zoom = max(0.5, min(8.0, zoom))
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    /// Whether to draw grid lines between cells.
    public var showGrid: Bool = true { didSet { needsDisplay = true } }
    
    /// Whether to show raster line numbers alongside the map grid.
    public var showRasterRuler: Bool = false { didSet { needsDisplay = true } }

    /// Whether to show layer transparency (dims hidden layers).
    public var showLayerDimming: Bool = true

    // MARK: - Internal State

    /// Cached character glyph bitmaps (256 entries, 8×8 bits each).
    private var charsetBitmaps: [[UInt8]]?

    /// Drag tracking for fill/select tools.
    private var dragOrigin: MapPoint?
    private var dragCurrent: MapPoint?
    private var isDragging = false

    /// Track last painted cell to avoid redundant paint events during drag.
    private var lastPaintedCell: MapPoint?

    // MARK: - Computed Properties

    /// Size of one character cell at current zoom, in points.
    private var cellSize: CGSize {
        CGSize(width: 8.0 * zoom, height: 8.0 * zoom)
    }

    override public var intrinsicContentSize: NSSize {
        guard let doc = document else { return NSSize(width: 320, height: 200) }
        return NSSize(width: CGFloat(doc.width) * cellSize.width,
                      height: CGFloat(doc.height) * cellSize.height)
    }

    override public var isFlipped: Bool { true }

    // MARK: - Drawing

    /// Renders the map grid, optimizing performance by only drawing dirty regions.
    override public func draw(_ dirtyRect: NSRect) {
        guard let doc = document, let ctx = NSGraphicsContext.current?.cgContext else { return }

        let cell = cellSize
        let bgColor = C64Palette.nsColor(for: doc.backgroundColor)

        // Determine visible cell range from dirtyRect for performance
        let minCol = max(0, Int(floor(dirtyRect.minX / cell.width)))
        let maxCol = min(doc.width - 1, Int(floor(dirtyRect.maxX / cell.width)))
        let minRow = max(0, Int(floor(dirtyRect.minY / cell.height)))
        let maxRow = min(doc.height - 1, Int(floor(dirtyRect.maxY / cell.height)))

        // Ensure charset bitmaps are loaded
        let bitmaps = charsetBitmaps ?? loadCharsetBitmaps()

        // Draw cells
        for row in minRow...maxRow {
            for col in minCol...maxCol {
                let x = CGFloat(col) * cell.width
                let y = CGFloat(row) * cell.height
                let cellRect = CGRect(x: x, y: y, width: cell.width, height: cell.height)

                // Background
                ctx.setFillColor(bgColor.cgColor)
                ctx.fill(cellRect)

                // Composite visible layers bottom to top
                for (layerIdx, layer) in doc.layers.enumerated() {
                    guard layer.isVisible else { continue }
                    let tile = layer.tiles[row][col]
                    let color = layer.colors[row][col]

                    // On upper layers, skip space chars ($20) to let lower layers show through
                    if layerIdx > 0 && tile == 0x20 { continue }

                    // Apply layer opacity for non-active layers (editor hint)
                    let opacity: CGFloat
                    if showLayerDimming && layerIdx != doc.activeLayerIndex {
                        opacity = CGFloat(layer.opacity) * 0.5
                    } else {
                        opacity = CGFloat(layer.opacity)
                    }

                    drawCharGlyph(ctx: ctx, bitmaps: bitmaps, tile: tile,
                                  fgColor: C64Palette.nsColor(for: color),
                                  bgColor: bgColor,
                                  rect: cellRect, opacity: opacity)
                }
            }
        }

        // Grid lines
        if showGrid && zoom >= 1.0 {
            ctx.setStrokeColor(NSColor(white: AppTheme.current.isDark ? 0.5 : 0.3, alpha: 0.3).cgColor)
            ctx.setLineWidth(0.5)

            for col in minCol...(maxCol + 1) {
                let x = CGFloat(col) * cell.width
                ctx.move(to: CGPoint(x: x, y: CGFloat(minRow) * cell.height))
                ctx.addLine(to: CGPoint(x: x, y: CGFloat(maxRow + 1) * cell.height))
            }
            for row in minRow...(maxRow + 1) {
                let y = CGFloat(row) * cell.height
                ctx.move(to: CGPoint(x: CGFloat(minCol) * cell.width, y: y))
                ctx.addLine(to: CGPoint(x: CGFloat(maxCol + 1) * cell.width, y: y))
            }
            ctx.strokePath()
        }

        // Selection / fill preview overlay
        if isDragging, let origin = dragOrigin, let current = dragCurrent,
           (currentTool == .fill || currentTool == .select) {
            let r = normalizedRect(from: origin, to: current)
            let overlayRect = CGRect(
                x: CGFloat(r.origin.col) * cell.width,
                y: CGFloat(r.origin.row) * cell.height,
                width: CGFloat(r.width) * cell.width,
                height: CGFloat(r.height) * cell.height
            )
            let overlayColor: NSColor = currentTool == .select
                ? NSColor.systemBlue.withAlphaComponent(0.25)
                : NSColor.systemYellow.withAlphaComponent(0.25)
            ctx.setFillColor(overlayColor.cgColor)
            ctx.fill(overlayRect)
            ctx.setStrokeColor(overlayColor.withAlphaComponent(0.8).cgColor)
            ctx.setLineWidth(1.0)
            ctx.stroke(overlayRect)
        }

        // Raster line ruler — one label per tile row showing the starting raster line
        if showRasterRuler, let doc = document {
            let cell = cellSize
            let rulerW: CGFloat = 28
            let rasterTop = 51   // PAL visible area starts at raster 51

            // Dark background strip
            ctx.setFillColor(NSColor(white: AppTheme.current.isDark ? 0.0 : 0.85, alpha: 0.65).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: rulerW, height: CGFloat(doc.height) * cell.height))

            let fontSize = max(8, min(11, cell.height * 0.55))
            let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            let color = AppTheme.current.syntaxKeyword.withAlphaComponent(0.9)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let tickColor = color.withAlphaComponent(0.5).cgColor

            for row in 0..<doc.height {
                let raster = rasterTop + row * 8
                let rowY = CGFloat(row) * cell.height
                let label = "\(raster)" as NSString

                // Tick at the row boundary
                ctx.setStrokeColor(tickColor)
                ctx.setLineWidth(0.5)
                ctx.move(to: CGPoint(x: rulerW, y: rowY))
                ctx.addLine(to: CGPoint(x: rulerW + 4, y: rowY))
                ctx.strokePath()

                // Label centred vertically in the row
                let labelSize = label.size(withAttributes: attrs)
                if labelSize.height <= cell.height {
                    let labelX = (rulerW - labelSize.width) / 2
                    let labelY = rowY + (cell.height - labelSize.height) / 2
                    label.draw(at: CGPoint(x: labelX, y: labelY), withAttributes: attrs)
                }
            }
        }
    }

    /// Draws a single 8×8 character glyph scaled into the given rect.
    private func drawCharGlyph(ctx: CGContext, bitmaps: [[UInt8]], tile: UInt8,
                               fgColor: NSColor, bgColor: NSColor,
                               rect: CGRect, opacity: CGFloat) {
        let charIdx = Int(tile)
        guard charIdx < bitmaps.count else { return }
        let bitmap = bitmaps[charIdx]

        let pixW = rect.width / 8.0
        let pixH = rect.height / 8.0

        let fg = fgColor.withAlphaComponent(opacity).cgColor

        ctx.setFillColor(fg)

        for py in 0..<8 {
            let byte = bitmap[py]
            guard byte != 0 else { continue }  // skip blank rows
            for px in 0..<8 {
                if byte & (0x80 >> px) != 0 {
                    let pixRect = CGRect(
                        x: rect.origin.x + CGFloat(px) * pixW,
                        y: rect.origin.y + CGFloat(py) * pixH,
                        width: pixW, height: pixH
                    )
                    ctx.fill(pixRect)
                }
            }
        }
    }

    // MARK: - Charset Loading

    /// Loads the charset bitmaps from the document (or falls back to the built-in ROM charset).
    private func loadCharsetBitmaps() -> [[UInt8]] {
        var bitmaps: [[UInt8]] = []
        let data: Data

        if let charsetData = document?.charsetData, charsetData.count >= 2048 {
            data = charsetData
        } else {
            data = C64ROMCharset.data
        }

        for i in 0..<256 {
            let offset = i * 8
            if offset + 8 <= data.count {
                bitmaps.append(Array(data[offset..<offset + 8]))
            } else {
                bitmaps.append(Array(repeating: 0, count: 8))
            }
        }

        charsetBitmaps = bitmaps
        return bitmaps
    }

    /// Invalidates the cached charset bitmaps to force reload on next draw.
    public func invalidateCharsetCache() {
        charsetBitmaps = nil
    }

    // MARK: - Mouse Events

    override public func mouseDown(with event: NSEvent) {
        guard let (col, row) = mapCoordinate(from: event) else { return }

        switch currentTool {
        case .paint:
            lastPaintedCell = MapPoint(col: col, row: row)
            delegate?.mapGridView(self, didPaintAt: col, row: row)

        case .fill, .select:
            dragOrigin = MapPoint(col: col, row: row)
            dragCurrent = dragOrigin
            isDragging = true

        case .floodFill:
            delegate?.mapGridView(self, didFloodFillAt: col, row: row)

        case .eyedropper:
            delegate?.mapGridView(self, didPickAt: col, row: row)
        }
    }

    override public func mouseDragged(with event: NSEvent) {
        guard let (col, row) = mapCoordinate(from: event) else { return }

        switch currentTool {
        case .paint:
            let current = MapPoint(col: col, row: row)
            if current != lastPaintedCell {
                lastPaintedCell = current
                delegate?.mapGridView(self, didDragTo: col, row: row)
            }

        case .fill, .select:
            dragCurrent = MapPoint(col: col, row: row)
            needsDisplay = true

        case .floodFill, .eyedropper:
            break
        }

        delegate?.mapGridView(self, cursorAt: col, row: row)
    }

    override public func mouseUp(with event: NSEvent) {
        guard let (col, row) = mapCoordinate(from: event) else {
            isDragging = false
            return
        }

        switch currentTool {
        case .paint:
            lastPaintedCell = nil

        case .fill:
            if let origin = dragOrigin {
                let end = MapPoint(col: col, row: row)
                delegate?.mapGridView(self, didFillFrom: origin, to: end)
            }
            isDragging = false
            needsDisplay = true

        case .select:
            if let origin = dragOrigin {
                let end = MapPoint(col: col, row: row)
                delegate?.mapGridView(self, didSelectFrom: origin, to: end)
            }
            isDragging = false
            needsDisplay = true

        case .floodFill, .eyedropper:
            break
        }
    }

    override public func mouseMoved(with event: NSEvent) {
        if let (col, row) = mapCoordinate(from: event) {
            delegate?.mapGridView(self, cursorAt: col, row: row)
        }
    }

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    // MARK: - Coordinate Conversion

    /// Converts a mouse event to map (col, row), clamped to valid range.
    private func mapCoordinate(from event: NSEvent) -> (Int, Int)? {
        guard let doc = document else { return nil }
        let local = convert(event.locationInWindow, from: nil)
        let col = Int(floor(local.x / cellSize.width))
        let row = Int(floor(local.y / cellSize.height))
        guard col >= 0, col < doc.width, row >= 0, row < doc.height else { return nil }
        return (col, row)
    }

    /// Normalizes two map points into a MapRect (handles any drag direction).
    private func normalizedRect(from a: MapPoint, to b: MapPoint) -> MapRect {
        let minCol = min(a.col, b.col)
        let maxCol = max(a.col, b.col)
        let minRow = min(a.row, b.row)
        let maxRow = max(a.row, b.row)
        return MapRect(origin: MapPoint(col: minCol, row: minRow),
                       width: maxCol - minCol + 1,
                       height: maxRow - minRow + 1)
    }

    // MARK: - Zoom

    override public func magnify(with event: NSEvent) {
        zoom += event.magnification
    }

    /// Zooms to fit the entire map in the visible area.
    public func zoomToFit(in visibleSize: NSSize) {
        guard let doc = document else { return }
        let mapWidth = CGFloat(doc.width) * 8.0
        let mapHeight = CGFloat(doc.height) * 8.0
        let scaleX = visibleSize.width / mapWidth
        let scaleY = visibleSize.height / mapHeight
        zoom = min(scaleX, scaleY)
    }
}

// MARK: - Built-in C64 ROM Character Set

/// Provides the standard C64 ROM character set data as a fallback.
public struct C64ROMCharset {
    /// 2048 bytes: 256 characters × 8 bytes each (Set 1: uppercase/graphics).
    public static var data: Data {
        Data(C64CharROM.romData.prefix(2048))
    }

    /// 2048 bytes: Set 2 (lowercase/uppercase), offset 2048 in the ROM.
    public static var lowercaseData: Data {
        let rom = C64CharROM.romData
        guard rom.count >= 4096 else { return data }
        return Data(rom[2048..<4096])
    }
}

