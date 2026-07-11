import Foundation

// MARK: - Map Edit Actions (for Undo/Redo)

/// Represents a single undoable edit to the map.
/// Note: Not Codable, as it's only used for in-memory undo/redo state.
public enum MapEditAction {
    /// A single tile was painted.
    case paint(layer: Int, col: Int, row: Int,
               oldTile: UInt8, oldColor: UInt8,
               newTile: UInt8, newColor: UInt8)

    /// A rectangular region was filled.
    case fill(layer: Int, rect: MapRect,
              oldTiles: [[UInt8]], oldColors: [[UInt8]],
              newTile: UInt8, newColor: UInt8)

    /// A rectangular region was pasted or stamped.
    case stamp(layer: Int, origin: MapPoint,
               oldTiles: [[UInt8]], oldColors: [[UInt8]],
               newTiles: [[UInt8]], newColors: [[UInt8]])

    /// A flood fill was performed.
    case floodFill(layer: Int, cells: [(col: Int, row: Int)],
                   oldTiles: [UInt8], oldColors: [UInt8],
                   newTile: UInt8, newColor: UInt8)

    /// A freehand paint stroke (one mouse-down-to-mouse-up gesture) covering
    /// multiple cells. Same shape as floodFill, kept separate for clarity.
    case stroke(layer: Int, cells: [(col: Int, row: Int)],
                oldTiles: [UInt8], oldColors: [UInt8],
                newTile: UInt8, newColor: UInt8)
}

/// Simple point in map coordinates.
public struct MapPoint: Codable, Equatable {
    public var col: Int
    public var row: Int
}

/// Simple rect in map coordinates.
public struct MapRect: Codable, Equatable {
    public var origin: MapPoint
    public var width: Int
    public var height: Int

    public var maxCol: Int { origin.col + width - 1 }
    public var maxRow: Int { origin.row + height - 1 }

    public func contains(col: Int, row: Int) -> Bool {
        col >= origin.col && col <= maxCol && row >= origin.row && row <= maxRow
    }
}

// MARK: - Undo Manager Integration

/// Manages undo/redo for map edits. Wraps NSUndoManager-style functionality
/// but keeps the map-specific logic here rather than spreading it across the VC.
public final class MapUndoManager {
    private var undoStack: [MapEditAction] = []
    private var redoStack: [MapEditAction] = []
    private let document: MapDocument

    /// Maximum number of undoable actions retained. Oldest actions are
    /// dropped first. Prevents unbounded memory growth in long sessions,
    /// since fill/stamp actions carry full region snapshots.
    public var maxHistoryDepth = 200

    /// Fires when undo/redo availability changes.
    public var onStateChanged: (() -> Void)?

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public init(document: MapDocument) {
        self.document = document
    }

    /// Records and performs an edit action.
    public func perform(_ action: MapEditAction) {
        apply(action, to: document)
        undoStack.append(action)
        if undoStack.count > maxHistoryDepth {
            undoStack.removeFirst(undoStack.count - maxHistoryDepth)
        }
        redoStack.removeAll()
        onStateChanged?()
    }

    /// Discards all undo/redo history. Must be called after any operation
    /// that invalidates stored layer indices or cell coordinates:
    /// layer removal, layer reordering, or document resize.
    public func clearHistory() {
        guard canUndo || canRedo else { return }
        undoStack.removeAll()
        redoStack.removeAll()
        onStateChanged?()
    }

    public func undo() {
        guard let action = undoStack.popLast() else { return }
        unapply(action, from: document)
        redoStack.append(action)
        onStateChanged?()
    }

    public func redo() {
        guard let action = redoStack.popLast() else { return }
        apply(action, to: document)
        undoStack.append(action)
        onStateChanged?()
    }

    // MARK: - Apply / Unapply

    /// Returns true if (row, col) is a valid cell in the given layer's
    /// current storage. Defends against actions recorded before a resize.
    private func isValidCell(_ l: MapLayer, row: Int, col: Int) -> Bool {
        row >= 0 && row < l.tiles.count && col >= 0 && col < (l.tiles.first?.count ?? 0)
    }

