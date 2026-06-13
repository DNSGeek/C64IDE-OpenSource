import Cocoa

// MARK: - Character Editor Window Controller

/// Manages the character set editor window, including unsaved changes handling.
class CharEditorWindowController: NSWindowController, NSWindowDelegate {

    var isModified = false

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Character Set Editor"
        window.center()
        window.minSize = NSSize(width: 700, height: 550)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = AppTheme.current.editorBackground
        self.init(window: window)
        window.delegate = self

        let editor = CharEditorViewController()
        editor.onModified = { [weak self] in self?.isModified = true }
        window.contentViewController = editor
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard isModified else { return true }
        let alert = NSAlert()
        alert.messageText = "You have unsaved changes in the Character Set Editor."
        alert.informativeText = "Close without exporting?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Intercepts the "Close Tab" menu action to close this window specifically.
    @objc func closeTab(_ sender: Any?) {
        window?.performClose(sender)
    }
}

// MARK: - Character Set Data Model

/// In-memory representation of a 256-character C64 charset.
class CharSetData {
    /// 256 characters, each represented by 8 bytes (8×8 pixels).
    var characters: [[UInt8]] = Array(repeating: Array(repeating: 0, count: 8), count: 256)
    
    /// Foreground and background color indices (0-15).
    var fgColor: Int = 14   // Light blue
    var bgColor: Int = 6    // Blue

    /// Multi-color mode configuration.
    var isMultiColor: Bool = false
    var multiColor1: Int = 1   // White
    var multiColor2: Int = 11  // Dark gray

    /// Retrieves a single pixel value (0 or 1) from a character.
    func getPixel(char: Int, row: Int, col: Int) -> UInt8 {
        guard char < 256, row < 8, col < 8 else { return 0 }
        return (characters[char][row] >> (7 - col)) & 1
    }

    /// Sets a single pixel value in a character.
    func setPixel(char: Int, row: Int, col: Int, value: UInt8) {
        guard char < 256, row < 8, col < 8 else { return }
        if value != 0 {
            characters[char][row] |= (1 << (7 - col))
        } else {
            characters[char][row] &= ~(1 << (7 - col))
        }
    }

    /// Retrieves a multi-color pixel (2 bits, col 0-3).
    func getMultiPixel(char: Int, row: Int, col: Int) -> UInt8 {
        guard char < 256, row < 8, col < 4 else { return 0 }
        let shift = 6 - col * 2
        return (characters[char][row] >> shift) & 0x03
    }

    /// Sets a multi-color pixel.
    func setMultiPixel(char: Int, row: Int, col: Int, value: UInt8) {
        guard char < 256, row < 8, col < 4 else { return }
        let shift = 6 - col * 2
        characters[char][row] &= ~(0x03 << shift)
        characters[char][row] |= (value & 0x03) << shift
    }

    /// Clears all pixels in a character.
    func clearChar(_ index: Int) {
        guard index < 256 else { return }
        characters[index] = Array(repeating: 0, count: 8)
    }

    /// Copies one character to another index.
    func copyChar(from src: Int, to dst: Int) {
        guard src < 256, dst < 256 else { return }
        characters[dst] = characters[src]
    }

    /// Inverts all pixels in a character.
    func invertChar(_ index: Int) {
        guard index < 256 else { return }
        for row in 0..<8 {
            characters[index][row] = ~characters[index][row]
        }
    }

    /// Mirrors a character horizontally.
    func mirrorHChar(_ index: Int) {
        guard index < 256 else { return }
        for row in 0..<8 {
            var reversed: UInt8 = 0
            for bit in 0..<8 {
                if characters[index][row] & (1 << bit) != 0 {
                    reversed |= 1 << (7 - bit)
                }
            }
            characters[index][row] = reversed
        }
    }

    /// Mirrors a character vertically (reverses row order).
    func mirrorVChar(_ index: Int) {
        guard index < 256 else { return }
        characters[index].reverse()
    }

    /// Shifts a character in the given direction with wrap-around.
    func shiftChar(_ index: Int, dx: Int, dy: Int) {
        guard index < 256 else { return }
        if dy != 0 {
            if dy < 0 {
                let first = characters[index].removeFirst()
                characters[index].append(first)
            } else {
                let last = characters[index].removeLast()
                characters[index].insert(last, at: 0)
            }
        }
        if dx != 0 {
            for row in 0..<8 {
                if dx > 0 {
                    let carry = (characters[index][row] & 1) << 7
                    characters[index][row] = (characters[index][row] >> 1) | carry
                } else {
                    let carry = (characters[index][row] >> 7) & 1
                    characters[index][row] = (characters[index][row] << 1) | carry
                }
            }
        }
    }

