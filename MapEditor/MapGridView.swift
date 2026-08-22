import Cocoa

// MARK: - C64 Color Palette

/// The standard C64 color palette (VIC-II colors 0–15).
///
/// There is exactly one palette definition in the app — `C64Reference.colorPalette`.
/// This type is the AppKit-facing view of it, so the Map Editor and the
/// Character Set Editor can never drift apart on what "color 6" looks like.
public struct C64Palette {

    /// RGB components (0–255) for each palette index.
    public static let components: [(r: UInt8, g: UInt8, b: UInt8)] = C64Reference.colorPalette.map {
        let rgb = $0.rgb
        return (UInt8(clamping: rgb.r), UInt8(clamping: rgb.g), UInt8(clamping: rgb.b))
    }

    public static let colors: [NSColor] = components.map {
        NSColor(red: CGFloat($0.r) / 255.0,
                green: CGFloat($0.g) / 255.0,
                blue: CGFloat($0.b) / 255.0,
                alpha: 1)
    }

    /// Returns the NSColor corresponding to a VIC-II color index (0–15).
    public static func nsColor(for index: UInt8) -> NSColor {
        colors[Int(index) & 0x0F]
    }

    /// Returns the RGB components corresponding to a VIC-II color index (0–15).
    public static func rgb(for index: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        components[index & 0x0F]
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

// MARK: - Glyph Cache

/// Renders 8×8 character glyphs into cached `CGImage`s.
///
/// Drawing a map cell used to cost up to 64 `CGContext.fill` calls; with the
/// cache it is a single `draw(_:in:)` per cell, and each distinct
/// (character, color, mode) combination is rasterized only once.
final class GlyphCache {

    /// 256 characters × 8 bytes.
    private var bitmaps: [[UInt8]] = GlyphCache.bitmaps(from: C64ROMCharset.data)
    private var images: [Int: CGImage] = [:]

    /// Multi-color registers ($D022/$D023), baked into multi-color glyphs.
    private var extraColor1: Int = 1
    private var extraColor2: Int = 2

    /// Replaces the charset. No-op if the data is identical, so redundant
    /// charset syncs do not throw away a warm cache.
    func setCharset(_ data: Data?) {
        let source = (data?.count ?? 0) >= CharSetData.byteCount ? data! : C64ROMCharset.data
        let new = GlyphCache.bitmaps(from: source)
        guard new != bitmaps else { return }
        bitmaps = new
        images.removeAll(keepingCapacity: true)
    }

    /// Updates the multi-color registers, dropping cached glyphs that baked
    /// in the old values.
    func setMultiColorRegisters(_ color1: Int, _ color2: Int) {
        guard color1 != extraColor1 || color2 != extraColor2 else { return }
        extraColor1 = color1
        extraColor2 = color2
        images.removeAll(keepingCapacity: true)
    }

    func invalidate() {
        images.removeAll(keepingCapacity: true)
    }

    /// Returns the glyph for `tile` drawn in `colorIndex`, transparent where
    /// the character has no foreground pixels.
    func image(tile: UInt8, colorIndex: Int, multiColor: Bool) -> CGImage? {
        let key = Int(tile) | ((colorIndex & 0x0F) << 8) | (multiColor ? 1 << 12 : 0)
        if let cached = images[key] { return cached }
        guard let made = render(tile: tile, colorIndex: colorIndex, multiColor: multiColor) else { return nil }
        images[key] = made
        return made
    }

    private static func bitmaps(from data: Data) -> [[UInt8]] {
        var result: [[UInt8]] = []
        result.reserveCapacity(CharSetData.charCount)
        let bytes = [UInt8](data)
        for i in 0..<CharSetData.charCount {
            let offset = i * 8
            if offset + 8 <= bytes.count {
                result.append(Array(bytes[offset..<offset + 8]))
            } else {
                result.append(Array(repeating: 0, count: 8))
            }
        }
        return result
    }

    private func render(tile: UInt8, colorIndex: Int, multiColor: Bool) -> CGImage? {
        let index = Int(tile)
        guard index < bitmaps.count else { return nil }
        let bitmap = bitmaps[index]

        var raw = [UInt8](repeating: 0, count: 8 * 8 * 4)   // RGBA, transparent

        // Palette for the four multi-color bit-pair values. 00 stays
        // transparent so the cell background (or a lower layer) shows through.
        let pairColors: [(r: UInt8, g: UInt8, b: UInt8)?] = multiColor
            ? [nil, C64Palette.rgb(for: extraColor1), C64Palette.rgb(for: extraColor2), C64Palette.rgb(for: colorIndex)]
            : [nil, C64Palette.rgb(for: colorIndex), nil, nil]

        for py in 0..<8 {
            let byte = bitmap[py]
            guard byte != 0 else { continue }
            // The map grid is a flipped view, where CGContext.draw mirrors
            // images vertically — so store scanlines bottom-up here and the
            // glyph lands the right way up on screen.
            let imageRow = 7 - py
            if multiColor {
                for pair in 0..<4 {
                    let value = Int((byte >> (6 - pair * 2)) & 0x03)
                    guard let color = pairColors[value] else { continue }
                    for px in (pair * 2)...(pair * 2 + 1) {
                        let offset = (imageRow * 8 + px) * 4
                        raw[offset] = color.r
                        raw[offset + 1] = color.g
                        raw[offset + 2] = color.b
                        raw[offset + 3] = 255
                    }
                }
            } else {
                guard let color = pairColors[1] else { continue }
                for px in 0..<8 where byte & (0x80 >> px) != 0 {
                    let offset = (imageRow * 8 + px) * 4
                    raw[offset] = color.r
                    raw[offset + 1] = color.g
                    raw[offset + 2] = color.b
                    raw[offset + 3] = 255
                }
            }
        }

        guard let provider = CGDataProvider(data: Data(raw) as CFData) else { return nil }
        return CGImage(width: 8, height: 8,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 32,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }
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

    /// A paint gesture (mouse down to mouse up) finished.
    /// The delegate should commit the accumulated stroke as one undo action.
    func mapGridViewDidEndPaintStroke(_ view: MapGridView)

    /// The zoom level changed (slider, pinch gesture, or zoomToFit).
    /// The delegate should sync any external UI (slider, rulers).
    func mapGridView(_ view: MapGridView, zoomDidChange zoom: CGFloat)
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
    /// Notifies the delegate so external UI (slider, raster ruler) stays in
    /// sync regardless of whether the change came from the slider, a pinch
    /// gesture, or zoomToFit.
    public var zoom: CGFloat = 2.0 {
        didSet {
            zoom = max(0.5, min(8.0, zoom))
            invalidateIntrinsicContentSize()
            needsDisplay = true
            if zoom != oldValue {
                delegate?.mapGridView(self, zoomDidChange: zoom)
            }
        }
    }

    /// Whether to draw grid lines between cells.
    public var showGrid: Bool = true { didSet { needsDisplay = true } }

    /// Whether inactive layers are dimmed as an editing hint.
    public var showLayerDimming: Bool = true { didSet { needsDisplay = true } }

    // MARK: - Internal State

    /// Rasterized character glyphs, keyed by character/color/mode.
    private let glyphs = GlyphCache()

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
        guard doc.width > 0, doc.height > 0 else { return }

        let cell = cellSize
        let bgColor = C64Palette.nsColor(for: doc.backgroundColor)

        // Determine visible cell range from dirtyRect for performance.
        // Clamped at both ends: an empty or edge-aligned dirty rect could
        // otherwise produce minCol > maxCol, which traps when used as a range.
        let minCol = max(0, min(doc.width - 1, Int(floor(dirtyRect.minX / cell.width))))
        let maxCol = max(minCol, min(doc.width - 1, Int(floor(dirtyRect.maxX / cell.width))))
        let minRow = max(0, min(doc.height - 1, Int(floor(dirtyRect.minY / cell.height))))
        let maxRow = max(minRow, min(doc.height - 1, Int(floor(dirtyRect.maxY / cell.height))))

        // The charset itself is only re-read when the document says so
        // (invalidateCharsetCache); rebuilding it per draw would allocate
        // 256 arrays just to compare them.
        glyphs.setMultiColorRegisters(Int(doc.extraColor1), Int(doc.extraColor2))
        ctx.interpolationQuality = .none

        // Background for the whole dirty area in one fill.
        ctx.setFillColor(bgColor.cgColor)
        ctx.fill(CGRect(x: CGFloat(minCol) * cell.width,
                        y: CGFloat(minRow) * cell.height,
                        width: CGFloat(maxCol - minCol + 1) * cell.width,
                        height: CGFloat(maxRow - minRow + 1) * cell.height))

        // Composite visible layers bottom to top
        for (layerIdx, layer) in doc.layers.enumerated() {
            guard layer.isVisible else { continue }

            // Apply layer opacity for non-active layers (editor hint)
            let opacity: CGFloat = showLayerDimming && layerIdx != doc.activeLayerIndex
                ? CGFloat(layer.opacity) * 0.5
                : CGFloat(layer.opacity)
            ctx.setAlpha(opacity)

            for row in minRow...maxRow {
                for col in minCol...maxCol {
                    let tile = layer.tiles[row][col]

                    // On upper layers, skip space chars ($20) to let lower layers show through
                    if layerIdx > 0 && tile == 0x20 { continue }

                    let color = Int(layer.colors[row][col]) & 0x0F
                    // The VIC-II only treats a cell as multi-color when bit 3
                    // of its color RAM value is set; colors 0-7 stay hi-res.
                    let multi = doc.isMultiColorMode && (color & 0x08) != 0
                    guard let glyph = glyphs.image(tile: tile,
                                                   colorIndex: multi ? color & 0x07 : color,
                                                   multiColor: multi) else { continue }
                    ctx.draw(glyph, in: CGRect(x: CGFloat(col) * cell.width,
                                               y: CGFloat(row) * cell.height,
                                               width: cell.width, height: cell.height))
                }
            }
        }
        ctx.setAlpha(1.0)

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

        // Note: the raster line ruler is drawn by the floating
        // MapRasterRulerView owned by the view controller, not here.
    }

    // MARK: - Charset Loading

    /// Invalidates the cached glyph images to force a rebuild on next draw.
    public func invalidateCharsetCache() {
        glyphs.invalidate()
        glyphs.setCharset(document?.charsetData)
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
        // Clamp instead of rejecting so dragging past the map edge keeps
        // painting/tracking the edge cells rather than going dead.
        guard let (col, row) = clampedMapCoordinate(from: event) else { return }

        switch currentTool {
        case .paint:
            let current = MapPoint(col: col, row: row)
            if current != lastPaintedCell {
                // A fast drag skips cells between events; walk the line so
                // the stroke stays continuous instead of dotted.
                if let previous = lastPaintedCell {
                    for point in MapGridView.line(from: previous, to: current) where point != previous {
                        delegate?.mapGridView(self, didDragTo: point.col, row: point.row)
                    }
                } else {
                    delegate?.mapGridView(self, didDragTo: col, row: row)
                }
                lastPaintedCell = current
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
        // Clamp here too: releasing the mouse just outside the view must not
        // silently cancel a fill/select drag or leave a paint stroke uncommitted.
        let coordinate = clampedMapCoordinate(from: event)

        switch currentTool {
        case .paint:
            lastPaintedCell = nil
            delegate?.mapGridViewDidEndPaintStroke(self)

        case .fill:
            if let origin = dragOrigin, let (col, row) = coordinate {
                delegate?.mapGridView(self, didFillFrom: origin,
                                      to: MapPoint(col: col, row: row))
            }
            dragOrigin = nil
            dragCurrent = nil
            isDragging = false
            needsDisplay = true

        case .select:
            if let origin = dragOrigin, let (col, row) = coordinate {
                delegate?.mapGridView(self, didSelectFrom: origin,
                                      to: MapPoint(col: col, row: row))
            }
            dragOrigin = nil
            dragCurrent = nil
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

    /// Converts a mouse event to map (col, row). Returns nil if the point
    /// is outside the map. Used for mouseDown/mouseMoved, where clicks
    /// outside the map should be ignored.
    private func mapCoordinate(from event: NSEvent) -> (Int, Int)? {
        guard let doc = document else { return nil }
        let local = convert(event.locationInWindow, from: nil)
        let col = Int(floor(local.x / cellSize.width))
        let row = Int(floor(local.y / cellSize.height))
        guard col >= 0, col < doc.width, row >= 0, row < doc.height else { return nil }
        return (col, row)
    }

    /// Converts a mouse event to map (col, row), clamping out-of-bounds
    /// points to the nearest valid cell. Used for mouseDragged/mouseUp so an
    /// in-progress gesture survives the cursor leaving the map area.
    /// Returns nil only when there is no document.
    private func clampedMapCoordinate(from event: NSEvent) -> (Int, Int)? {
        guard let doc = document, doc.width > 0, doc.height > 0 else { return nil }
        let local = convert(event.locationInWindow, from: nil)
        let col = max(0, min(doc.width - 1, Int(floor(local.x / cellSize.width))))
        let row = max(0, min(doc.height - 1, Int(floor(local.y / cellSize.height))))
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

    /// Bresenham line between two cells, inclusive of both ends.
    private static func line(from a: MapPoint, to b: MapPoint) -> [MapPoint] {
        var points: [MapPoint] = []
        var (x0, y0) = (a.col, a.row)
        let (x1, y1) = (b.col, b.row)
        let dx = abs(x1 - x0), sx = x0 < x1 ? 1 : -1
        let dy = -abs(y1 - y0), sy = y0 < y1 ? 1 : -1
        var err = dx + dy
        while true {
            points.append(MapPoint(col: x0, row: y0))
            if x0 == x1 && y0 == y1 { break }
            let e2 = 2 * err
            if e2 >= dy { err += dy; x0 += sx }
            if e2 <= dx { err += dx; y0 += sy }
        }
        return points
    }

    // MARK: - Zoom

    override public func magnify(with event: NSEvent) {
        zoom += event.magnification
    }

    /// Zooms to fit the entire map in the visible area.
    public func zoomToFit(in visibleSize: NSSize) {
        guard let doc = document, doc.width > 0, doc.height > 0 else { return }
        let mapWidth = CGFloat(doc.width) * 8.0
        let mapHeight = CGFloat(doc.height) * 8.0
        guard mapWidth > 0, mapHeight > 0 else { return }
        let scaleX = visibleSize.width / mapWidth
        let scaleY = visibleSize.height / mapHeight
        zoom = min(scaleX, scaleY)
    }
}

// MARK: - Built-in C64 ROM Character Set

/// Provides the standard C64 ROM character set data as a fallback.
public struct C64ROMCharset {
    /// 2048 bytes: 256 characters × 8 bytes each (Set 1: uppercase/graphics).
    /// Set 2 (lowercase) is reachable through
    /// `CharSetData.loadROMCharset(.lowercaseUppercase)`.
    public static let data: Data = Data(C64CharROM.romData.prefix(CharSetData.byteCount))
}
