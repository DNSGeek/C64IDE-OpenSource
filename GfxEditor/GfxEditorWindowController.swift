import Cocoa

// ═══════════════════════════════════════════════════════════
// MARK: - Drawing Tool
// ═══════════════════════════════════════════════════════════

enum DrawingTool: String, CaseIterable {
    case pencil = "Pencil"
    case eraser = "Eraser"
    case line = "Line"
    case rectOutline = "Rect"
    case rectFilled = "FillRect"
    case ovalOutline = "Oval"
    case ovalFilled = "FillOval"
    case fill = "Fill"
}

// ═══════════════════════════════════════════════════════════
// MARK: - Graphics Editor Window Controller
// ═══════════════════════════════════════════════════════════

class GfxEditorWindowController: NSWindowController, NSWindowDelegate {

    var isModified = false

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Hi-Res Graphics Editor"
        window.center()
        window.minSize = NSSize(width: 700, height: 500)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = AppTheme.current.panelBackground
        self.init(window: window)
        window.delegate = self

        let editor = GfxEditorViewController()
        editor.onModified = { [weak self] in self?.isModified = true }
        window.contentViewController = editor
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard isModified else { return true }
        let alert = NSAlert()
        alert.messageText = "You have unsaved changes in the Graphics Editor."
        alert.informativeText = "Close without exporting?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc func closeTab(_ sender: Any?) {
        window?.performClose(sender)
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - Graphics Editor View Controller
// ═══════════════════════════════════════════════════════════

class GfxEditorViewController: NSViewController, NSMenuItemValidation {

    private var bitmap = C64Bitmap()
    private var canvasView: BitmapCanvasView!
    private var canvasScroll: NSScrollView!
    private var rasterRulerView: GfxRasterRulerView!
    private var currentTool: DrawingTool = .pencil
    private var toolButtons: [NSButton] = []
    private var colorButtons: [NSButton] = []
    private var modeToggle: NSButton!
    private var zoomSlider: NSSlider!
    private var zoomLabel: NSTextField!
    private var infoLabel: NSTextField!
    private var drawColorIndex: UInt8 = 1
    private var sectionLabels: [NSTextField] = []
    private var dimLabels:     [NSTextField] = []

    var onModified: (() -> Void)?

