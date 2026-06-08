import Cocoa

// MARK: - Map Editor View Controller

/// Orchestrates the Map Editor UI, document state, tools, and data flow.
public final class MapEditorViewController: NSViewController, MapGridViewDelegate {

    // MARK: - Properties

    /// The active map document being edited.
    public private(set) var document = MapDocument()
    private var undoMgr: MapUndoManager!

    /// Currently selected tile index for painting. Updates the tile picker when changed.
    public var selectedTile: UInt8 = 1 { didSet { tilePickerView?.selectedTile = selectedTile } }

    /// Currently selected color index for painting. Updates the color picker when changed.
    public var selectedColor: UInt8 = 1 { didSet { colorPickerView?.selectedColor = selectedColor } }

    /// Tracks whether the document has been modified since the last save.
    public private(set) var isModified = false

    /// The URL this document was last saved to or loaded from.
    public var fileURL: URL?

    // MARK: - Subviews

    private var mapGridView: MapGridView!
    private var scrollView: NSScrollView!
    private var tilePickerView: TilePickerView!
    private var colorPickerView: ColorPickerView!
    private var layerListView: LayerListView!
    private var toolSegment: NSSegmentedControl!
    private var zoomSlider: NSSlider!
    private var coordLabel: NSTextField!
    private var bankWarningLabel: NSTextField!
    private var gridToggle: NSButton!
    private var rasterToggle: NSButton!
    private var rasterRulerView: MapRasterRulerView!
    private var exportPopup: NSPopUpButton!

    /// Enables live synchronization of charset updates from the Character Editor.
    public private(set) var isLiveSyncEnabled = false

    // MARK: - Lifecycle

    override public func becomeFirstResponder() -> Bool { return true }
    override public var acceptsFirstResponder: Bool { return true }

