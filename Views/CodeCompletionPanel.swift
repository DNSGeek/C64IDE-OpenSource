// MARK: - CodeCompletionPanel.swift
//
// The completion list: a borderless, non-activating panel under the caret
// holding a table of CodeCompletion entries with their detail text. It is
// deliberately not NSTextView's built-in completion window, which runs a
// nested event loop for as long as it is open and so freezes the editor's
// main-queue work (highlighting, scan results, timers) while the list is
// up. This panel is an ordinary child window: the text view keeps focus,
// typing goes on as normal, and the editor decides what the keys mean.

import Cocoa

final class CodeCompletionPanel: NSPanel {

    /// Called with the chosen entry when the user accepts it.
    var onAccept: ((CodeCompletion) -> Void)?

    private(set) var items: [CodeCompletion] = []

    private let table = NSTableView()
    private let scrollView = NSScrollView()
    private let container = NSView()
    private var codeFont: NSFont = SyntaxHighlighter.codeFont

    private static let maxVisibleRows = 8
    private static let minWidth: CGFloat = 220
    private static let maxWidth: CGFloat = 560
    private static let padding: CGFloat = 4

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true

        container.wantsLayer = true
        container.layer?.cornerRadius = 6
        container.layer?.borderWidth = 1
        container.autoresizingMask = [.width, .height]
        contentView = container

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("completion"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.rowHeight = 20
        table.allowsEmptySelection = false
        table.allowsMultipleSelection = false
        table.selectionHighlightStyle = .regular
        table.backgroundColor = .clear
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked(_:))
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autoresizingMask = [.width, .height]
        scrollView.frame = container.bounds.insetBy(dx: Self.padding, dy: Self.padding)
        container.addSubview(scrollView)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: - Showing

    var selectedItem: CodeCompletion? {
        let row = table.selectedRow
        guard row >= 0, row < items.count else { return nil }
        return items[row]
    }

    /// Shows (or updates) the list for `items`, with its top-left corner at
    /// `anchor` (screen coordinates: the bottom-left of the partial word).
    /// `lineHeight` lets it flip above the line when there is no room below.
    func show(items: [CodeCompletion], anchor: NSPoint, lineHeight: CGFloat,
              font: NSFont, parent owner: NSWindow) {
        self.items = items
        codeFont = font
        // Rows must clear the editor font, which is usually larger than
        // the system font the table was sized for.
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        table.rowHeight = max(20, lineHeight + 6)
        applyColors()
        table.reloadData()
        if !items.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }

        let size = preferredSize()
        var origin = NSPoint(x: anchor.x - Self.padding, y: anchor.y - 2 - size.height)
        if let screen = owner.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            if origin.y < visible.minY {
                origin.y = anchor.y + lineHeight + 2
            }
            if origin.x + size.width > visible.maxX {
                origin.x = max(visible.minX, visible.maxX - size.width)
            }
        }
        setFrame(NSRect(origin: origin, size: size), display: true)

        if parent !== owner {
            parent?.removeChildWindow(self)
            owner.addChildWindow(self, ordered: .above)
        }
        orderFront(nil)
    }

    func hide() {
        guard isVisible || parent != nil else { return }
        parent?.removeChildWindow(self)
        orderOut(nil)
        items = []
    }

    // MARK: - Keyboard

    /// Handles the keys that belong to the list. Returns false for anything
    /// else so the text view treats it as ordinary typing.
    func handle(_ event: NSEvent) -> Bool {
        guard isVisible else { return false }
        switch event.keyCode {
        case 125: moveSelection(by: 1); return true          // down
        case 126: moveSelection(by: -1); return true         // up
        case 121: moveSelection(by: Self.maxVisibleRows); return true   // page down
        case 116: moveSelection(by: -Self.maxVisibleRows); return true  // page up
        case 36, 76, 48:                                     // return, enter, tab
            if let item = selectedItem { onAccept?(item) } else { hide() }
            return true
        case 53:                                             // escape
            hide()
            return true
        default:
            return false
        }
    }

    private func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let current = max(0, table.selectedRow)
        let next = min(max(0, current + delta), items.count - 1)
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    @objc private func rowClicked(_ sender: Any?) {
        let row = table.clickedRow
        guard row >= 0, row < items.count else { return }
        onAccept?(items[row])
    }

    // MARK: - Layout

    private func preferredSize() -> NSSize {
        let detailFont = Self.detailFont
        var width: CGFloat = 0
        for item in items {
            var w = (item.text as NSString).size(withAttributes: [.font: codeFont]).width
            if let detail = item.detail {
                w += 16 + (detail as NSString).size(withAttributes: [.font: detailFont]).width
            }
            width = max(width, w)
        }
        width = min(Self.maxWidth, max(Self.minWidth, width + 24 + 2 * Self.padding))
        let rows = min(items.count, Self.maxVisibleRows)
        let height = CGFloat(rows) * table.rowHeight + 2 * Self.padding
        return NSSize(width: width, height: height)
    }

    private static var detailFont: NSFont { NSFont.systemFont(ofSize: NSFont.smallSystemFontSize) }

    private func applyColors() {
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        container.layer?.borderColor = NSColor.separatorColor.cgColor
    }

    // MARK: - Rows

    /// Row views are "emphasized" by hand: the panel never becomes key, and
    /// without this the selection would draw in the inactive grey.
    private final class EmphasizedRowView: NSTableRowView {
        override var isEmphasized: Bool {
            get { true }
            set { }
        }
    }

    private func attributedTitle(for item: CodeCompletion, selected: Bool) -> NSAttributedString {
        let text = NSMutableAttributedString(string: item.text, attributes: [
            .font: codeFont,
            .foregroundColor: selected ? NSColor.alternateSelectedControlTextColor : NSColor.labelColor,
        ])
        if let detail = item.detail, !detail.isEmpty {
            text.append(NSAttributedString(string: "   " + detail, attributes: [
                .font: Self.detailFont,
                .foregroundColor: selected
                    ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.8)
                    : NSColor.secondaryLabelColor,
            ]))
        }
        return text
    }
}

extension CodeCompletionPanel: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        EmphasizedRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = id
            let field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.textField?.attributedStringValue = attributedTitle(for: items[row],
                                                                selected: tableView.selectedRow == row)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // Re-colour the rows whose selection state changed.
        let visible = table.rows(in: table.visibleRect)
        for row in visible.location..<NSMaxRange(visible) where row < items.count {
            if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView {
                cell.textField?.attributedStringValue = attributedTitle(for: items[row],
                                                                        selected: table.selectedRow == row)
            }
        }
    }
}