    override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 680))
        view.wantsLayer = true
        view.layer?.backgroundColor = AppTheme.current.panelBackground.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange(_:)),
            name: .appThemeDidChange, object: nil)
    }

    @objc private func themeDidChange(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.view.window != nil else { return }
            self.applyThemeColors()
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        applyThemeColors()
    }

    private func applyThemeColors() {
        view.window?.appearance      = AppTheme.current.nsAppearance
        view.window?.backgroundColor = AppTheme.current.panelBackground
        view.layer?.backgroundColor  = AppTheme.current.panelBackground.cgColor
        sectionLabels.forEach { $0.textColor = AppTheme.current.syntaxKeyword }
        dimLabels.forEach     { $0.textColor = AppTheme.current.statusLabel }
        zoomLabel?.textColor         = AppTheme.current.statusLabel
        infoLabel?.textColor         = AppTheme.current.statusLabel
        canvasScroll?.backgroundColor = AppTheme.current.panelDetailBackground
        canvasView?.needsDisplay     = true
        rasterRulerView?.needsDisplay = true
    }

    private func buildUI() {
        let w = view.bounds.width
        var y = view.bounds.height - 10

        // ── Tool bar ─────────────────────────────────────
        y -= 28
        let tools = DrawingTool.allCases
        var tx: CGFloat = 12
        for tool in tools {
            let btn = NSButton(title: tool.rawValue, target: self, action: #selector(toolSelected(_:)))
            btn.tag = tools.firstIndex(of: tool)!
            let btnW: CGFloat = CGFloat(tool.rawValue.count) * 7.5 + 14
            btn.frame = NSRect(x: tx, y: y, width: btnW, height: 22)
            btn.font = NSFont.monospacedSystemFont(ofSize: 10, weight: tool == .pencil ? .bold : .medium)
            btn.bezelStyle = .recessed
            btn.state = tool == .pencil ? .on : .off
            view.addSubview(btn)
            toolButtons.append(btn)
            tx += btnW + 2
        }

        // Undo/Redo buttons
        let undoBtn = NSButton(title: "Undo", target: self, action: #selector(undoAction(_:)))
        undoBtn.frame = NSRect(x: tx + 10, y: y, width: 50, height: 22)
        undoBtn.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        view.addSubview(undoBtn)

        let redoBtn = NSButton(title: "Redo", target: self, action: #selector(redoAction(_:)))
        redoBtn.frame = NSRect(x: tx + 65, y: y, width: 50, height: 22)
        redoBtn.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        view.addSubview(redoBtn)

        // Clear button
        let clearBtn = NSButton(title: "Clear", target: self, action: #selector(clearAction(_:)))
        clearBtn.frame = NSRect(x: tx + 120, y: y, width: 50, height: 22)
        clearBtn.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        view.addSubview(clearBtn)

        // Import button
        let importBtn = NSButton(title: "Import…", target: self, action: #selector(importImage(_:)))
        importBtn.frame = NSRect(x: tx + 175, y: y, width: 70, height: 22)
        importBtn.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        view.addSubview(importBtn)

        // Multi-color toggle
        modeToggle = NSButton(checkboxWithTitle: "Multi-Color", target: self, action: #selector(modeChanged(_:)))
        modeToggle.frame = NSRect(x: tx + 255, y: y, width: 100, height: 22)
        let mcAttr = NSAttributedString(string: "Multi-Color", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: AppTheme.current.defaultText,
        ])
        modeToggle.attributedTitle = mcAttr
        view.addSubview(modeToggle)

        let gridToggle = NSButton(checkboxWithTitle: "Grid", target: self, action: #selector(gridChanged(_:)))
        gridToggle.frame = NSRect(x: tx + 360, y: y, width: 55, height: 22)
        gridToggle.state = .on
        let gridAttr = NSAttributedString(string: "Grid", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: AppTheme.current.defaultText,
        ])
        gridToggle.attributedTitle = gridAttr
        view.addSubview(gridToggle)

        // ── Color palette ────────────────────────────────
        y -= 28
        let palLabel = makeLabel("COLOR:", bold: true)
        palLabel.frame = NSRect(x: 12, y: y + 2, width: 55, height: 16)
        view.addSubview(palLabel)

        for i in 0..<16 {
            let btn = NSButton(frame: NSRect(x: 70 + CGFloat(i) * 22, y: y, width: 20, height: 20))
            btn.isBordered = false
            btn.title = ""
            btn.tag = i
            btn.target = self
            btn.action = #selector(colorSelected(_:))
            btn.wantsLayer = true
            let c = NSColor(hex: C64Reference.colorPalette[i].hex) ?? .black
            btn.layer?.backgroundColor = c.cgColor
            btn.layer?.cornerRadius = 3
            btn.layer?.borderColor = (i == 1 ? AppTheme.current.editorSelectionHighlight : AppTheme.current.statusLabel).cgColor
            btn.layer?.borderWidth = i == 1 ? 2 : 1
            view.addSubview(btn)
            colorButtons.append(btn)
        }

        // Zoom
        let zoomLbl = makeLabel("Zoom:", bold: false)
        zoomLbl.frame = NSRect(x: 440, y: y + 2, width: 45, height: 16)
        view.addSubview(zoomLbl)

        zoomSlider = NSSlider(value: 2, minValue: 1, maxValue: 4, target: self, action: #selector(zoomChanged(_:)))
        zoomSlider.frame = NSRect(x: 485, y: y, width: 100, height: 20)
        zoomSlider.numberOfTickMarks = 4
        zoomSlider.allowsTickMarkValuesOnly = true
        view.addSubview(zoomSlider)

        zoomLabel = makeLabel("2×", bold: false)
        zoomLabel.frame = NSRect(x: 590, y: y + 2, width: 30, height: 16)
        view.addSubview(zoomLabel)

        let rasterToggle = NSButton(checkboxWithTitle: "Raster", target: self, action: #selector(rasterChanged(_:)))
        rasterToggle.frame = NSRect(x: 630, y: y, width: 70, height: 22)
        rasterToggle.state = .off
        let rasterAttr = NSAttributedString(string: "Raster", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: AppTheme.current.syntaxKeyword,
        ])
        rasterToggle.attributedTitle = rasterAttr
        view.addSubview(rasterToggle)

        // ── Canvas ───────────────────────────────────────
        y -= 8
        canvasView = BitmapCanvasView(bitmap: bitmap)
        canvasView.zoom = 2
        canvasView.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        canvasView.onPixelDrawn = { [weak self] in
            self?.canvasView.needsDisplay = true
            self?.onModified?()
        }
        canvasView.onInfoUpdate = { [weak self] info in self?.infoLabel.stringValue = info }

        let rulerW: CGFloat = 30
        // Scroll view starts after the ruler, leaving a clean gap on the left
        canvasScroll = NSScrollView(frame: NSRect(x: 12 + rulerW, y: 40, width: w - 24 - rulerW, height: y - 40))
        canvasScroll.autoresizingMask = [.width, .height]
        canvasScroll.documentView = canvasView
        canvasScroll.hasVerticalScroller = true
        canvasScroll.hasHorizontalScroller = true
        canvasScroll.borderType = .noBorder
        canvasScroll.backgroundColor = AppTheme.current.panelDetailBackground
        view.addSubview(canvasScroll)

        // Ruler sits entirely to the LEFT of the scroll view — no overlap ever
        rasterRulerView = GfxRasterRulerView(frame: NSRect(
            x: 12, y: 40, width: rulerW, height: y - 40
        ))
        rasterRulerView.autoresizingMask = [.height]
        rasterRulerView.isHidden = true
        view.addSubview(rasterRulerView)

        // Keep ruler in sync with canvas vertical scroll
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(canvasScrolled(_:)),
            name: NSView.boundsDidChangeNotification,
            object: canvasScroll.contentView
        )

        // ── Bottom bar: info + export ────────────────────
        infoLabel = makeLabel("320×200 Hi-Res — Pencil — Color: 1 (White)", bold: false)
        infoLabel.frame = NSRect(x: 12, y: 14, width: 400, height: 16)
        view.addSubview(infoLabel)

        let exportBtns: [(String, Selector)] = [
            ("Export…", #selector(exportImage(_:))),
            ("Save to D64…", #selector(saveToD64(_:))),
        ]
        var ex: CGFloat = w - 220
        for (title, action) in exportBtns {
            let btn = NSButton(title: title, target: self, action: action)
            btn.frame = NSRect(x: ex, y: 10, width: 100, height: 24)
            btn.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
            btn.autoresizingMask = [.minXMargin]
            view.addSubview(btn)
            ex += 108
        }

        updateCanvasSize()
        updateInfo()
    }

    private func makeLabel(_ text: String, bold: Bool) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: bold ? .bold : .regular)
        label.textColor = bold ? AppTheme.current.syntaxKeyword : AppTheme.current.statusLabel
        if bold { sectionLabels.append(label) } else { dimLabels.append(label) }
        return label
    }

    // MARK: - Actions

    @objc private func toolSelected(_ sender: NSButton) {
        let tools = DrawingTool.allCases
        guard sender.tag < tools.count else { return }
        currentTool = tools[sender.tag]
        canvasView.currentTool = currentTool
        for (i, btn) in toolButtons.enumerated() {
            btn.font = NSFont.monospacedSystemFont(ofSize: 10, weight: i == sender.tag ? .bold : .medium)
            btn.state = i == sender.tag ? .on : .off
        }
        updateInfo()
    }

    @objc private func colorSelected(_ sender: NSButton) {
        drawColorIndex = UInt8(sender.tag)
        bitmap.drawColor = drawColorIndex
        canvasView.needsDisplay = true
        for btn in colorButtons {
            btn.layer?.borderColor = (btn.tag == sender.tag ? NSColor.cyan : NSColor.gray).cgColor
            btn.layer?.borderWidth = btn.tag == sender.tag ? 2 : 1
        }
        updateInfo()
    }

    @objc private func modeChanged(_ sender: NSButton) {
        // The mode switch clears the canvas, so it must be undoable.
        // UndoState snapshots isMultiColor, so undo restores both the
        // pixels and the mode (undoAction re-syncs this checkbox).
        bitmap.saveUndo()
        bitmap.isMultiColor = sender.state == .on
        bitmap.clear()
        canvasView.needsDisplay = true
        updateCanvasSize()
        updateInfo()
        onModified?()
    }

    @objc private func gridChanged(_ sender: NSButton) {
        canvasView.showGrid = sender.state == .on
        canvasView.needsDisplay = true
    }

    @objc private func rasterChanged(_ sender: NSButton) {
        let on = sender.state == .on
        rasterRulerView.isHidden = !on
        canvasView.showRasterRuler = false  // ruler is now drawn by rasterRulerView, not canvas
        canvasView.needsDisplay = true
    }

    @objc private func canvasScrolled(_ notification: Notification) {
        rasterRulerView.scrollOffset = canvasScroll.contentView.bounds.origin.y
        rasterRulerView.needsDisplay = true
    }

    @objc private func zoomChanged(_ sender: NSSlider) {
        let z = sender.integerValue
        canvasView.zoom = z
        zoomLabel.stringValue = "\(z)×"
        rasterRulerView.zoom = CGFloat(z)
        updateCanvasSize()
    }

    @objc private func undoAction(_ sender: Any?) {
        if bitmap.undo() {
            modeToggle.state = bitmap.isMultiColor ? .on : .off
            canvasView.needsDisplay = true
            updateCanvasSize()
            updateInfo()
        }
    }

    @objc private func redoAction(_ sender: Any?) {
        if bitmap.redo() {
            modeToggle.state = bitmap.isMultiColor ? .on : .off
            canvasView.needsDisplay = true
            updateCanvasSize()
            updateInfo()
        }
    }

    @objc private func clearAction(_ sender: Any?) {
        bitmap.saveUndo()
        bitmap.clear()
        canvasView.needsDisplay = true
    }

    // MARK: - Undo / Redo Responder Actions

    @objc func undo(_ sender: Any?) {
        undoAction(sender)
    }

    @objc func redo(_ sender: Any?) {
        redoAction(sender)
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(self)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(undo(_:)) { return bitmap.canUndo }
        if menuItem.action == #selector(redo(_:)) { return bitmap.canRedo }
        return true
    }

    // MARK: - Import

    @objc private func importImage(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .init(filenameExtension: "kla")!,
            .init(filenameExtension: "koa")!,
            .init(filenameExtension: "art")!,
            .init(filenameExtension: "ocp")!,
            .init(filenameExtension: "bin")!,
            .init(filenameExtension: "prg")!,
        ]
        panel.allowsOtherFileTypes = true
        panel.title = "Import C64 Image"
        panel.message = "Open a Koala Painter (.kla/.koa) or Art Studio (.art/.ocp) file"

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self = self else { return }
            guard let data = try? Data(contentsOf: url) else {
                self.showImportError("Could not read file.")
                return
            }

            self.bitmap.saveUndo()

            let ext = url.pathExtension.lowercased()
            let success: Bool

            if ext == "kla" || ext == "koa" {
                success = self.bitmap.importKoala(data)
            } else if ext == "art" || ext == "ocp" {
                success = self.bitmap.importArtStudio(data)
            } else {
                // Auto-detect by size
                if data.count >= 10001 && data.count <= 10003 {
                    success = self.bitmap.importKoala(data)
                } else if data.count >= 9000 && data.count <= 9002 {
                    success = self.bitmap.importArtStudio(data)
                } else {
                    self.showImportError("Unrecognized file format (\(data.count) bytes). Expected Koala (10003) or Art Studio (9002).")
                    return
                }
            }

            if success {
                self.modeToggle.state = self.bitmap.isMultiColor ? .on : .off
                self.canvasView.needsDisplay = true
                self.updateCanvasSize()
                self.updateInfo()
                self.onModified?()
            } else {
                self.showImportError("File format not recognized or data is corrupt.")
            }
        }
    }

    private func showImportError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Import Failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func updateCanvasSize() {
        let z = canvasView.zoom
        canvasView.frame = NSRect(x: 0, y: 0, width: 320 * z, height: 200 * z)
    }

    private func updateInfo() {
        let mode = bitmap.isMultiColor ? "160×200 Multi-Color" : "320×200 Hi-Res"
        let colorName = C64Reference.colorPalette[Int(drawColorIndex)].name
        infoLabel.stringValue = "\(mode) — \(currentTool.rawValue) — Color: \(drawColorIndex) (\(colorName))"
    }

    // MARK: - Export

    @objc private func exportImage(_ sender: Any?) {
        let panel = NSSavePanel()

        let accessory = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        if bitmap.isMultiColor {
            accessory.addItems(withTitles: ["Koala Painter (.kla)", "Raw Binary (.bin)", "Assembly (.asm)", "BASIC DATA (.bas)", "PRG (.prg)"])
        } else {
            accessory.addItems(withTitles: ["Art Studio (.art)", "Raw Binary (.bin)", "Assembly (.asm)", "BASIC DATA (.bas)", "PRG (.prg)"])
        }
        panel.accessoryView = accessory

        let baseName = bitmap.isMultiColor ? "image.kla" : "image.art"
        panel.nameFieldStringValue = baseName
        panel.title = "Export Image"

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self = self else { return }
            let format = accessory.indexOfSelectedItem

            switch format {
            case 0:
                let data = self.bitmap.isMultiColor ? self.bitmap.exportKoala() : self.bitmap.exportArtStudio()
                try? data.write(to: url)
            case 1:
                try? self.bitmap.exportRawBinary().write(to: url)
            case 2:
                try? self.bitmap.exportAsAssembly().write(to: url, atomically: true, encoding: .utf8)
            case 3:
                try? self.bitmap.exportAsBASIC().write(to: url, atomically: true, encoding: .utf8)
            case 4:
                try? self.bitmap.exportAsPRG().write(to: url)
            default: break
            }
        }
    }

    @objc private func saveToD64(_ sender: Any?) {
        // Ask for filename and format
        let alert = NSAlert()
        alert.messageText = "Save Image to D64"
        alert.informativeText = "Enter a filename for the disk image entry:"

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))

        let nameLabel = NSTextField(labelWithString: "Name:")
        nameLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        nameLabel.frame = NSRect(x: 0, y: 36, width: 50, height: 20)
        accessory.addSubview(nameLabel)

        let nameField = NSTextField(string: "IMAGE")
        nameField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        nameField.frame = NSRect(x: 55, y: 36, width: 200, height: 22)
        accessory.addSubview(nameField)

        let formatLabel = NSTextField(labelWithString: "Format:")
        formatLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        formatLabel.frame = NSRect(x: 0, y: 6, width: 50, height: 20)
        accessory.addSubview(formatLabel)

        let formatPicker = NSPopUpButton(frame: NSRect(x: 55, y: 4, width: 200, height: 24))
        if bitmap.isMultiColor {
            formatPicker.addItems(withTitles: ["Koala Painter", "Raw Binary", "PRG (self-displaying)"])
        } else {
            formatPicker.addItems(withTitles: ["Art Studio", "Raw Binary", "PRG (self-displaying)"])
        }
        formatPicker.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        accessory.addSubview(formatPicker)

        alert.accessoryView = accessory
        alert.addButton(withTitle: "New D64…")
        alert.addButton(withTitle: "Existing D64…")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        guard response != .alertThirdButtonReturn else { return }

        let filename = nameField.stringValue.uppercased().prefix(16)
        let format = formatPicker.indexOfSelectedItem

        let prgData: Data
        switch format {
        case 0: prgData = bitmap.isMultiColor ? bitmap.exportKoala() : bitmap.exportArtStudio()
        case 1: prgData = bitmap.exportRawBinary()
        case 2: prgData = bitmap.exportAsPRG()
        default: return
        }

        if response == .alertFirstButtonReturn {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.init(filenameExtension: "d64")!]
            panel.nameFieldStringValue = "\(filename.lowercased()).d64"
            panel.begin { saveResponse in
                guard saveResponse == .OK, let url = panel.url else { return }
                let disk = D64Image(diskName: String(filename), diskID: "GX")
                if disk.writeFile(name: String(filename), data: Array(prgData)) {
                    try? disk.save(to: url)
                }
            }
        } else if response == .alertSecondButtonReturn {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.init(filenameExtension: "d64")!]
            panel.begin { openResponse in
                guard openResponse == .OK, let url = panel.url else { return }
                if let disk = try? D64Image(contentsOf: url) {
                    if disk.writeFile(name: String(filename), data: Array(prgData)) {
                        try? disk.save()
                    }
                }
            }
        }
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - Bitmap Canvas View
// ═══════════════════════════════════════════════════════════