    override public func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(self)
    }

    /// Sets up the entire UI hierarchy programmatically.
    override public func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
        container.wantsLayer = true
        self.view = container

        setupToolbar()
        setupMapGrid()
        setupTilePicker()
        setupColorPicker()
        setupLayerList()
        setupStatusBar()
        layoutSubviews()

        undoMgr = MapUndoManager(document: document)
        undoMgr.onStateChanged = { [weak self] in
            self?.isModified = true
        }

        mapGridView.document = document
        tilePickerView?.charsetData = document.charsetData ?? C64ROMCharset.data

        // Observe charset notifications from the Character Set Editor
        NotificationCenter.default.addObserver(
            self, selector: #selector(charsetDidChange(_:)),
            name: .charsetDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(charsetSentToMapEditor(_:)),
            name: .charsetSendToMapEditor, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange(_:)),
            name: .appThemeDidChange, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override public func viewWillAppear() {
        super.viewWillAppear()
        applyThemeColors()
    }

    @objc private func themeDidChange(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.view.window != nil else { return }
            self.applyThemeColors()
        }
    }

    private func applyThemeColors() {
        view.window?.appearance      = AppTheme.current.nsAppearance
        scrollView?.backgroundColor  = AppTheme.current.panelDetailBackground
        // Update raster toggle label color
        let rasterAttr = NSAttributedString(string: "Raster", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: AppTheme.current.syntaxKeyword,
        ])
        rasterToggle?.attributedTitle = rasterAttr
        tilePickerView?.needsDisplay  = true
        rasterRulerView?.needsDisplay = true
        layerListView?.needsDisplay   = true
    }

    // MARK: - Charset Sync from Character Editor

    /// Applies charset data when live sync is enabled.
    @objc private func charsetDidChange(_ notification: Notification) {
        guard isLiveSyncEnabled else { return }
        applyCharsetFromNotification(notification)
    }

    /// Applies charset data unconditionally and enables live sync for future updates.
    @objc private func charsetSentToMapEditor(_ notification: Notification) {
        isLiveSyncEnabled = true
        applyCharsetFromNotification(notification)
    }

    /// Extracts charset data from the notification and updates the document and views.
    private func applyCharsetFromNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let data = userInfo["charsetData"] as? Data else { return }

        document.charsetData = data
        mapGridView.invalidateCharsetCache()
        mapGridView.needsDisplay = true
        tilePickerView?.charsetData = data
        isModified = true

        // Optionally sync the background color too
        if let bgColor = userInfo["bgColor"] as? Int {
            document.backgroundColor = UInt8(bgColor & 0x0F)
            mapGridView.needsDisplay = true
        }
    }

    /// Toggles live sync with the Character Editor.
    public func setLiveSync(_ enabled: Bool) {
        isLiveSyncEnabled = enabled
    }

    // MARK: - UI Setup

    private func setupToolbar() {
        toolSegment = NSSegmentedControl(labels: ["Paint", "Fill", "Flood", "Select", "Pick"],
                                         trackingMode: .selectOne,
                                         target: self,
                                         action: #selector(toolChanged(_:)))
        toolSegment.selectedSegment = 0
        toolSegment.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toolSegment)

        // Export popup button
        exportPopup = NSPopUpButton(frame: .zero, pullsDown: true)
        exportPopup.translatesAutoresizingMaskIntoConstraints = false
        exportPopup.controlSize = .small
        exportPopup.font = NSFont.systemFont(ofSize: 11)
        exportPopup.addItem(withTitle: "Export ▾")
        exportPopup.addItem(withTitle: "Export as Assembly (.s)…")
        exportPopup.addItem(withTitle: "Export as Binary (.bin)…")
        exportPopup.menu?.addItem(.separator())
        exportPopup.addItem(withTitle: "Save Map (.c64map)…")
        exportPopup.addItem(withTitle: "Open Map…")
        exportPopup.addItem(withTitle: "Load Charset…")
        exportPopup.target = self
        exportPopup.action = #selector(exportMenuSelected(_:))
        view.addSubview(exportPopup)

        zoomSlider = NSSlider(value: 2.0, minValue: 0.5, maxValue: 8.0,
                              target: self, action: #selector(zoomChanged(_:)))
        zoomSlider.translatesAutoresizingMaskIntoConstraints = false
        zoomSlider.controlSize = .small
        view.addSubview(zoomSlider)

        gridToggle = NSButton(checkboxWithTitle: "Grid", target: self, action: #selector(gridToggled(_:)))
        gridToggle.state = .on
        gridToggle.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(gridToggle)

        rasterToggle = NSButton(checkboxWithTitle: "Raster", target: self, action: #selector(rasterToggled(_:)))
        rasterToggle.state = .off
        rasterToggle.translatesAutoresizingMaskIntoConstraints = false
        let rasterAttr = NSAttributedString(string: "Raster", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: AppTheme.current.syntaxKeyword,
        ])
        rasterToggle.attributedTitle = rasterAttr
        view.addSubview(rasterToggle)
    }

    private func setupMapGrid() {
        mapGridView = MapGridView()
        mapGridView.delegate = self
        mapGridView.translatesAutoresizingMaskIntoConstraints = false

        scrollView = NSScrollView()
        scrollView.documentView = mapGridView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = AppTheme.current.panelDetailBackground
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        // Floating raster ruler — sits over the left edge of the scroll view
        rasterRulerView = MapRasterRulerView()
        rasterRulerView.translatesAutoresizingMaskIntoConstraints = false
        rasterRulerView.isHidden = true
        view.addSubview(rasterRulerView)

        // Keep ruler in sync with canvas scroll
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(mapScrolled(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    private func setupTilePicker() {
        tilePickerView = TilePickerView()
        tilePickerView.translatesAutoresizingMaskIntoConstraints = false
        tilePickerView.onTileSelected = { [weak self] tile in
            self?.selectedTile = tile
        }
        view.addSubview(tilePickerView)
    }

    private func setupColorPicker() {
        colorPickerView = ColorPickerView()
        colorPickerView.translatesAutoresizingMaskIntoConstraints = false
        colorPickerView.onColorSelected = { [weak self] color in
            self?.selectedColor = color
        }
        view.addSubview(colorPickerView)
    }

    private func setupLayerList() {
        layerListView = LayerListView()
        layerListView.translatesAutoresizingMaskIntoConstraints = false
        layerListView.onLayerChanged = { [weak self] in
            self?.mapGridView.needsDisplay = true
            self?.updateBankWarning()
        }
        layerListView.document = document
        view.addSubview(layerListView)
    }

    private func setupStatusBar() {
        coordLabel = NSTextField(labelWithString: "Col: 0  Row: 0")
        coordLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        coordLabel.textColor = .secondaryLabelColor
        coordLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(coordLabel)

        bankWarningLabel = NSTextField(labelWithString: "")
        bankWarningLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        bankWarningLabel.textColor = NSColor.systemOrange
        bankWarningLabel.alignment = .right
        bankWarningLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bankWarningLabel)
    }

    private func layoutSubviews() {
        let leftPanelWidth: CGFloat = 180
        let statusBarHeight: CGFloat = 24
        let toolbarHeight: CGFloat = 32

        NSLayoutConstraint.activate([
            // Toolbar row
            toolSegment.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            toolSegment.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: leftPanelWidth + 8),

            exportPopup.centerYAnchor.constraint(equalTo: toolSegment.centerYAnchor),
            exportPopup.leadingAnchor.constraint(equalTo: toolSegment.trailingAnchor, constant: 12),
            exportPopup.widthAnchor.constraint(equalToConstant: 100),

            zoomSlider.centerYAnchor.constraint(equalTo: toolSegment.centerYAnchor),
            zoomSlider.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            zoomSlider.widthAnchor.constraint(equalToConstant: 120),

            gridToggle.centerYAnchor.constraint(equalTo: toolSegment.centerYAnchor),
            gridToggle.trailingAnchor.constraint(equalTo: zoomSlider.leadingAnchor, constant: -12),

            rasterToggle.centerYAnchor.constraint(equalTo: toolSegment.centerYAnchor),
            rasterToggle.trailingAnchor.constraint(equalTo: gridToggle.leadingAnchor, constant: -12),

            // Left panel: tile picker + color picker + layer list
            tilePickerView.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            tilePickerView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            tilePickerView.widthAnchor.constraint(equalToConstant: leftPanelWidth - 8),
            tilePickerView.heightAnchor.constraint(equalToConstant: 300),

            colorPickerView.topAnchor.constraint(equalTo: tilePickerView.bottomAnchor, constant: 8),
            colorPickerView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            colorPickerView.widthAnchor.constraint(equalToConstant: leftPanelWidth - 8),
            colorPickerView.heightAnchor.constraint(equalToConstant: 60),

            layerListView.topAnchor.constraint(equalTo: colorPickerView.bottomAnchor, constant: 8),
            layerListView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            layerListView.widthAnchor.constraint(equalToConstant: leftPanelWidth - 8),
            layerListView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -statusBarHeight - 4),

            // Map grid (main area) — starts 32pt after left panel to leave room for ruler
            scrollView.topAnchor.constraint(equalTo: view.topAnchor, constant: toolbarHeight + 6),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: leftPanelWidth + 32),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -statusBarHeight),

            // Raster ruler — sits in the 32pt gap to the LEFT of the scroll view
            rasterRulerView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            rasterRulerView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            rasterRulerView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: leftPanelWidth),
            rasterRulerView.widthAnchor.constraint(equalToConstant: 32),

            // Status bar
            coordLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: leftPanelWidth + 40),
            coordLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4),

            bankWarningLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            bankWarningLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4),
            bankWarningLabel.leadingAnchor.constraint(greaterThanOrEqualTo: coordLabel.trailingAnchor, constant: 8),
        ])
    }

    // MARK: - Actions

    @objc private func toolChanged(_ sender: NSSegmentedControl) {
        let tools: [MapEditorTool] = [.paint, .fill, .floodFill, .select, .eyedropper]
        mapGridView.currentTool = tools[sender.selectedSegment]
    }

    @objc private func zoomChanged(_ sender: NSSlider) {
        let z = CGFloat(sender.doubleValue)
        mapGridView.zoom = z
        rasterRulerView.zoom = z
    }

    @objc private func gridToggled(_ sender: NSButton) {
        mapGridView.showGrid = sender.state == .on
    }

    @objc private func rasterToggled(_ sender: NSButton) {
        let on = sender.state == .on
        mapGridView.showRasterRuler = false  // ruler drawn by floating view, not canvas
        rasterRulerView.isHidden = !on
    }

    @objc private func mapScrolled(_ notification: Notification) {
        rasterRulerView.scrollOffset = scrollView.contentView.bounds.origin.y
        rasterRulerView.needsDisplay = true
    }

    @objc private func exportMenuSelected(_ sender: NSPopUpButton) {
        // Index 0 is the pull-down title "Export ▾", real items start at 1
        switch sender.indexOfSelectedItem {
        case 1:
            exportAssembly()
        case 2:
            exportBinary()
        // index 3 is the separator
        case 4:
            saveDocument()
        case 5:
            // Open — delegate to window controller via responder chain
            NSApp.sendAction(#selector(MapEditorWindowController.openMap), to: nil, from: self)
        case 6:
            // Load Charset — delegate to window controller
            NSApp.sendAction(#selector(MapEditorWindowController.loadCharset), to: nil, from: self)
        default:
            break
        }
    }

    // MARK: - Document Management

    public func newDocument(width: Int = 40, height: Int = 25) {
        document = MapDocument(width: width, height: height)
        undoMgr = MapUndoManager(document: document)
        undoMgr.onStateChanged = { [weak self] in self?.isModified = true }
        mapGridView.document = document
        layerListView.document = document
        fileURL = nil
        isModified = false
        updateBankWarning()
    }

    public func loadDocument(from url: URL) throws {
        let doc = try MapDocument.load(from: url)
        document = doc
        undoMgr = MapUndoManager(document: doc)
        undoMgr.onStateChanged = { [weak self] in self?.isModified = true }
        mapGridView.document = doc
        layerListView.document = doc
        tilePickerView?.charsetData = doc.charsetData ?? C64ROMCharset.data
        fileURL = url
        isModified = false
        updateBankWarning()
    }

    public func saveDocument() {
        guard let url = fileURL else {
            saveDocumentAs()
            return
        }
        do {
            try document.save(to: url)
            isModified = false
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    public func saveDocumentAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "c64map")!]
        panel.nameFieldStringValue = document.name + ".c64map"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self = self else { return }
            self.fileURL = url
            self.document.name = url.deletingPathExtension().lastPathComponent
            self.saveDocument()
        }
    }

    public func loadCharset(from url: URL) {
        guard let data = try? Data(contentsOf: url), data.count >= 2048 else {
            let alert = NSAlert()
            alert.messageText = "Invalid Character Set"
            alert.informativeText = "Expected at least 2048 bytes (256 characters × 8 bytes)."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        document.charsetData = data.prefix(2048)
        document.charsetPath = url.path
        mapGridView.invalidateCharsetCache()
        mapGridView.needsDisplay = true
        tilePickerView?.charsetData = data.prefix(2048)
        isModified = true
    }

    // MARK: - Export

    public func exportAssembly() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "s")!, .init(filenameExtension: "asm")!]
        let baseName = document.name.replacingOccurrences(of: " ", with: "_").lowercased()
        panel.nameFieldStringValue = "\(baseName)_map.s"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self = self else { return }
            if self.document.charsetBankStatus() == .mixed {
                let alert = NSAlert()
                alert.messageText = "Mixed Charset Banks Detected"
                alert.informativeText = """
                    This map uses tiles from both charset bank 0 ($00–$7F) and bank 1 ($80–$FF). \
                    The C64 can only display one charset bank at a time, so this map will not \
                    render correctly on real hardware or in VICE without raster interrupt tricks.
                    """
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Export Anyway")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            let asm = self.document.exportAsAssembly(label: baseName)
            try? asm.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    public func exportBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Export Here"
        panel.begin { [weak self] response in
            guard response == .OK, let dir = panel.url, let self = self else { return }
            if self.document.charsetBankStatus() == .mixed {
                let alert = NSAlert()
                alert.messageText = "Mixed Charset Banks Detected"
                alert.informativeText = """
                    This map uses tiles from both charset bank 0 ($00–$7F) and bank 1 ($80–$FF). \
                    The C64 can only display one charset bank at a time, so this map will not \
                    render correctly on real hardware or in VICE without raster interrupt tricks.
                    """
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Export Anyway")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            let baseName = self.document.name.replacingOccurrences(of: " ", with: "_").lowercased()
            let screenURL = dir.appendingPathComponent("\(baseName)_screen.bin")
            let colorURL = dir.appendingPathComponent("\(baseName)_color.bin")
            try? self.document.exportBinary(screenURL: screenURL, colorURL: colorURL)
        }
    }

    // MARK: - Tile Clipboard

    private struct TileClipboard {
        let width: Int
        let height: Int
        let tiles: [[UInt8]]   // [row][col]
        let colors: [[UInt8]]  // [row][col]
    }

    private var tileClipboard: TileClipboard?
    private var currentSelection: MapRect?   // track last selection

    // MARK: - MapGridViewDelegate

    public func mapGridView(_ view: MapGridView, didPaintAt col: Int, row: Int) {
        paintTile(at: col, row: row)
    }

    public func mapGridView(_ view: MapGridView, didDragTo col: Int, row: Int) {
        paintTile(at: col, row: row)
    }

    public func mapGridView(_ view: MapGridView, didFillFrom origin: MapPoint, to end: MapPoint) {
        let rect = normalizedRect(from: origin, to: end)
        guard let layer = document.activeLayer else { return }
        let layerIdx = document.activeLayerIndex

        // Capture old state
        var oldTiles: [[UInt8]] = []
        var oldColors: [[UInt8]] = []
        for row in rect.origin.row...rect.maxRow {
            var tileRow: [UInt8] = []
            var colorRow: [UInt8] = []
            for col in rect.origin.col...rect.maxCol {
                tileRow.append(layer.tiles[row][col])
                colorRow.append(layer.colors[row][col])
            }
            oldTiles.append(tileRow)
            oldColors.append(colorRow)
        }

        let action = MapEditAction.fill(layer: layerIdx, rect: rect,
                                         oldTiles: oldTiles, oldColors: oldColors,
                                         newTile: selectedTile, newColor: selectedColor)
        undoMgr.perform(action)
        updateBankWarning()
        mapGridView.needsDisplay = true
    }

    public func mapGridView(_ view: MapGridView, didFloodFillAt col: Int, row: Int) {
        guard let layer = document.activeLayer else { return }
        let layerIdx = document.activeLayerIndex
        let targetTile = layer.tiles[row][col]
        let targetColor = layer.colors[row][col]

        // Don't fill if we're already the target
        guard targetTile != selectedTile || targetColor != selectedColor else { return }

        // BFS flood fill
        var visited = Set<Int>()
        var queue: [(Int, Int)] = [(col, row)]
        var cells: [(col: Int, row: Int)] = []
        var oldTiles: [UInt8] = []
        var oldColors: [UInt8] = []

        while !queue.isEmpty {
            let (c, r) = queue.removeFirst()
            let key = r * document.width + c
            guard !visited.contains(key) else { continue }
            guard c >= 0, c < document.width, r >= 0, r < document.height else { continue }
            guard layer.tiles[r][c] == targetTile, layer.colors[r][c] == targetColor else { continue }

            visited.insert(key)
            cells.append((col: c, row: r))
            oldTiles.append(layer.tiles[r][c])
            oldColors.append(layer.colors[r][c])

            queue.append((c - 1, r))
            queue.append((c + 1, r))
            queue.append((c, r - 1))
            queue.append((c, r + 1))
        }

        let action = MapEditAction.floodFill(layer: layerIdx, cells: cells,
                                              oldTiles: oldTiles, oldColors: oldColors,
                                              newTile: selectedTile, newColor: selectedColor)
        undoMgr.perform(action)
        updateBankWarning()
        mapGridView.needsDisplay = true
    }

    public func mapGridView(_ view: MapGridView, didSelectFrom origin: MapPoint, to end: MapPoint) {
        let rect = normalizedRect(from: origin, to: end)
        currentSelection = rect
        let tileCount = rect.width * rect.height
        coordLabel.stringValue = "Selected: \(rect.width)×\(rect.height) (\(tileCount) tiles)"
    }

    // MARK: - Copy / Paste

    @objc public func copy(_ sender: Any?) {
        copySelection(sender)
    }

    @objc public func paste(_ sender: Any?) {
        pasteSelection(sender)
    }

    @objc public func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) {
            return currentSelection != nil
        }
        if item.action == #selector(paste(_:)) {
            return tileClipboard != nil && currentSelection != nil
        }
        return true
    }

    @objc private func copySelection(_ sender: Any? = nil) {
        guard let rect = currentSelection,
              let layer = document.activeLayer else { return }

        var tiles: [[UInt8]] = []
        var colors: [[UInt8]] = []
        for row in rect.origin.row ..< rect.origin.row + rect.height {
            var tileRow: [UInt8] = []
            var colorRow: [UInt8] = []
            for col in rect.origin.col ..< rect.origin.col + rect.width {
                tileRow.append(layer.tiles[row][col])
                colorRow.append(layer.colors[row][col])
            }
            tiles.append(tileRow)
            colors.append(colorRow)
        }

        tileClipboard = TileClipboard(width: rect.width, height: rect.height,
                                       tiles: tiles, colors: colors)
        coordLabel.stringValue = "Copied: \(rect.width)×\(rect.height)"
    }

    @objc private func pasteSelection(_ sender: Any? = nil) {
        guard let clipboard = tileClipboard,
              let dest = currentSelection,
              let layer = document.activeLayer else { return }

        let layerIdx = document.activeLayerIndex

        // Clip to the smaller of source/destination in each dimension
        let pasteRows = min(clipboard.height, dest.height)
        let pasteCols = min(clipboard.width, dest.width)

        // Snapshot old state
        var oldTiles: [[UInt8]] = []
        var oldColors: [[UInt8]] = []
        for row in 0 ..< pasteRows {
            let mapRow = dest.origin.row + row
            var tileRow: [UInt8] = []
            var colorRow: [UInt8] = []
            for col in 0 ..< pasteCols {
                let mapCol = dest.origin.col + col
                tileRow.append(layer.tiles[mapRow][mapCol])
                colorRow.append(layer.colors[mapRow][mapCol])
            }
            oldTiles.append(tileRow)
            oldColors.append(colorRow)
        }

        // Clip the new tiles from the clipboard to match paste dimensions
        let newTiles = clipboard.tiles.prefix(pasteRows).map { Array($0.prefix(pasteCols)) }
        let newColors = clipboard.colors.prefix(pasteRows).map { Array($0.prefix(pasteCols)) }

        let action = MapEditAction.stamp(
            layer: layerIdx,
            origin: dest.origin,
            oldTiles: oldTiles,
            oldColors: oldColors,
            newTiles: newTiles,
            newColors: newColors
        )
        undoMgr.perform(action)
        updateBankWarning()
        mapGridView.needsDisplay = true
        coordLabel.stringValue = "Pasted: \(pasteCols)×\(pasteRows)"
    }

    public func mapGridView(_ view: MapGridView, didPickAt col: Int, row: Int) {
        guard let layer = document.activeLayer else { return }
        selectedTile = layer.tiles[row][col]
        selectedColor = layer.colors[row][col]
        tilePickerView?.selectedTile = selectedTile
        colorPickerView?.selectedColor = selectedColor

        // Switch back to paint tool after picking
        toolSegment.selectedSegment = 0
        mapGridView.currentTool = .paint
    }

    public func mapGridView(_ view: MapGridView, cursorAt col: Int, row: Int) {
        let tile = document.tile(atCol: col, row: row) ?? 0
        let addr = row * document.width + col
        coordLabel.stringValue = String(format: "Col: %d  Row: %d  Tile: $%02X  Offset: $%04X", col, row, tile, addr)
    }

    // MARK: - Helpers

    private func paintTile(at col: Int, row: Int) {
        guard let layer = document.activeLayer else { return }
        let layerIdx = document.activeLayerIndex
        let oldTile = layer.tiles[row][col]
        let oldColor = layer.colors[row][col]

        guard oldTile != selectedTile || oldColor != selectedColor else { return }

        let action = MapEditAction.paint(layer: layerIdx, col: col, row: row,
                                          oldTile: oldTile, oldColor: oldColor,
                                          newTile: selectedTile, newColor: selectedColor)
        undoMgr.perform(action)
        updateBankWarning()
        mapGridView.setNeedsDisplay(
            NSRect(x: CGFloat(col) * 8.0 * mapGridView.zoom,
                   y: CGFloat(row) * 8.0 * mapGridView.zoom,
                   width: 8.0 * mapGridView.zoom,
                   height: 8.0 * mapGridView.zoom)
        )
    }

    /// Recomputes the charset bank status and updates the status bar warning label.
    /// Call this after any edit that changes tile data or layer visibility.
    public func updateBankWarning() {
        switch document.charsetBankStatus() {
        case .mixed:
            bankWarningLabel.stringValue = "⚠ Mixed charset banks ($00–$7F and $80–$FF)"
        case .clean, .bankZeroOnly, .bankOneOnly:
            bankWarningLabel.stringValue = ""
        }
    }

    private func normalizedRect(from a: MapPoint, to b: MapPoint) -> MapRect {
        let minCol = max(0, min(a.col, b.col))
        let maxCol = min(document.width - 1, max(a.col, b.col))
        let minRow = max(0, min(a.row, b.row))
        let maxRow = min(document.height - 1, max(a.row, b.row))
        return MapRect(origin: MapPoint(col: minCol, row: minRow),
                       width: maxCol - minCol + 1,
                       height: maxRow - minRow + 1)
    }

    // MARK: - Undo/Redo from menu

    @objc public func undo(_ sender: Any?) {
        undoMgr.undo()
        updateBankWarning()
        mapGridView.needsDisplay = true
    }

    @objc public func redo(_ sender: Any?) {
        undoMgr.redo()
        updateBankWarning()
        mapGridView.needsDisplay = true
    }
}