    /// Exports the full 2048-byte character set.
    func toBytes() -> [UInt8] {
        var result: [UInt8] = []
        for ch in characters {
            result.append(contentsOf: ch)
        }
        return result
    }

    /// Imports a raw 2048-byte character set.
    func loadFromBytes(_ bytes: [UInt8]) {
        guard bytes.count >= 2048 else { return }
        for i in 0..<256 {
            let offset = i * 8
            characters[i] = Array(bytes[offset..<offset + 8])
        }
    }

    /// Loads the standard C64 ROM character set (Set 1: uppercase/graphics).
    func loadROMCharset() {
        let rom = C64CharROM.romData
        loadFromBytes(Array(rom.prefix(2048)))
    }

    /// Creates a deep copy for undo snapshots.
    func deepCopy() -> CharSetData {
        let copy = CharSetData()
        copy.characters = characters.map { $0 }
        copy.fgColor = fgColor
        copy.bgColor = bgColor
        copy.isMultiColor = isMultiColor
        copy.multiColor1 = multiColor1
        copy.multiColor2 = multiColor2
        return copy
    }

    /// Loads a default set of glyphs for testing.
    func loadDefaultChars() {
        characters[32] = [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        let defaultGlyphs: [(Int, [UInt8])] = [
            (0, [0x3C, 0x66, 0x6E, 0x6E, 0x60, 0x62, 0x3C, 0x00]),
            (1, [0x18, 0x3C, 0x66, 0x7E, 0x66, 0x66, 0x66, 0x00]),
            (2, [0x7C, 0x66, 0x66, 0x7C, 0x66, 0x66, 0x7C, 0x00]),
            (3, [0x3C, 0x66, 0x60, 0x60, 0x60, 0x66, 0x3C, 0x00]),
            (4, [0x78, 0x6C, 0x66, 0x66, 0x66, 0x6C, 0x78, 0x00]),
            (5, [0x7E, 0x60, 0x60, 0x78, 0x60, 0x60, 0x7E, 0x00]),
            (48, [0x3C, 0x66, 0x6E, 0x76, 0x66, 0x66, 0x3C, 0x00]),
            (49, [0x18, 0x38, 0x18, 0x18, 0x18, 0x18, 0x7E, 0x00]),
            (83, [0x00, 0x66, 0xFF, 0xFF, 0xFF, 0x7E, 0x3C, 0x18]),
        ]
        for (idx, data) in defaultGlyphs {
            characters[idx] = data
        }
    }
}

// MARK: - Character Editor View Controller

/// Main editor controller handling UI, undo/redo, and export logic.
class CharEditorViewController: NSViewController, NSMenuItemValidation {

    private var charData = CharSetData()
    private var selectedChar: Int = 1  // Start with 'A'
    private var gridView: CharGridView!
    private var charMapView: CharMapView!
    private var previewLabel: NSTextField!
    private var charIndexLabel: NSTextField!
    private var exportTextView: NSTextView!
    private var exportScrollView: NSScrollView!
    private var formatSelector: NSPopUpButton!

    var onModified: (() -> Void)?

    // Undo system
    private struct UndoSnapshot {
        let charData: CharSetData
        let selectedChar: Int
        let label: String
    }
    private var undoStack: [UndoSnapshot] = []
    private var redoStack: [UndoSnapshot] = []
    private let maxUndoLevels = 50
    private var sectionLabels: [NSTextField] = []
    private var dimLabels:     [NSTextField] = []

    private func pushUndo(_ label: String) {
        let snapshot = UndoSnapshot(
            charData: charData.deepCopy(),
            selectedChar: selectedChar,
            label: label
        )
        undoStack.append(snapshot)
        if undoStack.count > maxUndoLevels { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func performUndo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(UndoSnapshot(charData: charData.deepCopy(), selectedChar: selectedChar, label: snapshot.label))
        restoreSnapshot(snapshot)
    }

    private func performRedo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(UndoSnapshot(charData: charData.deepCopy(), selectedChar: selectedChar, label: snapshot.label))
        restoreSnapshot(snapshot)
    }