class BitmapCanvasView: NSView {

    private let bitmap: C64Bitmap
    var zoom: Int = 2
    var currentTool: DrawingTool = .pencil
    var showGrid: Bool = true
    var showRasterRuler: Bool = false
    var onPixelDrawn: (() -> Void)?
    var onInfoUpdate: ((String) -> Void)?

    // Tool state
    private var isDrawing = false
    private var dragStart: (x: Int, y: Int)?
    private var dragEnd: (x: Int, y: Int)?

    // Flash overlay: tracks cells currently flashing (cellCol, cellRow) → fade deadline
    private var flashLayer: CALayer?
    private var flashingCells: [(col: Int, row: Int, deadline: Date)] = []
    private var flashTimer: Timer?

    init(bitmap: C64Bitmap) {
        self.bitmap = bitmap
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    // MARK: - Flash Animation

    /// Flash the 8×8 cell at (cellCol, cellRow) to signal a color conflict.
    func flashConflictCell(cellCol: Int, cellRow: Int) {
        // Append this cell; duplicates are fine — they'll just extend the flash
        flashingCells.append((col: cellCol, row: cellRow, deadline: Date(timeIntervalSinceNow: 0.45)))

        // Kick off the display timer if not already running
        if flashTimer == nil {
            flashTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                self?.tickFlash()
            }
        }
    }