// MARK: - Tile Picker View

/// Displays the 256-character tileset as a 16×16 grid for selection.
public final class TilePickerView: NSView {
    public var charsetData: Data? { didSet { needsDisplay = true } }
    public var selectedTile: UInt8 = 1 { didSet { needsDisplay = true } }
    public var onTileSelected: ((UInt8) -> Void)?

    override public var isFlipped: Bool { true }

    // ── Layout constants ────────────────────────────────────────────────────
    // The picker is divided into fixed zones (all in points, top-to-bottom):
    //   headerH   — "BANK 0" label above the first tile row
    //   8 × cs    — Bank 0 tile rows ($00–$7F)
    //   separatorH — chunky divider bar containing the "BANK 1" label
    //   8 × cs    — Bank 1 tile rows ($80–$FF)
    //
    // cs is derived from available width so tiles fill the panel horizontally.

    private let headerH:    CGFloat = 18
    private let separatorH: CGFloat = 18

    private var cs: CGFloat { bounds.width / 16.0 }

    /// Y origin of the Bank 0 tile block.
    private var bank0TilesY: CGFloat { headerH }

    /// Y origin of the separator bar.
    private var separatorY: CGFloat { bank0TilesY + cs * 8 }

    /// Y origin of the Bank 1 tile block.
    private var bank1TilesY: CGFloat { separatorY + separatorH }

