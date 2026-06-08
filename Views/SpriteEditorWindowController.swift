import Cocoa

// ═══════════════════════════════════════════════════════════
// MARK: - Sprite Editor Window Controller
// ═══════════════════════════════════════════════════════════

/// Manages the Sprite Editor's main window, including close handling and unsaved changes prompting.
class SpriteEditorWindowController: NSWindowController, NSWindowDelegate {

    var isModified = false

    /// Initializes the editor window and its content view controller.
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sprite Editor"
        window.center()
        window.minSize = NSSize(width: 700, height: 620)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = AppTheme.current.editorBackground

        self.init(window: window)
        window.delegate = self

        let editor = SpriteEditorViewController()
        editor.onModified = { [weak self] in self?.isModified = true }
        window.contentViewController = editor
    }

    /// Prompts the user to save changes before closing the window.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard isModified else { return true }
        let alert = NSAlert()
        alert.messageText = "You have unsaved changes in the Sprite Editor."
        alert.informativeText = "Close without exporting?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Intercepts ⌘W ("Close Tab" menu item) so it closes this window instead of propagating to AppDelegate.
    @objc func closeTab(_ sender: Any?) {
        window?.performClose(sender)
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - Sprite Data Model
// ═══════════════════════════════════════════════════════════

/// Represents a single sprite frame's pixel data and associated color metadata.
/// Coordinate system: rows 0..20 (top to bottom), cols 0..23 (left to right).
class SpriteData {
    /// 24x21 pixel grid. Values:
    /// Hi-res: 0 = transparent, 1 = sprite color
    /// Multi-color: 0 = transparent, 1 = multi-color 1, 2 = sprite color, 3 = multi-color 2
    var pixels: [[UInt8]] = Array(repeating: Array(repeating: 0, count: 24), count: 21)
    var isMultiColor: Bool = false
    var spriteColor: Int = 1      // C64 color index (0-15)
    var multiColor1: Int = 11     // Shared multi-color 1 (default: dark gray)
    var multiColor2: Int = 15     // Shared multi-color 2 (default: light gray)
    var backgroundColor: Int = 6  // For preview (default: blue)

    /// Converts the pixel grid into 63 bytes of sprite data suitable for C64 export.
    /// In multi-color mode, every 2 adjacent pixels are packed into a single byte.
    func toBytes() -> [UInt8] {
        var bytes: [UInt8] = []

        for row in 0..<21 {
            if isMultiColor {
                // Multi-color: 12 pixel-pairs per row = 3 bytes
                for byteCol in 0..<3 {
                    var byte: UInt8 = 0
                    for pixelPair in 0..<4 {
                        let col = byteCol * 4 + pixelPair
                        // Pack 2-bit values into the byte (MSB first)
                        byte |= pixels[row][col] << (6 - pixelPair * 2)
                    }
                    bytes.append(byte)
                }
            } else {
                // Hi-res: 24 pixels per row = 3 bytes
                for byteCol in 0..<3 {
                    var byte: UInt8 = 0
                    for bit in 0..<8 {
                        let col = byteCol * 8 + bit
                        if pixels[row][col] != 0 {
                            byte |= 1 << (7 - bit)
                        }
                    }
                    bytes.append(byte)
                }
            }
        }

        return bytes
    }

    /// Loads sprite data from a 63-byte array back into the pixel grid.
    func fromBytes(_ data: [UInt8]) {
        guard data.count >= 63 else { return }

        for row in 0..<21 {
            if isMultiColor {
                for byteCol in 0..<3 {
                    let byte = data[row * 3 + byteCol]
                    for pixelPair in 0..<4 {
                        let col = byteCol * 4 + pixelPair
                        pixels[row][col] = (byte >> (6 - pixelPair * 2)) & 0x03
                    }
                }
            } else {
                for byteCol in 0..<3 {
                    let byte = data[row * 3 + byteCol]
                    for bit in 0..<8 {
                        let col = byteCol * 8 + bit
                        pixels[row][col] = (byte >> (7 - bit)) & 0x01
                    }
                }
            }
        }
    }

    /// Clears all pixels to transparent (0).
    func clear() {
        pixels = Array(repeating: Array(repeating: UInt8(0), count: 24), count: 21)
    }

    /// Creates a deep copy of the current sprite data.
    func deepCopy() -> SpriteData {
        let copy = SpriteData()
        copy.pixels = pixels.map { $0 }
        copy.isMultiColor = isMultiColor
        copy.spriteColor = spriteColor
        copy.multiColor1 = multiColor1
        copy.multiColor2 = multiColor2
        copy.backgroundColor = backgroundColor
        return copy
    }

    /// Shifts all pixels by (dx, dy). If `wrap` is true, pixels wrap around edges.
    func shiftPixels(dx: Int, dy: Int, wrap: Bool) {
        let cols = isMultiColor ? 12 : 24
        var newPixels = Array(repeating: Array(repeating: UInt8(0), count: 24), count: 21)

        for row in 0..<21 {
            for col in 0..<cols {
                var srcRow = row - dy
                var srcCol = col - dx
                if wrap {
                    srcRow = ((srcRow % 21) + 21) % 21
                    srcCol = ((srcCol % cols) + cols) % cols
                }
                if srcRow >= 0 && srcRow < 21 && srcCol >= 0 && srcCol < cols {
                    newPixels[row][col] = pixels[srcRow][srcCol]
                }
            }
        }
        pixels = newPixels
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - Sprite Editor View Controller
// ═══════════════════════════════════════════════════════════

/// Manages the Sprite Editor's UI, frame management, animation, and export/import logic.
/// Layout strategy: Views are positioned using manual frames. Y=0 is at the bottom of the view
/// (due to `isFlipped = true` on custom views), so layout calculations proceed bottom-up.
class SpriteEditorViewController: NSViewController, NSMenuItemValidation {

    // ── Frame Data ────────────────────────────────────────
    private var frames: [SpriteData] = [SpriteData()]
    private var currentFrame: Int = 0
    private var spriteData: SpriteData { frames[currentFrame] }

    /// Clipboard storage for frame copy/paste operations.
    private var frameClipboard: SpriteData?

    // ── Undo System ───────────────────────────────────────
    private struct UndoSnapshot {
        let frames: [SpriteData]
        let currentFrame: Int
        let label: String
    }
    private var undoStack: [UndoSnapshot] = []
    private var redoStack: [UndoSnapshot] = []
    private let maxUndoLevels = 50

    // ── Animation ─────────────────────────────────────────
    private var animTimer: Timer?
    private var isPlaying: Bool = false
    private var animBg: NSView!
    private var sectionLabels: [NSTextField] = []
    private var dimLabels:     [NSTextField] = []
    private var animFPS: Double = 6
    private var pingPong: Bool = false
    private var animDirection: Int = 1  // 1 = forward, -1 = reverse (for ping-pong)

    // ── Onion Skinning ────────────────────────────────────
    private var onionSkinEnabled: Bool = false
    private var onionSkinFrames: Int = 1
    private var onionSkinOpacity: CGFloat = 0.25

    // ── UI Elements ───────────────────────────────────────
    private var gridView: SpriteGridView!
    private var preview1: SpritePreviewView!
    private var colorPicker: SpriteColorPickerView!
    private var exportTextView: NSTextView!
    private var exportScrollView: NSScrollView!
    private var multiColorToggle: NSButton!
    private var formatSelector: NSPopUpButton!

    // ── Animation Strip UI ────────────────────────────────
    private var animStripScroll: NSScrollView!
    private var animStripView: AnimationStripView!
    private var frameLabel: NSTextField!
    private var playBtn: NSButton!
    private var fpsLabel: NSTextField!
    private var pingPongBtn: NSButton!
    private var onionSkinBtn: NSButton!
    private var onionOpacitySlider: NSSlider!

    /// Closure called when any editable state changes.
    var onModified: (() -> Void)?

    // MARK: - Undo / Redo

    /// Captures the current state before a mutation. Must be called BEFORE modifying frames/pixels.
    private func pushUndo(_ label: String) {
        let snapshot = UndoSnapshot(
            frames: frames.map { $0.deepCopy() },
            currentFrame: currentFrame,
            label: label
        )
        undoStack.append(snapshot)
        if undoStack.count > maxUndoLevels {
            undoStack.removeFirst()
        }
        // New edits invalidate the redo stack
        redoStack.removeAll()
    }

    private func performUndo() {
        guard let snapshot = undoStack.popLast() else { return }
        let redoSnapshot = UndoSnapshot(
            frames: frames.map { $0.deepCopy() },
            currentFrame: currentFrame,
            label: snapshot.label
        )
        redoStack.append(redoSnapshot)
        restoreSnapshot(snapshot)
    }

    private func performRedo() {
        guard let snapshot = redoStack.popLast() else { return }
        let undoSnapshot = UndoSnapshot(
            frames: frames.map { $0.deepCopy() },
            currentFrame: currentFrame,
            label: snapshot.label
        )
        undoStack.append(undoSnapshot)
        restoreSnapshot(snapshot)
    }

    private func restoreSnapshot(_ snapshot: UndoSnapshot) {
        stopAnimation()
        frames = snapshot.frames
        animStripView?.frames = frames
        resizeAnimStrip()
        switchToFrame(min(snapshot.currentFrame, frames.count - 1))
    }

    override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 780, height: 720))
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
        view.window?.backgroundColor = AppTheme.current.editorBackground
        view.layer?.backgroundColor  = AppTheme.current.editorBackground.cgColor
        animBg?.layer?.backgroundColor = AppTheme.current.panelBackground.cgColor
        sectionLabels.forEach { $0.textColor = AppTheme.current.syntaxKeyword }
        dimLabels.forEach     { $0.textColor = AppTheme.current.statusLabel }
        frameLabel?.textColor        = AppTheme.current.statusLabel
        fpsLabel?.textColor          = AppTheme.current.statusLabel
        exportTextView?.backgroundColor  = AppTheme.current.panelDetailBackground
        exportTextView?.textColor        = AppTheme.current.syntaxFunction
        exportScrollView?.backgroundColor = AppTheme.current.panelDetailBackground
        multiColorToggle?.contentTintColor = AppTheme.current.defaultText
        gridView?.needsDisplay       = true
        preview1?.needsDisplay       = true
        colorPicker?.needsDisplay    = true
        animStripView?.needsDisplay  = true
    }

    // ── Layout Constants ─────────────────────────────────
    private var bgColor: NSColor { AppTheme.current.editorBackground }
    private var panelBg: NSColor { AppTheme.current.panelDetailBackground }
    private let animStripHeight: CGFloat = 140
    private let exportHeight: CGFloat = 130

    private func buildUI() {
        view.wantsLayer = true
        view.layer?.backgroundColor = bgColor.cgColor

        // ── Grid (left side, above the bottom panels) ────
        gridView = SpriteGridView(spriteData: spriteData)
        gridView.frame = NSRect(x: 20, y: animStripHeight + exportHeight + 10, width: 432, height: 378)
        gridView.autoresizingMask = [.minYMargin]
        gridView.onStrokeStart = { [weak self] in
            self?.pushUndo("Draw")
        }
        gridView.onPixelChanged = { [weak self] in
            self?.updatePreview()
            self?.updateExport()
            self?.onModified?()
        }
        view.addSubview(gridView)

        // ── Right panel ──────────────────────────────────
        let rightX: CGFloat = 470
        let rightTop = animStripHeight + exportHeight + 10

        let previewLabel = makeLabel("PREVIEW", x: rightX, y: rightTop + 388, bold: true)
        view.addSubview(previewLabel)

        preview1 = SpritePreviewView(spriteData: spriteData)
        preview1.frame = NSRect(x: rightX, y: rightTop + 300, width: 128, height: 112)
        preview1.scaleFactor = 4
        preview1.autoresizingMask = [.minYMargin]
        view.addSubview(preview1)

        multiColorToggle = NSButton(checkboxWithTitle: "Multi-Color Mode", target: self, action: #selector(toggleMultiColor(_:)))
        multiColorToggle.frame = NSRect(x: rightX, y: rightTop + 272, width: 200, height: 20)
        multiColorToggle.autoresizingMask = [.minYMargin]
        multiColorToggle.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        multiColorToggle.contentTintColor = AppTheme.current.defaultText
        view.addSubview(multiColorToggle)

        let colorLabel = makeLabel("COLORS", x: rightX, y: rightTop + 252, bold: true)
        colorLabel.autoresizingMask = [.minYMargin]
        view.addSubview(colorLabel)

        colorPicker = SpriteColorPickerView(spriteData: spriteData)
        colorPicker.frame = NSRect(x: rightX, y: rightTop + 50, width: 230, height: 200)
        colorPicker.autoresizingMask = [.minYMargin]
        colorPicker.onColorChanged = { [weak self] in
            self?.pushUndo("Change Color")
            self?.gridView.needsDisplay = true
            self?.updatePreview()
            self?.updateExport()
        }
        colorPicker.onDrawColorChanged = { [weak self] color in
            self?.gridView.drawColor = color
        }
        view.addSubview(colorPicker)

        // ── Shift buttons ────────────────────────────────
        let shiftY = rightTop + 6
        let shiftLabel = makeLabel("SHIFT", x: rightX, y: shiftY + 18, bold: true)
        shiftLabel.autoresizingMask = [.minYMargin]
        view.addSubview(shiftLabel)

        let shiftDirs: [(String, Int, Int, CGFloat, CGFloat)] = [
            ("↑", 0, -1, 40, 18), ("↓", 0, 1, 40, 0),
            ("←", -1, 0, 18, 0), ("→", 1, 0, 62, 0),
        ]
        for (title, dx, dy, offX, offY) in shiftDirs {
            let btn = NSButton(title: title, target: self, action: #selector(shiftPixels(_:)))
            btn.tag = (dx + 2) * 10 + (dy + 2)
            btn.frame = NSRect(x: rightX + 60 + offX, y: shiftY + offY, width: 22, height: 18)
            btn.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
            btn.autoresizingMask = [.minYMargin]
            view.addSubview(btn)
        }

        let wrapBtn = NSButton(checkboxWithTitle: "Wrap", target: nil, action: nil)
        wrapBtn.frame = NSRect(x: rightX + 150, y: shiftY + 4, width: 60, height: 18)
        wrapBtn.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        wrapBtn.contentTintColor = AppTheme.current.statusLabel
        wrapBtn.tag = 999
        wrapBtn.autoresizingMask = [.minYMargin]
        view.addSubview(wrapBtn)

        // ── Export panel ─────────────────────────────────
        let exportY: CGFloat = animStripHeight
        let exportLabel = makeLabel("EXPORT", x: 20, y: exportY + exportHeight - 10, bold: true)
        view.addSubview(exportLabel)

        formatSelector = NSPopUpButton(frame: NSRect(x: 90, y: exportY + exportHeight - 12, width: 160, height: 22))
        formatSelector.addItems(withTitles: ["BASIC DATA", "Assembly .byte", "C Array", "Hex String"])
        formatSelector.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        formatSelector.target = self
        formatSelector.action = #selector(formatChanged(_:))
        view.addSubview(formatSelector)

        let copyBtn = NSButton(title: "Copy", target: self, action: #selector(copyExport(_:)))
        copyBtn.frame = NSRect(x: 260, y: exportY + exportHeight - 12, width: 60, height: 22)
        copyBtn.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        view.addSubview(copyBtn)

        let clearBtn = NSButton(title: "Clear", target: self, action: #selector(clearSprite(_:)))
        clearBtn.frame = NSRect(x: 330, y: exportY + exportHeight - 12, width: 60, height: 22)
        clearBtn.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        view.addSubview(clearBtn)

        let flipHBtn = NSButton(title: "Flip H", target: self, action: #selector(flipHorizontal(_:)))
        flipHBtn.frame = NSRect(x: 400, y: exportY + exportHeight - 12, width: 60, height: 22)
        flipHBtn.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        view.addSubview(flipHBtn)

        let flipVBtn = NSButton(title: "Flip V", target: self, action: #selector(flipVertical(_:)))
        flipVBtn.frame = NSRect(x: 468, y: exportY + exportHeight - 12, width: 60, height: 22)
        flipVBtn.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        view.addSubview(flipVBtn)

        let importSpdBtn = NSButton(title: "Open SPD…", target: self, action: #selector(importSPDFile(_:)))
        importSpdBtn.frame = NSRect(x: 545, y: exportY + exportHeight - 12, width: 90, height: 22)
        importSpdBtn.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        view.addSubview(importSpdBtn)

        let importTextBtn = NSButton(title: "Import Text…", target: self, action: #selector(showImportTextPanel(_:)))
        importTextBtn.frame = NSRect(x: 645, y: exportY + exportHeight - 12, width: 100, height: 22)
        importTextBtn.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        view.addSubview(importTextBtn)

        exportTextView = NSTextView(frame: NSRect(x: 0, y: 0, width: 740, height: 90))
        exportTextView.isEditable = false
        exportTextView.isSelectable = true
        exportTextView.backgroundColor = panelBg
        exportTextView.textColor = AppTheme.current.syntaxFunction
        exportTextView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        exportTextView.textContainerInset = NSSize(width: 8, height: 4)

        exportScrollView = NSScrollView(frame: NSRect(x: 20, y: exportY + 6, width: 740, height: exportHeight - 20))
        exportScrollView.documentView = exportTextView
        exportScrollView.hasVerticalScroller = true
        exportScrollView.borderType = .noBorder
        exportScrollView.autoresizingMask = [.width]
        view.addSubview(exportScrollView)

        // ═══════════════════════════════════════════════════
        // ── Animation strip ──────────────────────────────
        // ═══════════════════════════════════════════════════
        animBg = NSView(frame: NSRect(x: 0, y: 0, width: 780, height: animStripHeight))
        animBg.wantsLayer = true
        animBg.layer?.backgroundColor = AppTheme.current.panelBackground.cgColor
        animBg.autoresizingMask = [.width]
        view.addSubview(animBg)

        let animLabel = makeLabel("ANIMATION", x: 20, y: animStripHeight - 16, bold: true)
        view.addSubview(animLabel)

        onionSkinBtn = NSButton(checkboxWithTitle: "Onion Skin", target: self, action: #selector(toggleOnionSkin(_:)))
        onionSkinBtn.frame = NSRect(x: 140, y: animStripHeight - 18, width: 100, height: 18)
        onionSkinBtn.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        onionSkinBtn.contentTintColor = AppTheme.current.statusLabel
        view.addSubview(onionSkinBtn)

        let opacityLabel = makeLabel("Opacity:", x: 245, y: animStripHeight - 16)
        view.addSubview(opacityLabel)

        onionOpacitySlider = NSSlider(value: Double(onionSkinOpacity), minValue: 0.1, maxValue: 0.6,
                                      target: self, action: #selector(onionOpacityChanged(_:)))
        onionOpacitySlider.frame = NSRect(x: 310, y: animStripHeight - 17, width: 80, height: 16)
        view.addSubview(onionOpacitySlider)

        animStripView = AnimationStripView()
        animStripView.frames = frames
        animStripView.selectedFrame = currentFrame
        animStripView.onFrameSelected = { [weak self] idx in self?.switchToFrame(idx) }
        animStripView.onFramesReordered = { [weak self] newFrames, newSelection in
            self?.pushUndo("Reorder Frames")
            self?.frames = newFrames
            self?.switchToFrame(newSelection)
            self?.onModified?()
        }

        animStripScroll = NSScrollView(frame: NSRect(x: 20, y: 36, width: 740, height: 80))
        animStripScroll.documentView = animStripView
        animStripScroll.hasVerticalScroller = false
        animStripScroll.hasHorizontalScroller = true
        animStripScroll.autohidesScrollers = true
        animStripScroll.borderType = .noBorder
        animStripScroll.autoresizingMask = [.width]
        view.addSubview(animStripScroll)
        resizeAnimStrip()

        // ── Playback controls ────────────────────────────
        let ctrlY: CGFloat = 8

        playBtn = NSButton(title: "▶ Play", target: self, action: #selector(togglePlayback(_:)))
        playBtn.frame = NSRect(x: 20, y: ctrlY, width: 70, height: 22)
        playBtn.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        view.addSubview(playBtn)

        pingPongBtn = NSButton(checkboxWithTitle: "Ping-Pong", target: self, action: #selector(togglePingFong(_:)))
        pingPongBtn.frame = NSRect(x: 96, y: ctrlY + 2, width: 100, height: 18)
        pingPongBtn.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        pingPongBtn.contentTintColor = AppTheme.current.statusLabel
        view.addSubview(pingPongBtn)

        let fpsStaticLabel = makeLabel("FPS:", x: 206, y: ctrlY + 3)
        view.addSubview(fpsStaticLabel)

        let fpsSlider = NSSlider(value: animFPS, minValue: 1, maxValue: 25,
                                 target: self, action: #selector(fpsChanged(_:)))
        fpsSlider.frame = NSRect(x: 240, y: ctrlY + 2, width: 90, height: 18)
        view.addSubview(fpsSlider)

        fpsLabel = makeLabel("6", x: 336, y: ctrlY + 3)
        view.addSubview(fpsLabel)

        let addBtn = NSButton(title: "+ Add", target: self, action: #selector(addFrame(_:)))
        addBtn.frame = NSRect(x: 380, y: ctrlY, width: 60, height: 22)
        addBtn.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        view.addSubview(addBtn)

        let dupBtn = NSButton(title: "Dup", target: self, action: #selector(duplicateFrame(_:)))
        dupBtn.frame = NSRect(x: 445, y: ctrlY, width: 50, height: 22)
        dupBtn.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        view.addSubview(dupBtn)

        let copyFrameBtn = NSButton(title: "Copy", target: self, action: #selector(copyFrame(_:)))
        copyFrameBtn.frame = NSRect(x: 500, y: ctrlY, width: 50, height: 22)
        copyFrameBtn.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        view.addSubview(copyFrameBtn)

        let pasteFrameBtn = NSButton(title: "Paste", target: self, action: #selector(pasteFrame(_:)))
        pasteFrameBtn.frame = NSRect(x: 555, y: ctrlY, width: 55, height: 22)
        pasteFrameBtn.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        view.addSubview(pasteFrameBtn)

        let delBtn = NSButton(title: "Del", target: self, action: #selector(deleteFrame(_:)))
        delBtn.frame = NSRect(x: 615, y: ctrlY, width: 50, height: 22)
        delBtn.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        view.addSubview(delBtn)

        frameLabel = makeLabel("Frame 1 / 1", x: 680, y: ctrlY + 3)
        view.addSubview(frameLabel)

        updateFrameLabel()
        updateExport()
    }

    private func makeLabel(_ text: String, x: CGFloat, y: CGFloat, bold: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: bold ? .bold : .regular)
        label.textColor = bold ? AppTheme.current.syntaxKeyword : AppTheme.current.statusLabel
        label.frame = NSRect(x: x, y: y, width: 200, height: 16)
        if bold { sectionLabels.append(label) } else { dimLabels.append(label) }
        return label
    }

    // MARK: - Keyboard Handling

    override func keyDown(with event: NSEvent) {
        // Note: event.keyCode values are platform-dependent. Space, arrows, and Cmd combos are standard.
        switch event.keyCode {
        case 49:  // Space — play/stop
            togglePlayback(nil)
        case 123: // Left arrow — previous frame
            if !isPlaying && currentFrame > 0 { switchToFrame(currentFrame - 1) }
        case 124: // Right arrow — next frame
            if !isPlaying && currentFrame < frames.count - 1 { switchToFrame(currentFrame + 1) }
        default:
            if event.modifierFlags.contains(.command) {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "c": copyFrame(nil)
                case "v": pasteFrame(nil)
                default: super.keyDown(with: event)
                }
            } else {
                super.keyDown(with: event)
            }
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(self)
    }

    // MARK: - Undo / Redo Responder Actions

    @objc func undo(_ sender: Any?) {
        performUndo()
    }

    @objc func redo(_ sender: Any?) {
        performRedo()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(undo(_:)) {
            return !undoStack.isEmpty
        }
        if menuItem.action == #selector(redo(_:)) {
            return !redoStack.isEmpty
        }
        return true
    }

    // MARK: - Actions

    @objc private func toggleMultiColor(_ sender: NSButton) {
        stopAnimation()
        pushUndo("Toggle Multi-Color")
        let newMode = sender.state == .on
        for frame in frames {
            frame.isMultiColor = newMode
        }
        switchToFrame(currentFrame)
        onModified?()
    }

    @objc private func togglePingFong(_ sender: NSButton) {
        pingPong = sender.state == .on
        animDirection = 1
    }

    @objc private func formatChanged(_ sender: NSPopUpButton) {
        updateExport()
    }

    @objc private func copyExport(_ sender: Any?) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(exportTextView.string, forType: .string)
    }

    @objc private func clearSprite(_ sender: Any?) {
        pushUndo("Clear Sprite")
        spriteData.clear()
        gridView.needsDisplay = true
        updatePreview()
        updateExport()
        onModified?()
    }

    @objc private func flipHorizontal(_ sender: Any?) {
        pushUndo("Flip Horizontal")
        let cols = spriteData.isMultiColor ? 12 : 24
        for row in 0..<21 {
            var newRow = Array(repeating: UInt8(0), count: 24)
            for col in 0..<cols {
                newRow[cols - 1 - col] = spriteData.pixels[row][col]
            }
            spriteData.pixels[row] = newRow
        }
        gridView.needsDisplay = true
        updatePreview()
        updateExport()
        onModified?()
    }

    @objc private func flipVertical(_ sender: Any?) {
        pushUndo("Flip Vertical")
        spriteData.pixels.reverse()
        gridView.needsDisplay = true
        updatePreview()
        updateExport()
        onModified?()
    }

    @objc private func shiftPixels(_ sender: NSButton) {
        pushUndo("Shift Pixels")
        let encoded = sender.tag
        let dx = (encoded / 10) - 2
        let dy = (encoded % 10) - 2
        let wrap = view.subviews.compactMap({ $0 as? NSButton }).first(where: { $0.tag == 999 })?.state == .on
        spriteData.shiftPixels(dx: dx, dy: dy, wrap: wrap)
        gridView.needsDisplay = true
        updatePreview()
        updateExport()
        onModified?()
    }

    // MARK: - Onion Skin

    @objc private func toggleOnionSkin(_ sender: NSButton) {
        onionSkinEnabled = sender.state == .on
        updateGridOnionSkin()
        gridView.needsDisplay = true
    }

    @objc private func onionOpacityChanged(_ sender: NSSlider) {
        onionSkinOpacity = CGFloat(sender.doubleValue)
        updateGridOnionSkin()
        gridView.needsDisplay = true
    }

    private func updateGridOnionSkin() {
        if onionSkinEnabled && frames.count > 1 {
            var ghosts: [(SpriteData, CGFloat)] = []
            // Previous frames (red tint)
            for offset in 1...onionSkinFrames {
                let idx = currentFrame - offset
                if idx >= 0 {
                    let fade = onionSkinOpacity / CGFloat(offset)
                    ghosts.append((frames[idx], fade))
                }
            }
            // Next frames (blue tint)
            for offset in 1...onionSkinFrames {
                let idx = currentFrame + offset
                if idx < frames.count {
                    let fade = onionSkinOpacity / CGFloat(offset)
                    ghosts.append((frames[idx], -fade))
                }
            }
            gridView.onionSkinFrames = ghosts
        } else {
            gridView.onionSkinFrames = []
        }
    }

    // MARK: - Updates

    private func updatePreview() {
        preview1?.needsDisplay = true
        animStripView?.needsDisplay = true
    }

    private func updateExport() {
        let format = formatSelector?.indexOfSelectedItem ?? 0
        let allBytes = frames.map { $0.toBytes() }
        switch format {
        case 0: exportTextView.string = exportAsBasicData(allBytes)
        case 1: exportTextView.string = exportAsAssembly(allBytes)
        case 2: exportTextView.string = exportAsCArray(allBytes)
        case 3: exportTextView.string = exportAsHex(allBytes)
        default: break
        }
    }

    // MARK: - Frame Management

    private func updateFrameLabel() {
        frameLabel?.stringValue = "Frame \(currentFrame + 1) / \(frames.count)"
    }

    private func switchToFrame(_ index: Int) {
        guard index >= 0 && index < frames.count else { return }
        currentFrame = index
        gridView.spriteData = spriteData
        preview1.spriteData = spriteData
        colorPicker.spriteData = spriteData
        multiColorToggle.state = spriteData.isMultiColor ? .on : .off
        colorPicker.updateForMode()
        updateGridOnionSkin()
        gridView.needsDisplay = true
        updatePreview()
        updateExport()
        updateFrameLabel()
        animStripView?.selectedFrame = currentFrame
        animStripView?.needsDisplay = true
    }

    @objc private func addFrame(_ sender: Any?) {
        stopAnimation()
        pushUndo("Add Frame")
        let newFrame = SpriteData()
        newFrame.isMultiColor = spriteData.isMultiColor
        newFrame.spriteColor = spriteData.spriteColor
        newFrame.multiColor1 = spriteData.multiColor1
        newFrame.multiColor2 = spriteData.multiColor2
        newFrame.backgroundColor = spriteData.backgroundColor
        frames.insert(newFrame, at: currentFrame + 1)
        animStripView.frames = frames
        resizeAnimStrip()
        switchToFrame(currentFrame + 1)
        onModified?()
    }

    @objc private func duplicateFrame(_ sender: Any?) {
        stopAnimation()
        pushUndo("Duplicate Frame")
        let copy = spriteData.deepCopy()
        frames.insert(copy, at: currentFrame + 1)
        animStripView.frames = frames
        resizeAnimStrip()
        switchToFrame(currentFrame + 1)
        onModified?()
    }

    @objc private func copyFrame(_ sender: Any?) {
        frameClipboard = spriteData.deepCopy()
    }

    @objc private func pasteFrame(_ sender: Any?) {
        guard let clip = frameClipboard else { return }
        stopAnimation()
        pushUndo("Paste Frame")
        let pasted = clip.deepCopy()
        frames.insert(pasted, at: currentFrame + 1)
        animStripView.frames = frames
        resizeAnimStrip()
        switchToFrame(currentFrame + 1)
        onModified?()
    }

    @objc private func deleteFrame(_ sender: Any?) {
        guard frames.count > 1 else { return }
        stopAnimation()
        pushUndo("Delete Frame")
        frames.remove(at: currentFrame)
        animStripView.frames = frames
        resizeAnimStrip()
        switchToFrame(min(currentFrame, frames.count - 1))
        onModified?()
    }

    private func resizeAnimStrip() {
        let thumbW: CGFloat = 52
        let spacing: CGFloat = 6
        let totalW = max(animStripScroll.frame.width,
                        CGFloat(frames.count) * (thumbW + spacing) + spacing)
        animStripView.frame = NSRect(x: 0, y: 0, width: totalW, height: animStripScroll.frame.height - 16)
    }

    // MARK: - Playback

    @objc private func togglePlayback(_ sender: Any?) {
        if isPlaying { stopAnimation() } else { startAnimation() }
    }

    @objc private func fpsChanged(_ sender: NSSlider) {
        animFPS = sender.doubleValue
        fpsLabel.stringValue = String(Int(animFPS))
        if isPlaying { startAnimation() }
    }

    private func startAnimation() {
        guard frames.count > 1 else { return }
        animTimer?.invalidate()
        isPlaying = true
        animDirection = 1
        playBtn.title = "■ Stop"
        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / animFPS, repeats: true) { [weak self] _ in
            self?.animTick()
        }
    }

    private func stopAnimation() {
        animTimer?.invalidate()
        animTimer = nil
        isPlaying = false
        playBtn?.title = "▶ Play"
    }

    @objc private func animTick() {
        var next = currentFrame + animDirection

        if pingPong {
            if next >= frames.count {
                animDirection = -1
                next = frames.count - 2
            } else if next < 0 {
                animDirection = 1
                next = 1
            }
            next = max(0, min(frames.count - 1, next))
        } else {
            next = next % frames.count
        }

        // Force synchronous drawing during playback to prevent run-loop starvation at higher FPS
        currentFrame = next
        preview1.spriteData = spriteData
        preview1.needsDisplay = true
        preview1.displayIfNeeded()
        animStripView.selectedFrame = currentFrame
        animStripView.needsDisplay = true
        animStripView.displayIfNeeded()
        updateFrameLabel()
    }

    // MARK: - Export Formats

    private func exportAsBasicData(_ allBytes: [[UInt8]]) -> String {
        var lines: [String] = []
        var lineNum = 1000
        for (fi, bytes) in allBytes.enumerated() {
            lines.append("\(lineNum) REM FRAME \(fi + 1)")
            lineNum += 10
            for i in stride(from: 0, to: bytes.count, by: 8) {
                let chunk = bytes[i..<min(i + 8, bytes.count)]
                lines.append("\(lineNum) DATA \(chunk.map { String($0) }.joined(separator: ","))")
                lineNum += 10
            }
        }
        return lines.joined(separator: "\n")
    }

    private func exportAsAssembly(_ allBytes: [[UInt8]]) -> String {
        var lines: [String] = []
        if allBytes.count > 1 {
            lines.append("; \(allBytes.count) animation frames")
            lines.append("sprite_frame_lo:")
            lines.append("    .byte " + (0..<allBytes.count).map { "<sprite_frame_\($0)" }.joined(separator: ", "))
            lines.append("sprite_frame_hi:")
            lines.append("    .byte " + (0..<allBytes.count).map { ">sprite_frame_\($0)" }.joined(separator: ", "))
            lines.append("")
            for (fi, bytes) in allBytes.enumerated() {
                lines.append("sprite_frame_\(fi):  ; frame \(fi + 1)")
                for row in 0..<21 {
                    let start = row * 3
                    let vals = bytes[start..<start+3].map { String(format: "$%02X", $0) }.joined(separator: ", ")
                    lines.append("    .byte \(vals)")
                }
                if fi < allBytes.count - 1 { lines.append("") }
            }
        } else {
            lines.append("sprite_data:")
            let bytes = allBytes[0]
            for row in 0..<21 {
                let start = row * 3
                let vals = bytes[start..<start+3].map { String(format: "$%02X", $0) }.joined(separator: ", ")
                lines.append("    .byte \(vals)    ; row \(row)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func exportAsCArray(_ allBytes: [[UInt8]]) -> String {
        let n = allBytes.count
        var lines = ["const unsigned char sprite_data[\(n)][63] = {"]
        for (fi, bytes) in allBytes.enumerated() {
            lines.append("    {  /* frame \(fi + 1) */")
            for row in 0..<21 {
                let start = row * 3
                let vals = bytes[start..<start+3].map { String(format: "0x%02X", $0) }.joined(separator: ", ")
                let comma = row < 20 ? "," : ""
                lines.append("        \(vals)\(comma)")
            }
            lines.append(fi < n - 1 ? "    }," : "    }")
        }
        lines.append("};")
        return lines.joined(separator: "\n")
    }

    private func exportAsHex(_ allBytes: [[UInt8]]) -> String {
        return allBytes.enumerated().map { fi, bytes in
            "; frame \(fi + 1)\n" + bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        }.joined(separator: "\n")
    }

    // MARK: - Import: SPD File

    @objc private func importSPDFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "Import Sprite Data"
        panel.allowedContentTypes = [
            .init(filenameExtension: "spd")!,
            .init(filenameExtension: "bin")!,
            .init(filenameExtension: "prg")!,
            .data,
        ]
        panel.allowsOtherFileTypes = true
        panel.message = "Open a SpritePad (.spd) file or raw binary sprite data"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            let ext = url.pathExtension.lowercased()

            if ext == "spd" {
                try importSPD(data)
            } else if ext == "prg" {
                try importRawBinary(Array(data.dropFirst(2)))
            } else {
                if data.count >= 9, data[0] == 0x53, data[1] == 0x50 {
                    try importSPD(data)
                } else {
                    try importRawBinary(Array(data))
                }
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Import Failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private func importSPD(_ data: Data) throws {
        let bytes = Array(data)
        var spriteFrames: [SpriteData] = []

        if bytes.count >= 3 && bytes[0] == 0x53 && bytes[1] == 0x50 {
            let version = bytes[2]
            guard bytes.count >= 9 else {
                throw ImportError.invalidFormat("SPD file too short for v2 header")
            }

            let numSprites = Int(bytes[4]) + 1
            let bgColor = Int(bytes[6])
            let mc1 = Int(bytes[7])
            let mc2 = Int(bytes[8])

            let headerSize = version >= 4 ? 13 : 9
            let dataStart = min(headerSize, bytes.count)

            for i in 0..<numSprites {
                let offset = dataStart + i * 64
                guard offset + 63 < bytes.count || offset + 63 == bytes.count else { break }

                let frame = SpriteData()
                let spriteBytes = Array(bytes[offset..<min(offset + 64, bytes.count)])

                let infoByte = spriteBytes.count > 63 ? spriteBytes[63] : 0
                frame.spriteColor = Int(infoByte & 0x0F)
                frame.isMultiColor = (infoByte & 0x80) != 0
                frame.backgroundColor = bgColor
                frame.multiColor1 = mc1
                frame.multiColor2 = mc2
                frame.fromBytes(Array(spriteBytes.prefix(63)))

                spriteFrames.append(frame)
            }
        } else {
            let numSprites = bytes.count / 64
            guard numSprites > 0 else {
                throw ImportError.invalidFormat("File too small for sprite data")
            }

            for i in 0..<numSprites {
                let offset = i * 64
                let frame = SpriteData()
                let spriteBytes = Array(bytes[offset..<offset + 64])

                let infoByte = spriteBytes[63]
                frame.spriteColor = Int(infoByte & 0x0F)
                frame.isMultiColor = (infoByte & 0x80) != 0
                frame.fromBytes(Array(spriteBytes.prefix(63)))

                spriteFrames.append(frame)
            }
        }

        guard !spriteFrames.isEmpty else {
            throw ImportError.invalidFormat("No sprite data found in file")
        }

        loadImportedFrames(spriteFrames)
    }

    private func importRawBinary(_ bytes: [UInt8]) throws {
        let bytesPerSprite = (bytes.count % 64 == 0) ? 64 : 63
        let numSprites = bytes.count / bytesPerSprite
        guard numSprites > 0 else {
            throw ImportError.invalidFormat("File too small for sprite data (\(bytes.count) bytes)")
        }

        var spriteFrames: [SpriteData] = []
        for i in 0..<numSprites {
            let offset = i * bytesPerSprite
            let frame = SpriteData()
            frame.fromBytes(Array(bytes[offset..<offset + min(63, bytesPerSprite)]))
            frame.spriteColor = spriteData.spriteColor
            frame.isMultiColor = spriteData.isMultiColor
            frame.multiColor1 = spriteData.multiColor1
            frame.multiColor2 = spriteData.multiColor2
            frame.backgroundColor = spriteData.backgroundColor
            spriteFrames.append(frame)
        }

        loadImportedFrames(spriteFrames)
    }

    // MARK: - Import: Paste Text

    @objc private func showImportTextPanel(_ sender: Any?) {
        stopAnimation()

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Import Sprite Data from Text"
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = AppTheme.current.editorBackground
        panel.isFloatingPanel = true

        let contentView = NSView(frame: panel.contentView!.bounds)

        let hint = NSTextField(wrappingLabelWithString:
            "Paste sprite data below. Accepts BASIC DATA, assembly .byte, C arrays, or hex bytes. Multi-sprite data will create multiple frames.")
        hint.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        hint.textColor = AppTheme.current.statusLabel
        hint.frame = NSRect(x: 20, y: 350, width: 480, height: 36)
        contentView.addSubview(hint)

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 476, height: 280))
        textView.isEditable = true
        textView.isSelectable = true
        textView.backgroundColor = panelBg
        textView.textColor = AppTheme.current.syntaxFunction
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 6)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false

        let scrollView = NSScrollView(frame: NSRect(x: 20, y: 60, width: 480, height: 284))
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        contentView.addSubview(scrollView)

        let importBtn = NSButton(title: "Import", target: nil, action: nil)
        importBtn.frame = NSRect(x: 340, y: 20, width: 80, height: 28)
        importBtn.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        importBtn.keyEquivalent = "\r"
        contentView.addSubview(importBtn)

        let cancelBtn = NSButton(title: "Cancel", target: nil, action: nil)
        cancelBtn.frame = NSRect(x: 430, y: 20, width: 70, height: 28)
        cancelBtn.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        cancelBtn.keyEquivalent = "\u{1b}"
        contentView.addSubview(cancelBtn)

        let replaceToggle = NSButton(checkboxWithTitle: "Replace existing frames", target: nil, action: nil)
        replaceToggle.frame = NSRect(x: 20, y: 24, width: 200, height: 18)
        replaceToggle.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        replaceToggle.contentTintColor = AppTheme.current.statusLabel
        replaceToggle.state = .on
        contentView.addSubview(replaceToggle)

        panel.contentView = contentView
        panel.center()

        cancelBtn.target = panel
        cancelBtn.action = #selector(NSPanel.close)

        let handler = ImportTextHandler(
            panel: panel,
            textView: textView,
            replaceToggle: replaceToggle,
            editor: self
        )
        importBtn.target = handler
        importBtn.action = #selector(ImportTextHandler.doImport(_:))

        // Keep handler alive via associated object
        objc_setAssociatedObject(panel, "importHandler", handler, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        panel.makeKeyAndOrderFront(nil)
    }

    /// Parses sprite bytes from pasted text. Auto-detects format by priority:
    /// 1. BASIC DATA (lines containing "DATA")
    /// 2. Assembly .byte / !byte
    /// 3. C array (contains "0x")
    /// 4. Raw hex/decimal fallback
    func parseTextToBytes(_ text: String) throws -> [UInt8] {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else {
            throw ImportError.invalidFormat("No data found in text")
        }

        var allBytes: [UInt8] = []

        let sampleLine = lines.first(where: {
            !$0.hasPrefix(";") && !$0.hasPrefix("//") && !$0.hasPrefix("/*") && !$0.hasPrefix("*")
        }) ?? lines[0]

        if sampleLine.contains("DATA ") || sampleLine.contains("data ") {
            for line in lines {
                guard let dataRange = line.range(of: "DATA ", options: .caseInsensitive) ??
                                      line.range(of: "data ", options: .caseInsensitive) else { continue }
                let valueStr = line[dataRange.upperBound...]
                let values = valueStr.components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .compactMap { UInt8($0) }
                allBytes.append(contentsOf: values)
            }

        } else if sampleLine.contains(".byte") || sampleLine.contains(".BYTE") ||
                  sampleLine.contains("!byte") || sampleLine.contains("!BYTE") {
            for line in lines {
                var work = line
                if let semi = work.firstIndex(of: ";") { work = String(work[..<semi]) }
                guard let byteRange = work.range(of: ".byte ", options: .caseInsensitive) ??
                                      work.range(of: "!byte ", options: .caseInsensitive) else { continue }
                let valueStr = work[byteRange.upperBound...]
                let values = valueStr.components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .compactMap { parseAsmByte($0) }
                allBytes.append(contentsOf: values)
            }

        } else if sampleLine.contains("0x") || sampleLine.contains("0X") {
            for line in lines {
                var work = line
                if let cmt = work.range(of: "/*") { work = String(work[..<cmt.lowerBound]) }
                if let cmt = work.range(of: "//") { work = String(work[..<cmt.lowerBound]) }
                work = work.replacingOccurrences(of: "{", with: "")
                    .replacingOccurrences(of: "}", with: "")
                    .replacingOccurrences(of: ";", with: "")
                let values = work.components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { $0.hasPrefix("0x") || $0.hasPrefix("0X") }
                    .compactMap { UInt8($0.dropFirst(2), radix: 16) }
                allBytes.append(contentsOf: values)
            }

        } else {
            for line in lines {
                var work = line
                if work.hasPrefix(";") || work.hasPrefix("//") { continue }
                if let semi = work.firstIndex(of: ";") { work = String(work[..<semi]) }
                let tokens = work.components(separatedBy: .whitespaces)
                    .map { $0.trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }
                    .filter { !$0.isEmpty }
                let hexValues = tokens.compactMap { UInt8($0, radix: 16) }
                if !hexValues.isEmpty {
                    allBytes.append(contentsOf: hexValues)
                    continue
                }
                let decValues = work.components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .compactMap { UInt8($0) }
                allBytes.append(contentsOf: decValues)
            }
        }

        guard !allBytes.isEmpty else {
            throw ImportError.invalidFormat("Could not parse any byte values from text")
        }

        return allBytes
    }

    private func parseAsmByte(_ str: String) -> UInt8? {
        let s = str.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("$") { return UInt8(s.dropFirst(), radix: 16) }
        if s.hasPrefix("%") { return UInt8(s.dropFirst(), radix: 2) }
        if s.hasPrefix("0x") || s.hasPrefix("0X") { return UInt8(s.dropFirst(2), radix: 16) }
        return UInt8(s)
    }

    func importFromBytes(_ bytes: [UInt8], replace: Bool) {
        let bytesPerSprite = (bytes.count % 64 == 0 && bytes.count >= 64) ? 64 : 63
        let numSprites = max(1, bytes.count / bytesPerSprite)

        var spriteFrames: [SpriteData] = []
        for i in 0..<numSprites {
            let offset = i * bytesPerSprite
            let end = min(offset + 63, bytes.count)
            guard offset < bytes.count else { break }

            let frame = SpriteData()
            let chunk = Array(bytes[offset..<end])
            var padded = chunk
            while padded.count < 63 { padded.append(0) }
            frame.fromBytes(padded)

            frame.spriteColor = spriteData.spriteColor
            frame.isMultiColor = spriteData.isMultiColor
            frame.multiColor1 = spriteData.multiColor1
            frame.multiColor2 = spriteData.multiColor2
            frame.backgroundColor = spriteData.backgroundColor
            spriteFrames.append(frame)
        }

        guard !spriteFrames.isEmpty else { return }

        pushUndo("Import Sprites")
        if replace {
            loadImportedFrames(spriteFrames)
        } else {
            for (i, frame) in spriteFrames.enumerated() {
                frames.insert(frame, at: currentFrame + 1 + i)
            }
            animStripView.frames = frames
            resizeAnimStrip()
            switchToFrame(currentFrame + 1)
            onModified?()
        }
    }

    private func loadImportedFrames(_ newFrames: [SpriteData]) {
        stopAnimation()
        frames = newFrames
        currentFrame = 0
        animStripView.frames = frames
        resizeAnimStrip()
        switchToFrame(0)
        onModified?()
    }

    private enum ImportError: LocalizedError {
        case invalidFormat(String)

        var errorDescription: String? {
            switch self {
            case .invalidFormat(let msg): return msg
            }
        }
    }
}

/// Helper class to handle the Import Text panel button action.
/// Required because NSButton target must be an NSObject that outlives the local scope.
class ImportTextHandler: NSObject {
    let panel: NSPanel
    let textView: NSTextView
    let replaceToggle: NSButton
    weak var editor: SpriteEditorViewController?

    init(panel: NSPanel, textView: NSTextView, replaceToggle: NSButton, editor: SpriteEditorViewController) {
        self.panel = panel
        self.textView = textView
        self.replaceToggle = replaceToggle
        self.editor = editor
    }

    @objc func doImport(_ sender: Any?) {
        guard let editor = editor else { return }
        let text = textView.string

        do {
            let bytes = try editor.parseTextToBytes(text)
            let replace = replaceToggle.state == .on
            editor.importFromBytes(bytes, replace: replace)
            panel.close()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Parse Error"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - Sprite Grid View (the pixel editor)
// ═══════════════════════════════════════════════════════════

/// Custom NSView that renders the 24x21 pixel sprite grid.
/// Uses `isFlipped = true` so Y coordinates grow downward (standard for pixel editors).
class SpriteGridView: NSView {

    var spriteData: SpriteData
    var drawColor: UInt8 = 1
    var onPixelChanged: (() -> Void)?

    /// Called when a new paint stroke begins (mouseDown, not drag).
    var onStrokeStart: (() -> Void)?

    /// Onion skin ghost frames: (SpriteData, opacity)
    /// Positive opacity = previous frame (reddish tint)
    /// Negative opacity = next frame (bluish tint), use abs() for actual alpha
    var onionSkinFrames: [(SpriteData, CGFloat)] = []

    private var gridBg:   NSColor { AppTheme.current.panelDetailBackground }
    private var gridLine: NSColor { NSColor(white: AppTheme.current.isDark ? 0.20 : 0.65, alpha: 1.0) }

    init(spriteData: SpriteData) {
        self.spriteData = spriteData
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var cellSize: CGSize {
        let cols = spriteData.isMultiColor ? 12 : 24
        let w = bounds.width / CGFloat(cols)
        let h = bounds.height / 21.0
        return CGSize(width: w, height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        gridBg.setFill()
        bounds.fill()

        let cols = spriteData.isMultiColor ? 12 : 24
        let cell = cellSize

        // ── Draw onion skin ghost frames first ───────────
        for (ghost, opacity) in onionSkinFrames {
            let alpha = abs(opacity)
            let tint: NSColor = opacity > 0
                ? NSColor(red: 1.0, green: 0.3, blue: 0.3, alpha: alpha)
                : NSColor(red: 0.3, green: 0.5, blue: 1.0, alpha: alpha)

            let ghostCols = ghost.isMultiColor ? 12 : 24
            let effectiveCols = min(cols, ghostCols)

            for row in 0..<21 {
                for col in 0..<effectiveCols {
                    let value = ghost.pixels[row][col]
                    guard value != 0 else { continue }
                    tint.setFill()
                    let rect = NSRect(x: CGFloat(col) * cell.width, y: CGFloat(row) * cell.height,
                                      width: cell.width, height: cell.height)
                    rect.fill()
                }
            }
        }

        // ── Draw current frame pixels ────────────────────
        for row in 0..<21 {
            for col in 0..<cols {
                let value = spriteData.pixels[row][col]
                guard value != 0 || onionSkinFrames.isEmpty else { continue }
                let color = colorForValue(value)
                color.setFill()
                let rect = NSRect(x: CGFloat(col) * cell.width, y: CGFloat(row) * cell.height,
                                  width: cell.width, height: cell.height)
                rect.fill()
            }
        }

        // ── Draw grid lines ──────────────────────────────
        gridLine.setStroke()
        for col in 0...cols {
            let x = CGFloat(col) * cell.width
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x, y: 0))
            path.line(to: NSPoint(x: x, y: bounds.height))
            path.lineWidth = 1
            path.stroke()
        }
        for row in 0...21 {
            let y = CGFloat(row) * cell.height
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 0, y: y))
            path.line(to: NSPoint(x: bounds.width, y: y))
            path.lineWidth = 1
            path.stroke()
        }

        // Byte boundaries (thicker lines every 8 pixels in hi-res, every 4 in multi-color)
        let byteWidth = spriteData.isMultiColor ? 4 : 8
        NSColor(white: AppTheme.current.isDark ? 0.35 : 0.65, alpha: 1.0).setStroke()
        for col in stride(from: 0, through: cols, by: byteWidth) {
            let x = CGFloat(col) * cell.width
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x, y: 0))
            path.line(to: NSPoint(x: x, y: bounds.height))
            path.lineWidth = 2
            path.stroke()
        }
    }

    private func colorForValue(_ value: UInt8) -> NSColor {
        if spriteData.isMultiColor {
            switch value {
            case 0: return c64Color(spriteData.backgroundColor)
            case 1: return c64Color(spriteData.multiColor1)
            case 2: return c64Color(spriteData.spriteColor)
            case 3: return c64Color(spriteData.multiColor2)
            default: return .black
            }
        } else {
            return value == 0 ? c64Color(spriteData.backgroundColor) : c64Color(spriteData.spriteColor)
        }
    }

    private func c64Color(_ index: Int) -> NSColor {
        guard index >= 0, index < C64Reference.colorPalette.count else { return .black }
        return NSColor(hex: C64Reference.colorPalette[index].hex) ?? .black
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        onStrokeStart?()
        handleMouse(event)
    }
    override func mouseDragged(with event: NSEvent) { handleMouse(event) }

    override func rightMouseDown(with event: NSEvent) {
        onStrokeStart?()
        handleMouse(event, erase: true)
    }
    override func rightMouseDragged(with event: NSEvent) { handleMouse(event, erase: true) }

    private func handleMouse(_ event: NSEvent, erase: Bool = false) {
        let point = convert(event.locationInWindow, from: nil)
        let cols = spriteData.isMultiColor ? 12 : 24
        let cell = cellSize

        let col = Int(point.x / cell.width)
        let row = Int(point.y / cell.height)

        guard row >= 0, row < 21, col >= 0, col < cols else { return }

        spriteData.pixels[row][col] = erase ? 0 : drawColor
        needsDisplay = true
        onPixelChanged?()
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - Sprite Preview View
// ═══════════════════════════════════════════════════════════

/// Renders a scaled-up preview of the sprite for the right panel.
class SpritePreviewView: NSView {

    var spriteData: SpriteData
    var scaleFactor: CGFloat = 1

    init(spriteData: SpriteData) {
        self.spriteData = spriteData
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        c64Color(spriteData.backgroundColor).setFill()
        bounds.fill()

        let cols = spriteData.isMultiColor ? 12 : 24
        let pixelW = spriteData.isMultiColor ? 2.0 * scaleFactor : 1.0 * scaleFactor
        let pixelH = scaleFactor

        let totalW = CGFloat(cols) * pixelW
        let totalH = 21.0 * pixelH
        let offsetX = (bounds.width - totalW) / 2
        let offsetY = (bounds.height - totalH) / 2

        for row in 0..<21 {
            for col in 0..<cols {
                let value = spriteData.pixels[row][col]
                guard value != 0 else { continue }

                let color: NSColor
                if spriteData.isMultiColor {
                    switch value {
                    case 1: color = c64Color(spriteData.multiColor1)
                    case 2: color = c64Color(spriteData.spriteColor)
                    case 3: color = c64Color(spriteData.multiColor2)
                    default: continue
                    }
                } else {
                    color = c64Color(spriteData.spriteColor)
                }

                color.setFill()
                NSRect(x: offsetX + CGFloat(col) * pixelW,
                       y: offsetY + CGFloat(row) * pixelH,
                       width: pixelW, height: pixelH).fill()
            }
        }

        NSColor(white: AppTheme.current.isDark ? 0.3 : 0.6, alpha: 1).setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }

    private func c64Color(_ index: Int) -> NSColor {
        guard index >= 0, index < C64Reference.colorPalette.count else { return .black }
        return NSColor(hex: C64Reference.colorPalette[index].hex) ?? .black
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - Color Picker View
// ═══════════════════════════════════════════════════════════

/// Manages sprite color role selection (Sprite, MC1, MC2, BG) and palette interaction.
class SpriteColorPickerView: NSView {

    var spriteData: SpriteData
    var onColorChanged: (() -> Void)?
    var onDrawColorChanged: ((UInt8) -> Void)?

    private var selectedRole: Int = 0  // 0=sprite, 1=multi1, 2=multi2, 3=background

    private let roles = ["Sprite Color", "Multi-Color 1", "Multi-Color 2", "Background"]
    private var roleButtons: [NSButton] = []
    private var roleSwatches: [NSButton] = []
    private var paletteButtons: [ColorSwatchButton] = []
    private var lastBuiltMultiColor: Bool? = nil

    init(spriteData: SpriteData) {
        self.spriteData = spriteData
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Builds the role buttons, swatches, and palette once. Called on init and mode change.
    private func setup() {
        let currentMode = spriteData.isMultiColor
        guard lastBuiltMultiColor != currentMode else { return }
        lastBuiltMultiColor = currentMode

        subviews.forEach { $0.removeFromSuperview() }
        roleButtons.removeAll()
        roleSwatches.removeAll()
        paletteButtons.removeAll()

        let swatchSize: CGFloat = 24
        let spacing: CGFloat = 4
        let startY: CGFloat = 0

        let activeRoles = spriteData.isMultiColor ? 4 : 2
        for i in 0..<activeRoles {
            let label: String
            if !spriteData.isMultiColor {
                label = i == 0 ? "Sprite Color" : "Background"
            } else {
                label = roles[i]
            }

            let y = startY + CGFloat(i) * 28

            let btn = NSButton(title: label, target: self, action: #selector(roleSelected(_:)))
            btn.tag = i
            btn.isBordered = false
            btn.frame = NSRect(x: 30, y: y, width: 140, height: 20)
            addSubview(btn)
            roleButtons.append(btn)

            let swatch = NSButton(frame: NSRect(x: 2, y: y, width: 22, height: 20))
            swatch.target = self
            swatch.action = #selector(roleSelected(_:))
            swatch.tag = i
            swatch.isBordered = false
            swatch.title = ""
            swatch.wantsLayer = true
            swatch.layer?.cornerRadius = 3
            addSubview(swatch)
            roleSwatches.append(swatch)
        }

        let paletteY = startY + CGFloat(activeRoles) * 28 + 10

        let palLabel = NSTextField(labelWithString: "PALETTE")
        palLabel.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .bold)
        palLabel.textColor = AppTheme.current.statusLabel
        palLabel.frame = NSRect(x: 2, y: paletteY, width: 80, height: 14)
        addSubview(palLabel)

        for i in 0..<16 {
            let col = i % 8
            let row = i / 8
            let x = CGFloat(col) * (swatchSize + spacing) + 2
            let y = paletteY + 18 + CGFloat(row) * (swatchSize + spacing)

            let btn = ColorSwatchButton(colorIndex: i)
            btn.frame = NSRect(x: x, y: y, width: swatchSize, height: swatchSize)
            btn.target = self
            btn.action = #selector(paletteColorClicked(_:))
            addSubview(btn)
            paletteButtons.append(btn)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // Update visual state of existing views
        let colorIndices = [spriteData.spriteColor, spriteData.multiColor1,
                            spriteData.multiColor2, spriteData.backgroundColor]

        for (i, btn) in roleButtons.enumerated() {
            let isSelected = i == selectedRole
            btn.font = NSFont.monospacedSystemFont(ofSize: 10, weight: isSelected ? .bold : .regular)
            btn.contentTintColor = isSelected ? .cyan : .gray
        }

        for (i, swatch) in roleSwatches.enumerated() {
            let colorIndex: Int
            if !spriteData.isMultiColor {
                colorIndex = i == 0 ? spriteData.spriteColor : spriteData.backgroundColor
            } else {
                colorIndex = colorIndices[i]
            }
            let isSelected = i == selectedRole
            let c = NSColor(hex: C64Reference.colorPalette[colorIndex].hex) ?? .black
            swatch.layer?.backgroundColor = c.cgColor
            swatch.layer?.borderColor = (isSelected ? AppTheme.current.editorSelectionHighlight : AppTheme.current.statusLabel).cgColor
            swatch.layer?.borderWidth = isSelected ? 2 : 1
        }
    }

    func updateForMode() {
        selectedRole = 0
        lastBuiltMultiColor = nil  // force rebuild on next draw
        needsDisplay = true
        let defaultDrawColor: UInt8 = spriteData.isMultiColor ? 2 : 1
        onDrawColorChanged?(defaultDrawColor)
    }

    @objc private func roleSelected(_ sender: NSButton) {
        selectedRole = sender.tag
        needsDisplay = true
        let drawValue: UInt8
        switch sender.tag {
        case 0: drawValue = spriteData.isMultiColor ? 2 : 1
        case 1: drawValue = spriteData.isMultiColor ? 1 : 0
        case 2: drawValue = 3
        case 3: drawValue = 0
        default: return
        }
        onDrawColorChanged?(drawValue)
    }

    @objc private func setDrawColor(_ sender: NSButton) {
        onDrawColorChanged?(UInt8(sender.tag))
    }

    @objc private func paletteColorClicked(_ sender: ColorSwatchButton) {
        let colorIndex = sender.colorIndex
        switch selectedRole {
        case 0: spriteData.spriteColor = colorIndex
        case 1: spriteData.multiColor1 = colorIndex
        case 2: spriteData.multiColor2 = colorIndex
        case 3: spriteData.backgroundColor = colorIndex
        default: break
        }
        needsDisplay = true
        onColorChanged?()
    }
}

/// Simple button that renders a C64 color swatch.
class ColorSwatchButton: NSButton {
    let colorIndex: Int

    init(colorIndex: Int) {
        self.colorIndex = colorIndex
        super.init(frame: .zero)
        self.isBordered = false
        self.title = ""
        self.wantsLayer = true
        let c = NSColor(hex: C64Reference.colorPalette[colorIndex].hex) ?? .black
        self.layer?.backgroundColor = c.cgColor
        self.layer?.cornerRadius = 3
        self.layer?.borderColor = NSColor(white: AppTheme.current.isDark ? 0.4 : 0.6, alpha: 1).cgColor
        self.layer?.borderWidth = 1
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let c = NSColor(hex: C64Reference.colorPalette[colorIndex].hex) ?? .black
        c.setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
        path.fill()

        NSColor(white: AppTheme.current.isDark ? 0.4 : 0.6, alpha: 1).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - Animation Strip View (with drag-to-reorder)
// ═══════════════════════════════════════════════════════════

/// Renders frame thumbnails and handles drag-to-reorder interactions.
class AnimationStripView: NSView {

    var frames: [SpriteData] = []
    var selectedFrame: Int = 0
    var onFrameSelected: ((Int) -> Void)?
    var onFramesReordered: (([SpriteData], Int) -> Void)?

    private let thumbW: CGFloat = 52
    private let thumbH: CGFloat = 46
    private let spacing: CGFloat = 6

    private var dragIndex: Int? = nil
    private var dragCurrentX: CGFloat = 0
    private var dragStartX: CGFloat = 0
    private var isDragging: Bool = false

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        AppTheme.current.panelBackground.setFill()
        bounds.fill()

        for (i, frame) in frames.enumerated() {
            var x = spacing + CGFloat(i) * (thumbW + spacing)

            if isDragging && i == dragIndex {
                x += (dragCurrentX - dragStartX)
            }

            let thumbRect = NSRect(x: x, y: 4, width: thumbW, height: thumbH)

            let isSelected = i == selectedFrame
            let bgColor: NSColor
            if isDragging && i == dragIndex {
                bgColor = AppTheme.current.editorSelectionHighlight.withAlphaComponent(0.35)
            } else if isSelected {
                bgColor = AppTheme.current.editorSelectionHighlight.withAlphaComponent(0.2)
            } else {
                bgColor = AppTheme.current.panelDetailBackground
            }
            bgColor.setFill()
            NSBezierPath(roundedRect: thumbRect, xRadius: 4, yRadius: 4).fill()

            drawThumb(frame, in: thumbRect.insetBy(dx: 4, dy: 4))

            let border = NSBezierPath(roundedRect: thumbRect.insetBy(dx: 0.5, dy: 0.5),
                                      xRadius: 4, yRadius: 4)
            border.lineWidth = isSelected ? 2 : 1
            (isSelected ? AppTheme.current.editorSelectionHighlight : NSColor(white: AppTheme.current.isDark ? 0.28 : 0.60, alpha: 1)).setStroke()
            border.stroke()

            // Frame number label (modern text drawing)
            let text = "\(i + 1)"
            let font = NSFont.monospacedSystemFont(ofSize: 8, weight: .medium)
            let color = isSelected ? AppTheme.current.editorSelectionHighlight : AppTheme.current.statusLabel
            let rect = NSRect(x: x + 3, y: thumbH - 2, width: 20, height: 16)
            text.draw(with: rect, options: .usesLineFragmentOrigin, attributes: [.font: font, .foregroundColor: color], context: nil)
        }

        // Draw drop indicator line when dragging
        if isDragging, let dragIdx = dragIndex {
            let dropIdx = dropTargetIndex()
            if dropIdx != dragIdx && dropIdx != dragIdx + 1 {
                let indicatorX = spacing + CGFloat(dropIdx) * (thumbW + spacing) - spacing / 2
                AppTheme.current.editorSelectionHighlight.setFill()
                NSRect(x: indicatorX - 1, y: 2, width: 2, height: thumbH + 4).fill()
            }
        }
    }

    private func drawThumb(_ sprite: SpriteData, in rect: NSRect) {
        let cols = sprite.isMultiColor ? 12 : 24
        let pw = rect.width / CGFloat(cols)
        let ph = rect.height / 21.0

        c64Color(sprite.backgroundColor).setFill()
        rect.fill()

        for row in 0..<21 {
            for col in 0..<cols {
                let v = sprite.pixels[row][col]
                guard v != 0 else { continue }
                let color: NSColor
                if sprite.isMultiColor {
                    switch v {
                    case 1: color = c64Color(sprite.multiColor1)
                    case 2: color = c64Color(sprite.spriteColor)
                    case 3: color = c64Color(sprite.multiColor2)
                    default: continue
                    }
                } else {
                    color = c64Color(sprite.spriteColor)
                }
                color.setFill()
                NSRect(x: rect.minX + CGFloat(col) * pw,
                       y: rect.minY + CGFloat(row) * ph,
                       width: max(pw, 1), height: max(ph, 1)).fill()
            }
        }
    }

    private func c64Color(_ index: Int) -> NSColor {
        guard index >= 0, index < C64Reference.colorPalette.count else { return .black }
        return NSColor(hex: C64Reference.colorPalette[index].hex) ?? .black
    }

    // MARK: - Mouse (click + drag-to-reorder)

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let idx = indexForPoint(pt)
        guard idx >= 0, idx < frames.count else { return }

        dragIndex = idx
        dragStartX = pt.x
        dragCurrentX = pt.x
        isDragging = false

        selectedFrame = idx
        needsDisplay = true
        onFrameSelected?(idx)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragIndex != nil else { return }
        let pt = convert(event.locationInWindow, from: nil)
        dragCurrentX = pt.x

        if !isDragging && abs(dragCurrentX - dragStartX) > 4 {
            isDragging = true
        }
        if isDragging {
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragIndex = nil
            isDragging = false
            needsDisplay = true
        }

        guard isDragging, let fromIdx = dragIndex else { return }

        var toIdx = dropTargetIndex()
        if toIdx == fromIdx || toIdx == fromIdx + 1 { return }

        let movedFrame = frames.remove(at: fromIdx)
        if toIdx > fromIdx { toIdx -= 1 }
        frames.insert(movedFrame, at: toIdx)

        selectedFrame = toIdx
        onFramesReordered?(frames, toIdx)
    }

    private func indexForPoint(_ pt: NSPoint) -> Int {
        return Int((pt.x - spacing) / (thumbW + spacing))
    }

    private func dropTargetIndex() -> Int {
        let x = dragCurrentX
        let raw = Int((x - spacing / 2) / (thumbW + spacing) + 0.5)
        return max(0, min(frames.count, raw))
    }
}