    private func apply(_ action: MapEditAction, to doc: MapDocument) {
        switch action {
        case let .paint(layer, col, row, _, _, newTile, newColor):
            guard layer >= 0, layer < doc.layers.count else { return }
            let l = doc.layers[layer]
            guard isValidCell(l, row: row, col: col) else { return }
            l.tiles[row][col] = newTile
            l.colors[row][col] = newColor

        case let .fill(layer, rect, _, _, newTile, newColor):
            guard layer >= 0, layer < doc.layers.count else { return }
            let l = doc.layers[layer]
            for row in rect.origin.row...rect.maxRow {
                for col in rect.origin.col...rect.maxCol {
                    guard isValidCell(l, row: row, col: col) else { continue }
                    l.tiles[row][col] = newTile
                    l.colors[row][col] = newColor
                }
            }

        case let .stamp(layer, origin, _, _, newTiles, newColors):
            guard layer >= 0, layer < doc.layers.count else { return }
            let l = doc.layers[layer]
            for row in 0..<newTiles.count {
                for col in 0..<newTiles[row].count {
                    let mapRow = origin.row + row
                    let mapCol = origin.col + col
                    guard isValidCell(l, row: mapRow, col: mapCol) else { continue }
                    l.tiles[mapRow][mapCol] = newTiles[row][col]
                    l.colors[mapRow][mapCol] = newColors[row][col]
                }
            }

        case let .floodFill(layer, cells, _, _, newTile, newColor),
             let .stroke(layer, cells, _, _, newTile, newColor):
            guard layer >= 0, layer < doc.layers.count else { return }
            let l = doc.layers[layer]
            for cell in cells {
                guard isValidCell(l, row: cell.row, col: cell.col) else { continue }
                l.tiles[cell.row][cell.col] = newTile
                l.colors[cell.row][cell.col] = newColor
            }
        }
    }

    private func unapply(_ action: MapEditAction, from doc: MapDocument) {
        switch action {
        case let .paint(layer, col, row, oldTile, oldColor, _, _):
            guard layer >= 0, layer < doc.layers.count else { return }
            let l = doc.layers[layer]
            guard isValidCell(l, row: row, col: col) else { return }
            l.tiles[row][col] = oldTile
            l.colors[row][col] = oldColor

        case let .fill(layer, rect, oldTiles, oldColors, _, _):
            guard layer >= 0, layer < doc.layers.count else { return }
            let l = doc.layers[layer]
            for row in rect.origin.row...rect.maxRow {
                for col in rect.origin.col...rect.maxCol {
                    guard isValidCell(l, row: row, col: col) else { continue }
                    let localRow = row - rect.origin.row
                    let localCol = col - rect.origin.col
                    l.tiles[row][col] = oldTiles[localRow][localCol]
                    l.colors[row][col] = oldColors[localRow][localCol]
                }
            }

        case let .stamp(layer, origin, oldTiles, oldColors, _, _):
            guard layer >= 0, layer < doc.layers.count else { return }
            let l = doc.layers[layer]
            for row in 0..<oldTiles.count {
                for col in 0..<oldTiles[row].count {
                    let mapRow = origin.row + row
                    let mapCol = origin.col + col
                    guard isValidCell(l, row: mapRow, col: mapCol) else { continue }
                    l.tiles[mapRow][mapCol] = oldTiles[row][col]
                    l.colors[mapRow][mapCol] = oldColors[row][col]
                }
            }

        case let .floodFill(layer, cells, oldTiles, oldColors, _, _),
             let .stroke(layer, cells, oldTiles, oldColors, _, _):
            guard layer >= 0, layer < doc.layers.count else { return }
            let l = doc.layers[layer]
            for (i, cell) in cells.enumerated() {
                guard isValidCell(l, row: cell.row, col: cell.col) else { continue }
                l.tiles[cell.row][cell.col] = oldTiles[i]
                l.colors[cell.row][cell.col] = oldColors[i]
            }
        }
    }
}