    // ── Drawing ─────────────────────────────────────────────────────────────

    override public func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let data = charsetData ?? C64ROMCharset.data
        let cs   = self.cs
        let w    = bounds.width

        let amber     = NSColor.systemOrange
        let amberDim  = amber.withAlphaComponent(0.15)

        // ── Bank 0 header ────────────────────────────────────────────────────
        ctx.setFillColor(amberDim.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: headerH))

        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .bold),
            .foregroundColor: amber,
        ]
        NSAttributedString(string: "  BANK 0   $00–$7F", attributes: headerAttrs)
            .draw(in: CGRect(x: 4, y: 3, width: w - 8, height: headerH - 2))

        // ── Bank 0 tiles (chars $00–$7F, rows 0–7) ──────────────────────────
        drawTileBlock(ctx: ctx, data: data, cs: cs,
                      startChar: 0, rows: 8, originY: bank0TilesY)

        // ── Separator bar ────────────────────────────────────────────────────
        let sepRect = CGRect(x: 0, y: separatorY, width: w, height: separatorH)

        ctx.setFillColor(amber.cgColor)
        ctx.fill(sepRect)

        let sepAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor.black,
        ]
        NSAttributedString(string: "  BANK 1   $80–$FF", attributes: sepAttrs)
            .draw(in: CGRect(x: 4, y: separatorY + 3, width: w - 8, height: separatorH - 4))

        // ── Bank 1 tiles (chars $80–$FF, rows 8–15) ─────────────────────────
        drawTileBlock(ctx: ctx, data: data, cs: cs,
                      startChar: 128, rows: 8, originY: bank1TilesY)

        // ── Selection highlight ──────────────────────────────────────────────
        if let selRect = tileRect(for: selectedTile, cs: cs) {
            ctx.setStrokeColor(NSColor.systemYellow.cgColor)
            ctx.setLineWidth(2.0)
            ctx.stroke(selRect.insetBy(dx: 1, dy: 1))
        }
    }

    /// Draws a block of tile rows starting at `startChar`, for `rows` rows, at `originY`.
    private func drawTileBlock(ctx: CGContext, data: Data, cs: CGFloat,
                                startChar: Int, rows: Int, originY: CGFloat) {
        for r in 0..<rows {
            for c in 0..<16 {
                let charIdx = startChar + r * 16 + c
                let rect = CGRect(x: CGFloat(c) * cs,
                                  y: originY + CGFloat(r) * cs,
                                  width: cs, height: cs)

                // Cell background
                let isSelected = UInt8(charIdx) == selectedTile
                ctx.setFillColor(isSelected ? NSColor.systemBlue.cgColor : NSColor.black.cgColor)
                ctx.fill(rect)

                // Glyph pixels
                let offset = charIdx * 8
                guard offset + 8 <= data.count else { continue }
                let pixSize = cs / 8.0
                ctx.setFillColor(NSColor.white.cgColor)
                for py in 0..<8 {
                    let byte = data[offset + py]
                    guard byte != 0 else { continue }
                    for px in 0..<8 {
                        if byte & (0x80 >> px) != 0 {
                            ctx.fill(CGRect(
                                x: rect.origin.x + CGFloat(px) * pixSize,
                                y: rect.origin.y + CGFloat(py) * pixSize,
                                width: pixSize, height: pixSize))
                        }
                    }
                }
            }
        }
    }

    /// Returns the screen rect for a given tile index, accounting for the
    /// header and separator offsets. Returns nil if the index is out of range.
    private func tileRect(for tile: UInt8, cs: CGFloat) -> CGRect? {
        let i   = Int(tile)
        let col = i % 16
        let row = i / 16   // 0–15
        let originY = row < 8 ? bank0TilesY : bank1TilesY
        let tileRow = row < 8 ? row : row - 8
        return CGRect(x: CGFloat(col) * cs,
                      y: originY + CGFloat(tileRow) * cs,
                      width: cs, height: cs)
    }

    // ── Mouse ────────────────────────────────────────────────────────────────

    override public func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let cs    = self.cs
        guard cs > 0 else { return }

        let col = Int(floor(local.x / cs))
        guard col >= 0, col < 16 else { return }

        // Determine which bank block the click landed in
        let tileRow: Int
        if local.y >= bank0TilesY && local.y < separatorY {
            tileRow = Int(floor((local.y - bank0TilesY) / cs))
            guard tileRow < 8 else { return }
        } else if local.y >= bank1TilesY && local.y < bank1TilesY + cs * 8 {
            tileRow = 8 + Int(floor((local.y - bank1TilesY) / cs))
            guard tileRow < 16 else { return }
        } else {
            return  // clicked in header or separator — ignore
        }

        let tile = UInt8(tileRow * 16 + col)
        selectedTile = tile
        onTileSelected?(tile)
    }
}

