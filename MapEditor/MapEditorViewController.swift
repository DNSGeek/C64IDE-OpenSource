import Cocoa
import UniformTypeIdentifiers

// MARK: - Map Editor View Controller

/// Orchestrates the Map Editor UI, document state, tools, and data flow.
public final class MapEditorViewController: NSViewController, MapGridViewDelegate, NSUserInterfaceValidations {

    // MARK: - Properties

    /// The active map document being edited.
    public private(set) var document = MapDocument()
    private var undoMgr: MapUndoManager!

    /// Currently selected tile index for painting. Updates the tile picker when changed.
    public var selectedTile: UInt8 = 1 { didSet { tilePickerView?.selectedTile = selectedTile } }

    /// Currently selected color index for painting. Updates the color picker when changed.
    public var selectedColor: UInt8 = 1 {
        didSet {
            colorPickerView?.selectedColor = selectedColor
            tilePickerView?.foregroundColorIndex = selectedColor
        }
    }

    /// Tracks whether the document has been modified since the last save.
    public private(set) var isModified = false

    /// The URL this document was last saved to or loaded from.
    public var fileURL: URL?

    // MARK: - Subviews

    private var mapGridView: MapGridView!
    private var scrollView: NSScrollView!
    private var tilePickerView: TilePickerView!
    private var colorPickerView: ColorPickerView!
    private var bgPickerView: ColorPickerView!
    private var layerListView: LayerListView!
    private var toolSegment: NSSegmentedControl!
    private var zoomSlider: NSSlider!
    private var coordLabel: NSTextField!
    private var bankWarningLabel: NSTextField!
    private var gridToggle: NSButton!
    private var rasterToggle: NSButton!
    private var dimToggle: NSButton!
    private var fitButton: NSButton!
    private var panelLabels: [NSTextField] = []
    private var rasterRulerView: MapRasterRulerView!
    private var exportPopup: NSPopUpButton!

    /// Enables live synchronization of charset updates from the Character Editor.
    public private(set) var isLiveSyncEnabled = false

    // MARK: - Lifecycle

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

