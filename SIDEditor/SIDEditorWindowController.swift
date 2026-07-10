import Cocoa
import UniformTypeIdentifiers

// MARK: - SID Editor Window Controller

class SIDEditorWindowController: NSWindowController, NSWindowDelegate {

    var isModified = false

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 870),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SID Editor"
        window.center()
        window.minSize = NSSize(width: 700, height: 700)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = AppTheme.current.panelBackground

        self.init(window: window)
        window.delegate = self

        let editor = SIDEditorViewController()
        editor.onModified = { [weak self] in self?.isModified = true }
        editor.onSaved    = { [weak self] in self?.isModified = false }
        window.contentViewController = editor
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard isModified else { return true }
        let alert = NSAlert()
        alert.messageText = "You have unsaved changes in the SID Editor."
        alert.informativeText = "Do you want to save your song before closing?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            guard let editor = window?.contentViewController as? SIDEditorViewController else { return true }
            return editor.saveSong(forcePrompt: false)  // False if user cancels the save panel
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    @objc func closeTab(_ sender: Any?) {
        window?.performClose(sender)
    }
}

// MARK: - SID Editor View Controller

class SIDEditorViewController: NSViewController, NSMenuItemValidation {

    private var song = SIDSong()
    private var currentInstrument: Int = 0
    private var currentPattern: Int = 0
    private var cursorRow: Int = 0
    private var cursorVoice: Int = 0

    var onModified: (() -> Void)?
    var onSaved: (() -> Void)?

    /// URL of the currently open .sidsong file, if any.
    private var currentFileURL: URL?

    /// Uniform type for .sidsong files (dynamic; no Info.plist registration required).
    private static let sidsongType = UTType(filenameExtension: "sidsong")

    // MARK: - Undo / Redo Responder Actions

    @objc func undo(_ sender: Any?) { performUndo() }
    @objc func redo(_ sender: Any?) { performRedo() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(undo(_:)) { return !undoStack.isEmpty }
        if menuItem.action == #selector(redo(_:)) { return !redoStack.isEmpty }
        return true
    }

    // Undo system
    private struct UndoSnapshot {
        let song: SIDSong
        let currentInstrument: Int
        let currentPattern: Int
        let label: String
    }
    private var undoStack: [UndoSnapshot] = []
    private var redoStack: [UndoSnapshot] = []
    private let maxUndoLevels = 50
    private var sectionLabels: [NSTextField] = []
    private var dimLabels:     [NSTextField] = []

    private func pushUndo(_ label: String) {
        let snapshot = UndoSnapshot(
            song: song.deepCopy(),
            currentInstrument: currentInstrument,
            currentPattern: currentPattern,
            label: label
        )
        undoStack.append(snapshot)
        if undoStack.count > maxUndoLevels { undoStack.removeFirst() }
        redoStack.removeAll()
        // Reset slider coalescing unless this IS a slider push
        if label != lastSliderUndoLabel { lastSliderUndoLabel = nil }
    }

