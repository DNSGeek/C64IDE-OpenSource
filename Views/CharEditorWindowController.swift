import Cocoa
import UniformTypeIdentifiers

// MARK: - Character Editor Window Controller

/// Manages the character set editor window, including unsaved changes handling.
class CharEditorWindowController: NSWindowController, NSWindowDelegate {

    var isModified = false

    /// The hosted editor. Exposed so the app delegate can prompt on quit.
    private(set) var editor: CharEditorViewController!

    /// Design size of the editor layout. The window must never be allowed to
    /// shrink below this or the character map and export pane get clipped.
    static let designSize = NSSize(width: 780, height: 700)

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: CharEditorWindowController.designSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Character Set Editor"
        window.center()
        window.contentMinSize = CharEditorWindowController.designSize
        window.titlebarAppearsTransparent = true
        window.backgroundColor = AppTheme.current.editorBackground
        self.init(window: window)
        window.delegate = self

        let editor = CharEditorViewController()
        editor.onModified = { [weak self] in self?.isModified = true }
        editor.onExported = { [weak self] in self?.isModified = false }
        self.editor = editor
        window.contentViewController = editor
    }

    /// Prompts to export unsaved charset changes before a destructive
    /// operation (close, quit). Returns `true` if the caller may proceed.
    @discardableResult
    func promptToSaveIfNeeded() -> Bool {
        guard isModified else { return true }
        let alert = NSAlert()
        alert.messageText = "You have unsaved changes in the Character Set Editor."
        alert.informativeText = "Export the character set before closing?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Export…")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return editor?.exportCharsetBinaryModally() ?? false
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        promptToSaveIfNeeded()
    }

    /// Intercepts the "Close Tab" menu action to close this window specifically.
    @objc func closeTab(_ sender: Any?) {
        window?.performClose(sender)
    }

    /// Routes ⌘S to the charset exporter. Without this the responder chain
    /// falls through to the app delegate, which would save the front source
    /// document instead of the charset.
    @objc func saveCurrentDocument(_ sender: Any?) {
        editor?.exportCharsetBinaryModally()
    }
}

// MARK: - Character Set Data Model

/// In-memory representation of a 256-character C64 charset.
class CharSetData {

    /// Number of characters in a C64 character set.
    static let charCount = 256

    /// Size in bytes of a full character set (256 chars × 8 bytes).
    static let byteCount = 2048

    /// 256 characters, each represented by 8 bytes (8×8 pixels).
    var characters: [[UInt8]] = Array(repeating: Array(repeating: 0, count: 8),
                                      count: CharSetData.charCount)

    /// Foreground and background color indices (0-15).
    var fgColor: Int = 14   // Light blue
    var bgColor: Int = 6    // Blue

    /// Multi-color mode configuration.
    /// In multi-color mode each row is read as four 2-bit pixel pairs:
    ///   00 = background ($D021), 01 = multiColor1 ($D022),
    ///   10 = multiColor2 ($D023), 11 = foreground (color RAM).
    var isMultiColor: Bool = false
    var multiColor1: Int = 1   // White
    var multiColor2: Int = 11  // Dark gray

    /// Number of editable columns for the current mode (8 hi-res, 4 multi-color).
    var columnCount: Int { isMultiColor ? 4 : 8 }

    private func isValid(_ index: Int) -> Bool { index >= 0 && index < CharSetData.charCount }

    /// Retrieves a single pixel value (0 or 1) from a character.
    func getPixel(char: Int, row: Int, col: Int) -> UInt8 {
        guard isValid(char), row >= 0, row < 8, col >= 0, col < 8 else { return 0 }
        return (characters[char][row] >> (7 - col)) & 1
    }

    /// Sets a single pixel value in a character.
    func setPixel(char: Int, row: Int, col: Int, value: UInt8) {
        guard isValid(char), row >= 0, row < 8, col >= 0, col < 8 else { return }
        if value != 0 {
            characters[char][row] |= (1 << (7 - col))
        } else {
            characters[char][row] &= ~(1 << (7 - col))
        }
    }

    /// Retrieves a multi-color pixel (2 bits, col 0-3).
    func getMultiPixel(char: Int, row: Int, col: Int) -> UInt8 {
        guard isValid(char), row >= 0, row < 8, col >= 0, col < 4 else { return 0 }
        let shift = 6 - col * 2
        return (characters[char][row] >> shift) & 0x03
    }

    /// Sets a multi-color pixel.
    func setMultiPixel(char: Int, row: Int, col: Int, value: UInt8) {
        guard isValid(char), row >= 0, row < 8, col >= 0, col < 4 else { return }
        let shift = 6 - col * 2
        characters[char][row] &= ~(0x03 << shift)
        characters[char][row] |= (value & 0x03) << shift
    }

    /// Reads a pixel in whichever mode is active. `col` is 0-7 in hi-res and
    /// 0-3 in multi-color.
    func value(char: Int, row: Int, col: Int) -> UInt8 {
        isMultiColor ? getMultiPixel(char: char, row: row, col: col)
                     : getPixel(char: char, row: row, col: col)
    }

    /// Writes a pixel in whichever mode is active.
    func setValue(char: Int, row: Int, col: Int, value: UInt8) {
        if isMultiColor {
            setMultiPixel(char: char, row: row, col: col, value: value)
        } else {
            setPixel(char: char, row: row, col: col, value: value == 0 ? 0 : 1)
        }
    }