    private func tickFlash() {
        let now = Date()
        flashingCells.removeAll { $0.deadline < now }
        needsDisplay = true
        if flashingCells.isEmpty {
            flashTimer?.invalidate()
            flashTimer = nil
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Background
        let bgColor = NSColor(hex: C64Reference.colorPalette[Int(bitmap.backgroundColor)].hex) ?? .black
        bgColor.setFill()
        bounds.fill()

        let z = CGFloat(zoom)
        let pixelW = bitmap.isMultiColor ? z * 2 : z
        let maxX = bitmap.isMultiColor ? 160 : 320

        // Draw pixels
        for y in 0..<200 {
            for x in 0..<maxX {
                let colorIdx = bitmap.displayColor(x: bitmap.isMultiColor ? x * 2 : x, y: y)
                if colorIdx != bitmap.backgroundColor {
                    let c = NSColor(hex: C64Reference.colorPalette[Int(colorIdx)].hex) ?? .black
                    c.setFill()
                    NSRect(x: CGFloat(x) * pixelW, y: CGFloat(y) * z, width: pixelW, height: z).fill()
                }
            }
        }

        // Cell grid (light overlay)
        if showGrid && zoom >= 2 {
            NSColor(white: AppTheme.current.isDark ? 0.2 : 0.5, alpha: 0.3).setStroke()
            for col in 0...40 {
                let x = CGFloat(col) * 8 * z
                NSBezierPath.strokeLine(from: NSPoint(x: x, y: 0), to: NSPoint(x: x, y: 200 * z))
            }
            for row in 0...25 {
                let y = CGFloat(row) * 8 * z
                NSBezierPath.strokeLine(from: NSPoint(x: 0, y: y), to: NSPoint(x: 320 * z, y: y))
            }
        }

        // Flash overlay for conflicting cells
        let now = Date()
        for cell in flashingCells {
            let remaining = cell.deadline.timeIntervalSince(now)
            let alpha = CGFloat(max(0, min(1, remaining / 0.45)))  // fade out over full duration
            NSColor(red: 1.0, green: 0.2, blue: 0.0, alpha: 0.55 * alpha).setFill()
            let cellRect = NSRect(
                x: CGFloat(cell.col) * 8 * z,
                y: CGFloat(cell.row) * 8 * z,
                width: 8 * z,
                height: 8 * z
            )
            cellRect.fill()
            // Bright border
            NSColor(red: 1.0, green: 0.6, blue: 0.0, alpha: 0.9 * alpha).setStroke()
            let border = NSBezierPath(rect: cellRect.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1.5
            border.stroke()
        }

        // Shape preview during drag
        if let start = dragStart, let end = dragEnd,
           currentTool != .pencil && currentTool != .eraser && currentTool != .fill {
            AppTheme.current.editorSelectionHighlight.withAlphaComponent(0.5).setStroke()
            let path = NSBezierPath()
            path.lineWidth = 1
            let x1 = CGFloat(start.x) * z
            let y1 = CGFloat(start.y) * z
            let x2 = CGFloat(end.x) * z
            let y2 = CGFloat(end.y) * z

            switch currentTool {
            case .line:
                path.move(to: NSPoint(x: x1, y: y1))
                path.line(to: NSPoint(x: x2, y: y2))
            case .rectOutline, .rectFilled:
                let r = NSRect(x: min(x1, x2), y: min(y1, y2), width: abs(x2 - x1), height: abs(y2 - y1))
                path.appendRect(r)
            case .ovalOutline, .ovalFilled:
                let r = NSRect(x: min(x1, x2), y: min(y1, y2), width: abs(x2 - x1), height: abs(y2 - y1))
                path.appendOval(in: r)
            default: break
            }
            path.stroke()
        }

        // Raster line ruler — drawn last so it sits on top of everything
        if showRasterRuler {
            let rulerW: CGFloat = 26
            // Semi-transparent dark background strip
            NSColor(white: AppTheme.current.isDark ? 0.0 : 0.85, alpha: 0.65).setFill()
            NSRect(x: 0, y: 0, width: rulerW, height: CGFloat(200) * z).fill()

            let font = NSFont.monospacedSystemFont(ofSize: max(8, z * 2.5), weight: .regular)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: AppTheme.current.syntaxKeyword.withAlphaComponent(0.9),
            ]
            // One label per character row (every 8 pixel rows)
            // PAL visible area starts at raster 51
            let rasterTop = 51
            for charRow in 0..<25 {
                let raster = rasterTop + charRow * 8
                let label = "\(raster)" as NSString
                let rowY = CGFloat(charRow) * 8 * z
                // Tick mark at character boundary
                AppTheme.current.syntaxKeyword.withAlphaComponent(0.5).setStroke()
                NSBezierPath.strokeLine(
                    from: NSPoint(x: rulerW, y: rowY),
                    to:   NSPoint(x: rulerW + 4, y: rowY)
                )
                // Label centered in the character row
                let labelSize = label.size(withAttributes: attrs)
                let labelY = rowY + (8 * z - labelSize.height) / 2
                let labelX = (rulerW - labelSize.width) / 2
                if labelSize.height <= 8 * z {
                    label.draw(at: NSPoint(x: labelX, y: labelY), withAttributes: attrs)
                }
            }
        }
    }

    // MARK: - Mouse → Pixel Coordinates

    private func pixelCoord(from event: NSEvent) -> (x: Int, y: Int) {
        let pt = convert(event.locationInWindow, from: nil)
        let z = CGFloat(zoom)
        let x = Int(pt.x / z)
        let y = Int(pt.y / z)
        return (max(0, min(319, x)), max(0, min(199, y)))
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        let (x, y) = pixelCoord(from: event)
        bitmap.saveUndo()
        isDrawing = true
        dragStart = (x, y)
        dragEnd = (x, y)

        switch currentTool {
        case .pencil:
            handleDrawResult(bitmap.trySetPixel(x: x, y: y, color: bitmap.drawColor), pixelX: x, pixelY: y)
        case .eraser:
            bitmap.setPixel(x: x, y: y, value: 0)
            onPixelDrawn?()
        case .fill:
            floodFill(x: x, y: y, targetColor: bitmap.getPixel(x: x, y: y), fillColor: bitmap.drawColor)
            onPixelDrawn?()
        default:
            needsDisplay = true
        }

        onInfoUpdate?("(\(x), \(y))")
    }

    override func mouseDragged(with event: NSEvent) {
        let (x, y) = pixelCoord(from: event)
        dragEnd = (x, y)

        switch currentTool {
        case .pencil:
            if let start = dragStart {
                drawLine(x0: start.x, y0: start.y, x1: x, y1: y, color: bitmap.drawColor)
                dragStart = (x, y)
            }
            onPixelDrawn?()
        case .eraser:
            if let start = dragStart {
                drawLine(x0: start.x, y0: start.y, x1: x, y1: y, color: 0)
                dragStart = (x, y)
            }
            onPixelDrawn?()
        default:
            needsDisplay = true
        }

        onInfoUpdate?("(\(x), \(y))")
    }

    override func mouseUp(with event: NSEvent) {
        let (x, y) = pixelCoord(from: event)
        dragEnd = (x, y)

        guard let start = dragStart else { isDrawing = false; return }

        switch currentTool {
        case .line:
            drawLine(x0: start.x, y0: start.y, x1: x, y1: y, color: bitmap.drawColor)
        case .rectOutline:
            drawRect(x0: start.x, y0: start.y, x1: x, y1: y, color: bitmap.drawColor, filled: false)
        case .rectFilled:
            drawRect(x0: start.x, y0: start.y, x1: x, y1: y, color: bitmap.drawColor, filled: true)
        case .ovalOutline:
            drawOval(x0: start.x, y0: start.y, x1: x, y1: y, color: bitmap.drawColor, filled: false)
        case .ovalFilled:
            drawOval(x0: start.x, y0: start.y, x1: x, y1: y, color: bitmap.drawColor, filled: true)
        default: break
        }

        isDrawing = false
        dragStart = nil
        dragEnd = nil
        onPixelDrawn?()
    }

    // MARK: - Color Conflict Handling

    /// Handle the result of a `trySetPixel` call. On conflict, flash the cell and — for
    /// multi-color mode — present the slot-replacement sheet.
    private func handleDrawResult(_ result: C64Bitmap.DrawPixelResult, pixelX: Int, pixelY: Int) {
        switch result {
        case .ok:
            onPixelDrawn?()
        case .conflict(let cellCol, let cellRow, let resolve):
            flashConflictCell(cellCol: cellCol, cellRow: cellRow)
            if let resolve = resolve {
                // Multi-color: ask the user which slot to evict
                presentMultiColorConflictSheet(cellCol: cellCol, cellRow: cellRow,
                                               color: bitmap.drawColor,
                                               pixelX: pixelX, pixelY: pixelY,
                                               resolve: resolve)
            }
            // Hi-res with no resolve closure: flash only, draw is rejected
        }
    }

    /// Present a sheet asking which multi-color slot should be replaced.
    private func presentMultiColorConflictSheet(cellCol: Int, cellRow: Int,
                                                 color: UInt8, pixelX: Int, pixelY: Int,
                                                 resolve: @escaping (C64Bitmap.MultiColorSlot) -> Void) {
        guard let window = self.window else { return }

        let colorName = C64Reference.colorPalette[Int(color)].name
        let alert = NSAlert()
        alert.messageText = "Cell Color Limit Reached"
        alert.informativeText = """
            Cell (\(cellCol), \(cellRow)) already uses all 4 multi-color slots. \
            Choose a slot to replace with \(colorName) (color \(color)):
            """
        alert.alertStyle = .warning

        // Add one button per slot
        for slot in C64Bitmap.MultiColorSlot.allCases {
            alert.addButton(withTitle: slot.label)
        }
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            // NSAlert buttons are numbered from .alertFirstButtonReturn
            let slotIndex = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            guard slotIndex >= 0, slotIndex < C64Bitmap.MultiColorSlot.allCases.count else { return }
            let slot = C64Bitmap.MultiColorSlot.allCases[slotIndex]
            resolve(slot)
            self.onPixelDrawn?()
            self.needsDisplay = true
        }
    }