    private func performUndo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(UndoSnapshot(song: song.deepCopy(), currentInstrument: currentInstrument, currentPattern: currentPattern, label: snapshot.label))
        restoreSnapshot(snapshot)
    }

    private func performRedo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(UndoSnapshot(song: song.deepCopy(), currentInstrument: currentInstrument, currentPattern: currentPattern, label: snapshot.label))
        restoreSnapshot(snapshot)
    }

    private func restoreSnapshot(_ snapshot: UndoSnapshot) {
        song.title = snapshot.song.title
        song.author = snapshot.song.author
        song.speed = snapshot.song.speed
        song.instruments = snapshot.song.instruments
        song.patterns = snapshot.song.patterns
        song.sequence = snapshot.song.sequence
        song.filterCutoff = snapshot.song.filterCutoff
        song.filterResonance = snapshot.song.filterResonance
        song.filterType = snapshot.song.filterType
        song.filterVoices = snapshot.song.filterVoices
        song.globalVolume = snapshot.song.globalVolume
        currentInstrument = min(snapshot.currentInstrument, song.instruments.count - 1)
        currentPattern = min(snapshot.currentPattern, song.patterns.count - 1)
        refreshAllUI()
        markModified()
    }

    /// Refreshes all UI elements from current song state.
    private func refreshAllUI() {
        refreshInstrumentSelector()
        refreshInstrumentUI()
        refreshPatternSelector()
        for btn in filterButtons {
            btn.state = song.filterType & UInt8(1 << btn.tag) != 0 ? .on : .off
        }
        for btn in filterVoiceButtons {
            btn.state = song.filterVoices & UInt8(1 << btn.tag) != 0 ? .on : .off
        }
        trackerView?.currentInstrument = currentInstrument
        trackerView?.patternIndex = currentPattern
        trackerView?.needsDisplay = true
        updateTrackerContentSize()
        speedField?.integerValue = song.speed
    }

    /// Rebuilds the pattern popup to match the song's pattern list.
    private func refreshPatternSelector() {
        guard let patternSelector else { return }
        patternSelector.removeAllItems()
        for i in song.patterns.indices {
            patternSelector.addItem(withTitle: String(format: "Pat %02d", i))
        }
        patternSelector.selectItem(at: currentPattern)
    }

    /// Resizes tracker document view to fit the current pattern's row count.
    private func updateTrackerContentSize() {
        guard let tv = trackerView, currentPattern < song.patterns.count else { return }
        let rows = song.patterns[currentPattern].length
        let contentHeight = CGFloat(rows + 1) * 16
        tv.frame = NSRect(x: 0, y: 0, width: tv.frame.width, height: contentHeight)
    }

    // Instrument UI
    private var instrNameField: NSTextField!
    private var waveButtons: [NSButton] = []
    private var adsrSliders: [NSSlider] = []
    private var adsrLabels: [NSTextField] = []
    private var pwSlider: NSSlider!
    private var pwLabel: NSTextField!
    private var envelopeView: ADSREnvelopeView!
    private var instrSelector: NSPopUpButton!

    // Filter UI
    private var cutoffSlider: NSSlider!
    private var resonanceSlider: NSSlider!
    private var volumeSlider: NSSlider!
    private var filterButtons: [NSButton] = []
    private var filterVoiceButtons: [NSButton] = []

    // Tracker UI
    private var trackerView: TrackerView!
    private var trackerScrollView: NSScrollView!
    private var speedField: NSTextField!
    private var patternSelector: NSPopUpButton!

    // Export
    private var exportTextView: NSTextView!

    // Layout
    private var trackerTopY: CGFloat = 0

    // Audio
    private var audioEngine = SIDAudioEngine()
    private var playButton: NSButton!
    private var stopButton: NSButton!
    private var previewButton: NSButton!

    private var bgColor: NSColor { AppTheme.current.panelBackground }

    override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 870))
        view.wantsLayer = true
        view.layer?.backgroundColor = bgColor.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        refreshInstrumentUI()
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
        updateWindowTitle()
    }

    private func applyThemeColors() {
        view.window?.appearance      = AppTheme.current.nsAppearance
        view.window?.backgroundColor = AppTheme.current.panelBackground
        view.layer?.backgroundColor  = AppTheme.current.panelBackground.cgColor
        sectionLabels.forEach { $0.textColor = AppTheme.current.syntaxKeyword }
        dimLabels.forEach     { $0.textColor = AppTheme.current.statusLabel }
        adsrLabels.forEach    { $0.textColor = AppTheme.current.statusLabel }
        exportTextView?.backgroundColor  = AppTheme.current.panelDetailBackground
        exportTextView?.textColor        = AppTheme.current.syntaxFunction
        envelopeView?.needsDisplay       = true
        trackerView?.needsDisplay        = true
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard trackerScrollView != nil else { return }
        let msgBarTop: CGFloat = 80  // y=12 + height=60 + 8pt gap
        let trackerHeight = trackerTopY - msgBarTop
        trackerScrollView.frame = NSRect(x: 12, y: msgBarTop, width: view.bounds.width - 24, height: max(trackerHeight, 32))
    }

    // MARK: - Build UI

    private func buildUI() {
        var y = view.bounds.height - 10

        // ═══════════════════════════════════════════════════
        // INSTRUMENT EDITOR (top section)
        // ═══════════════════════════════════════════════════

        y -= 20
        let instLabel = makeLabel("INSTRUMENT", bold: true, color: AppTheme.current.syntaxKeyword)
        instLabel.frame = NSRect(x: 12, y: y, width: 120, height: 16)
        view.addSubview(instLabel)

        instrSelector = NSPopUpButton(frame: NSRect(x: 120, y: y - 2, width: 140, height: 20))
        instrSelector.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        instrSelector.target = self
        instrSelector.action = #selector(instrumentSelected(_:))
        view.addSubview(instrSelector)

        let addInstBtn = NSButton(title: "+", target: self, action: #selector(addInstrument(_:)))
        addInstBtn.frame = NSRect(x: 265, y: y - 2, width: 24, height: 20)
        addInstBtn.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        view.addSubview(addInstBtn)

        instrNameField = NSTextField(string: "New Sound")
        instrNameField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        instrNameField.frame = NSRect(x: 300, y: y - 2, width: 150, height: 20)
        instrNameField.target = self
        instrNameField.action = #selector(instrNameChanged(_:))
        view.addSubview(instrNameField)

        previewButton = NSButton(title: "♪ Preview", target: self, action: #selector(previewInstrument(_:)))
        previewButton.frame = NSRect(x: 460, y: y - 2, width: 85, height: 20)
        previewButton.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        view.addSubview(previewButton)

        // File buttons (top right)
        let fileBtns: [(String, Selector, CGFloat, CGFloat)] = [
            ("Open...",    #selector(openDocument(_:)),   570, 70),
            ("Save",       #selector(saveDocument(_:)),   645, 60),
            ("Save As...", #selector(saveDocumentAs(_:)), 710, 95),
        ]
        for (title, action, x, w) in fileBtns {
            let btn = NSButton(title: title, target: self, action: action)
            btn.frame = NSRect(x: x, y: y - 2, width: w, height: 20)
            btn.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
            view.addSubview(btn)
        }

        // ── Waveform buttons ─────────────────────────────
        y -= 30
        let waveLabel = makeLabel("WAVEFORM", bold: true, color: AppTheme.current.syntaxOperator)
        waveLabel.frame = NSRect(x: 12, y: y, width: 80, height: 16)
        view.addSubview(waveLabel)

        let waveNames = ["TRI", "SAW", "PUL", "NOI"]
        let waveValues: [SIDWaveform] = [.triangle, .sawtooth, .pulse, .noise]
        for (i, name) in waveNames.enumerated() {
            let btn = NSButton(checkboxWithTitle: name, target: self, action: #selector(waveformChanged(_:)))
            btn.tag = Int(waveValues[i].rawValue)
            btn.frame = NSRect(x: 100 + CGFloat(i) * 65, y: y, width: 60, height: 18)
            btn.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
            let attrTitle = NSAttributedString(string: name, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: AppTheme.current.defaultText,
            ])
            btn.attributedTitle = attrTitle
            view.addSubview(btn)
            waveButtons.append(btn)
        }

        // Pulse width
        let pwl = makeLabel("PW:", bold: false, color: AppTheme.current.statusLabel)
        pwl.frame = NSRect(x: 370, y: y, width: 30, height: 16)
        view.addSubview(pwl)

        pwSlider = NSSlider(value: 2048, minValue: 0, maxValue: 4095, target: self, action: #selector(pwChanged(_:)))
        pwSlider.frame = NSRect(x: 400, y: y, width: 120, height: 18)
        view.addSubview(pwSlider)

        pwLabel = makeLabel("2048", bold: false, color: AppTheme.current.statusLabel)
        pwLabel.frame = NSRect(x: 525, y: y, width: 50, height: 16)
        view.addSubview(pwLabel)

        // ── ADSR sliders + envelope view ─────────────────
        y -= 28
        let adsrLabel = makeLabel("ADSR ENVELOPE", bold: true, color: AppTheme.current.syntaxOperator)
        adsrLabel.frame = NSRect(x: 12, y: y, width: 120, height: 16)
        view.addSubview(adsrLabel)

        y -= 24
        let adsrNames = ["A:", "D:", "S:", "R:"]
        let adsrDefaults: [Double] = [2, 8, 6, 4]
        for (i, name) in adsrNames.enumerated() {
            let lbl = makeLabel(name, bold: false, color: AppTheme.current.statusLabel)
            lbl.frame = NSRect(x: 12, y: y - CGFloat(i) * 24, width: 20, height: 16)
            view.addSubview(lbl)

            let slider = NSSlider(value: adsrDefaults[i], minValue: 0, maxValue: 15, target: self, action: #selector(adsrChanged(_:)))
            slider.tag = i
            slider.numberOfTickMarks = 16
            slider.allowsTickMarkValuesOnly = true
            slider.frame = NSRect(x: 35, y: y - CGFloat(i) * 24, width: 180, height: 18)
            view.addSubview(slider)
            adsrSliders.append(slider)

            let valLabel = makeLabel(String(Int(adsrDefaults[i])), bold: false, color: AppTheme.current.syntaxKeyword)
            valLabel.frame = NSRect(x: 220, y: y - CGFloat(i) * 24, width: 30, height: 16)
            view.addSubview(valLabel)
            adsrLabels.append(valLabel)
        }

        // ADSR envelope visualization
        envelopeView = ADSREnvelopeView()
        envelopeView.frame = NSRect(x: 270, y: y - 90, width: 280, height: 110)
        envelopeView.onValuesChanged = { [weak self] a, d, s, r in
            guard let self, self.currentInstrument < self.song.instruments.count else { return }
            // Coalesce all drag events under a single undo entry (pushed on first movement)
            let label = "Drag ADSR"
            if self.lastSliderUndoLabel != label { self.pushUndo(label); self.lastSliderUndoLabel = label }
            let inst = self.song.instruments[self.currentInstrument]
            inst.attack  = a
            inst.decay   = d
            inst.sustain = s
            inst.release = r
            // Sync sliders and value labels
            self.adsrSliders[0].integerValue = a
            self.adsrSliders[1].integerValue = d
            self.adsrSliders[2].integerValue = s
            self.adsrSliders[3].integerValue = r
            self.adsrLabels[0].stringValue = "\(a)"
            self.adsrLabels[1].stringValue = "\(d)"
            self.adsrLabels[2].stringValue = "\(s)"
            self.adsrLabels[3].stringValue = "\(r)"
            self.envelopeView.attack  = a
            self.envelopeView.decay   = d
            self.envelopeView.sustain = s
            self.envelopeView.release = r
            self.markModified()
        }
        envelopeView.onDragEnded = { [weak self] in
            // Clear coalescing key so the next gesture gets its own undo entry
            self?.lastSliderUndoLabel = nil
        }
        view.addSubview(envelopeView)

        // ── Filter & Volume ──────────────────────────────
        let filterX: CGFloat = 570
        let filterLabel = makeLabel("FILTER", bold: true, color: AppTheme.current.syntaxOperator)
        filterLabel.frame = NSRect(x: filterX, y: y + 24, width: 60, height: 16)
        view.addSubview(filterLabel)

        let filterNames = ["LP", "BP", "HP"]
        for (i, name) in filterNames.enumerated() {
            let btn = NSButton(checkboxWithTitle: name, target: self, action: #selector(filterTypeChanged(_:)))
            btn.tag = 4 + i  // Bits 4, 5, 6
            btn.frame = NSRect(x: filterX + CGFloat(i) * 45, y: y, width: 40, height: 18)
            btn.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
            let attrTitle = NSAttributedString(string: name, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
                .foregroundColor: AppTheme.current.defaultText,
            ])
            btn.attributedTitle = attrTitle
            view.addSubview(btn)
            filterButtons.append(btn)
        }

        let cutLabel = makeLabel("Cut:", bold: false, color: AppTheme.current.statusLabel)
        cutLabel.frame = NSRect(x: filterX, y: y - 24, width: 30, height: 16)
        view.addSubview(cutLabel)
        cutoffSlider = NSSlider(value: 1024, minValue: 0, maxValue: 2047, target: self, action: #selector(filterChanged(_:)))
        cutoffSlider.frame = NSRect(x: filterX + 32, y: y - 24, width: 150, height: 18)
        view.addSubview(cutoffSlider)

        let resLabel = makeLabel("Res:", bold: false, color: AppTheme.current.statusLabel)
        resLabel.frame = NSRect(x: filterX, y: y - 48, width: 30, height: 16)
        view.addSubview(resLabel)
        resonanceSlider = NSSlider(value: 0, minValue: 0, maxValue: 15, target: self, action: #selector(filterChanged(_:)))
        resonanceSlider.frame = NSRect(x: filterX + 32, y: y - 48, width: 150, height: 18)
        view.addSubview(resonanceSlider)

        let volLabel = makeLabel("Vol:", bold: false, color: AppTheme.current.statusLabel)
        volLabel.frame = NSRect(x: filterX, y: y - 72, width: 30, height: 16)
        view.addSubview(volLabel)
        volumeSlider = NSSlider(value: 15, minValue: 0, maxValue: 15, target: self, action: #selector(volumeChanged(_:)))
        volumeSlider.frame = NSRect(x: filterX + 32, y: y - 72, width: 150, height: 18)
        view.addSubview(volumeSlider)

        // Filter voice routing ($D417 bits 0-2). A voice not routed here
        // plays dry on real hardware no matter what LP/BP/HP are set to.
        let routeLabel = makeLabel("Voices:", bold: false, color: AppTheme.current.statusLabel)
        routeLabel.frame = NSRect(x: filterX, y: y - 96, width: 50, height: 16)
        view.addSubview(routeLabel)

        for i in 0..<3 {
            let btn = NSButton(checkboxWithTitle: "\(i + 1)", target: self, action: #selector(filterVoiceChanged(_:)))
            btn.tag = i  // Bit index into filterVoices
            btn.frame = NSRect(x: filterX + 52 + CGFloat(i) * 40, y: y - 96, width: 36, height: 18)
            btn.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
            let attrTitle = NSAttributedString(string: "\(i + 1)", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
                .foregroundColor: AppTheme.current.defaultText,
            ])
            btn.attributedTitle = attrTitle
            view.addSubview(btn)
            filterVoiceButtons.append(btn)
        }

        // ═══════════════════════════════════════════════════
        // TRACKER (bottom section)
        // ═══════════════════════════════════════════════════

        let trackerY = y - 120
        let trackerLabel = makeLabel("TRACKER", bold: true, color: AppTheme.current.syntaxKeyword)
        trackerLabel.frame = NSRect(x: 12, y: trackerY, width: 80, height: 16)
        view.addSubview(trackerLabel)

        // Pattern selector
        patternSelector = NSPopUpButton(frame: NSRect(x: 100, y: trackerY - 2, width: 80, height: 20))
        patternSelector.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        patternSelector.addItem(withTitle: "Pat 00")
        patternSelector.target = self
        patternSelector.action = #selector(patternSelected(_:))
        view.addSubview(patternSelector)

        let addPatBtn = NSButton(title: "+", target: self, action: #selector(addPattern(_:)))
        addPatBtn.frame = NSRect(x: 185, y: trackerY - 2, width: 24, height: 20)
        addPatBtn.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        view.addSubview(addPatBtn)

        // Speed
        let speedLabel = makeLabel("Speed:", bold: false, color: AppTheme.current.statusLabel)
        speedLabel.frame = NSRect(x: 220, y: trackerY, width: 50, height: 16)
        view.addSubview(speedLabel)

        speedField = NSTextField(string: "6")
        speedField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        speedField.frame = NSRect(x: 275, y: trackerY - 2, width: 35, height: 20)
        speedField.target = self
        speedField.action = #selector(speedChanged(_:))
        view.addSubview(speedField)

        // Export buttons
        let exportBtns: [(String, Selector)] = [
            ("▶ Play", #selector(playPattern(_:))),
            ("■ Stop", #selector(stopPlayback(_:))),
            ("Export ASM", #selector(exportASM(_:))),
            ("Export BASIC", #selector(exportBASIC(_:))),
            ("Copy", #selector(copyExport(_:))),
        ]
        var ebx: CGFloat = 330
        for (title, action) in exportBtns {
            let btn = NSButton(title: title, target: self, action: action)
            btn.frame = NSRect(x: ebx, y: trackerY - 2, width: 85, height: 20)
            btn.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
            view.addSubview(btn)
            ebx += 90
        }

        // Tracker grid (wrapped in scroll view)
        let trackerGridY = trackerY - 26
        trackerTopY = CGFloat(trackerGridY)
        let scrollFrame = NSRect(x: 12, y: 80, width: view.bounds.width - 24, height: CGFloat(trackerGridY - 80))

        trackerView = TrackerView(song: song, patternIndex: 0)
        let contentHeight = CGFloat(song.patterns[0].length + 1) * 16
        trackerView.frame = NSRect(x: 0, y: 0, width: scrollFrame.width, height: contentHeight)
        trackerView.autoresizingMask = [.width]
        trackerView.onNoteEntered = { [weak self] voice, row, note in
            self?.pushUndo("Note Entry")
            self?.song.patterns[self?.currentPattern ?? 0].notes[voice][row] = note
            self?.trackerView.needsDisplay = true
            self?.markModified()
        }
        trackerView.onNotePreview = { [weak self] noteNum in
            guard let self = self, self.currentInstrument < self.song.instruments.count else { return }
            let inst = self.song.instruments[self.currentInstrument]
            self.audioEngine.onRowAdvanced = nil
            self.audioEngine.onPlaybackStopped = nil
            self.audioEngine.playNote(instrument: inst, noteNumber: noteNum, duration: 0.3,
                                      filterCutoff: self.song.filterCutoff,
                                      filterResonance: self.song.filterResonance,
                                      filterType: self.song.filterType,
                                      filterVoices: self.song.filterVoices)
        }
        // Undo/Redo — callbacks ready for future SID undo implementation
        trackerView.onUndo = { [weak self] in self?.performUndo() }
        trackerView.onRedo = { [weak self] in self?.performRedo() }

        trackerScrollView = NSScrollView(frame: scrollFrame)
        trackerScrollView.documentView = trackerView
        trackerScrollView.hasVerticalScroller = true
        trackerScrollView.autoresizingMask = [.width, .height]
        trackerScrollView.drawsBackground = false
        view.addSubview(trackerScrollView)

        // Export text (bottom strip)
        let exportTV = NSTextView(frame: NSRect(x: 0, y: 0, width: view.bounds.width - 24, height: 60))
        exportTV.isEditable = false
        exportTV.isSelectable = true
        exportTV.backgroundColor = AppTheme.current.panelDetailBackground
        exportTV.textColor = AppTheme.current.syntaxFunction
        exportTV.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        exportTV.textContainerInset = NSSize(width: 6, height: 4)
        exportTextView = exportTV

        let exportScroll = NSScrollView(frame: NSRect(x: 12, y: 12, width: view.bounds.width - 24, height: 60))
        exportScroll.autoresizingMask = [.width]
        exportScroll.documentView = exportTV
        exportScroll.hasVerticalScroller = true
        exportScroll.borderType = .noBorder
        view.addSubview(exportScroll)

        refreshInstrumentSelector()
    }

    private func makeLabel(_ text: String, bold: Bool, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: bold ? .bold : .regular)
        label.textColor = color
        if bold { sectionLabels.append(label) } else { dimLabels.append(label) }
        return label
    }

    // MARK: - Refresh UI

    private func refreshInstrumentUI() {
        guard currentInstrument < song.instruments.count else { return }
        let inst = song.instruments[currentInstrument]

        instrNameField.stringValue = inst.name

        for btn in waveButtons {
            btn.state = inst.waveform.rawValue & UInt8(btn.tag) != 0 ? .on : .off
        }

        adsrSliders[0].integerValue = inst.attack
        adsrSliders[1].integerValue = inst.decay
        adsrSliders[2].integerValue = inst.sustain
        adsrSliders[3].integerValue = inst.release

        for (i, slider) in adsrSliders.enumerated() {
            adsrLabels[i].stringValue = "\(slider.integerValue)"
        }

        pwSlider.integerValue = inst.pulseWidth
        pwLabel.stringValue = "\(inst.pulseWidth)"

        envelopeView.attack = inst.attack
        envelopeView.decay = inst.decay
        envelopeView.sustain = inst.sustain
        envelopeView.release = inst.release
        envelopeView.needsDisplay = true

        cutoffSlider.integerValue = song.filterCutoff
        resonanceSlider.integerValue = song.filterResonance
        volumeSlider.integerValue = song.globalVolume
    }

    private func refreshInstrumentSelector() {
        instrSelector.removeAllItems()
        for (i, inst) in song.instruments.enumerated() {
            instrSelector.addItem(withTitle: String(format: "%02d: %@", i, inst.name))
        }
        instrSelector.selectItem(at: currentInstrument)
    }

    // MARK: - Instrument Actions

    @objc private func instrumentSelected(_ sender: NSPopUpButton) {
        currentInstrument = sender.indexOfSelectedItem
        trackerView.currentInstrument = currentInstrument
        refreshInstrumentUI()
    }

    @objc private func addInstrument(_ sender: Any?) {
        pushUndo("Add Instrument")
        let inst = SIDInstrument()
        inst.name = "Sound \(song.instruments.count)"
        song.instruments.append(inst)
        currentInstrument = song.instruments.count - 1
        trackerView.currentInstrument = currentInstrument
        refreshInstrumentSelector()
        refreshInstrumentUI()
        markModified()
    }

    @objc private func instrNameChanged(_ sender: NSTextField) {
        guard currentInstrument < song.instruments.count else { return }
        pushUndo("Rename Instrument")
        song.instruments[currentInstrument].name = sender.stringValue
        refreshInstrumentSelector()
        markModified()
    }

    @objc private func waveformChanged(_ sender: NSButton) {
        guard currentInstrument < song.instruments.count else { return }
        pushUndo("Change Waveform")
        let inst = song.instruments[currentInstrument]
        let bit = SIDWaveform(rawValue: UInt8(sender.tag))
        if sender.state == .on {
            inst.waveform.insert(bit)
        } else {
            inst.waveform.remove(bit)
        }
        refreshInstrumentUI()
        markModified()
    }

    // Track last slider undo label to coalesce continuous slider drags
    private var lastSliderUndoLabel: String?

    @objc private func adsrChanged(_ sender: NSSlider) {
        guard currentInstrument < song.instruments.count else { return }
        let label = "Change ADSR"
        if lastSliderUndoLabel != label { pushUndo(label); lastSliderUndoLabel = label }
        let inst = song.instruments[currentInstrument]
        let val = sender.integerValue
        switch sender.tag {
        case 0: inst.attack = val
        case 1: inst.decay = val
        case 2: inst.sustain = val
        case 3: inst.release = val
        default: break
        }
        adsrLabels[sender.tag].stringValue = "\(val)"
        envelopeView.attack = inst.attack
        envelopeView.decay = inst.decay
        envelopeView.sustain = inst.sustain
        envelopeView.release = inst.release
        envelopeView.needsDisplay = true
        markModified()
    }

    @objc private func pwChanged(_ sender: NSSlider) {
        guard currentInstrument < song.instruments.count else { return }
        let label = "Change Pulse Width"
        if lastSliderUndoLabel != label { pushUndo(label); lastSliderUndoLabel = label }
        song.instruments[currentInstrument].pulseWidth = sender.integerValue
        pwLabel.stringValue = "\(sender.integerValue)"
        markModified()
    }

    @objc private func filterTypeChanged(_ sender: NSButton) {
        pushUndo("Change Filter Type")
        lastSliderUndoLabel = nil
        let bit = UInt8(1 << sender.tag)
        if sender.state == .on {
            song.filterType |= bit
        } else {
            song.filterType &= ~bit
        }
        markModified()
    }

    @objc private func filterVoiceChanged(_ sender: NSButton) {
        pushUndo("Change Filter Routing")
        lastSliderUndoLabel = nil
        let bit = UInt8(1 << sender.tag)
        if sender.state == .on {
            song.filterVoices |= bit
        } else {
            song.filterVoices &= ~bit
        }
        markModified()
    }

    @objc private func filterChanged(_ sender: Any?) {
        let label = "Change Filter"
        if lastSliderUndoLabel != label { pushUndo(label); lastSliderUndoLabel = label }
        song.filterCutoff = cutoffSlider.integerValue
        song.filterResonance = resonanceSlider.integerValue
        markModified()
    }

    @objc private func volumeChanged(_ sender: Any?) {
        let label = "Change Volume"
        if lastSliderUndoLabel != label { pushUndo(label); lastSliderUndoLabel = label }
        song.globalVolume = volumeSlider.integerValue
        markModified()
    }

    // MARK: - Pattern Actions

    @objc private func patternSelected(_ sender: NSPopUpButton) {
        currentPattern = sender.indexOfSelectedItem
        trackerView.patternIndex = currentPattern
        updateTrackerContentSize()
        trackerView.needsDisplay = true
    }

    @objc private func addPattern(_ sender: Any?) {
        pushUndo("Add Pattern")
        lastSliderUndoLabel = nil
        song.patterns.append(SIDPattern())
        song.sequence.append(song.patterns.count - 1)
        currentPattern = song.patterns.count - 1
        patternSelector.addItem(withTitle: String(format: "Pat %02d", currentPattern))
        patternSelector.selectItem(at: currentPattern)
        trackerView.patternIndex = currentPattern
        updateTrackerContentSize()
        trackerView.needsDisplay = true
        markModified()
    }

    @objc private func speedChanged(_ sender: NSTextField) {
        pushUndo("Change Speed")
        lastSliderUndoLabel = nil
        song.speed = max(1, min(20, sender.integerValue))
        markModified()
    }

    // MARK: - Export

    @objc private func exportASM(_ sender: Any?) {
        exportTextView.string = song.exportAsAssembly()
    }

    @objc private func exportBASIC(_ sender: Any?) {
        exportTextView.string = song.exportAsBASIC()
    }

    @objc private func copyExport(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(exportTextView.string, forType: .string)
    }

    // MARK: - Save / Load

    // Standard responder-chain selectors: if the app's File menu items use
    // saveDocument:/saveDocumentAs:/openDocument:, Cmd-S / Cmd-Shift-S / Cmd-O
    // route here automatically while this editor is key.
    @objc func saveDocument(_ sender: Any?) { saveSong(forcePrompt: false) }
    @objc func saveDocumentAs(_ sender: Any?) { saveSong(forcePrompt: true) }
    @objc func openDocument(_ sender: Any?) { openSong() }

    /// Marks the song as having unsaved changes.
    private func markModified() {
        view.window?.isDocumentEdited = true
        onModified?()
    }

    /// Marks the song as clean (just saved or just loaded).
    private func markSaved() {
        view.window?.isDocumentEdited = false
        onSaved?()
        updateWindowTitle()
    }

    /// Reflects the current file (if any) in the window title and proxy icon.
    private func updateWindowTitle() {
        guard let window = view.window else { return }
        if let url = currentFileURL {
            window.title = "SID Editor - \(url.lastPathComponent)"
            window.representedURL = url
        } else {
            window.title = "SID Editor"
            window.representedURL = nil
        }
    }

    /// Saves the song to its current file, prompting for a location when
    /// there is none yet or when forcePrompt is true (Save As).
    /// Returns false if the user cancelled or the write failed.
    @discardableResult
    func saveSong(forcePrompt: Bool) -> Bool {
        var url = currentFileURL

        if url == nil || forcePrompt {
            let panel = NSSavePanel()
            panel.title = "Save SID Song"
            panel.canCreateDirectories = true
            if let type = SIDEditorViewController.sidsongType {
                panel.allowedContentTypes = [type]
            }
            let suggested = song.title.isEmpty ? "Untitled" : song.title
            panel.nameFieldStringValue = suggested
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            guard panel.runModal() == .OK, let chosen = panel.url else { return false }
            url = chosen
        }

        guard let url else { return false }

        do {
            try song.jsonData().write(to: url, options: .atomic)
            currentFileURL = url
            markSaved()
            return true
        } catch {
            showErrorAlert(title: "Save Failed",
                           message: "Could not save the song to \(url.lastPathComponent).\n\n\(error.localizedDescription)")
            return false
        }
    }

    /// Opens a .sidsong file, offering to save unsaved changes first.
    func openSong() {
        if view.window?.isDocumentEdited == true {
            let alert = NSAlert()
            alert.messageText = "You have unsaved changes."
            alert.informativeText = "Do you want to save your song before opening another one?"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Don't Save")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                guard saveSong(forcePrompt: false) else { return }
            case .alertSecondButtonReturn:
                break
            default:
                return
            }
        }

        let panel = NSOpenPanel()
        panel.title = "Open SID Song"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let type = SIDEditorViewController.sidsongType {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            let loaded = try SIDSong.fromJSONData(data)
            adoptSong(loaded)
            currentFileURL = url
            markSaved()
        } catch {
            showErrorAlert(title: "Open Failed",
                           message: "Could not open \(url.lastPathComponent).\n\n\(error.localizedDescription)")
        }
    }

    /// Copies a loaded song's state into the live song object.
    /// Fields are copied (not the reference) because TrackerView holds a
    /// reference to the existing song instance, mirroring restoreSnapshot().
    private func adoptSong(_ loaded: SIDSong) {
        audioEngine.stop()

        song.title = loaded.title
        song.author = loaded.author
        song.speed = loaded.speed
        song.instruments = loaded.instruments
        song.patterns = loaded.patterns
        song.sequence = loaded.sequence
        song.filterCutoff = loaded.filterCutoff
        song.filterResonance = loaded.filterResonance
        song.filterType = loaded.filterType
        song.filterVoices = loaded.filterVoices
        song.globalVolume = loaded.globalVolume

        currentInstrument = 0
        currentPattern = 0
        trackerView.currentInstrument = 0
        trackerView.patternIndex = 0
        trackerView.cursorRow = 0
        trackerView.cursorVoice = 0

        undoStack.removeAll()
        redoStack.removeAll()
        lastSliderUndoLabel = nil

        refreshAllUI()
        exportTextView.string = ""
    }

    private func showErrorAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Audio Preview

    @objc private func previewInstrument(_ sender: Any?) {
        guard currentInstrument < song.instruments.count else { return }
        let inst = song.instruments[currentInstrument]
        audioEngine.onRowAdvanced = nil
        audioEngine.onPlaybackStopped = nil
        audioEngine.playNote(instrument: inst, noteNumber: 48, duration: 1.5,
                             filterCutoff: song.filterCutoff,
                             filterResonance: song.filterResonance,
                             filterType: song.filterType,
                             filterVoices: song.filterVoices)
    }

    @objc private func playPattern(_ sender: Any?) {
        audioEngine.onRowAdvanced = { [weak self] row in
            self?.trackerView.cursorRow = row
            self?.trackerView.needsDisplay = true
            let rowY = CGFloat(row + 1) * 16
            self?.trackerView.scrollToVisible(NSRect(x: 0, y: rowY, width: 1, height: 16))
        }
        audioEngine.onPlaybackStopped = { [weak self] in
            self?.trackerView.cursorRow = 0
            self?.trackerView.needsDisplay = true
        }
        audioEngine.playPattern(song: song, patternIndex: currentPattern)
    }

    @objc private func stopPlayback(_ sender: Any?) {
        audioEngine.stop()
        trackerView.cursorRow = 0
        trackerView.needsDisplay = true
    }
}

// MARK: - ADSR Envelope View

/// Custom NSView for visualizing and editing ADSR envelope parameters.
class ADSREnvelopeView: NSView {

    var attack:  Int = 2  { didSet { needsDisplay = true } }
    var decay:   Int = 8  { didSet { needsDisplay = true } }
    var sustain: Int = 6  { didSet { needsDisplay = true } }
    var release: Int = 4  { didSet { needsDisplay = true } }

    /// Called while the user drags a handle. Values are already clamped 0–15.
    var onValuesChanged: ((Int, Int, Int, Int) -> Void)?

    /// Called when the user releases a handle (for undo coalescing boundary).
    var onDragEnded: (() -> Void)?

    private var bgColor:         NSColor { AppTheme.current.panelDetailBackground }
    private var lineColor:       NSColor { AppTheme.current.syntaxKeyword }
    private var fillColor:       NSColor { AppTheme.current.syntaxKeyword.withAlphaComponent(0.15) }
    private var gridColor:       NSColor { NSColor(white: AppTheme.current.isDark ? 0.15 : 0.70, alpha: 1.0) }
    private var handleColor:     NSColor { AppTheme.current.syntaxKeyword }
    private var handleHoverColor: NSColor { AppTheme.current.defaultText }
    private let handleRadius: CGFloat = 5.0
    private let hitRadius:    CGFloat = 12.0

    // Which handle is being dragged: 0=attack peak, 1=decay knee (D+S), 2=release tail
    private var draggingHandle: Int? = nil
    private var hoveredHandle:  Int? = nil

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: - Geometry helpers

    private var inset: CGRect { bounds.insetBy(dx: 8, dy: 14) }

    /// Computes the five x/y envelope points from current ADSR values.
    private func envelopePoints() -> (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat,
                                       CGFloat, CGFloat, CGFloat) {
        let r      = inset
        let aTimes  = SIDInstrument.attackTimes.map { CGFloat($0) }
        let drTimes = SIDInstrument.decayReleaseTimes.map { CGFloat($0) }

        let aTime        = aTimes[min(attack,  15)]
        let dTime        = drTimes[min(decay,  15)]
        let rTime        = drTimes[min(release, 15)]
        let sustainLevel = CGFloat(sustain) / 15.0
        let sustainHold: CGFloat = 200
        let totalTime    = aTime + dTime + rTime + sustainHold

        let x0 = r.minX
        let x1 = r.minX + CGFloat(aTime  / totalTime) * r.width
        let x2 = x1     + CGFloat(dTime  / totalTime) * r.width
        let x3 = x2     + CGFloat(sustainHold / totalTime) * r.width
        let x4 = r.minX + CGFloat((aTime + dTime + sustainHold + rTime) / totalTime) * r.width

        let yBottom  = r.minY
        let yTop     = r.maxY
        let ySustain = yBottom + sustainLevel * r.height

        return (x0, x1, x2, x3, x4, yBottom, yTop, ySustain)
    }

    /// Returns the four draggable handle positions in view coordinates.
    private func handlePoints() -> (attackPeak: CGPoint,
                                    decayKnee:  CGPoint,
                                    sustainMid: CGPoint,
                                    releaseMid: CGPoint) {
        let (_, x1, x2, x3, x4, yBottom, yTop, ySustain) = envelopePoints()
        return (
            CGPoint(x: x1, y: yTop),                               // A — drag X
            CGPoint(x: x2, y: ySustain),                           // D — drag X only
            CGPoint(x: (x2 + x3) * 0.5, y: ySustain),             // S — drag Y only, sits mid-sustain segment
            CGPoint(x: x3 + (x4 - x3) * 0.5,                      // R — drag X, sits mid-release slope
                    y: yBottom + (ySustain - yBottom) * 0.5)
        )
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        bgColor.setFill()
        bounds.fill()

        let r = inset
        let (x0, x1, x2, x3, x4, yBottom, yTop, ySustain) = envelopePoints()

        // Grid
        gridColor.setStroke()
        for i in 1..<4 {
            let y = r.minY + r.height * CGFloat(i) / 4
            NSBezierPath.strokeLine(from: NSPoint(x: r.minX, y: y),
                                    to:   NSPoint(x: r.maxX, y: y))
        }

        // Fill
        let fill = NSBezierPath()
        fill.move(to: NSPoint(x: x0, y: yBottom))
        fill.line(to: NSPoint(x: x1, y: yTop))
        fill.line(to: NSPoint(x: x2, y: ySustain))
        fill.line(to: NSPoint(x: x3, y: ySustain))
        fill.line(to: NSPoint(x: x4, y: yBottom))
        fill.line(to: NSPoint(x: x0, y: yBottom))
        fill.close()
        fillColor.setFill()
        fill.fill()

        // Envelope line
        let line = NSBezierPath()
        line.move(to: NSPoint(x: x0, y: yBottom))
        line.line(to: NSPoint(x: x1, y: yTop))
        line.line(to: NSPoint(x: x2, y: ySustain))
        line.line(to: NSPoint(x: x3, y: ySustain))
        line.line(to: NSPoint(x: x4, y: yBottom))
        line.lineWidth = 2
        lineColor.setStroke()
        line.stroke()

        // Segment labels
        let labelFont  = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)
        let labelAttrs: [NSAttributedString.Key: Any] = [.font: labelFont,
                                                          .foregroundColor: AppTheme.current.statusLabel]
        let labelY = r.minY - 12
        "A".draw(at: NSPoint(x: (x0 + x1) / 2 - 3, y: labelY), withAttributes: labelAttrs)
        "D".draw(at: NSPoint(x: (x1 + x2) / 2 - 3, y: labelY), withAttributes: labelAttrs)
        "S".draw(at: NSPoint(x: (x2 + x3) / 2 - 3, y: labelY), withAttributes: labelAttrs)
        "R".draw(at: NSPoint(x: (x3 + x4) / 2 - 3, y: labelY), withAttributes: labelAttrs)

        // Drag handles
        let handles = handlePoints()
        let pts = [handles.attackPeak, handles.decayKnee, handles.sustainMid, handles.releaseMid]
        let valueLabels = ["\(attack)", "\(decay)", "\(sustain)", "\(release)"]
        let valueLabelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 8, weight: .bold),
            .foregroundColor: AppTheme.current.defaultText,
        ]

        for (i, pt) in pts.enumerated() {
            let isHot = (draggingHandle == i || hoveredHandle == i)
            let color = isHot ? handleHoverColor : handleColor

            // Outer ring
            let outerR = handleRadius + (isHot ? 2 : 0)
            let circleRect = CGRect(x: pt.x - outerR, y: pt.y - outerR,
                                    width: outerR * 2, height: outerR * 2)
            color.withAlphaComponent(0.3).setFill()
            NSBezierPath(ovalIn: circleRect).fill()

            // Solid dot
            let dotR = handleRadius - 1
            let dotRect = CGRect(x: pt.x - dotR, y: pt.y - dotR,
                                 width: dotR * 2, height: dotR * 2)
            color.setFill()
            NSBezierPath(ovalIn: dotRect).fill()

            // Value label — float above the handle when dragging, otherwise small below
            if isHot {
                let lbl = valueLabels[i] as NSString
                let lblSize = lbl.size(withAttributes: valueLabelAttrs)
                lbl.draw(at: NSPoint(x: pt.x - lblSize.width / 2,
                                     y: pt.y + dotR + 2),
                         withAttributes: valueLabelAttrs)
            }
        }

        // Border
        NSColor(white: AppTheme.current.isDark ? 0.2 : 0.6, alpha: 1).setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        draggingHandle = nearestHandle(to: pt)
        hoveredHandle  = nil
        needsDisplay   = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let handle = draggingHandle else { return }
        let pt = convert(event.locationInWindow, from: nil)
        applyDrag(handle: handle, at: pt)
    }

    override func mouseUp(with event: NSEvent) {
        if draggingHandle != nil {
            onDragEnded?()
        }
        draggingHandle = nil
        needsDisplay   = true
    }

    override func mouseMoved(with event: NSEvent) {
        let pt  = convert(event.locationInWindow, from: nil)
        let old = hoveredHandle
        hoveredHandle = nearestHandle(to: pt)
        if hoveredHandle != old { needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredHandle = nil
        needsDisplay  = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    // MARK: - Drag logic

    /// Returns the handle index (0/1/2) whose hit area contains `pt`, or nil.
    private func nearestHandle(to pt: CGPoint) -> Int? {
        let handles = handlePoints()
        let pts = [handles.attackPeak, handles.decayKnee, handles.sustainMid, handles.releaseMid]
        for (i, hp) in pts.enumerated() {
            let dx = pt.x - hp.x, dy = pt.y - hp.y
            if sqrt(dx*dx + dy*dy) <= hitRadius { return i }
        }
        return nil
    }

    /// Converts a drag position into updated ADSR values and fires the callback.
    private func applyDrag(handle: Int, at pt: CGPoint) {
        let r = inset
        guard r.width > 0, r.height > 0 else { return }

        let aTimes  = SIDInstrument.attackTimes.map { CGFloat($0) }
        let drTimes = SIDInstrument.decayReleaseTimes.map { CGFloat($0) }

        var a = attack, d = decay, s = sustain, rel = release

        switch handle {

        case 0: // Attack peak — horizontal only
            let fraction = max(0, min(1, (pt.x - r.minX) / r.width))
            a = nearestIndex(in: aTimes, forFraction: fraction,
                             otherTimes: [drTimes[d], 200, drTimes[rel]])

        case 1: // Decay knee — horizontal only, X maps to D
            let aTime  = aTimes[min(a, 15)]
            let rTime  = drTimes[min(rel, 15)]
            let sustainHold: CGFloat = 200
            let totalTime = aTime + drTimes[min(d, 15)] + sustainHold + rTime
            let x1 = r.minX + CGFloat(aTime / totalTime) * r.width
            let remainingWidth = r.maxX - x1
            if remainingWidth > 0 {
                let fraction = max(0, min(1, (pt.x - x1) / remainingWidth))
                d = nearestIndex(in: drTimes, forFraction: fraction,
                                 otherTimes: [sustainHold, rTime])
            }

        case 2: // Sustain mid — vertical only, Y maps to S
            let yFraction = max(0, min(1, (pt.y - r.minY) / r.height))
            s = Int(round(yFraction * 15))

        case 3: // Release mid — horizontal only, same fixed-budget approach as before
            let aTime       = aTimes[min(a, 15)]
            let dTime       = drTimes[min(d, 15)]
            let sustainHold: CGFloat = 200
            let fixedTime   = aTime + dTime + sustainHold
            let f = max(0.01, min(0.99, (pt.x - r.minX) / r.width))
            let desiredRTime = fixedTime * (1 - f) / f
            var bestIdx  = 0
            var bestDist = CGFloat.greatestFiniteMagnitude
            for (i, t) in drTimes.enumerated() {
                let dist = abs(t - desiredRTime)
                if dist < bestDist { bestDist = dist; bestIdx = i }
            }
            rel = bestIdx

        default: break
        }

        onValuesChanged?(a, d, s, rel)
    }

    /// Given a normalised fraction [0,1] and a lookup table of durations,
    /// returns the table index whose proportional position (relative to itself
    /// plus `otherTimes`) is closest to `fraction`.
    private func nearestIndex(in table: [CGFloat], forFraction fraction: CGFloat,
                               otherTimes: [CGFloat]) -> Int {
        let otherSum = otherTimes.reduce(0, +)
        var bestIdx  = 0
        var bestDist = CGFloat.greatestFiniteMagnitude

        for (i, t) in table.enumerated() {
            let total = t + otherSum
            guard total > 0 else { continue }
            let f    = t / total
            let dist = abs(f - fraction)
            if dist < bestDist { bestDist = dist; bestIdx = i }
        }
        return bestIdx
    }
}

// MARK: - Tracker View (Pattern Grid)

/// Custom NSView for rendering the SID pattern tracker grid.
class TrackerView: NSView {

    private let song: SIDSong
    var patternIndex: Int
    var cursorRow: Int = 0
    var cursorVoice: Int = 0
    var currentInstrument: Int = 0
    var onNoteEntered: ((Int, Int, PatternNote) -> Void)?

    /// Called when a note is typed — for audio preview.
    var onNotePreview: ((Int) -> Void)?

    /// Called on ⌘Z — for undo support.
    var onUndo: (() -> Void)?
    /// Called on ⌘⇧Z — for redo support.
    var onRedo: (() -> Void)?

    private let rowHeight: CGFloat = 16
    private let voiceWidth: CGFloat = 120
    private let rowNumWidth: CGFloat = 30

    private var bgColor:     NSColor { AppTheme.current.panelDetailBackground }
    private var cursorColor: NSColor { AppTheme.current.selectionBackground }
    private var beatColor:   NSColor { AppTheme.current.panelBackground }
    private var noteColor:   NSColor { AppTheme.current.syntaxKeyword }
    private var emptyColor:  NSColor { AppTheme.current.statusLabel }
    private var offColor:    NSColor { AppTheme.current.logError }
    private var headerColor: NSColor { AppTheme.current.syntaxOperator }

    init(song: SIDSong, patternIndex: Int) {
        self.song = song
        self.patternIndex = patternIndex
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        bgColor.setFill()
        bounds.fill()

        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let boldFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)

        guard patternIndex < song.patterns.count else { return }
        let pattern = song.patterns[patternIndex]

        // Header
        let headerY: CGFloat = 0
        for voice in 0..<3 {
            let x = rowNumWidth + CGFloat(voice) * voiceWidth
            let header = "VOICE \(voice + 1)"
            header.draw(at: NSPoint(x: x + 8, y: headerY + 1), withAttributes: [
                .font: boldFont, .foregroundColor: headerColor
            ])
        }

        // Separator
        NSColor(white: AppTheme.current.isDark ? 0.2 : 0.6, alpha: 1).setStroke()
        NSBezierPath.strokeLine(from: NSPoint(x: 0, y: rowHeight), to: NSPoint(x: bounds.width, y: rowHeight))

        // Rows
        for row in 0..<pattern.length {
            let y = CGFloat(row + 1) * rowHeight

            // Beat highlighting (every 4th row)
            if row % 4 == 0 {
                beatColor.setFill()
                NSRect(x: 0, y: y, width: bounds.width, height: rowHeight).fill()
            }

            // Cursor highlight
            if row == cursorRow {
                cursorColor.setFill()
                NSRect(x: rowNumWidth + CGFloat(cursorVoice) * voiceWidth, y: y, width: voiceWidth, height: rowHeight).fill()
            }

            // Row number
            let rowStr = String(format: "%02d", row)
            let rowColor = row % 4 == 0 ? AppTheme.current.defaultText : AppTheme.current.statusLabel
            rowStr.draw(at: NSPoint(x: 4, y: y + 1), withAttributes: [.font: font, .foregroundColor: rowColor])

            // Notes for each voice
            for voice in 0..<3 {
                let note = pattern.notes[voice][row]
                let x = rowNumWidth + CGFloat(voice) * voiceWidth + 8

                let color: NSColor
                if note.isEmpty {
                    color = emptyColor
                } else if note.isNoteOff {
                    color = offColor
                } else {
                    color = noteColor
                }

                note.displayString.draw(at: NSPoint(x: x, y: y + 1), withAttributes: [.font: font, .foregroundColor: color])
            }
        }

        // Voice separator lines
        NSColor(white: AppTheme.current.isDark ? 0.15 : 0.65, alpha: 1).setStroke()
        for i in 0...3 {
            let x = rowNumWidth + CGFloat(i) * voiceWidth
            NSBezierPath.strokeLine(from: NSPoint(x: x, y: 0), to: NSPoint(x: x, y: bounds.height))
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let pt = convert(event.locationInWindow, from: nil)
        let row = Int((pt.y - rowHeight) / rowHeight)
        let voice = Int((pt.x - rowNumWidth) / voiceWidth)

        guard patternIndex < song.patterns.count else { return }
        let pattern = song.patterns[patternIndex]

        if row >= 0 && row < pattern.length && voice >= 0 && voice < 3 {
            cursorRow = row
            cursorVoice = voice
            needsDisplay = true
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        // Handle Command-key combos — don't eat them as piano input
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "z":
                if event.modifierFlags.contains(.shift) {
                    onRedo?()
                } else {
                    onUndo?()
                }
            default:
                super.keyDown(with: event)
            }
            return
        }

        guard patternIndex < song.patterns.count else { return }
        let pattern = song.patterns[patternIndex]

        let chars = event.charactersIgnoringModifiers ?? ""

        // Arrow keys
        switch event.keyCode {
        case 125: // Down
            cursorRow = min(cursorRow + 1, pattern.length - 1)
            scrollCursorVisible()
            needsDisplay = true; return
        case 126: // Up
            cursorRow = max(cursorRow - 1, 0)
            scrollCursorVisible()
            needsDisplay = true; return
        case 124: // Right
            cursorVoice = min(cursorVoice + 1, 2)
            needsDisplay = true; return
        case 123: // Left
            cursorVoice = max(cursorVoice - 1, 0)
            needsDisplay = true; return
        default: break
        }

        // Delete / Backspace — clear note
        if event.keyCode == 51 || event.keyCode == 117 {
            onNoteEntered?(cursorVoice, cursorRow, .empty)
            cursorRow = min(cursorRow + 1, pattern.length - 1)
            scrollCursorVisible()
            needsDisplay = true
            return
        }

        // Note off (period key)
        if chars == "." {
            onNoteEntered?(cursorVoice, cursorRow, .noteOff)
            cursorRow = min(cursorRow + 1, pattern.length - 1)
            scrollCursorVisible()
            needsDisplay = true
            return
        }

        // Piano keyboard mapping (2 octaves):
        // Lower row: Z=C-3, S=C#3, X=D-3, D=D#3, C=E-3, V=F-3, G=F#3, B=G-3, H=G#3, N=A-3, J=A#3, M=B-3
        // Upper row: Q=C-4, 2=C#4, W=D-4, 3=D#4, E=E-4, R=F-4, 5=F#4, T=G-4, 6=G#4, Y=A-4, 7=A#4, U=B-4
        let pianoMap: [Character: Int] = [
            "z": 36, "s": 37, "x": 38, "d": 39, "c": 40, "v": 41, "g": 42, "b": 43, "h": 44, "n": 45, "j": 46, "m": 47,
            "q": 48, "2": 49, "w": 50, "3": 51, "e": 52, "r": 53, "5": 54, "t": 55, "6": 56, "y": 57, "7": 58, "u": 59,
            "i": 60, "9": 61, "o": 62, "0": 63, "p": 64,
        ]

        if let ch = chars.lowercased().first, let noteNum = pianoMap[ch] {
            let note = PatternNote(note: noteNum, instrument: currentInstrument)
            onNoteEntered?(cursorVoice, cursorRow, note)
            onNotePreview?(noteNum)
            cursorRow = min(cursorRow + 1, pattern.length - 1)
            scrollCursorVisible()
            needsDisplay = true
            return
        }

        super.keyDown(with: event)
    }

    private func scrollCursorVisible() {
        let rowY = CGFloat(cursorRow + 1) * rowHeight
        scrollToVisible(NSRect(x: 0, y: rowY, width: 1, height: rowHeight))
    }
}