    /// The C64 palette index a pixel value maps to in the current mode.
    func paletteIndex(forValue value: UInt8) -> Int {
        guard isMultiColor else { return value == 0 ? bgColor : fgColor }
        switch value {
        case 0:  return bgColor
        case 1:  return multiColor1
        case 2:  return multiColor2
        default: return fgColor
        }
    }

    /// Clears all pixels in a character.
    func clearChar(_ index: Int) {
        guard isValid(index) else { return }
        characters[index] = Array(repeating: 0, count: 8)
    }

    /// Inverts all pixels in a character.
    func invertChar(_ index: Int) {
        guard isValid(index) else { return }
        for row in 0..<8 {
            characters[index][row] = ~characters[index][row]
        }
    }

    /// Mirrors a character horizontally. In multi-color mode whole 2-bit
    /// pixel pairs are reversed, not individual bits, so colors survive.
    func mirrorHChar(_ index: Int) {
        guard isValid(index) else { return }
        for row in 0..<8 {
            let byte = characters[index][row]
            var reversed: UInt8 = 0
            if isMultiColor {
                for pair in 0..<4 {
                    let value = (byte >> (6 - pair * 2)) & 0x03
                    reversed |= value << (pair * 2)
                }
            } else {
                for bit in 0..<8 where byte & (1 << bit) != 0 {
                    reversed |= 1 << (7 - bit)
                }
            }
            characters[index][row] = reversed
        }
    }

    /// Mirrors a character vertically (reverses row order).
    func mirrorVChar(_ index: Int) {
        guard isValid(index) else { return }
        characters[index].reverse()
    }

    /// Shifts a character in the given direction with wrap-around.
    /// Horizontal shifts move a whole pixel: 1 bit in hi-res, 2 bits (one
    /// pixel pair) in multi-color mode.
    func shiftChar(_ index: Int, dx: Int, dy: Int) {
        guard isValid(index) else { return }
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
            let step = isMultiColor ? 2 : 1
            let mask: UInt8 = isMultiColor ? 0x03 : 0x01
            for row in 0..<8 {
                let byte = characters[index][row]
                if dx > 0 {
                    let carry = (byte & mask) << (8 - step)
                    characters[index][row] = (byte >> step) | carry
                } else {
                    let carry = (byte >> (8 - step)) & mask
                    characters[index][row] = (byte << step) | carry
                }
            }
        }
    }

    /// Exports the full 2048-byte character set.
    func toBytes() -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(CharSetData.byteCount)
        for ch in characters {
            result.append(contentsOf: ch)
        }
        return result
    }

    /// Imports a raw 2048-byte character set.
    func loadFromBytes(_ bytes: [UInt8]) {
        guard bytes.count >= CharSetData.byteCount else { return }
        for i in 0..<CharSetData.charCount {
            let offset = i * 8
            characters[i] = Array(bytes[offset..<offset + 8])
        }
    }

    /// The two character sets present in the C64 character ROM.
    enum ROMSet: Int {
        case uppercaseGraphics = 0
        case lowercaseUppercase = 1

        var title: String {
            switch self {
            case .uppercaseGraphics:  return "Uppercase / Graphics"
            case .lowercaseUppercase: return "Lowercase / Uppercase"
            }
        }
    }

    /// Loads one of the two standard C64 ROM character sets.
    func loadROMCharset(_ set: ROMSet = .uppercaseGraphics) {
        let rom = C64CharROM.romData
        let offset = set.rawValue * CharSetData.byteCount
        guard rom.count >= offset + CharSetData.byteCount else {
            loadFromBytes(Array(rom.prefix(CharSetData.byteCount)))
            return
        }
        loadFromBytes(Array(rom[offset..<offset + CharSetData.byteCount]))
    }

    /// Creates a deep copy for undo snapshots.
    func deepCopy() -> CharSetData {
        let copy = CharSetData()
        copy.characters = characters
        copy.fgColor = fgColor
        copy.bgColor = bgColor
        copy.isMultiColor = isMultiColor
        copy.multiColor1 = multiColor1
        copy.multiColor2 = multiColor2
        return copy
    }
}

// MARK: - Character Editor View Controller

/// Main editor controller handling UI, undo/redo, and export logic.
class CharEditorViewController: NSViewController, NSMenuItemValidation {

    private var charData = CharSetData()
    private var selectedChar: Int = 1  // Start with 'A'
    private var gridView: CharGridView!
    private var charMapView: CharMapView!
    private var charIndexLabel: NSTextField!
    private var exportTextView: NSTextView!
    private var exportScrollView: NSScrollView!
    private var formatSelector: NSPopUpButton!
    private var multiColorToggle: NSButton!
    private var penSelector: NSSegmentedControl!
    private var penLabel: NSTextField!
    private var mc1Label: NSTextField!
    private var mc2Label: NSTextField!
    /// All palette swatches, keyed by the register they edit
    /// (0 = fg, 1 = bg, 2 = mc1, 3 = mc2).
    private var swatchRows: [Int: [ColorSwatchBtn]] = [:]
    private var pasteButton: NSButton!

    /// One character's worth of bytes, for Copy/Paste Char.
    private var charClipboard: [UInt8]?

    var onModified: (() -> Void)?
    var onExported: (() -> Void)?