    // MARK: - Drawing Primitives

    /// Bresenham line — uses trySetPixel for color enforcement.
    /// Conflicts during a drag are flashed but don't stop the line; the conflicting
    /// pixels are simply skipped (the line keeps going through non-conflicting cells).
    private func drawLine(x0: Int, y0: Int, x1: Int, y1: Int, color: UInt8) {
        var x = x0, y = y0
        let dx = abs(x1 - x0), dy = -abs(y1 - y0)
        let sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1
        var err = dx + dy

        while true {
            if color == 0 {
                bitmap.setPixel(x: x, y: y, value: 0)   // eraser: always allowed
            } else {
                let result = bitmap.trySetPixel(x: x, y: y, color: color)
                if case .conflict(let col, let row, _) = result {
                    flashConflictCell(cellCol: col, cellRow: row)
                }
            }
            if x == x1 && y == y1 { break }
            let e2 = 2 * err
            if e2 >= dy { err += dy; x += sx }
            if e2 <= dx { err += dx; y += sy }
        }
    }

    /// Rectangle (outline or filled)
    private func drawRect(x0: Int, y0: Int, x1: Int, y1: Int, color: UInt8, filled: Bool) {
        let minX = min(x0, x1), maxX = max(x0, x1)
        let minY = min(y0, y1), maxY = max(y0, y1)

        if filled {
            for y in minY...maxY {
                for x in minX...maxX {
                    if color == 0 {
                        bitmap.setPixel(x: x, y: y, value: 0)
                    } else {
                        let result = bitmap.trySetPixel(x: x, y: y, color: color)
                        if case .conflict(let col, let row, _) = result {
                            flashConflictCell(cellCol: col, cellRow: row)
                        }
                    }
                }
            }
        } else {
            drawLine(x0: minX, y0: minY, x1: maxX, y1: minY, color: color)
            drawLine(x0: maxX, y0: minY, x1: maxX, y1: maxY, color: color)
            drawLine(x0: maxX, y0: maxY, x1: minX, y1: maxY, color: color)
            drawLine(x0: minX, y0: maxY, x1: minX, y1: minY, color: color)
        }
    }