        attachDocument()

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
        panelLabels.forEach { $0.textColor = AppTheme.current.statusLabel }
        coordLabel?.textColor = AppTheme.current.statusLabel
        tilePickerView?.needsDisplay  = true
        rasterRulerView?.needsDisplay = true
        layerListView?.needsDisplay   = true
    }

    // MARK: - Charset Sync from Character Editor

    /// Applies charset data when live sync is enabled.
    @objc private func charsetDidChange(_ notification: Notification) {
        guard isLiveSyncEnabled, let payload = CharsetPayload(notification: notification) else { return }
        // Live sync mirrors the glyphs and the mode they are drawn in, but not
        // the background color: that one belongs to the map, and silently
        // repainting it from the Character Editor was the old behavior.
        apply(payload, adoptBackground: false)
    }

    /// Applies charset data unconditionally and enables live sync for future updates.
    @objc private func charsetSentToMapEditor(_ notification: Notification) {
        guard let payload = CharsetPayload(notification: notification) else { return }
        applyCharset(payload)
    }

    /// Adopts a charset sent explicitly from the Character Set Editor,
    /// including its background color, and turns on live sync.
    ///
    /// Called directly by the app delegate as well as via notification: a
    /// Map Editor created *while* `.charsetSendToMapEditor` is being
    /// delivered never receives that notification, so the first "Send to Map
    /// Editor" would otherwise do nothing at all.
    public func applyCharset(_ payload: CharsetPayload) {
        setLiveSync(true)
        apply(payload, adoptBackground: true)
    }

    private func apply(_ payload: CharsetPayload, adoptBackground: Bool) {
        var changed = false

        if document.charsetData != payload.charset {
            document.charsetData = payload.charset
            // The embedded data no longer came from the file on disk; keeping
            // the old path would save a .c64map pointing at a charset it does
            // not actually use.
            document.charsetPath = nil
            mapGridView.invalidateCharsetCache()
            tilePickerView?.charsetData = payload.charset
            changed = true
        }

        // Multi-color is a property of the charset itself — a multi-color
        // charset drawn as hi-res is unreadable — so it travels with the
        // glyphs even on a live sync.
        let mc1 = UInt8(payload.multiColor1 & 0x0F)
        let mc2 = UInt8(payload.multiColor2 & 0x0F)
        if document.isMultiColorMode != payload.isMultiColor
            || document.extraColor1 != mc1 || document.extraColor2 != mc2 {
            document.isMultiColorMode = payload.isMultiColor
            document.extraColor1 = mc1
            document.extraColor2 = mc2
            colorPickerView?.multiColorHint = document.isMultiColorMode
            changed = true
        }

        if adoptBackground, document.backgroundColor != UInt8(payload.bgColor & 0x0F) {
            document.backgroundColor = UInt8(payload.bgColor & 0x0F)
            bgPickerView?.selectedColor = document.backgroundColor
            changed = true
        }

        guard changed else { return }
        tilePickerView?.applyDocumentColors(document)
        mapGridView.needsDisplay = true
        isModified = true
    }

    /// Turns live charset sync with the Character Set Editor on or off.
    public func setLiveSync(_ enabled: Bool) {
        isLiveSyncEnabled = enabled
        exportPopup?.menu?.items
            .first { $0.title == MapEditorViewController.liveSyncTitle }?
            .state = enabled ? .on : .off
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
        // Index 0 is the pull-down's title; the rest are matched by title in
        // exportMenuSelected() so inserting an item cannot silently re-map
        // the actions.
        exportPopup.addItem(withTitle: "Map ▾")
        for title in MapEditorViewController.menuTitles {
            if title.isEmpty {
                exportPopup.menu?.addItem(.separator())
            } else {
                exportPopup.addItem(withTitle: title)
            }
        }
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

        dimToggle = NSButton(checkboxWithTitle: "Dim", target: self, action: #selector(dimToggled(_:)))
        dimToggle.state = .on
        dimToggle.toolTip = "Dim layers other than the active one"
        dimToggle.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dimToggle)

        fitButton = NSButton(title: "Fit", target: self, action: #selector(zoomToFit(_:)))
        fitButton.bezelStyle = .rounded
        fitButton.controlSize = .small
        fitButton.toolTip = "Zoom so the whole map is visible"
        fitButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(fitButton)
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

        // Keep ruler in sync with canvas scroll.
        // NSClipView does not reliably post bounds changes by default,
        // so enable it explicitly.
        scrollView.contentView.postsBoundsChangedNotifications = true
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

        // The background color ($D021) belongs to the map, so it needs its own
        // control here rather than being dictated by the Character Editor.
        bgPickerView = ColorPickerView()
        bgPickerView.translatesAutoresizingMaskIntoConstraints = false
        bgPickerView.selectedColor = document.backgroundColor
        bgPickerView.onColorSelected = { [weak self] color in
            guard let self else { return }
            guard self.document.backgroundColor != color else { return }
            self.document.backgroundColor = color
            self.mapGridView.needsDisplay = true
            self.tilePickerView?.applyDocumentColors(self.document)
            self.isModified = true
        }
        view.addSubview(bgPickerView)
    }

    /// Small caption above a left-panel control.
    private func panelLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .bold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        panelLabels.append(label)
        view.addSubview(label)
        return label
    }

    private func setupLayerList() {
        layerListView = LayerListView()
        layerListView.translatesAutoresizingMaskIntoConstraints = false
        layerListView.onLayerChanged = { [weak self] in
            self?.mapGridView.needsDisplay = true
            self?.updateBankWarning()
        }
        // Adding a layer or toggling visibility changes what gets saved, so
        // the close/quit prompt has to know about it.
        layerListView.onLayerEdited = { [weak self] in
            self?.isModified = true
        }
        // Structural changes (layer removal) invalidate recorded layer
        // indices in the undo stack, so history must be discarded.
        layerListView.onLayerStructureChanged = { [weak self] in
            self?.undoMgr.clearHistory()
            self?.isModified = true
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
        // The tile picker draws 16 rows of square tiles plus two 18pt bank
        // headers; sizing it to exactly that avoids a large dead gap.
        let tileSide = (leftPanelWidth - 8) / 16.0
        let tilePickerHeight = ceil(tileSide * 16 + 36)
        let paintLabel = panelLabel("PAINT COLOR")
        let bgLabel = panelLabel("BACKGROUND ($D021)")

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

            dimToggle.centerYAnchor.constraint(equalTo: toolSegment.centerYAnchor),
            dimToggle.trailingAnchor.constraint(equalTo: rasterToggle.leadingAnchor, constant: -12),

            fitButton.centerYAnchor.constraint(equalTo: toolSegment.centerYAnchor),
            fitButton.trailingAnchor.constraint(equalTo: dimToggle.leadingAnchor, constant: -12),
            fitButton.leadingAnchor.constraint(greaterThanOrEqualTo: exportPopup.trailingAnchor, constant: 8),

            // Left panel: tile picker + color picker + layer list
            tilePickerView.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            tilePickerView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            tilePickerView.widthAnchor.constraint(equalToConstant: leftPanelWidth - 8),
            tilePickerView.heightAnchor.constraint(equalToConstant: tilePickerHeight),

            paintLabel.topAnchor.constraint(equalTo: tilePickerView.bottomAnchor, constant: 6),
            paintLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),

            colorPickerView.topAnchor.constraint(equalTo: paintLabel.bottomAnchor, constant: 2),
            colorPickerView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            colorPickerView.widthAnchor.constraint(equalToConstant: leftPanelWidth - 8),
            colorPickerView.heightAnchor.constraint(equalToConstant: 44),

            bgLabel.topAnchor.constraint(equalTo: colorPickerView.bottomAnchor, constant: 6),
            bgLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),

            bgPickerView.topAnchor.constraint(equalTo: bgLabel.bottomAnchor, constant: 2),
            bgPickerView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            bgPickerView.widthAnchor.constraint(equalToConstant: leftPanelWidth - 8),
            bgPickerView.heightAnchor.constraint(equalToConstant: 30),

            layerListView.topAnchor.constraint(equalTo: bgPickerView.bottomAnchor, constant: 8),
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
        guard tools.indices.contains(sender.selectedSegment) else { return }
        mapGridView.currentTool = tools[sender.selectedSegment]
    }

    @objc private func zoomChanged(_ sender: NSSlider) {
        // Setting zoom triggers mapGridView(_:zoomDidChange:), which syncs
        // the ruler and re-syncs the slider to the clamped value.
        mapGridView.zoom = CGFloat(sender.doubleValue)
    }

    @objc private func gridToggled(_ sender: NSButton) {
        mapGridView.showGrid = sender.state == .on
    }

    @objc private func rasterToggled(_ sender: NSButton) {
        rasterRulerView.isHidden = sender.state != .on
    }

    @objc private func dimToggled(_ sender: NSButton) {
        mapGridView.showLayerDimming = sender.state == .on
    }

    @objc private func zoomToFit(_ sender: Any?) {
        mapGridView.zoomToFit(in: scrollView.contentView.bounds.size)
    }

    @objc private func mapScrolled(_ notification: Notification) {
        rasterRulerView.scrollOffset = scrollView.contentView.bounds.origin.y
        rasterRulerView.needsDisplay = true
    }

    /// Pull-down entries, in order. An empty string is a separator.
    private static let menuTitles = [
        "New Map…",
        "Resize Map…",
        "",
        "Save Map (.c64map)…",
        "Open Map…",
        "Load Charset…",
        MapEditorViewController.liveSyncTitle,
        "",
        "Export as Assembly (.s)…",
        "Export as Binary (.bin)…",
    ]

    private static let liveSyncTitle = "Live Charset Sync"

    @objc private func exportMenuSelected(_ sender: NSPopUpButton) {
        switch sender.titleOfSelectedItem {
        case "New Map…":
            NSApp.sendAction(#selector(MapEditorWindowController.newMapPrompt), to: nil, from: self)
        case "Resize Map…":
            promptResizeMap()
        case "Save Map (.c64map)…":
            saveDocument()
        case "Open Map…":
            // Open — delegate to window controller via responder chain
            NSApp.sendAction(#selector(MapEditorWindowController.openMap), to: nil, from: self)
        case "Load Charset…":
            // Load Charset — delegate to window controller
            NSApp.sendAction(#selector(MapEditorWindowController.loadCharset), to: nil, from: self)
        case MapEditorViewController.liveSyncTitle:
            setLiveSync(!isLiveSyncEnabled)
        case "Export as Assembly (.s)…":
            exportAssembly()
        case "Export as Binary (.bin)…":
            exportBinary()
        default:
            break
        }
    }

    /// Asks for new map dimensions and resizes in place, preserving overlap.
    private func promptResizeMap() {
        guard let size = MapEditorViewController.promptForMapSize(
            title: "Resize Map",
            message: "Existing tiles are kept where the old and new maps overlap.",
            width: document.width, height: document.height) else { return }
        guard size.width != document.width || size.height != document.height else { return }
        document.resize(to: size.width, height: size.height)
        // Recorded undo actions reference cells that may no longer exist.
        undoMgr.clearHistory()
        currentSelection = nil
        resetPaintStroke()
        rasterRulerView?.rows = document.height
        mapGridView.invalidateIntrinsicContentSize()
        mapGridView.needsDisplay = true
        updateBankWarning()
        isModified = true
    }

    /// Shared width/height prompt used by New Map and Resize Map.
    static func promptForMapSize(title: String, message: String,
                                 width: Int, height: Int) -> (width: Int, height: Int)? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message + "\n\nSize in characters (1–\(MapDocument.maxDimension)). "
            + "A single C64 screen is 40×25."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 26))
        let widthField = NSTextField(frame: NSRect(x: 46, y: 2, width: 56, height: 22))
        let heightField = NSTextField(frame: NSRect(x: 156, y: 2, width: 56, height: 22))
        widthField.integerValue = width
        heightField.integerValue = height
        let widthLabel = NSTextField(labelWithString: "Width:")
        widthLabel.frame = NSRect(x: 0, y: 5, width: 44, height: 16)
        let heightLabel = NSTextField(labelWithString: "Height:")
        heightLabel.frame = NSRect(x: 106, y: 5, width: 48, height: 16)
        accessory.addSubview(widthLabel)
        accessory.addSubview(widthField)
        accessory.addSubview(heightLabel)
        accessory.addSubview(heightField)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = widthField

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let newWidth = max(1, min(MapDocument.maxDimension, widthField.integerValue))
        let newHeight = max(1, min(MapDocument.maxDimension, heightField.integerValue))
        return (newWidth, newHeight)
    }

    // MARK: - Document Management

    public func newDocument(width: Int = 40, height: Int = 25) {
        document = MapDocument(width: width, height: height)
        attachDocument()
        fileURL = nil
        isModified = false
    }

    public func loadDocument(from url: URL) throws {
        document = try MapDocument.load(from: url)
        attachDocument()
        fileURL = url
        isModified = false
    }

    /// Common wiring after `document` is replaced: rebuild the undo manager,
    /// point every view at the new document, and reset transient edit state.
    private func attachDocument() {
        undoMgr = MapUndoManager(document: document)
        undoMgr.onStateChanged = { [weak self] in self?.isModified = true }
        mapGridView.document = document
        layerListView.document = document
        tilePickerView?.charsetData = document.charsetData ?? C64ROMCharset.data
        tilePickerView?.applyDocumentColors(document)
        tilePickerView?.foregroundColorIndex = selectedColor
        bgPickerView?.selectedColor = document.backgroundColor
        colorPickerView?.multiColorHint = document.isMultiColorMode
        rasterRulerView?.rows = document.height
        resetPaintStroke()
        currentSelection = nil
        updateBankWarning()
    }

    public func saveDocument() {
        guard let url = fileURL else {
            saveDocumentAs()
            return
        }
        writeDocument(to: url)
    }

    public func saveDocumentAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "c64map")].compactMap { $0 }
        panel.nameFieldStringValue = document.name + ".c64map"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self = self else { return }
            self.writeDocument(to: url)
        }
    }

    /// Synchronous save for callers that must know the outcome before
    /// proceeding (e.g. the window-close prompt). Runs the save panel
    /// modally if the document has never been saved.
    /// Returns true if the document was saved successfully.
    @discardableResult
    public func saveDocumentModally() -> Bool {
        var url = fileURL
        if url == nil {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "c64map")].compactMap { $0 }
            panel.nameFieldStringValue = document.name + ".c64map"
            guard panel.runModal() == .OK, let chosen = panel.url else { return false }
            url = chosen
        }
        guard let saveURL = url else { return false }
        return writeDocument(to: saveURL)
    }

    /// Writes the document to `url`, committing fileURL/name/title state
    /// only if the write succeeds. Shows an alert and leaves state
    /// untouched on failure.
    @discardableResult
    private func writeDocument(to url: URL) -> Bool {
        let oldName = document.name
        document.name = url.deletingPathExtension().lastPathComponent
        do {
            try document.save(to: url)
            fileURL = url
            isModified = false
            view.window?.title = "Map Editor - \(document.name)"
            return true
        } catch {
            document.name = oldName
            NSAlert(error: error).runModal()
            return false
        }
    }

    public func loadCharset(from url: URL) {
        // Same reader as the Character Set Editor's import, so a .prg or .64c
        // with a load-address header works in both places.
        guard let data = try? Data(contentsOf: url),
              let bytes = CharEditorViewController.extractCharset(from: data) else {
            let alert = NSAlert()
            alert.messageText = "Invalid Character Set"
            alert.informativeText = "Expected at least 2048 bytes (256 characters × 8 bytes)."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        let charset = Data(bytes)
        document.charsetData = charset
        document.charsetPath = url.path
        mapGridView.invalidateCharsetCache()
        mapGridView.needsDisplay = true
        tilePickerView?.charsetData = charset
        tilePickerView?.applyDocumentColors(document)
        isModified = true
    }

    // MARK: - Export

    /// If the map mixes charset banks, warns the user and asks whether to
    /// proceed. Returns true if export should continue.
    private func confirmExportDespiteMixedBanks() -> Bool {
        guard document.charsetBankStatus() == .mixed else { return true }
        let alert = NSAlert()
        alert.messageText = "Mixed Charset Banks Detected"
        alert.informativeText = """
            This map uses tiles from both charset bank 0 ($00-$7F) and bank 1 ($80-$FF). \
            The C64 can only display one charset bank at a time, so this map will not \
            render correctly on real hardware or in VICE without raster interrupt tricks.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Export Anyway")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    public func exportAssembly() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = ["s", "asm"].compactMap { UTType(filenameExtension: $0) }
        let baseName = MapDocument.sanitizeAssemblyLabel(
            document.name.replacingOccurrences(of: " ", with: "_").lowercased())
        panel.nameFieldStringValue = "\(baseName)_map.s"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self = self else { return }
            guard self.confirmExportDespiteMixedBanks() else { return }
            let asm = self.document.exportAsAssembly(label: baseName)
            do {
                try asm.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    public func exportBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Export Here"
        panel.begin { [weak self] response in
            guard response == .OK, let dir = panel.url, let self = self else { return }
            guard self.confirmExportDespiteMixedBanks() else { return }
            let baseName = MapDocument.sanitizeAssemblyLabel(
                self.document.name.replacingOccurrences(of: " ", with: "_").lowercased())
            let screenURL = dir.appendingPathComponent("\(baseName)_screen.bin")
            let colorURL = dir.appendingPathComponent("\(baseName)_color.bin")
            do {
                try self.document.exportBinary(screenURL: screenURL, colorURL: colorURL)
            } catch {
                NSAlert(error: error).runModal()
            }
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

    // MARK: - Paint Stroke State
    //
    // A stroke is one mouse-down-to-mouse-up paint gesture. Cells are
    // applied to the layer immediately for live feedback, but recorded as a
    // single MapEditAction.stroke on mouse-up so one Cmd+Z undoes the whole
    // stroke instead of one cell at a time.

    private var strokeCells: [(col: Int, row: Int)] = []
    private var strokeOldTiles: [UInt8] = []
    private var strokeOldColors: [UInt8] = []
    private var strokeVisited = Set<Int>()
    private var strokeLayerIndex = 0

    /// The tile/color actually painted by the current stroke. Captured when
    /// the stroke starts: committing with whatever is selected *now* would
    /// re-apply the wrong tile if the selection changed before the commit.
    private var strokeTile: UInt8 = 0
    private var strokeColor: UInt8 = 0

    private func resetPaintStroke() {
        strokeCells.removeAll()
        strokeOldTiles.removeAll()
        strokeOldColors.removeAll()
        strokeVisited.removeAll()
    }

    /// Commits the accumulated stroke as one undo action. No-op if empty.
    private func commitPaintStroke() {
        guard !strokeCells.isEmpty else { return }
        let action = MapEditAction.stroke(layer: strokeLayerIndex,
                                          cells: strokeCells,
                                          oldTiles: strokeOldTiles,
                                          oldColors: strokeOldColors,
                                          newTile: strokeTile,
                                          newColor: strokeColor)
        resetPaintStroke()
        // perform() re-applies the same values already painted live, which
        // is an idempotent no-op, then records the action.
        undoMgr.perform(action)
        updateBankWarning()
    }

    // MARK: - MapGridViewDelegate

    public func mapGridView(_ view: MapGridView, didPaintAt col: Int, row: Int) {
        commitPaintStroke()  // safety net if a prior stroke never got a mouse-up
        paintTile(at: col, row: row)
    }

    public func mapGridView(_ view: MapGridView, didDragTo col: Int, row: Int) {
        paintTile(at: col, row: row)
    }

    public func mapGridViewDidEndPaintStroke(_ view: MapGridView) {
        commitPaintStroke()
    }

    public func mapGridView(_ view: MapGridView, zoomDidChange zoom: CGFloat) {
        zoomSlider.doubleValue = Double(zoom)
        rasterRulerView.zoom = zoom
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
        guard let layer = document.activeLayer,
              row >= 0, row < document.height,
              col >= 0, col < document.width else { return }
        let layerIdx = document.activeLayerIndex
        let targetTile = layer.tiles[row][col]
        let targetColor = layer.colors[row][col]

        // Don't fill if we're already the target
        guard targetTile != selectedTile || targetColor != selectedColor else { return }

        // BFS flood fill.
        // Head-index traversal instead of removeFirst(), which is O(n) per
        // pop on Array and makes large fills quadratic.
        var visited = Set<Int>()
        var queue: [(Int, Int)] = [(col, row)]
        var head = 0
        var cells: [(col: Int, row: Int)] = []
        var oldTiles: [UInt8] = []
        var oldColors: [UInt8] = []

        while head < queue.count {
            let (c, r) = queue[head]
            head += 1

            // Bounds first: out-of-range coordinates would otherwise produce
            // keys that alias valid cells (e.g. c = -1 aliases the last
            // column of the previous row).
            guard c >= 0, c < document.width, r >= 0, r < document.height else { continue }
            let key = r * document.width + c
            guard !visited.contains(key) else { continue }
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

        guard !cells.isEmpty else { return }

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
        if item.action == #selector(undo(_:)) {
            return undoMgr.canUndo
        }
        if item.action == #selector(redo(_:)) {
            return undoMgr.canRedo
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
        guard let layer = document.activeLayer,
              row >= 0, row < document.height,
              col >= 0, col < document.width else { return }
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

    /// Paints one cell as part of the current stroke. The cell is written
    /// directly to the layer for immediate feedback; the undo action is
    /// created in commitPaintStroke() when the gesture ends.
    private func paintTile(at col: Int, row: Int) {
        guard let layer = document.activeLayer,
              row >= 0, row < document.height,
              col >= 0, col < document.width else { return }

        // Each cell is recorded at most once per stroke so its pre-stroke
        // value is what gets restored on undo.
        let key = row * document.width + col
        guard !strokeVisited.contains(key) else { return }

        let newTile = strokeCells.isEmpty ? selectedTile : strokeTile
        let newColor = strokeCells.isEmpty ? selectedColor : strokeColor
        let oldTile = layer.tiles[row][col]
        let oldColor = layer.colors[row][col]
        guard oldTile != newTile || oldColor != newColor else { return }

        // First cell of a stroke pins the layer and the painted tile/color for
        // the whole stroke (a drag can begin outside the map, so mouseDown is
        // not reliable).
        if strokeCells.isEmpty {
            strokeLayerIndex = document.activeLayerIndex
            strokeTile = selectedTile
            strokeColor = selectedColor
        }

        strokeVisited.insert(key)
        strokeCells.append((col: col, row: row))
        strokeOldTiles.append(oldTile)
        strokeOldColors.append(oldColor)

        layer.tiles[row][col] = newTile
        layer.colors[row][col] = newColor

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
            bankWarningLabel.stringValue = "Warning: mixed charset banks ($00-$7F and $80-$FF)"
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
        resetPaintStroke()
        updateBankWarning()
        mapGridView.needsDisplay = true
    }

    @objc public func redo(_ sender: Any?) {
        undoMgr.redo()
        resetPaintStroke()
        updateBankWarning()
        mapGridView.needsDisplay = true
    }
}

// MARK: - Tile Picker View

/// Displays the 256-character tileset as a 16×16 grid for selection.
public final class TilePickerView: NSView {
    public var charsetData: Data? {
        didSet {
            glyphs.setCharset(charsetData)
            needsDisplay = true
        }
    }
    public var selectedTile: UInt8 = 1 { didSet { needsDisplay = true } }
    public var onTileSelected: ((UInt8) -> Void)?

    /// Colors mirrored from the document so the picker previews tiles the
    /// way they will actually appear on the map.
    public var backgroundColorIndex: UInt8 = 6 { didSet { needsDisplay = true } }
    public var foregroundColorIndex: UInt8 = 1 { didSet { needsDisplay = true } }
    public var isMultiColorMode = false { didSet { needsDisplay = true } }

    private let glyphs = GlyphCache()

    /// Copies every color-affecting setting from the document.
    public func applyDocumentColors(_ document: MapDocument) {
        backgroundColorIndex = document.backgroundColor
        isMultiColorMode = document.isMultiColorMode
        glyphs.setMultiColorRegisters(Int(document.extraColor1), Int(document.extraColor2))
        needsDisplay = true
    }

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
        let cs   = self.cs
        let w    = bounds.width
        guard cs > 0 else { return }
        ctx.interpolationQuality = .none

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
        drawTileBlock(ctx: ctx, cs: cs, startChar: 0, rows: 8, originY: bank0TilesY)

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
        drawTileBlock(ctx: ctx, cs: cs, startChar: 128, rows: 8, originY: bank1TilesY)

        // ── Selection highlight ──────────────────────────────────────────────
        if let selRect = tileRect(for: selectedTile, cs: cs) {
            ctx.setStrokeColor(NSColor.systemYellow.cgColor)
            ctx.setLineWidth(2.0)
            ctx.stroke(selRect.insetBy(dx: 1, dy: 1))
        }
    }

    /// Draws a block of tile rows starting at `startChar`, for `rows` rows, at `originY`.
    private func drawTileBlock(ctx: CGContext, cs: CGFloat,
                                startChar: Int, rows: Int, originY: CGFloat) {
        let selectedBg = NSColor.systemBlue.cgColor
        let bg = C64Palette.nsColor(for: backgroundColorIndex).cgColor
        let color = Int(foregroundColorIndex) & 0x0F
        // A cell is only multi-color when bit 3 of its color RAM value is set.
        let multi = isMultiColorMode && (color & 0x08) != 0

        for r in 0..<rows {
            for c in 0..<16 {
                let charIdx = startChar + r * 16 + c
                let rect = CGRect(x: CGFloat(c) * cs,
                                  y: originY + CGFloat(r) * cs,
                                  width: cs, height: cs)

                // Cell background
                let isSelected = UInt8(charIdx) == selectedTile
                ctx.setFillColor(isSelected ? selectedBg : bg)
                ctx.fill(rect)

                // Glyph — one cached image per (char, color, mode) instead of
                // up to 64 fills per tile, 256 tiles per redraw.
                if let glyph = glyphs.image(tile: UInt8(charIdx),
                                            colorIndex: multi ? color & 0x07 : color,
                                            multiColor: multi) {
                    ctx.draw(glyph, in: rect)
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

    /// When set, colors 8–15 are marked: in multi-color text mode only those
    /// color RAM values make a cell render as multi-color.
    public var multiColorHint = false { didSet { needsDisplay = true } }

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

            if multiColorHint && i >= 8 {
                ctx.setFillColor(NSColor.systemYellow.withAlphaComponent(0.9).cgColor)
                ctx.fillEllipse(in: CGRect(x: rect.maxX - 7, y: rect.minY + 3, width: 4, height: 4))
            }

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

/// Simple layer management panel: list, add/remove, visibility toggle,
/// active-layer selection.
public final class LayerListView: NSView {
    public var document: MapDocument? { didSet { rebuildList() } }

    /// Fires for display-affecting changes (visibility, selection, add/remove).
    public var onLayerChanged: (() -> Void)?

    /// Fires for changes that alter what would be written to disk
    /// (add/remove a layer, toggle visibility) so the owner can mark the
    /// document modified. Selecting the active layer does not fire this.
    public var onLayerEdited: (() -> Void)?

    /// Fires for structural changes that invalidate recorded undo history
    /// (currently: layer removal). The owner must clear the undo stack.
    public var onLayerStructureChanged: (() -> Void)?

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
            let visBtn = NSButton(image: NSImage(systemSymbolName: eyeIcon, accessibilityDescription: "Toggle visibility")!,
                                  target: self, action: #selector(toggleVisibility(_:)))
            visBtn.bezelStyle = .inline
            visBtn.tag = i

            // The layer name itself is the selection target: a borderless
            // button styled like a label.
            let isActive = i == doc.activeLayerIndex
            let nameBtn = NSButton(title: layer.name, target: self, action: #selector(selectLayer(_:)))
            nameBtn.isBordered = false
            nameBtn.tag = i
            nameBtn.font = isActive ? .boldSystemFont(ofSize: 11) : .systemFont(ofSize: 11)
            nameBtn.contentTintColor = isActive ? .controlAccentColor : .labelColor
            nameBtn.alignment = .left
            nameBtn.setContentHuggingPriority(.defaultLow, for: .horizontal)

            let delBtn = NSButton(image: NSImage(systemSymbolName: "minus.circle", accessibilityDescription: "Remove layer")!,
                                  target: self, action: #selector(removeLayer(_:)))
            delBtn.bezelStyle = .inline
            delBtn.tag = i
            delBtn.isEnabled = doc.layers.count > 1

            let row = NSStackView(views: [visBtn, nameBtn, delBtn])
            row.orientation = .horizontal
            row.spacing = 4
            stackView.addArrangedSubview(row)
        }
    }

    @objc private func toggleVisibility(_ sender: NSButton) {
        guard let doc = document, sender.tag >= 0, sender.tag < doc.layers.count else { return }
        doc.layers[sender.tag].isVisible.toggle()
        rebuildList()
        onLayerEdited?()
        onLayerChanged?()
    }

    @objc private func selectLayer(_ sender: NSButton) {
        guard let doc = document, sender.tag >= 0, sender.tag < doc.layers.count else { return }
        doc.activeLayerIndex = sender.tag
        rebuildList()
        onLayerChanged?()
    }

    @objc private func addLayer() {
        document?.addLayer()
        rebuildList()
        onLayerEdited?()
        onLayerChanged?()
    }

    @objc private func removeLayer(_ sender: NSButton) {
        guard let doc = document, doc.layers.count > 1,
              sender.tag >= 0, sender.tag < doc.layers.count else { return }
        doc.removeLayer(at: sender.tag)
        rebuildList()
        onLayerStructureChanged?()  // undo history now holds stale indices
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

    /// Number of tile rows to label. Set from the document height so maps
    /// taller than one screen still get a full ruler. Note the raster
    /// numbers only correspond to real VIC-II raster lines within the first
    /// 25 rows (one static screen); beyond that they are extrapolated.
    public var rows = 25 { didSet { needsDisplay = true } }

    // Must be flipped to match MapGridView (y=0 at top)
    override public var isFlipped: Bool { true }

    private let rulerW: CGFloat = 32
    private let rasterTop = 51  // PAL visible area starts at raster line 51

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