// MARK: - Color Picker View

/// Displays the 16 C64 colors as clickable swatches.
public final class ColorPickerView: NSView {
    public var selectedColor: UInt8 = 1 { didSet { needsDisplay = true } }
    public var onColorSelected: ((UInt8) -> Void)?

    override public var isFlipped: Bool { true }

    override public func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let swatchW = bounds.width / 8.0
        let swatchH = bounds.height / 2.0

        for i in 0..<16 {
            let col = i % 8
            let row = i / 8
            let rect = CGRect(x: CGFloat(col) * swatchW, y: CGFloat(row) * swatchH,
                             width: swatchW, height: swatchH)

            ctx.setFillColor(C64Palette.nsColor(for: UInt8(i)).cgColor)
            ctx.fill(rect)

            if UInt8(i) == selectedColor {
                ctx.setStrokeColor(NSColor.systemYellow.cgColor)
                ctx.setLineWidth(2.5)
                ctx.stroke(rect.insetBy(dx: 2, dy: 2))
            }
        }
    }

    override public func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let col = Int(floor(local.x / (bounds.width / 8.0)))
        let row = Int(floor(local.y / (bounds.height / 2.0)))
        guard col >= 0, col < 8, row >= 0, row < 2 else { return }
        let color = UInt8(row * 8 + col)
        selectedColor = color
        onColorSelected?(color)
    }
}