    /// Oval (midpoint ellipse algorithm)
    private func drawOval(x0: Int, y0: Int, x1: Int, y1: Int, color: UInt8, filled: Bool) {
        let cx = (x0 + x1) / 2, cy = (y0 + y1) / 2
        let rx = abs(x1 - x0) / 2, ry = abs(y1 - y0) / 2
        guard rx > 0, ry > 0 else { return }

        if filled {
            // Scanline approximation using ellipse equation: x = rx * sqrt(1 - (dy/ry)^2)
            for y in (cy - ry)...(cy + ry) {
                let dy = Double(y - cy)
                let halfWidth = Double(rx) * sqrt(max(0, 1.0 - (dy * dy) / Double(ry * ry)))
                let startX = cx - Int(halfWidth)
                let endX = cx + Int(halfWidth)
                for x in startX...endX {
                    if color == 0 {
                        bitmap.setPixel(x: x, y: y, value: 0)
                    } else {
                        let result = bitmap.trySetPixel(x: x, y: y, color: color)
                        if case .conflict(let col, let row, _) = result {
                            flashConflictCell(cellCol: col, cellRow: row)
                        }
                    }
                }
            }
        } else {
            let steps = max(rx, ry) * 4
            for i in 0...steps {
                let angle = 2.0 * Double.pi * Double(i) / Double(steps)
                let x = cx + Int(Double(rx) * cos(angle))
                let y = cy + Int(Double(ry) * sin(angle))
                if color == 0 {
                    bitmap.setPixel(x: x, y: y, value: 0)
                } else {
                    let result = bitmap.trySetPixel(x: x, y: y, color: color)
                    if case .conflict(let col, let row, _) = result {
                        flashConflictCell(cellCol: col, cellRow: row)
                    }
                }
            }
        }
    }