    private func restoreSnapshot(_ snapshot: UndoSnapshot) {
        charData.characters = snapshot.charData.characters
        charData.fgColor = snapshot.charData.fgColor
        charData.bgColor = snapshot.charData.bgColor
        charData.isMultiColor = snapshot.charData.isMultiColor
        charData.multiColor1 = snapshot.charData.multiColor1
        charData.multiColor2 = snapshot.charData.multiColor2
        selectedChar = snapshot.selectedChar
        gridView?.charIndex = selectedChar
        gridView?.needsDisplay = true
        charMapView?.needsDisplay = true
        charIndexLabel?.stringValue = String(format: "Char: %d ($%02X)", selectedChar, selectedChar)
        updateExport()
    }

    override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 780, height: 620))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        charData.loadDefaultChars()
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
        sectionLabels.forEach { $0.textColor = AppTheme.current.syntaxKeyword }
        dimLabels.forEach     { $0.textColor = AppTheme.current.statusLabel }
        charIndexLabel?.textColor    = AppTheme.current.statusLabel
        previewLabel?.textColor      = AppTheme.current.statusLabel
        exportTextView?.backgroundColor  = AppTheme.current.panelDetailBackground
        exportTextView?.textColor        = AppTheme.current.syntaxFunction
        exportScrollView?.backgroundColor = AppTheme.current.panelDetailBackground
        gridView?.needsDisplay       = true
        charMapView?.needsDisplay    = true
    }

    private func buildUI() {
        view.wantsLayer = true
        view.layer?.backgroundColor = AppTheme.current.editorBackground.cgColor

        let gridLabel = makeLabel("CHARACTER EDITOR", x: 20, y: 580, bold: true)
        view.addSubview(gridLabel)

        charIndexLabel = makeLabel("Char: 1 ($01)", x: 200, y: 580, bold: false)
        view.addSubview(charIndexLabel)

        gridView = CharGridView(charData: charData, charIndex: selectedChar)
        gridView.frame = NSRect(x: 20, y: 300, width: 272, height: 272)
        gridView.onStrokeStart = { [weak self] in
            self?.pushUndo("Draw")
        }
        gridView.onPixelChanged = { [weak self] in
            self?.charMapView?.needsDisplay = true
            self?.updateExport()
            self?.onModified?()
            self?.charData.postDidChange()
        }
        view.addSubview(gridView)

        let btnY: CGFloat = 268
        let buttons: [(String, Selector, CGFloat)] = [
            ("Clear", #selector(clearChar(_:)), 20),
            ("Invert", #selector(invertChar(_:)), 75),
            ("FlipH", #selector(flipH(_:)), 140),
            ("FlipV", #selector(flipV(_:)), 200),
        ]
        for (title, action, x) in buttons {
            let btn = NSButton(title: title, target: self, action: action)
            btn.frame = NSRect(x: x, y: btnY, width: 55, height: 22)
            btn.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
            view.addSubview(btn)
        }

        let shiftY: CGFloat = 240
        let shiftLabel = makeLabel("SHIFT:", x: 20, y: shiftY + 2, bold: false)
        view.addSubview(shiftLabel)

        let shifts: [(String, Selector, CGFloat)] = [
            ("←", #selector(shiftLeft(_:)), 80),
            ("→", #selector(shiftRight(_:)), 110),
            ("↑", #selector(shiftUp(_:)), 140),
            ("↓", #selector(shiftDown(_:)), 170),
        ]
        for (title, action, x) in shifts {
            let btn = NSButton(title: title, target: self, action: action)
            btn.frame = NSRect(x: x, y: shiftY, width: 28, height: 22)
            btn.font = NSFont.systemFont(ofSize: 14)
            view.addSubview(btn)
        }

        let colorY: CGFloat = 195
        let fgLabel = makeLabel("FG:", x: 20, y: colorY + 2, bold: false)
        view.addSubview(fgLabel)

        for i in 0..<16 {
            let btn = ColorSwatchBtn(colorIndex: i, role: 0)
            btn.frame = NSRect(x: 50 + CGFloat(i) * 18, y: colorY, width: 16, height: 16)
            btn.target = self
            btn.action = #selector(fgColorClicked(_:))
            view.addSubview(btn)
        }

        let bgLabel = makeLabel("BG:", x: 20, y: colorY - 22, bold: false)
        view.addSubview(bgLabel)

        for i in 0..<16 {
            let btn = ColorSwatchBtn(colorIndex: i, role: 1)
            btn.frame = NSRect(x: 50 + CGFloat(i) * 18, y: colorY - 24, width: 16, height: 16)
            btn.target = self
            btn.action = #selector(bgColorClicked(_:))
            view.addSubview(btn)
        }

        let mapLabel = makeLabel("CHARACTER MAP", x: 320, y: 580, bold: true)
        view.addSubview(mapLabel)

        charMapView = CharMapView(charData: charData, selectedChar: selectedChar)
        charMapView.frame = NSRect(x: 320, y: 300, width: 432, height: 272)
        charMapView.onCharSelected = { [weak self] index in
            self?.selectChar(index)
        }
        view.addSubview(charMapView)

        let exportY: CGFloat = 140
        let exportLabel = makeLabel("EXPORT", x: 20, y: exportY, bold: true)
        view.addSubview(exportLabel)

        formatSelector = NSPopUpButton(frame: NSRect(x: 90, y: exportY - 2, width: 180, height: 22))
        formatSelector.addItems(withTitles: ["Selected Char (ASM)", "Selected Char (BASIC)", "Selected Char (Hex)", "Full Set (ASM)", "Full Set (BASIC)", "Full Set (Info)"])
        formatSelector.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        formatSelector.target = self
        formatSelector.action = #selector(formatChanged(_:))
        view.addSubview(formatSelector)

        let copyBtn = NSButton(title: "Copy", target: self, action: #selector(copyExport(_:)))
        copyBtn.frame = NSRect(x: 280, y: exportY - 2, width: 60, height: 22)
        copyBtn.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        view.addSubview(copyBtn)

        let sendToMapBtn = NSButton(title: "Send to Map Editor", target: self, action: #selector(sendToMapEditor(_:)))
        sendToMapBtn.frame = NSRect(x: 350, y: exportY - 2, width: 145, height: 22)
        sendToMapBtn.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        view.addSubview(sendToMapBtn)

        let importBtn = NSButton(title: "Import…", target: self, action: #selector(importCharset(_:)))
        importBtn.frame = NSRect(x: 505, y: exportY - 2, width: 75, height: 22)
        importBtn.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        view.addSubview(importBtn)

        let exportBinBtn = NSButton(title: "Save .bin", target: self, action: #selector(exportCharsetBinary(_:)))
        exportBinBtn.frame = NSRect(x: 590, y: exportY - 2, width: 75, height: 22)
        exportBinBtn.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        view.addSubview(exportBinBtn)

        let loadROMBtn = NSButton(title: "Load ROM", target: self, action: #selector(loadROMCharset(_:)))
        loadROMBtn.frame = NSRect(x: 675, y: exportY - 2, width: 75, height: 22)
        loadROMBtn.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        view.addSubview(loadROMBtn)

        exportTextView = NSTextView(frame: NSRect(x: 0, y: 0, width: 740, height: 100))
        exportTextView.isEditable = false
        exportTextView.isSelectable = true
        exportTextView.backgroundColor = AppTheme.current.panelDetailBackground
        exportTextView.textColor = AppTheme.current.syntaxFunction
        exportTextView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        exportTextView.textContainerInset = NSSize(width: 8, height: 4)

        exportScrollView = NSScrollView(frame: NSRect(x: 20, y: 20, width: 740, height: 110))
        exportScrollView.documentView = exportTextView
        exportScrollView.hasVerticalScroller = true
        exportScrollView.borderType = .noBorder
        view.addSubview(exportScrollView)

        updateExport()
    }

    @objc private func sendToMapEditor(_ sender: Any?) {
        charData.postSendToMapEditor()
    }

    private func makeLabel(_ text: String, x: CGFloat, y: CGFloat, bold: Bool) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: bold ? .bold : .regular)
        label.textColor = bold ? AppTheme.current.syntaxKeyword : AppTheme.current.statusLabel
        label.frame = NSRect(x: x, y: y, width: 200, height: 16)
        if bold { sectionLabels.append(label) } else { dimLabels.append(label) }
        return label
    }

    // MARK: - Character Selection

    private func selectChar(_ index: Int) {
        selectedChar = index
        gridView.charIndex = index
        gridView.needsDisplay = true
        charMapView.selectedChar = index
        charMapView.needsDisplay = true
        charIndexLabel.stringValue = String(format: "Char: %d ($%02X)", index, index)
        updateExport()
    }

    // MARK: - Keyboard

    override var acceptsFirstResponder: Bool { true }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        super.keyDown(with: event)
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

    @objc private func clearChar(_ sender: Any?) {
        pushUndo("Clear Char")
        charData.clearChar(selectedChar)
        gridView.needsDisplay = true
        charMapView.needsDisplay = true
        updateExport()
        charData.postDidChange()
    }

    @objc private func invertChar(_ sender: Any?) {
        pushUndo("Invert")
        charData.invertChar(selectedChar)
        gridView.needsDisplay = true
        charMapView.needsDisplay = true
        updateExport()
        charData.postDidChange()
    }

    @objc private func flipH(_ sender: Any?) {
        pushUndo("Flip H")
        charData.mirrorHChar(selectedChar)
        gridView.needsDisplay = true
        charMapView.needsDisplay = true
        updateExport()
        charData.postDidChange()
    }

    @objc private func flipV(_ sender: Any?) {
        pushUndo("Flip V")
        charData.mirrorVChar(selectedChar)
        gridView.needsDisplay = true
        charMapView.needsDisplay = true
        updateExport()
        charData.postDidChange()
    }

    @objc private func shiftLeft(_ sender: Any?) {
        pushUndo("Shift Left")
        charData.shiftChar(selectedChar, dx: -1, dy: 0)
        gridView.needsDisplay = true
        charMapView.needsDisplay = true
        updateExport()
        charData.postDidChange()
    }

    @objc private func shiftRight(_ sender: Any?) {
        pushUndo("Shift Right")
        charData.shiftChar(selectedChar, dx: 1, dy: 0)
        gridView.needsDisplay = true
        charMapView.needsDisplay = true
        updateExport()
        charData.postDidChange()
    }

    @objc private func shiftUp(_ sender: Any?) {
        pushUndo("Shift Up")
        charData.shiftChar(selectedChar, dx: 0, dy: -1)
        gridView.needsDisplay = true
        charMapView.needsDisplay = true
        updateExport()
        charData.postDidChange()
    }

    @objc private func shiftDown(_ sender: Any?) {
        pushUndo("Shift Down")
        charData.shiftChar(selectedChar, dx: 0, dy: 1)
        gridView.needsDisplay = true
        charMapView.needsDisplay = true
        updateExport()
        charData.postDidChange()
    }

    @objc private func fgColorClicked(_ sender: ColorSwatchBtn) {
        pushUndo("Change FG Color")
        charData.fgColor = sender.colorIndex
        gridView.needsDisplay = true
        charMapView.needsDisplay = true
        charData.postDidChange()
    }

    @objc private func bgColorClicked(_ sender: ColorSwatchBtn) {
        pushUndo("Change BG Color")
        charData.bgColor = sender.colorIndex
        gridView.needsDisplay = true
        charMapView.needsDisplay = true
        charData.postDidChange()
    }

    @objc private func formatChanged(_ sender: Any?) { updateExport() }

    @objc private func copyExport(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(exportTextView.string, forType: .string)
    }

    @objc private func importCharset(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .init(filenameExtension: "chr")!,
            .init(filenameExtension: "bin")!,
            .init(filenameExtension: "charset")!,
        ]
        panel.title = "Import Character Set"
        panel.message = "Select a 2048-byte (or larger) character set file."
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self = self else { return }
            guard var bytes = try? Data(contentsOf: url) else { return }

            // Strip 2-byte PRG load address header if present
            if bytes.count == 2050 || bytes.count == 4098 {
                bytes = bytes.dropFirst(2)
            }

            guard bytes.count >= 2048 else {
                let alert = NSAlert()
                alert.messageText = "Invalid Character Set"
                alert.informativeText = "Expected at least 2048 bytes (256 chars × 8 bytes)."
                alert.alertStyle = .warning
                alert.runModal()
                return
            }

            self.pushUndo("Import Charset")
            self.charData.loadFromBytes(Array(bytes.prefix(2048)))
            self.gridView.needsDisplay = true
            self.charMapView.needsDisplay = true
            self.updateExport()
            self.onModified?()
            self.charData.postDidChange()
        }
    }

    @objc private func exportCharsetBinary(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "bin")!]
        panel.nameFieldStringValue = "charset.bin"
        panel.title = "Export Character Set"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self = self else { return }
            let bytes = Data(self.charData.toBytes())
            do {
                try bytes.write(to: url, options: .atomic)
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }

    @objc private func loadROMCharset(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Load ROM Character Set"
        alert.informativeText = "This will replace all 256 characters with the standard C64 ROM charset (uppercase/graphics). This action can be undone."
        alert.addButton(withTitle: "Load")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        pushUndo("Load ROM Charset")
        charData.loadROMCharset()
        gridView.needsDisplay = true
        charMapView.needsDisplay = true
        updateExport()
        onModified?()
        charData.postDidChange()
    }

    // MARK: - Export

    private func updateExport() {
        let format = formatSelector?.indexOfSelectedItem ?? 0
        let bytes = charData.characters[selectedChar]

        switch format {
        case 0:
            let values = bytes.map { String(format: "$%02X", $0) }.joined(separator: ", ")
            exportTextView.string = String(format: "char_%d:  ; $%02X\n    .byte \(values)", selectedChar, selectedChar)
        case 1:
            let values = bytes.map { String($0) }.joined(separator: ",")
            exportTextView.string = "1000 REM CHAR \(selectedChar)\n1010 DATA \(values)"
        case 2:
            exportTextView.string = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        case 3:
            var lines = ["; Full C64 character set (2048 bytes)", "charset_data:"]
            for ch in 0..<256 {
                let row = charData.characters[ch]
                let isEmpty = row.allSatisfy { $0 == 0 }
                if !isEmpty {
                    let values = row.map { String(format: "$%02X", $0) }.joined(separator: ", ")
                    lines.append(String(format: "    ; Char %3d ($%02X)", ch, ch))
                    lines.append("    .byte \(values)")
                } else {
                    lines.append("    .byte $00, $00, $00, $00, $00, $00, $00, $00")
                }
            }
            exportTextView.string = lines.joined(separator: "\n")
        case 4:
            var lines = ["900 REM CHARACTER SET DATA"]
            var lineNum = 1000
            for ch in 0..<256 {
                let row = charData.characters[ch]
                let values = row.map { String($0) }.joined(separator: ",")
                lines.append("\(lineNum) DATA \(values) : REM CHR \(ch)")
                lineNum += 10
            }
            exportTextView.string = lines.joined(separator: "\n")
        case 5:
            let defined = charData.characters.filter { !$0.allSatisfy { $0 == 0 } }.count
            exportTextView.string = "; Full character set: 2048 bytes\n; Use .incbin \"charset.bin\" to include\n; Chars defined: \(defined) / 256\n; Load at $3000: LDA #$0C : STA $D018"
        default: break
        }
    }
}

// MARK: - Character Grid View (8x8 pixel editor)

/// Renders the active 8×8 character for editing with mouse drawing support.
class CharGridView: NSView {

    private let charData: CharSetData
    var charIndex: Int
    var onPixelChanged: (() -> Void)?
    var onStrokeStart: (() -> Void)?

    init(charData: CharSetData, charIndex: Int) {
        self.charData = charData
        self.charIndex = charIndex
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    private var cellSize: CGFloat { min(bounds.width, bounds.height) / 8.0 }

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSColor(hex: C64Reference.colorPalette[charData.bgColor].hex) ?? .black
        let fg = NSColor(hex: C64Reference.colorPalette[charData.fgColor].hex) ?? .white
        let cell = cellSize

        bg.setFill()
        bounds.fill()

        for row in 0..<8 {
            for col in 0..<8 {
                let pixel = charData.getPixel(char: charIndex, row: row, col: col)
                if pixel != 0 {
                    fg.setFill()
                    NSRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell, width: cell, height: cell).fill()
                }
            }
        }

        // CharGridView grid lines
        NSColor(white: AppTheme.current.isDark ? 0.30 : 0.65, alpha: 1.0).setStroke()
        let gridPath = NSBezierPath()
        for i in 0...8 {
            let pos = CGFloat(i) * cell
            gridPath.move(to: NSPoint(x: pos, y: 0))
            gridPath.line(to: NSPoint(x: pos, y: 8 * cell))
            gridPath.move(to: NSPoint(x: 0, y: pos))
            gridPath.line(to: NSPoint(x: 8 * cell, y: pos))
        }
        gridPath.stroke()

        // Border
        AppTheme.current.editorSelectionHighlight.withAlphaComponent(0.5).setStroke()
        let border = NSBezierPath(rect: NSRect(x: 0, y: 0, width: 8 * cell, height: 8 * cell).insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 2
        border.stroke()
    }

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
        let pt = convert(event.locationInWindow, from: nil)
        let cell = cellSize
        let col = Int(pt.x / cell)
        let row = Int(pt.y / cell)
        guard row >= 0, row < 8, col >= 0, col < 8 else { return }

        charData.setPixel(char: charIndex, row: row, col: col, value: erase ? 0 : 1)
        needsDisplay = true
        onPixelChanged?()
    }
}

// MARK: - Character Map View (256-char overview)

/// Renders the full 256-character overview grid with selection highlighting.
class CharMapView: NSView {

    private let charData: CharSetData
    var selectedChar: Int
    var onCharSelected: ((Int) -> Void)?

    init(charData: CharSetData, selectedChar: Int) {
        self.charData = charData
        self.selectedChar = selectedChar
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    private var charCellSize: CGSize {
        CGSize(width: bounds.width / 16.0, height: bounds.height / 16.0)
    }

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSColor(hex: C64Reference.colorPalette[charData.bgColor].hex) ?? .black
        let fg = NSColor(hex: C64Reference.colorPalette[charData.fgColor].hex) ?? .white
        let cell = charCellSize

        bg.setFill()
        bounds.fill()

        for charIdx in 0..<256 {
            let mapCol = charIdx % 16
            let mapRow = charIdx / 16
            let originX = CGFloat(mapCol) * cell.width
            let originY = CGFloat(mapRow) * cell.height

            let pixW = cell.width / 8.0
            let pixH = cell.height / 8.0

            for row in 0..<8 {
                for col in 0..<8 {
                    if charData.getPixel(char: charIdx, row: row, col: col) != 0 {
                        fg.setFill()
                        NSRect(x: originX + CGFloat(col) * pixW,
                               y: originY + CGFloat(row) * pixH,
                               width: pixW, height: pixH).fill()
                    }
                }
            }
        }

        // CharMapView grid lines
        NSColor(white: AppTheme.current.isDark ? 0.20 : 0.60, alpha: 0.5).setStroke()
        let gridPath = NSBezierPath()
        for i in 0...16 {
            let x = CGFloat(i) * cell.width
            let y = CGFloat(i) * cell.height
            gridPath.move(to: NSPoint(x: x, y: 0))
            gridPath.line(to: NSPoint(x: x, y: bounds.height))
            gridPath.move(to: NSPoint(x: 0, y: y))
            gridPath.line(to: NSPoint(x: bounds.width, y: y))
        }
        gridPath.stroke()

        // Highlight selected char
        let selCol = selectedChar % 16
        let selRow = selectedChar / 16
        AppTheme.current.editorSelectionHighlight.setStroke()
        let selRect = NSRect(x: CGFloat(selCol) * cell.width, y: CGFloat(selRow) * cell.height,
                             width: cell.width, height: cell.height).insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(rect: selRect)
        path.lineWidth = 2
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let cell = charCellSize
        let col = Int(pt.x / cell.width)
        let row = Int(pt.y / cell.height)
        guard col >= 0, col < 16, row >= 0, row < 16 else { return }
        let charIdx = row * 16 + col
        onCharSelected?(charIdx)
    }
}

// MARK: - Color Swatch Button (shared with sprite editor)

/// Custom button rendering a C64 palette color swatch.
class ColorSwatchBtn: NSButton {
    let colorIndex: Int
    let role: Int  // 0 = fg, 1 = bg

    init(colorIndex: Int, role: Int) {
        self.colorIndex = colorIndex
        self.role = role
        super.init(frame: .zero)
        self.isBordered = false
        self.title = ""
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let c = NSColor(hex: C64Reference.colorPalette[colorIndex].hex) ?? .black
        c.setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 2, yRadius: 2)
        path.fill()
        NSColor(white: AppTheme.current.isDark ? 0.4 : 0.6, alpha: 1).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }
}