    /// Last charset payload broadcast to observers, used to suppress
    /// redundant notifications (each one forces a full Map Editor redraw).
    private var lastPostedCharset: Data?

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
        charMapView?.selectedChar = selectedChar
        gridView?.needsDisplay = true
        charMapView?.needsDisplay = true
        charIndexLabel?.stringValue = charLabel(for: selectedChar)
        syncMultiColorControls()
        updateExport()
        // Undo is an edit like any other: mark dirty and re-sync observers,
        // otherwise a live-synced Map Editor keeps showing the undone glyphs.
        onModified?()
        postCharsetChange()
    }

    override func loadView() {
        self.view = NSView(frame: NSRect(origin: .zero, size: CharEditorWindowController.designSize))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Start from the ROM charset: the Map Editor's fallback is the same
        // data, so "Send to Map Editor" no longer blanks an untouched map.
        charData.loadROMCharset(.uppercaseGraphics)
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
        multiColorToggle?.contentTintColor = AppTheme.current.defaultText
        exportTextView?.backgroundColor  = AppTheme.current.panelDetailBackground
        exportTextView?.textColor        = AppTheme.current.syntaxFunction
        exportScrollView?.backgroundColor = AppTheme.current.panelDetailBackground
        gridView?.needsDisplay       = true
        charMapView?.needsDisplay    = true
    }

    // MARK: - UI Construction

    private func buildUI() {
        view.wantsLayer = true
        view.layer?.backgroundColor = AppTheme.current.editorBackground.cgColor

        let gridLabel = makeLabel("CHARACTER EDITOR", x: 20, y: 676, bold: true)
        view.addSubview(gridLabel)

        charIndexLabel = makeLabel(charLabel(for: selectedChar), x: 200, y: 676, bold: false)
        view.addSubview(charIndexLabel)

        gridView = CharGridView(charData: charData, charIndex: selectedChar)
        gridView.frame = NSRect(x: 20, y: 396, width: 272, height: 272)
        gridView.autoresizingMask = [.minYMargin]
        gridView.onStrokeWillModify = { [weak self] in
            self?.pushUndo("Draw")
        }
        gridView.onPixelChanged = { [weak self] in
            guard let self else { return }
            self.charMapView?.needsDisplay = true
            // Full-set export text is rebuilt once at the end of the stroke.
            self.updateExport(duringStroke: true)
            self.onModified?()
        }
        gridView.onStrokeEnd = { [weak self] in
            guard let self else { return }
            self.updateExport()
            self.postCharsetChange()
        }
        view.addSubview(gridView)

        // ── Character operations ─────────────────────────────────────────
        let btnY: CGFloat = 364
        let buttons: [(String, Selector, CGFloat, CGFloat)] = [
            ("Clear", #selector(clearChar(_:)), 20, 55),
            ("Invert", #selector(invertChar(_:)), 79, 58),
            ("FlipH", #selector(flipH(_:)), 141, 52),
            ("FlipV", #selector(flipV(_:)), 197, 52),
        ]
        for (title, action, x, w) in buttons {
            view.addSubview(makeButton(title, action: action, x: x, y: btnY, width: w))
        }

        let shiftY: CGFloat = 336
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
            btn.autoresizingMask = [.minYMargin]
            btn.font = NSFont.systemFont(ofSize: 14)
            view.addSubview(btn)
        }

        view.addSubview(makeButton("Copy", action: #selector(copyChar(_:)), x: 206, y: shiftY, width: 50))
        pasteButton = makeButton("Paste", action: #selector(pasteChar(_:)), x: 258, y: shiftY, width: 52)
        pasteButton.isEnabled = false
        view.addSubview(pasteButton)

        // ── Multi-color mode ─────────────────────────────────────────────
        let mcY: CGFloat = 306
        multiColorToggle = NSButton(checkboxWithTitle: "Multi-Color", target: self,
                                    action: #selector(toggleMultiColor(_:)))
        multiColorToggle.frame = NSRect(x: 18, y: mcY, width: 110, height: 20)
        multiColorToggle.autoresizingMask = [.minYMargin]
        multiColorToggle.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        multiColorToggle.contentTintColor = AppTheme.current.defaultText
        view.addSubview(multiColorToggle)

        penLabel = makeLabel("PEN:", x: 134, y: mcY + 2, bold: false)
        penLabel.frame.size.width = 34
        view.addSubview(penLabel)

        penSelector = NSSegmentedControl(labels: ["BG", "MC1", "MC2", "FG"],
                                         trackingMode: .selectOne,
                                         target: self, action: #selector(penChanged(_:)))
        penSelector.frame = NSRect(x: 170, y: mcY - 1, width: 140, height: 22)
        penSelector.autoresizingMask = [.minYMargin]
        penSelector.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        penSelector.selectedSegment = 3
        view.addSubview(penSelector)

        // ── Color rows ───────────────────────────────────────────────────
        addSwatchRow(title: "FG:",  y: 278, action: #selector(fgColorClicked(_:)),  role: 0)
        addSwatchRow(title: "BG:",  y: 252, action: #selector(bgColorClicked(_:)),  role: 1)
        mc1Label = addSwatchRow(title: "MC1:", y: 226, action: #selector(mc1ColorClicked(_:)), role: 2)
        mc2Label = addSwatchRow(title: "MC2:", y: 200, action: #selector(mc2ColorClicked(_:)), role: 3)

        // ── Character map ────────────────────────────────────────────────
        let mapLabel = makeLabel("CHARACTER MAP", x: 320, y: 676, bold: true)
        view.addSubview(mapLabel)

        // Square so the 16×16 preview cells are not horizontally stretched.
        charMapView = CharMapView(charData: charData, selectedChar: selectedChar)
        charMapView.frame = NSRect(x: 320, y: 396, width: 272, height: 272)
        charMapView.autoresizingMask = [.minYMargin]
        charMapView.onCharSelected = { [weak self] index in
            self?.selectChar(index)
        }
        view.addSubview(charMapView)

        // ── Export ───────────────────────────────────────────────────────
        let exportY: CGFloat = 170
        let exportLabel = makeLabel("EXPORT", x: 20, y: exportY, bold: true)
        view.addSubview(exportLabel)

        formatSelector = NSPopUpButton(frame: NSRect(x: 90, y: exportY - 2, width: 180, height: 22))
        formatSelector.addItems(withTitles: ["Selected Char (ASM)", "Selected Char (BASIC)", "Selected Char (Hex)", "Full Set (ASM)", "Full Set (BASIC)", "Full Set (Info)"])
        formatSelector.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        formatSelector.autoresizingMask = [.minYMargin]
        formatSelector.target = self
        formatSelector.action = #selector(formatChanged(_:))
        view.addSubview(formatSelector)

        let exportButtons: [(String, Selector, CGFloat, CGFloat)] = [
            ("Copy", #selector(copyExport(_:)), 280, 60),
            ("Send to Map Editor", #selector(sendToMapEditor(_:)), 350, 145),
            ("Import…", #selector(importCharset(_:)), 505, 75),
            ("Save .bin", #selector(exportCharsetBinary(_:)), 590, 75),
            ("Load ROM", #selector(loadROMCharset(_:)), 675, 75),
        ]
        for (title, action, x, w) in exportButtons {
            view.addSubview(makeButton(title, action: action, x: x, y: exportY - 2, width: w))
        }

        exportTextView = NSTextView(frame: NSRect(x: 0, y: 0, width: 740, height: 140))
        exportTextView.isEditable = false
        exportTextView.isSelectable = true
        exportTextView.backgroundColor = AppTheme.current.panelDetailBackground
        exportTextView.textColor = AppTheme.current.syntaxFunction
        exportTextView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        exportTextView.textContainerInset = NSSize(width: 8, height: 4)

        exportScrollView = NSScrollView(frame: NSRect(x: 20, y: 20, width: 740, height: 140))
        exportScrollView.documentView = exportTextView
        exportScrollView.hasVerticalScroller = true
        exportScrollView.borderType = .noBorder
        // Only the export pane absorbs extra window space.
        exportScrollView.autoresizingMask = [.width, .height]
        view.addSubview(exportScrollView)

        syncMultiColorControls()
        updateExport()
    }

    /// Builds a labelled row of 16 C64 palette swatches. Returns the row label
    /// so multi-color rows can be shown/hidden as a unit.
    @discardableResult
    private func addSwatchRow(title: String, y: CGFloat, action: Selector, role: Int) -> NSTextField {
        let label = makeLabel(title, x: 20, y: y + 2, bold: false)
        view.addSubview(label)
        var row: [ColorSwatchBtn] = []
        for i in 0..<16 {
            let btn = ColorSwatchBtn(colorIndex: i, role: role)
            btn.frame = NSRect(x: 50 + CGFloat(i) * 18, y: y, width: 16, height: 16)
            btn.autoresizingMask = [.minYMargin]
            btn.target = self
            btn.action = action
            view.addSubview(btn)
            row.append(btn)
        }
        swatchRows[role] = row
        return label
    }

    /// Rings the swatch that matches each register's current value, so the
    /// active foreground/background/multi-color choices are visible.
    private func refreshSwatchSelection() {
        let selected = [0: charData.fgColor, 1: charData.bgColor,
                        2: charData.multiColor1, 3: charData.multiColor2]
        for (role, row) in swatchRows {
            for btn in row where btn.isSelectedSwatch != (btn.colorIndex == selected[role]) {
                btn.isSelectedSwatch = btn.colorIndex == selected[role]
            }
        }
    }

    private func makeButton(_ title: String, action: Selector, x: CGFloat, y: CGFloat, width: CGFloat) -> NSButton {
        let btn = NSButton(title: title, target: self, action: action)
        btn.frame = NSRect(x: x, y: y, width: width, height: 22)
        btn.autoresizingMask = [.minYMargin]
        btn.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        return btn
    }

    private func makeLabel(_ text: String, x: CGFloat, y: CGFloat, bold: Bool) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: bold ? .bold : .regular)
        label.textColor = bold ? AppTheme.current.syntaxKeyword : AppTheme.current.statusLabel
        label.frame = NSRect(x: x, y: y, width: 200, height: 16)
        label.autoresizingMask = [.minYMargin]
        if bold { sectionLabels.append(label) } else { dimLabels.append(label) }
        return label
    }

    private func charLabel(for index: Int) -> String {
        String(format: "Char: %d ($%02X)", index, index)
    }

    /// Shows or hides the multi-color-only controls to match the current mode.
    private func syncMultiColorControls() {
        let mc = charData.isMultiColor
        multiColorToggle?.state = mc ? .on : .off
        penSelector?.isHidden = !mc
        penLabel?.isHidden = !mc
        mc1Label?.isHidden = !mc
        mc2Label?.isHidden = !mc
        swatchRows[2]?.forEach { $0.isHidden = !mc }
        swatchRows[3]?.forEach { $0.isHidden = !mc }
        gridView?.drawValue = mc ? UInt8(max(0, penSelector?.selectedSegment ?? 3)) : 1
        refreshSwatchSelection()
    }

    // MARK: - Change Broadcasting

    /// Posts the charset to observers (the Map Editor) unless nothing changed
    /// since the last post. Called at edit boundaries, never per-pixel.
    private func postCharsetChange() {
        let bytes = Data(charData.toBytes())
        let unchanged = bytes == lastPostedCharset
            && charData.fgColor == lastPostedFg
            && charData.bgColor == lastPostedBg
            && charData.isMultiColor == lastPostedMC
            && charData.multiColor1 == lastPostedMC1
            && charData.multiColor2 == lastPostedMC2
        guard !unchanged else { return }
        lastPostedCharset = bytes
        lastPostedFg = charData.fgColor
        lastPostedBg = charData.bgColor
        lastPostedMC = charData.isMultiColor
        lastPostedMC1 = charData.multiColor1
        lastPostedMC2 = charData.multiColor2
        charData.postDidChange()
    }

    private var lastPostedFg = -1
    private var lastPostedBg = -1
    private var lastPostedMC = false
    private var lastPostedMC1 = -1
    private var lastPostedMC2 = -1

    /// Runs a discrete (non-stroke) edit: snapshot, mutate, refresh, notify.
    private func applyEdit(_ label: String, _ body: () -> Void) {
        pushUndo(label)
        body()
        refreshSwatchSelection()
        gridView?.needsDisplay = true
        charMapView?.needsDisplay = true
        updateExport()
        onModified?()
        postCharsetChange()
    }

    // MARK: - Character Selection

    private func selectChar(_ index: Int) {
        guard index >= 0, index < CharSetData.charCount else { return }
        selectedChar = index
        gridView.charIndex = index
        gridView.needsDisplay = true
        charMapView.selectedChar = index
        charMapView.needsDisplay = true
        charIndexLabel.stringValue = charLabel(for: index)
        updateExport()
    }

    // MARK: - Keyboard

    override var acceptsFirstResponder: Bool { true }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        // Arrow keys walk the character map; everything else falls through.
        let step: Int
        switch event.keyCode {
        case 123: step = -1   // left
        case 124: step = 1    // right
        case 126: step = -16  // up
        case 125: step = 16   // down
        default:
            super.keyDown(with: event)
            return
        }
        let next = selectedChar + step
        guard next >= 0, next < CharSetData.charCount else { return }
        selectChar(next)
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
        if menuItem.action == #selector(pasteChar(_:)) {
            return charClipboard != nil
        }
        return true
    }

    // MARK: - Actions

    @objc private func clearChar(_ sender: Any?) {
        applyEdit("Clear Char") { charData.clearChar(selectedChar) }
    }

    @objc private func invertChar(_ sender: Any?) {
        applyEdit("Invert") { charData.invertChar(selectedChar) }
    }

    @objc private func flipH(_ sender: Any?) {
        applyEdit("Flip H") { charData.mirrorHChar(selectedChar) }
    }

    @objc private func flipV(_ sender: Any?) {
        applyEdit("Flip V") { charData.mirrorVChar(selectedChar) }
    }

    @objc private func shiftLeft(_ sender: Any?) {
        applyEdit("Shift Left") { charData.shiftChar(selectedChar, dx: -1, dy: 0) }
    }

    @objc private func shiftRight(_ sender: Any?) {
        applyEdit("Shift Right") { charData.shiftChar(selectedChar, dx: 1, dy: 0) }
    }

    @objc private func shiftUp(_ sender: Any?) {
        applyEdit("Shift Up") { charData.shiftChar(selectedChar, dx: 0, dy: -1) }
    }

    @objc private func shiftDown(_ sender: Any?) {
        applyEdit("Shift Down") { charData.shiftChar(selectedChar, dx: 0, dy: 1) }
    }

    @objc private func copyChar(_ sender: Any?) {
        charClipboard = charData.characters[selectedChar]
        pasteButton?.isEnabled = true
    }

    @objc private func pasteChar(_ sender: Any?) {
        guard let bytes = charClipboard else { return }
        applyEdit("Paste Char") { charData.characters[selectedChar] = bytes }
    }

    @objc private func toggleMultiColor(_ sender: NSButton) {
        // The bytes are unchanged; multi-color simply reinterprets each row
        // as four 2-bit pixel pairs, exactly as the VIC-II does.
        applyEdit("Toggle Multi-Color") {
            charData.isMultiColor = sender.state == .on
        }
        syncMultiColorControls()
    }

    @objc private func penChanged(_ sender: NSSegmentedControl) {
        gridView?.drawValue = UInt8(max(0, sender.selectedSegment))
    }

    @objc private func fgColorClicked(_ sender: ColorSwatchBtn) {
        applyEdit("Change FG Color") { charData.fgColor = sender.colorIndex }
    }

    @objc private func bgColorClicked(_ sender: ColorSwatchBtn) {
        applyEdit("Change BG Color") { charData.bgColor = sender.colorIndex }
    }

    @objc private func mc1ColorClicked(_ sender: ColorSwatchBtn) {
        applyEdit("Change MC1 Color") { charData.multiColor1 = sender.colorIndex }
    }

    @objc private func mc2ColorClicked(_ sender: ColorSwatchBtn) {
        applyEdit("Change MC2 Color") { charData.multiColor2 = sender.colorIndex }
    }

    @objc private func formatChanged(_ sender: Any?) { updateExport() }

    @objc private func copyExport(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(exportTextView.string, forType: .string)
    }

    @objc private func sendToMapEditor(_ sender: Any?) {
        charData.postSendToMapEditor()
    }

    // MARK: - Import / Export

    /// File types accepted as a raw character set.
    private static let charsetTypes = ["chr", "bin", "charset", "64c", "prg", "raw"]

    @objc private func importCharset(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = CharEditorViewController.charsetTypes.compactMap {
            UTType(filenameExtension: $0)
        }
        panel.title = "Import Character Set"
        panel.message = "Select a 2048-byte (or larger) character set file."
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self = self else { return }
            guard let bytes = try? Data(contentsOf: url) else {
                self.warn("Could Not Read File", "\(url.lastPathComponent) could not be opened.")
                return
            }

            guard let charset = CharEditorViewController.extractCharset(from: bytes) else {
                self.warn("Invalid Character Set",
                          "Expected at least 2048 bytes (256 chars × 8 bytes); this file has \(bytes.count).")
                return
            }

            self.applyEdit("Import Charset") {
                self.charData.loadFromBytes(charset)
            }
        }
    }

    /// Extracts 2048 charset bytes from a file, stripping a 2-byte PRG load
    /// address when the remainder is an exact multiple of the charset size.
    static func extractCharset(from data: Data) -> [UInt8]? {
        var bytes = data
        let hasLoadAddress = (bytes.count - 2) >= CharSetData.byteCount
            && (bytes.count - 2) % CharSetData.byteCount == 0
            && bytes.count % CharSetData.byteCount != 0
        if hasLoadAddress { bytes = bytes.dropFirst(2) }
        guard bytes.count >= CharSetData.byteCount else { return nil }
        return Array(bytes.prefix(CharSetData.byteCount))
    }

    private func warn(_ message: String, _ info: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.alertStyle = .warning
        alert.runModal()
    }

    /// Where the charset was last written, so ⌘S and the close prompt can
    /// save without asking again.
    private var lastExportURL: URL?

    private func makeSavePanel() -> NSSavePanel {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "bin")].compactMap { $0 }
        panel.nameFieldStringValue = lastExportURL?.lastPathComponent ?? "charset.bin"
        panel.directoryURL = lastExportURL?.deletingLastPathComponent()
        panel.title = "Export Character Set"
        return panel
    }

    /// "Save .bin" always asks, so it doubles as Save As.
    @objc private func exportCharsetBinary(_ sender: Any?) {
        let panel = makeSavePanel()
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self = self else { return }
            self.write(to: url)
        }
    }

    /// Synchronous export, for callers that must know the outcome before
    /// proceeding (the close/quit prompt, ⌘S). Writes straight to the last
    /// exported file when there is one.
    @discardableResult
    func exportCharsetBinaryModally() -> Bool {
        if let url = lastExportURL { return write(to: url) }
        let panel = makeSavePanel()
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return write(to: url)
    }

    @discardableResult
    private func write(to url: URL) -> Bool {
        do {
            try Data(charData.toBytes()).write(to: url, options: .atomic)
            lastExportURL = url
            // The charset now exists on disk, so there is nothing unsaved.
            onExported?()
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    @objc private func loadROMCharset(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Load ROM Character Set"
        alert.informativeText = "This replaces all 256 characters with a standard C64 ROM charset. This action can be undone."
        alert.addButton(withTitle: CharSetData.ROMSet.uppercaseGraphics.title)
        alert.addButton(withTitle: CharSetData.ROMSet.lowercaseUppercase.title)
        alert.addButton(withTitle: "Cancel")

        let set: CharSetData.ROMSet
        switch alert.runModal() {
        case .alertFirstButtonReturn:  set = .uppercaseGraphics
        case .alertSecondButtonReturn: set = .lowercaseUppercase
        default: return
        }

        applyEdit("Load ROM Charset") { charData.loadROMCharset(set) }
    }

    // MARK: - Export Text

    /// Rebuilds the export pane. During a paint stroke the whole-set formats
    /// are skipped — regenerating 2300 lines per mouse event is pure waste;
    /// the stroke-end callback rebuilds them once.
    private func updateExport(duringStroke: Bool = false) {
        let format = formatSelector?.indexOfSelectedItem ?? 0
        guard !(duringStroke && format >= 3) else { return }
        let bytes = charData.characters[selectedChar]

        switch format {
        case 0:
            let values = bytes.map { String(format: "$%02X", $0) }.joined(separator: ", ")
            exportTextView.string = String(format: "char_%d:  ; $%02X\n", selectedChar, selectedChar)
                + "    .byte \(values)"
        case 1:
            let values = bytes.map { String($0) }.joined(separator: ",")
            exportTextView.string = "1000 REM CHAR \(selectedChar)\n1010 DATA \(values)"
        case 2:
            exportTextView.string = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        case 3:
            var lines = ["; Full C64 character set (2048 bytes)", "charset_data:"]
            lines.reserveCapacity(CharSetData.charCount * 2 + 2)
            for ch in 0..<CharSetData.charCount {
                let row = charData.characters[ch]
                let values = row.map { String(format: "$%02X", $0) }.joined(separator: ", ")
                if !row.allSatisfy({ $0 == 0 }) {
                    lines.append(String(format: "    ; Char %3d ($%02X)", ch, ch))
                }
                lines.append("    .byte \(values)")
            }
            exportTextView.string = lines.joined(separator: "\n")
        case 4:
            var lines = ["900 REM CHARACTER SET DATA"]
            lines.reserveCapacity(CharSetData.charCount + 1)
            var lineNum = 1000
            for ch in 0..<CharSetData.charCount {
                let values = charData.characters[ch].map { String($0) }.joined(separator: ",")
                lines.append("\(lineNum) DATA \(values) : REM CHR \(ch)")
                lineNum += 10
            }
            exportTextView.string = lines.joined(separator: "\n")
        case 5:
            let defined = charData.characters.filter { !$0.allSatisfy { $0 == 0 } }.count
            var lines = [
                "; Full character set: 2048 bytes",
                "; Use .incbin \"charset.bin\" to include",
                "; Chars defined: \(defined) / 256",
                "; Load at $3000: LDA #$0C : STA $D018",
                "; $D021 background = \(charData.bgColor) (\(colorName(charData.bgColor)))",
                "; Color RAM        = \(charData.fgColor) (\(colorName(charData.fgColor)))",
            ]
            if charData.isMultiColor {
                lines.append("; $D022 multi-color 1 = \(charData.multiColor1) (\(colorName(charData.multiColor1))) [bit-pair 01]")
                lines.append("; $D023 multi-color 2 = \(charData.multiColor2) (\(colorName(charData.multiColor2))) [bit-pair 10]")
                lines.append("; set bit 4 of $D016 to enable multi-color text mode")
                lines.append("; a cell is multi-color only when its color RAM value is 8-15")
            }
            exportTextView.string = lines.joined(separator: "\n")
        default: break
        }
    }

    private func colorName(_ index: Int) -> String {
        guard index >= 0, index < C64Reference.colorPalette.count else { return "?" }
        return C64Reference.colorPalette[index].name
    }
}

// MARK: - Shared C64 Color Helper

/// Resolves a C64 palette index to an NSColor using the single shared
/// palette definition in `C64Reference`.
func c64PaletteColor(_ index: Int) -> NSColor {
    guard index >= 0, index < C64Reference.colorPalette.count else { return .black }
    return NSColor(hex: C64Reference.colorPalette[index].hex) ?? .black
}

// MARK: - Character Grid View (8x8 pixel editor)

/// Renders the active 8×8 character for editing with mouse drawing support.
class CharGridView: NSView {

    private let charData: CharSetData
    var charIndex: Int

    /// Pixel value painted by the left mouse button. Always 1 in hi-res;
    /// 0-3 in multi-color mode (selected with the pen control).
    var drawValue: UInt8 = 1

    var onPixelChanged: (() -> Void)?

    /// Called immediately before the first actual pixel change of a stroke,
    /// so the undo snapshot is taken from the pre-stroke state — and clicks
    /// that change nothing never push an undo entry.
    var onStrokeWillModify: (() -> Void)?

    /// Called on mouse-up if the stroke modified anything.
    var onStrokeEnd: (() -> Void)?

    private var strokeDidModify = false
    private var lastCell: (row: Int, col: Int)?

    init(charData: CharSetData, charIndex: Int) {
        self.charData = charData
        self.charIndex = charIndex
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    /// Size of one bit cell (hi-res pixel). Multi-color pixels are two wide.
    private var cellSize: CGFloat { min(bounds.width, bounds.height) / 8.0 }

    override func draw(_ dirtyRect: NSRect) {
        let cell = cellSize
        let cols = charData.columnCount
        let colWidth = cell * CGFloat(8 / cols)

        c64PaletteColor(charData.bgColor).setFill()
        bounds.fill()

        for row in 0..<8 {
            for col in 0..<cols {
                let value = charData.value(char: charIndex, row: row, col: col)
                guard value != 0 else { continue }
                c64PaletteColor(charData.paletteIndex(forValue: value)).setFill()
                NSRect(x: CGFloat(col) * colWidth, y: CGFloat(row) * cell,
                       width: colWidth, height: cell).fill()
            }
        }

        // CharGridView grid lines — one per editable pixel
        NSColor(white: AppTheme.current.isDark ? 0.30 : 0.65, alpha: 1.0).setStroke()
        let gridPath = NSBezierPath()
        for i in 0...cols {
            let x = CGFloat(i) * colWidth
            gridPath.move(to: NSPoint(x: x, y: 0))
            gridPath.line(to: NSPoint(x: x, y: 8 * cell))
        }
        for i in 0...8 {
            let y = CGFloat(i) * cell
            gridPath.move(to: NSPoint(x: 0, y: y))
            gridPath.line(to: NSPoint(x: 8 * cell, y: y))
        }
        gridPath.stroke()

        // Border
        AppTheme.current.editorSelectionHighlight.withAlphaComponent(0.5).setStroke()
        let border = NSBezierPath(rect: NSRect(x: 0, y: 0, width: 8 * cell, height: 8 * cell).insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 2
        border.stroke()
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) { beginStroke(event, erase: false) }
    override func mouseDragged(with event: NSEvent) { continueStroke(event, erase: false) }
    override func rightMouseDown(with event: NSEvent) { beginStroke(event, erase: true) }
    override func rightMouseDragged(with event: NSEvent) { continueStroke(event, erase: true) }

    override func mouseUp(with event: NSEvent) { endStroke() }
    override func rightMouseUp(with event: NSEvent) { endStroke() }

    private func beginStroke(_ event: NSEvent, erase: Bool) {
        strokeDidModify = false
        lastCell = nil
        continueStroke(event, erase: erase)
    }

    private func endStroke() {
        lastCell = nil
        if strokeDidModify {
            strokeDidModify = false
            onStrokeEnd?()
        }
    }

    private func continueStroke(_ event: NSEvent, erase: Bool) {
        guard let cell = cellCoordinate(for: event) else {
            lastCell = nil
            return
        }
        let value: UInt8 = erase ? 0 : drawValue
        var changed = false

        // Interpolate from the previous cell: fast drags deliver far fewer
        // events than cells crossed, which would otherwise leave gaps.
        if let previous = lastCell {
            for point in CharGridView.line(from: previous, to: cell) {
                changed = paint(row: point.row, col: point.col, value: value) || changed
            }
        } else {
            changed = paint(row: cell.row, col: cell.col, value: value)
        }
        lastCell = cell

        if changed {
            needsDisplay = true
            onPixelChanged?()
        }
    }

    /// Writes one pixel, reporting whether it actually changed.
    private func paint(row: Int, col: Int, value: UInt8) -> Bool {
        guard charData.value(char: charIndex, row: row, col: col) != value else { return false }
        if !strokeDidModify {
            strokeDidModify = true
            onStrokeWillModify?()
        }
        charData.setValue(char: charIndex, row: row, col: col, value: value)
        return true
    }

    /// Converts an event to a (row, col) inside the grid, or nil if outside.
    private func cellCoordinate(for event: NSEvent) -> (row: Int, col: Int)? {
        let point = convert(event.locationInWindow, from: nil)
        let cell = cellSize
        guard cell > 0 else { return nil }
        let cols = charData.columnCount
        let colWidth = cell * CGFloat(8 / cols)
        // floor(), not Int(): Int() truncates toward zero, so a coordinate
        // just outside the top/left edge would land on row/col 0 and paint
        // the edge while dragging outside the view.
        let col = Int(floor(point.x / colWidth))
        let row = Int(floor(point.y / cell))
        guard row >= 0, row < 8, col >= 0, col < cols else { return nil }
        return (row, col)
    }

    /// Bresenham line between two grid cells, inclusive of both ends.
    private static func line(from a: (row: Int, col: Int), to b: (row: Int, col: Int)) -> [(row: Int, col: Int)] {
        var points: [(row: Int, col: Int)] = []
        var (x0, y0) = (a.col, a.row)
        let (x1, y1) = (b.col, b.row)
        let dx = abs(x1 - x0), sx = x0 < x1 ? 1 : -1
        let dy = -abs(y1 - y0), sy = y0 < y1 ? 1 : -1
        var err = dx + dy
        while true {
            points.append((row: y0, col: x0))
            if x0 == x1 && y0 == y1 { break }
            let e2 = 2 * err
            if e2 >= dy { err += dy; x0 += sx }
            if e2 <= dx { err += dx; y0 += sy }
        }
        return points
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

    /// Square cells, so preview glyphs keep their aspect ratio.
    private var charCellSize: CGFloat { min(bounds.width, bounds.height) / 16.0 }

    override func draw(_ dirtyRect: NSRect) {
        let cell = charCellSize
        let cols = charData.columnCount
        let pixW = cell / CGFloat(cols)
        let pixH = cell / 8.0
        let gridSide = cell * 16

        c64PaletteColor(charData.bgColor).setFill()
        bounds.fill()

        // Cache the four possible pixel colors instead of resolving a hex
        // string for every one of the 16k pixels drawn here.
        let palette = (0...3).map { c64PaletteColor(charData.paletteIndex(forValue: UInt8($0))) }

        for charIdx in 0..<CharSetData.charCount {
            let originX = CGFloat(charIdx % 16) * cell
            let originY = CGFloat(charIdx / 16) * cell

            for row in 0..<8 {
                for col in 0..<cols {
                    let value = charData.value(char: charIdx, row: row, col: col)
                    guard value != 0 else { continue }
                    palette[Int(value)].setFill()
                    NSRect(x: originX + CGFloat(col) * pixW,
                           y: originY + CGFloat(row) * pixH,
                           width: pixW, height: pixH).fill()
                }
            }
        }

        // CharMapView grid lines
        NSColor(white: AppTheme.current.isDark ? 0.20 : 0.60, alpha: 0.5).setStroke()
        let gridPath = NSBezierPath()
        for i in 0...16 {
            let pos = CGFloat(i) * cell
            gridPath.move(to: NSPoint(x: pos, y: 0))
            gridPath.line(to: NSPoint(x: pos, y: gridSide))
            gridPath.move(to: NSPoint(x: 0, y: pos))
            gridPath.line(to: NSPoint(x: gridSide, y: pos))
        }
        gridPath.stroke()

        // Highlight selected char
        AppTheme.current.editorSelectionHighlight.setStroke()
        let selRect = NSRect(x: CGFloat(selectedChar % 16) * cell,
                             y: CGFloat(selectedChar / 16) * cell,
                             width: cell, height: cell).insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(rect: selRect)
        path.lineWidth = 2
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let cell = charCellSize
        guard cell > 0 else { return }
        let col = Int(floor(point.x / cell))
        let row = Int(floor(point.y / cell))
        guard col >= 0, col < 16, row >= 0, row < 16 else { return }
        onCharSelected?(row * 16 + col)
    }
}

// MARK: - Color Swatch Button

/// Custom button rendering a C64 palette color swatch.
class ColorSwatchBtn: NSButton {
    let colorIndex: Int

    /// Which color register this swatch edits: 0 = fg, 1 = bg, 2 = mc1, 3 = mc2.
    let role: Int

    /// Draws a ring when this swatch holds its register's current value.
    var isSelectedSwatch = false { didSet { needsDisplay = true } }

    init(colorIndex: Int, role: Int) {
        self.colorIndex = colorIndex
        self.role = role
        super.init(frame: .zero)
        self.isBordered = false
        self.title = ""
        self.toolTip = colorIndex < C64Reference.colorPalette.count
            ? "\(colorIndex): \(C64Reference.colorPalette[colorIndex].name)"
            : nil
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        c64PaletteColor(colorIndex).setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 2, yRadius: 2)
        path.fill()
        if isSelectedSwatch {
            AppTheme.current.editorSelectionHighlight.setStroke()
            path.lineWidth = 2
        } else {
            NSColor(white: AppTheme.current.isDark ? 0.4 : 0.6, alpha: 1).setStroke()
            path.lineWidth = 0.5
        }
        path.stroke()
    }
}