    /// Flood fill (iterative, stack-based)
    private func floodFill(x startX: Int, y startY: Int, targetColor: UInt8, fillColor: UInt8) {
        guard targetColor != fillColor else { return }
        let maxX = bitmap.isMultiColor ? 160 : 320

        var stack: [(Int, Int)] = [(startX, startY)]
        var visited = Set<Int>()

        while let (x, y) = stack.popLast() {
            let key = y * maxX + x
            guard !visited.contains(key) else { continue }
            guard x >= 0, x < maxX, y >= 0, y < 200 else { continue }
            let sx = bitmap.isMultiColor ? x * 2 : x
            guard bitmap.getPixel(x: sx, y: y) == targetColor else { continue }

            visited.insert(key)
            if fillColor == 0 {
                bitmap.setPixel(x: sx, y: y, value: 0)
            } else {
                let result = bitmap.trySetPixel(x: sx, y: y, color: fillColor)
                if case .conflict(let col, let row, _) = result {
                    flashConflictCell(cellCol: col, cellRow: row)
                    // Don't propagate fill into conflicting cells
                    continue
                }
            }

            stack.append((x + 1, y))
            stack.append((x - 1, y))
            stack.append((x, y + 1))
            stack.append((x, y - 1))
        }
    }
}

// MARK: - Gfx Raster Ruler View