// MARK: - Layer List View

/// Simple layer management panel: list, add/remove, visibility toggle, reorder.
public final class LayerListView: NSView {
    public var document: MapDocument? { didSet { rebuildList() } }
    public var onLayerChanged: (() -> Void)?

    private var stackView: NSStackView!
    private var addButton: NSButton!

    override public var isFlipped: Bool { true }

    public init() {
        super.init(frame: .zero)
        setup()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true

        let header = NSTextField(labelWithString: "Layers")
        header.font = .boldSystemFont(ofSize: 11)
        header.textColor = .secondaryLabelColor

        addButton = NSButton(title: "+", target: self, action: #selector(addLayer))
        addButton.bezelStyle = .inline
        addButton.controlSize = .small

        let headerStack = NSStackView(views: [header, addButton])
        headerStack.orientation = .horizontal
        headerStack.distribution = .fill

        stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 2

        let outerStack = NSStackView(views: [headerStack, stackView])
        outerStack.orientation = .vertical
        outerStack.alignment = .leading
        outerStack.spacing = 6
        outerStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outerStack)

        NSLayoutConstraint.activate([
            outerStack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            outerStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            outerStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
        ])
    }

    public func rebuildList() {
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let doc = document else { return }

        for (i, layer) in doc.layers.enumerated() {
            let eyeIcon = layer.isVisible ? "eye" : "eye.slash"
            let visBtn = NSButton(image: NSImage(systemSymbolName: eyeIcon, accessibilityDescription: nil)!,
                                  target: self, action: #selector(toggleVisibility(_:)))
            visBtn.bezelStyle = .inline
            visBtn.tag = i

            let nameLabel = NSTextField(labelWithString: layer.name)
            nameLabel.font = .systemFont(ofSize: 11)
            nameLabel.textColor = i == doc.activeLayerIndex ? .controlAccentColor : .labelColor

            let selectBtn = NSButton(title: "", target: self, action: #selector(selectLayer(_:)))
            selectBtn.tag = i
            selectBtn.isTransparent = true

            let row = NSStackView(views: [visBtn, nameLabel])
            row.orientation = .horizontal
            row.spacing = 4
            stackView.addArrangedSubview(row)
        }
    }

    @objc private func toggleVisibility(_ sender: NSButton) {
        guard let doc = document, sender.tag < doc.layers.count else { return }
        doc.layers[sender.tag].isVisible.toggle()
        rebuildList()
        onLayerChanged?()
    }

    @objc private func selectLayer(_ sender: NSButton) {
        guard let doc = document, sender.tag < doc.layers.count else { return }
        doc.activeLayerIndex = sender.tag
        rebuildList()
        onLayerChanged?()
    }

    @objc private func addLayer() {
        document?.addLayer()
        rebuildList()
        onLayerChanged?()
    }
}

// MARK: - Map Raster Ruler View

/// Floating view that sits over the left edge of the map scroll view,
/// showing raster line numbers at every tile row (each tile = 8 raster lines).
/// Syncs with scroll via `scrollOffset` and zoom via `zoom`.
public final class MapRasterRulerView: NSView {

    public var zoom: CGFloat = 2.0 { didSet { needsDisplay = true } }
    public var scrollOffset: CGFloat = 0 { didSet { needsDisplay = true } }

    // Must be flipped to match MapGridView (y=0 at top)
    override public var isFlipped: Bool { true }

    private let rulerW: CGFloat = 32
    private let rasterTop = 51  // PAL visible area starts at raster line 51
    private let rows = 25

    override public func draw(_ dirtyRect: NSRect) {
        NSColor(white: AppTheme.current.isDark ? 0.0 : 0.85, alpha: 0.75).setFill()
        bounds.fill()

        let cellH = 8.0 * zoom   // one tile row = 8 raster lines = cellH points
        let font = NSFont.monospacedSystemFont(ofSize: max(8, min(11, cellH * 0.5)), weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: AppTheme.current.syntaxKeyword.withAlphaComponent(0.95),
        ]
        let tickColor = AppTheme.current.syntaxKeyword.withAlphaComponent(0.5)

        for row in 0..<rows {
            let raster = rasterTop + row * 8
            let rowY = CGFloat(row) * cellH - scrollOffset

            guard rowY >= -cellH && rowY <= bounds.height else { continue }

            // Tick at right edge
            tickColor.setStroke()
            NSBezierPath.strokeLine(
                from: NSPoint(x: rulerW - 4, y: rowY),
                to:   NSPoint(x: rulerW,     y: rowY)
            )

            // Label centred vertically in the row
            let label = "\(raster)" as NSString
            let labelSize = label.size(withAttributes: attrs)
            if labelSize.height <= cellH {
                let labelX = (rulerW - 4 - labelSize.width) / 2
                let labelY = rowY + (cellH - labelSize.height) / 2
                label.draw(at: NSPoint(x: labelX, y: labelY), withAttributes: attrs)
            }
        }

        // Right-edge border
        AppTheme.current.syntaxKeyword.withAlphaComponent(0.3).setStroke()
        NSBezierPath.strokeLine(
            from: NSPoint(x: rulerW - 0.5, y: 0),
            to:   NSPoint(x: rulerW - 0.5, y: bounds.height)
        )
    }
}