/// A thin view that floats over the left edge of the canvas scroll view,
/// showing raster line numbers at every character row boundary (every 8px rows).
/// Scrolls in sync with the canvas via `scrollOffset`.
class GfxRasterRulerView: NSView {

    var zoom: CGFloat = 2.0 { didSet { needsDisplay = true } }
    var scrollOffset: CGFloat = 0 { didSet { needsDisplay = true } }

    // Must be flipped to match BitmapCanvasView (y=0 at top)
    override var isFlipped: Bool { true }

    private let rulerW: CGFloat = 30
    private let rasterTop = 51  // PAL standard: visible raster starts at line 51

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: AppTheme.current.isDark ? 0.0 : 0.85, alpha: 0.75).setFill()
        bounds.fill()

        let z = zoom
        let font = NSFont.monospacedSystemFont(ofSize: max(8, min(11, z * 2.8)), weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: AppTheme.current.syntaxKeyword.withAlphaComponent(0.95),
        ]
        let tickColor = AppTheme.current.syntaxKeyword.withAlphaComponent(0.5)

        for charRow in 0..<25 {
            let raster = rasterTop + charRow * 8
            let rowY = CGFloat(charRow) * 8 * z - scrollOffset

            guard rowY >= -8 * z && rowY <= bounds.height else { continue }

            tickColor.setStroke()
            NSBezierPath.strokeLine(
                from: NSPoint(x: rulerW - 4, y: rowY),
                to:   NSPoint(x: rulerW,     y: rowY)
            )

            let label = "\(raster)" as NSString
            let labelSize = label.size(withAttributes: attrs)
            let rowH = 8 * z
            if labelSize.height <= rowH {
                let labelX = (rulerW - 4 - labelSize.width) / 2
                let labelY = rowY + (rowH - labelSize.height) / 2
                label.draw(at: NSPoint(x: labelX, y: labelY), withAttributes: attrs)
            }
        }

        AppTheme.current.syntaxKeyword.withAlphaComponent(0.3).setStroke()
        NSBezierPath.strokeLine(
            from: NSPoint(x: rulerW - 0.5, y: 0),
            to:   NSPoint(x: rulerW - 0.5, y: bounds.height)
        )
    }
}

