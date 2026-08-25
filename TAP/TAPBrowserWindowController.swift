import Cocoa
import UniformTypeIdentifiers

// ═══════════════════════════════════════════════════════════
// MARK: - Tape Browser Window Controller
// ═══════════════════════════════════════════════════════════

/// Manages the window lifecycle and initial configuration for the Tape Browser.
class TAPBrowserWindowController: NSWindowController {

    /// Initializes a new Tape Browser window with default dimensions and styling.
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Tape Browser"
        window.center()
        window.minSize = NSSize(width: 520, height: 480)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = AppTheme.current.editorBackground
        self.init(window: window)
        window.contentViewController = TAPBrowserViewController()
    }

    /// Closes the browser window.
    @objc func closeTab(_ sender: Any?) { window?.performClose(sender) }
}

// ═══════════════════════════════════════════════════════════
// MARK: - Tape Browser View Controller
// ═══════════════════════════════════════════════════════════

/// Handles all UI logic, file operations, and state management for the Tape Browser.
class TAPBrowserViewController: NSViewController,
                                NSTableViewDataSource,
                                NSTableViewDelegate,
                                NSWindowDelegate {

    // MARK: - State

    /// The currently loaded archive. TAP archives are read-only in this view; T64 archives are writable.
    private var archive: (any TapeArchive)?

    /// Convenience cast for TAP-specific operations (timing configuration, reparsing).
    private var tapImage: TAPImage? { archive as? TAPImage }

    /// Convenience cast for write operations.
    private var writable: (any WritableTapeArchive)? { archive as? WritableTapeArchive }

    /// Tracks unsaved changes. Updates the window title and gates close prompts.
    private var isDirty = false { didSet { updateWindowTitle() } }

    // MARK: - UI Outlets

    private var tableView:       NSTableView!
    private var scrollView:      NSScrollView!
    private var headerLabel:     NSTextField!
    private var statusLabel:     NSTextField!
    private var turboWarning:    NSTextField!
    private var formatBadge:     NSTextField!

    // Top toolbar (archive-level operations)
    private var newBtn:          NSButton!
    private var saveBtn:         NSButton!
    private var saveAsBtn:       NSButton!

    // File operations bar (entry actions)
    private var extractBtn:      NSButton!
    private var exportD64Btn:    NSButton!
    private var exportD81Btn:    NSButton!
    private var openInIDEBtn:    NSButton!
    private var disassembleBtn:  NSButton!

    // Edit operations bar (archive mutations)
    private var addPRGBtn:       NSButton!
    private var deleteBtn:       NSButton!
    private var renameBtn:       NSButton!
    private var tapeNameBtn:     NSButton!

    // Timing panel (TAP only — disabled/dimmed for T64)
    private var timingBox:       NSBox!
    private var presetPopup:     NSPopUpButton!
    private var smSlider:        NSSlider!
    private var mlSlider:        NSSlider!
    private var pilotSlider:     NSSlider!
    private var smValueLabel:    NSTextField!
    private var mlValueLabel:    NSTextField!
    private var pilotValueLabel: NSTextField!
    private var reparseButton:   NSButton!

    // Log panel
    private var logScrollView:   NSScrollView!
    private var logTextView:     NSTextView!
    private var logDisclosure:   NSButton!
    private var logVisible = false

    // MARK: - Colors

    private var bgColor:    NSColor { AppTheme.current.panelBackground }
    private var tableBg:    NSColor { AppTheme.current.panelDetailBackground }
    private var boxBg:      NSColor { AppTheme.current.panelDetailBackground }
    private var amberColor: NSColor { AppTheme.current.logCommand }
    private var warnColor:  NSColor { AppTheme.current.logWarning }
    private var dimColor:   NSColor { AppTheme.current.statusLabel }

    // Layout constant — timing box height
    private let timingBoxH: CGFloat = 116

    // MARK: - View Lifecycle

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 660, height: 620))
        view.wantsLayer = true
        view.layer?.backgroundColor = bgColor.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange(_:)),
            name: .appThemeDidChange, object: nil)
        buildUI()
        updateWriteControlsAvailability()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.delegate = self
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

    /// Applies current theme colors to all UI elements.
    private func applyThemeColors() {
        view.window?.appearance       = AppTheme.current.nsAppearance
        view.layer?.backgroundColor   = AppTheme.current.panelBackground.cgColor
        headerLabel.textColor         = AppTheme.current.logCommand
        statusLabel.textColor         = AppTheme.current.statusLabel
        turboWarning.textColor        = AppTheme.current.logWarning
        formatBadge.textColor         = AppTheme.current.statusLabel
        tableView.backgroundColor     = AppTheme.current.panelDetailBackground
        scrollView.backgroundColor    = AppTheme.current.panelDetailBackground
        logTextView.backgroundColor   = AppTheme.current.panelDetailBackground
        logTextView.textColor         = AppTheme.current.statusLabel
        logScrollView.backgroundColor = AppTheme.current.panelDetailBackground
        timingBox.borderColor         = NSColor(white: AppTheme.current.isDark ? 0.25 : 0.65, alpha: 1.0)
        timingBox.fillColor           = AppTheme.current.panelDetailBackground
        tableView.reloadData()
    }

    // MARK: - UI Construction

    /// Builds the entire interface using manual frame-based layout.
    /// Coordinates flow top-down (y decreases as elements are added).
    private func buildUI() {
        let w = view.bounds.width
        var y = view.bounds.height - 8

        // ── Toolbar (archive-level: open / new / save / save as) ──
        y -= 28
        let openBtn = NSButton(title: "Open…", target: self, action: #selector(openArchive(_:)))
        openBtn.frame = NSRect(x: 12, y: y, width: 64, height: 24)
        openBtn.font  = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        openBtn.autoresizingMask = [.minYMargin]
        view.addSubview(openBtn)

        newBtn = NSButton(title: "New T64", target: self, action: #selector(newArchive(_:)))
        newBtn.frame = NSRect(x: 80, y: y, width: 70, height: 24)
        newBtn.font  = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        newBtn.autoresizingMask = [.minYMargin]
        view.addSubview(newBtn)

        saveBtn = NSButton(title: "Save", target: self, action: #selector(saveArchive(_:)))
        saveBtn.frame = NSRect(x: 154, y: y, width: 56, height: 24)
        saveBtn.font  = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        saveBtn.autoresizingMask = [.minYMargin]
        view.addSubview(saveBtn)

        saveAsBtn = NSButton(title: "Save As…", target: self, action: #selector(saveArchiveAs(_:)))
        saveAsBtn.frame = NSRect(x: 214, y: y, width: 84, height: 24)
        saveAsBtn.font  = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        saveAsBtn.autoresizingMask = [.minYMargin]
        view.addSubview(saveAsBtn)

        // Format badge — right-aligned
        formatBadge = NSTextField(labelWithString: "NO ARCHIVE")
        formatBadge.font      = NSFont.monospacedSystemFont(ofSize: 9, weight: .bold)
        formatBadge.textColor = dimColor
        formatBadge.alignment = .right
        formatBadge.frame     = NSRect(x: w - 220 - 12, y: y + 4, width: 220, height: 16)
        formatBadge.autoresizingMask = [.minXMargin, .minYMargin]
        view.addSubview(formatBadge)

        // ── Archive header ───────────────────────────────────
        y -= 30
        headerLabel = NSTextField(labelWithString: "No archive loaded")
        headerLabel.font           = NSFont.monospacedSystemFont(ofSize: 14, weight: .bold)
        headerLabel.textColor      = amberColor
        headerLabel.frame          = NSRect(x: 12, y: y, width: w - 24, height: 20)
        headerLabel.autoresizingMask = [.width, .minYMargin]
        view.addSubview(headerLabel)

        // ── Turbo warning ────────────────────────────────────
        y -= 20
        turboWarning = NSTextField(labelWithString:
            "⚠ Tape contains non-standard / turbo loader block(s) — those files cannot be extracted.")
        turboWarning.font      = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        turboWarning.textColor = warnColor
        turboWarning.frame     = NSRect(x: 12, y: y, width: w - 24, height: 16)
        turboWarning.autoresizingMask = [.width, .minYMargin]
        turboWarning.isHidden  = true
        view.addSubview(turboWarning)

        // ── File operations bar (entry actions) ──────────────
        y -= 28
        let fileButtons: [(String, Selector, (NSButton) -> Void)] = [
            ("Extract PRG…",   #selector(extractPRG(_:)),      { self.extractBtn      = $0 }),
            ("Export to D64…", #selector(exportToD64(_:)),     { self.exportD64Btn    = $0 }),
            ("Export to D81…", #selector(exportToD81(_:)),     { self.exportD81Btn    = $0 }),
            ("Open in IDE",    #selector(openInIDE(_:)),       { self.openInIDEBtn    = $0 }),
            ("Disassemble",    #selector(disassembleFile(_:)), { self.disassembleBtn  = $0 }),
        ]
        var bx: CGFloat = 12
        for (title, action, capture) in fileButtons {
            let btn  = NSButton(title: title, target: self, action: action)
            let btnW = CGFloat(title.count) * 7.5 + 16
            btn.frame = NSRect(x: bx, y: y, width: btnW, height: 22)
            btn.font  = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
            btn.autoresizingMask = [.minYMargin]
            view.addSubview(btn)
            capture(btn)
            bx += btnW + 4
        }

        // ── Edit operations bar (archive mutations) ──────────
        y -= 28
        let editButtons: [(String, Selector, (NSButton) -> Void)] = [
            ("Add PRG…",     #selector(addPRGFile(_:)),    { self.addPRGBtn   = $0 }),
            ("Delete",       #selector(deleteSelected(_:)),{ self.deleteBtn   = $0 }),
            ("Rename…",      #selector(renameSelected(_:)),{ self.renameBtn   = $0 }),
            ("Tape Name…",   #selector(editTapeName(_:)),  { self.tapeNameBtn = $0 }),
        ]
        bx = 12
        for (title, action, capture) in editButtons {
            let btn  = NSButton(title: title, target: self, action: action)
            let btnW = CGFloat(title.count) * 7.5 + 16
            btn.frame = NSRect(x: bx, y: y, width: btnW, height: 22)
            btn.font  = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
            btn.autoresizingMask = [.minYMargin]
            view.addSubview(btn)
            capture(btn)
            bx += btnW + 4
        }

        // Hint label on the edit bar — clarifies drag-and-drop
        let dropHint = NSTextField(labelWithString: "(drag .prg files into the list)")
        dropHint.font      = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        dropHint.textColor = dimColor
        dropHint.frame     = NSRect(x: bx + 8, y: y + 4, width: 200, height: 16)
        dropHint.autoresizingMask = [.minYMargin]
        view.addSubview(dropHint)

        // ── Timing panel (TAP only — dimmed for T64) ─────────
        y -= 10
        let boxH = timingBoxH
        y -= boxH

        timingBox = NSBox(frame: NSRect(x: 12, y: y, width: w - 24, height: boxH))
        timingBox.title              = "Tape Timing  (TAP only)"
        timingBox.titleFont          = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
        timingBox.boxType            = .custom
        timingBox.borderColor        = NSColor(white: AppTheme.current.isDark ? 0.25 : 0.65, alpha: 1.0)
        timingBox.fillColor          = boxBg
        timingBox.cornerRadius       = 4
        timingBox.contentViewMargins = NSSize(width: 8, height: 6)
        timingBox.autoresizingMask   = [.width, .minYMargin]
        view.addSubview(timingBox)

        buildTimingControls(in: timingBox, width: w - 24)

        // ── Directory table ──────────────────────────────────
        y -= 10

        tableView = NSTableView()
        tableView.backgroundColor              = tableBg
        tableView.style                        = .plain
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.headerView                   = nil
        tableView.rowHeight                    = 20
        tableView.intercellSpacing             = NSSize(width: 4, height: 2)
        tableView.dataSource                   = self
        tableView.delegate                     = self
        tableView.doubleAction                 = #selector(tableDoubleClicked(_:))
        tableView.target                       = self
        tableView.registerForDraggedTypes([.fileURL])

        for (id, title, width) in [
            ("idx",  "#",              30),
            ("name", "Filename",      180),
            ("type", "Type",           40),
            ("addr", "Address Range", 130),
            ("size", "Size",           60),
        ] as [(String, String, Int)] {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = title; col.width = CGFloat(width); col.minWidth = CGFloat(width - 10)
            tableView.addTableColumn(col)
        }

        let tableHeight = y - 56 - 10
        scrollView = NSScrollView(frame: NSRect(x: 12, y: 56 + 10, width: w - 24, height: tableHeight))
        scrollView.autoresizingMask    = [.width, .height]
        scrollView.documentView        = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType          = .noBorder
        view.addSubview(scrollView)

        // ── Parse log ────────────────────────────────────────
        logDisclosure = NSButton(title: "▶ Parse Log", target: self, action: #selector(toggleLog(_:)))
        logDisclosure.bezelStyle       = .inline
        logDisclosure.isBordered       = false
        logDisclosure.frame            = NSRect(x: 12, y: 34, width: 110, height: 18)
        logDisclosure.font             = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        logDisclosure.contentTintColor = dimColor
        logDisclosure.autoresizingMask = [.minYMargin]
        view.addSubview(logDisclosure)

        logTextView = NSTextView(frame: .zero)
        logTextView.isEditable      = false
        logTextView.isSelectable    = true
        logTextView.backgroundColor = tableBg
        logTextView.textColor       = dimColor
        logTextView.font            = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)

        logScrollView = NSScrollView(frame: NSRect(x: 12, y: 56, width: w - 24, height: 0))
        logScrollView.documentView         = logTextView
        logScrollView.hasVerticalScroller  = true
        logScrollView.borderType           = .noBorder
        logScrollView.autoresizingMask     = [.width]
        logScrollView.isHidden             = true
        view.addSubview(logScrollView)

        // ── Status bar ───────────────────────────────────────
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font           = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor      = .gray
        statusLabel.frame          = NSRect(x: 12, y: 12, width: w - 24, height: 18)
        statusLabel.autoresizingMask = [.width]
        view.addSubview(statusLabel)
    }

    // MARK: - Timing panel construction

    /// Builds the timing controls for TAP archives.
    /// TAP timing uses 8µs units. Short/Medium boundary controls block sync detection.
    /// Pilot pulses control the initial sync sequence length.
    private func buildTimingControls(in box: NSBox, width: CGFloat) {
        let cv = box.contentView!
        let cw = width - 20

        let presetLabel = NSTextField(labelWithString: "Preset:")
        presetLabel.frame     = NSRect(x: 0, y: 80, width: 50, height: 18)
        presetLabel.font      = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        presetLabel.textColor = dimColor
        cv.addSubview(presetLabel)

        presetPopup = NSPopUpButton(frame: NSRect(x: 54, y: 78, width: 180, height: 22))
        presetPopup.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        for preset in TAPTiming.allPresets { presetPopup.addItem(withTitle: preset.name) }
        presetPopup.addItem(withTitle: "Custom")
        presetPopup.target = self
        presetPopup.action = #selector(presetChanged(_:))
        cv.addSubview(presetPopup)

        reparseButton = NSButton(title: "Re-parse", target: self, action: #selector(reparseNow(_:)))
        reparseButton.frame      = NSRect(x: cw - 80, y: 78, width: 80, height: 22)
        reparseButton.font       = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        reparseButton.bezelStyle = .rounded
        reparseButton.isEnabled  = false
        cv.addSubview(reparseButton)

        let labelW: CGFloat = 148
        let valueW: CGFloat = 36
        let sliderW = cw - labelW - valueW - 8

        func addSlider(label: String, y: CGFloat, min: Double, max: Double, current: Double,
                       slider: inout NSSlider!, valueLabel: inout NSTextField!) {
            let lbl = NSTextField(labelWithString: label)
            lbl.frame = NSRect(x: 0, y: y + 2, width: labelW, height: 16)
            lbl.font  = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
            lbl.textColor = dimColor
            cv.addSubview(lbl)

            slider = NSSlider(frame: NSRect(x: labelW + 4, y: y, width: sliderW, height: 20))
            slider.minValue = min; slider.maxValue = max; slider.doubleValue = current
            slider.numberOfTickMarks = 0; slider.isContinuous = true
            slider.target = self; slider.action = #selector(sliderChanged(_:))
            cv.addSubview(slider)

            valueLabel = NSTextField(labelWithString: "\(Int(current))")
            valueLabel.frame     = NSRect(x: labelW + sliderW + 8, y: y + 2, width: valueW, height: 16)
            valueLabel.font      = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
            valueLabel.textColor = amberColor
            valueLabel.alignment = .right
            cv.addSubview(valueLabel)
        }

        let t = TAPTiming.palC64
        addSlider(label: "Short/Medium boundary (units):", y: 54,
                  min: 24, max: 80,  current: Double(t.shortMax),
                  slider: &smSlider, valueLabel: &smValueLabel)
        addSlider(label: "Medium/Long boundary (units):",  y: 30,
                  min: 36, max: 110, current: Double(t.mediumMax),
                  slider: &mlSlider, valueLabel: &mlValueLabel)
        addSlider(label: "Min pilot pulses:",              y: 6,
                  min: 40, max: 400, current: Double(t.minPilotPulses),
                  slider: &pilotSlider, valueLabel: &pilotValueLabel)

        for (yHint, label) in [(56, "(×8 µs)"), (32, "(×8 µs)")] as [(Int, String)] {
            let hint = NSTextField(labelWithString: label)
            hint.frame     = NSRect(x: labelW + sliderW + valueW + 10, y: CGFloat(yHint), width: 50, height: 14)
            hint.font      = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
            hint.textColor = AppTheme.current.statusLabel
            cv.addSubview(hint)
        }
    }

    // MARK: - Timing box enable/disable

    /// Enables or dims the timing panel. T64 archives are compressed tape formats
    /// that do not store timing data, so the panel is disabled to avoid confusion.
    private func setTimingBoxEnabled(_ enabled: Bool) {
        timingBox.alphaValue    = enabled ? 1.0 : 0.35
        presetPopup.isEnabled   = enabled
        smSlider.isEnabled      = enabled
        mlSlider.isEnabled      = enabled
        pilotSlider.isEnabled   = enabled
        reparseButton.isEnabled = enabled && tapImage != nil
        timingBox.title = enabled
            ? "Tape Timing  (TAP only)"
            : "Tape Timing  (not applicable for T64)"
    }

    // MARK: - Timing actions

    @objc private func presetChanged(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        guard idx < TAPTiming.allPresets.count else { return }
        let preset = TAPTiming.allPresets[idx].timing
        smSlider.doubleValue    = Double(preset.shortMax)
        mlSlider.doubleValue    = Double(preset.mediumMax)
        pilotSlider.doubleValue = Double(preset.minPilotPulses)
        updateValueLabels()
        applyTimingAndReparse(preset)
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        // Enforce boundary constraints
        if sender === smSlider && smSlider.doubleValue >= mlSlider.doubleValue {
            smSlider.doubleValue = mlSlider.doubleValue - 1
        }
        if sender === mlSlider && mlSlider.doubleValue <= smSlider.doubleValue {
            mlSlider.doubleValue = smSlider.doubleValue + 1
        }
        updateValueLabels()
        markCustomPreset()
        reparseButton.isEnabled = tapImage != nil
    }

    @objc private func reparseNow(_ sender: Any?) {
        guard let tap = tapImage else { return }
        tap.timing.shortMax       = UInt32(smSlider.doubleValue)
        tap.timing.mediumMax      = UInt32(mlSlider.doubleValue)
        tap.timing.minPilotPulses   = Int(pilotSlider.doubleValue)
        tap.reparse()
        reparseButton.isEnabled = false
        refreshDirectory()
        statusLabel.stringValue += " — re-parsed with custom timing"
    }

    private func applyTimingAndReparse(_ t: TAPTiming) {
        guard let tap = tapImage else { return }
        tap.timing = t
        tap.reparse()
        reparseButton.isEnabled = false
        refreshDirectory()
    }

    private func updateValueLabels() {
        smValueLabel.stringValue    = "\(Int(smSlider.doubleValue))"
        mlValueLabel.stringValue    = "\(Int(mlSlider.doubleValue))"
        pilotValueLabel.stringValue = "\(Int(pilotSlider.doubleValue))"
    }

    private func markCustomPreset() {
        let current = TAPTiming(shortMax:       UInt32(smSlider.doubleValue),
                                mediumMax:      UInt32(mlSlider.doubleValue),
                                minPilotPulses: Int(pilotSlider.doubleValue))
        if let match = TAPTiming.allPresets.firstIndex(where: { $0.timing == current }) {
            presetPopup.selectItem(at: match)
        } else {
            // "Custom" is always appended at index == allPresets.count
            presetPopup.selectItem(at: TAPTiming.allPresets.count)
        }
    }

    private func syncSlidersToTiming(_ t: TAPTiming) {
        smSlider.doubleValue    = Double(t.shortMax)
        mlSlider.doubleValue    = Double(t.mediumMax)
        pilotSlider.doubleValue = Double(t.minPilotPulses)
        updateValueLabels()
        if let match = TAPTiming.allPresets.firstIndex(where: { $0.timing == t }) {
            presetPopup.selectItem(at: match)
        } else {
            presetPopup.selectItem(at: TAPTiming.allPresets.count)
        }
    }

    // MARK: - Log toggle

    @objc private func toggleLog(_ sender: Any?) {
        logVisible.toggle()
        logDisclosure.title = logVisible ? "▼ Parse Log" : "▶ Parse Log"
        let logH: CGFloat    = logVisible ? 120 : 0
        let tableBottom      = 56 + logH + (logVisible ? 4 : 0)
        logScrollView.isHidden = !logVisible
        logScrollView.frame    = NSRect(x: 12, y: 56, width: view.bounds.width - 24, height: logH)
        let newY = tableBottom + 10
        let newH = scrollView.frame.maxY - newY
        scrollView.frame = NSRect(x: 12, y: newY, width: view.bounds.width - 24, height: max(40, newH))
    }

    // MARK: - Refresh

    /// Updates all UI elements to reflect the current archive state.
    private func refreshDirectory() {
        guard let arc = archive else {
            headerLabel.stringValue = "No archive loaded"
            statusLabel.stringValue = ""
            turboWarning.isHidden   = true
            logTextView.string      = ""
            tableView.reloadData()
            updateBadge()
            updateWriteControlsAvailability()
            updateWindowTitle()
            return
        }

        let isTAP = arc is TAPImage
        let tap   = arc as? TAPImage

        // Timing panel — dim and disable for T64, fully active for TAP
        setTimingBoxEnabled(isTAP)

        // Turbo warning — TAP only
        turboWarning.isHidden = !(tap?.hasTurboBlocks ?? false)

        headerLabel.stringValue = "\(arc.formatTag) ▶▶ \(arc.archiveName)"
        logTextView.string      = arc.parseLog.joined(separator: "\n")

        let n = arc.entries.count
        var status = "\(n) file\(n == 1 ? "" : "s") in archive"
        if let tap = tap, tap.hasTurboBlocks { status += " · turbo loader detected" }
        statusLabel.stringValue = status

        tableView.reloadData()
        updateBadge()
        updateWriteControlsAvailability()
        updateWindowTitle()
    }

    /// Returns the currently selected entry, or nil if none.
    private func selectedEntry() -> TAPEntry? {
        let row = tableView.selectedRow
        guard row >= 0, row < (archive?.entries.count ?? 0) else { return nil }
        return archive?.entries[row]
    }

    // MARK: - Badge / window title

    private func updateBadge() {
        guard let arc = archive else {
            formatBadge.stringValue = "NO ARCHIVE"
            return
        }
        let mode = (arc is WritableTapeArchive) ? "EDITABLE" : "READ ONLY"
        formatBadge.stringValue = "\(mode) · \(arc.formatTag)"
    }

    private func updateWindowTitle() {
        guard let arc = archive else {
            view.window?.title = "Tape Browser"
            return
        }
        let name   = arc.fileURL?.lastPathComponent ?? "\(arc.archiveName) (unsaved)"
        let prefix = isDirty ? "• " : ""
        view.window?.title = "\(prefix)\(arc.formatTag) — \(name)"
    }

    private func updateWriteControlsAvailability() {
        let hasArchive   = archive != nil
        let isWritable   = writable != nil
        let hasSelection = selectedEntry() != nil

        // Top toolbar
        saveBtn.isEnabled    = isWritable
        saveAsBtn.isEnabled  = isWritable

        // Edit ops bar
        addPRGBtn.isEnabled    = isWritable
        deleteBtn.isEnabled    = isWritable && hasSelection
        renameBtn.isEnabled    = isWritable && hasSelection
        tapeNameBtn.isEnabled  = isWritable

        // Entry actions bar — these are read-only ops, always available with selection + archive
        let canExtract = hasArchive && hasSelection
        extractBtn.isEnabled     = canExtract
        exportD64Btn.isEnabled   = canExtract
        exportD81Btn.isEnabled   = canExtract
        openInIDEBtn.isEnabled   = canExtract
        disassembleBtn.isEnabled = canExtract
    }

    // MARK: - Open / New / Save

    @objc private func openArchive(_ sender: Any?) {
        guard promptToSaveIfDirty() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            contentType(for: "tap"),
            contentType(for: "t64"),
        ]
        panel.title = "Open Tape Image (TAP / T64)"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                self?.archive = try TapeArchiveLoader.load(from: url)
                if let tap = self?.tapImage { self?.syncSlidersToTiming(tap.timing) }
                self?.reparseButton.isEnabled = false
                self?.isDirty = false
                self?.refreshDirectory()
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    @objc private func newArchive(_ sender: Any?) {
        guard promptToSaveIfDirty() else { return }
        let name = promptForString(
            title: "New T64 Archive",
            message: "Tape display name (max 24 chars, ASCII).",
            defaultValue: "TAPE",
            maxLen: 24
        ) ?? "TAPE"
        archive = T64Image(emptyWithName: name)
        isDirty = false
        refreshDirectory()
        statusLabel.stringValue = "New T64 archive created — Save to write to disk."
    }

    @objc private func saveArchive(_ sender: Any?) {
        _ = performSave(askForLocation: false)
    }

    @objc private func saveArchiveAs(_ sender: Any?) {
        _ = performSave(askForLocation: true)
    }

    /// Saves the archive, asking for a location when one is needed.
    ///
    /// Synchronous by design. The unsaved-changes prompt has to know whether
    /// the save actually happened before it can allow a close to proceed, and
    /// the previous asynchronous `panel.begin` returned control immediately —
    /// so choosing "Save" for a never-saved archive left `isDirty` set,
    /// cancelled the close, and only then put a save panel on screen.
    ///
    /// - Returns: true when the archive is on disk and no longer dirty.
    @discardableResult
    private func performSave(askForLocation: Bool) -> Bool {
        guard let arc = writable else { return false }

        var target = askForLocation ? nil : arc.fileURL
        if target == nil {
            let panel = NSSavePanel()
            panel.allowedContentTypes  = [contentType(for: "t64")]
            panel.nameFieldStringValue =
                arc.fileURL?.lastPathComponent
                ?? "\(sanitizeForMacOS(arc.archiveName.lowercased(), fallback: "tape")).t64"
            panel.title = "Save T64 Archive"
            guard panel.runModal() == .OK, let chosen = panel.url else { return false }
            target = chosen
        }

        do {
            try arc.save(to: target)
            isDirty = false
            statusLabel.stringValue = "Saved → \(target?.lastPathComponent ?? "")"
            refreshDirectory()
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    // MARK: - Edit operations

    @objc private func addPRGFile(_ sender: Any?) {
        guard let arc = writable else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [contentType(for: "prg")]
        panel.allowsMultipleSelection = true
        panel.title = "Add PRG file(s) to archive"
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.addURLs(panel.urls, to: arc)
        }
    }

    /// Shared add path used by both the "Add PRG…" panel and the drag-and-drop handler.
    @discardableResult
    private func addURLs(_ urls: [URL], to arc: any WritableTapeArchive) -> Int {
        var added = 0
        var failures: [String] = []
        for url in urls {
            // Dropped files of other types used to disappear without a word.
            guard url.pathExtension.lowercased() == "prg" else {
                failures.append("\(url.lastPathComponent): not a .prg file")
                continue
            }
            do {
                let data = try Data(contentsOf: url)
                let name = url.deletingPathExtension().lastPathComponent.uppercased()
                try arc.addEntry(name: name, prgData: data)
                added += 1
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if added > 0 {
            isDirty = true
            refreshDirectory()
            tableView.scrollRowToVisible(arc.entries.count - 1)
            tableView.selectRowIndexes(IndexSet(integer: arc.entries.count - 1),
                                       byExtendingSelection: false)
        }
        if !failures.isEmpty {
            let alert = NSAlert()
            alert.messageText     = "Some files were not added"
            alert.informativeText = failures.joined(separator: "\n")
            alert.runModal()
        } else if added > 0 {
            statusLabel.stringValue = "Added \(added) file\(added == 1 ? "" : "s")"
        }
        return added
    }

    @objc private func deleteSelected(_ sender: Any?) {
        guard let arc = writable,
              let entry = selectedEntry() else { return }

        let alert = NSAlert()
        alert.messageText     = "Delete \"\(entry.name)\"?"
        alert.informativeText = "This change is in memory until you Save."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try arc.deleteEntry(at: entry.index)
            isDirty = true
            refreshDirectory()
            statusLabel.stringValue = "Deleted \"\(entry.name)\""
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func renameSelected(_ sender: Any?) {
        guard let arc = writable,
              let entry = selectedEntry() else { return }

        guard let newName = promptForString(
            title: "Rename Entry",
            message: "New filename (max 16 chars, ASCII).",
            defaultValue: entry.name,
            maxLen: 16
        ), !newName.isEmpty, newName != entry.name else { return }

        do {
            try arc.renameEntry(at: entry.index, to: newName)
            isDirty = true
            refreshDirectory()
            // Keep selection on the renamed row
            tableView.selectRowIndexes(IndexSet(integer: entry.index),
                                       byExtendingSelection: false)
            statusLabel.stringValue = "Renamed to \"\(newName)\""
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func editTapeName(_ sender: Any?) {
        guard let arc = writable else { return }
        guard let newName = promptForString(
            title: "Tape Display Name",
            message: "Tape name shown in the directory listing (max 24 chars).",
            defaultValue: arc.archiveName,
            maxLen: 24
        ), newName != arc.archiveName else { return }
        arc.setArchiveName(newName)
        isDirty = true
        refreshDirectory()
    }

    // MARK: - Extract PRG

    @objc private func extractPRG(_ sender: Any?) {
        guard let arc = archive, let entry = selectedEntry() else {
            statusLabel.stringValue = "Select a file to extract."
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(sanitizeForMacOS(entry.name.lowercased())).prg"
        panel.title = "Extract \"\(entry.name)\""
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            if let data = arc.extractPRG(for: entry) {
                do {
                    try data.write(to: url)
                    self?.statusLabel.stringValue = "Extracted \"\(entry.name)\" → \(url.lastPathComponent)"
                } catch {
                    self?.statusLabel.stringValue = "Write failed: \(error.localizedDescription)"
                }
            } else {
                self?.statusLabel.stringValue = "Could not decode \"\(entry.name)\" — data may be damaged."
            }
        }
    }

    // MARK: - Export to disk

    @objc private func exportToD64(_ sender: Any?) { exportToDisk(format: "d64") }
    @objc private func exportToD81(_ sender: Any?) { exportToDisk(format: "d81") }

    private func exportToDisk(format: String) {
        guard let arc = archive, let entry = selectedEntry() else {
            statusLabel.stringValue = "Select a file to export."
            return
        }
        let isD81 = format == "d81"
        let alert = NSAlert()
        alert.messageText     = "Export \"\(entry.name)\" to \(format.uppercased())"
        alert.informativeText = "Create a new \(format.uppercased()) or add to an existing one?"
        alert.addButton(withTitle: "New \(format.uppercased())…")
        alert.addButton(withTitle: "Existing \(format.uppercased())…")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        guard response != .alertThirdButtonReturn else { return }

        if response == .alertFirstButtonReturn {
            let panel = NSSavePanel()
            panel.allowedContentTypes  = [contentType(for: format)]
            panel.nameFieldStringValue = "\(sanitizeForMacOS(entry.name.lowercased())).\(format)"
            panel.begin { [weak self] saveResp in
                guard saveResp == .OK, let url = panel.url else { return }
                // D64 and D81 are standard C64 disk image formats
                let disk: any DiskImage = isD81
                    ? D81Image(diskName: entry.name.uppercased(), diskID: "C6")
                    : D64Image(diskName: entry.name.uppercased(), diskID: "C6")
                guard arc.exportToDisk(entry, disk: disk) else {
                    self?.statusLabel.stringValue = "Export failed — could not extract file data."
                    return
                }
                do {
                    // The write was previously a `try?`, so a failure here
                    // still reported success and left no file behind.
                    try disk.save(to: url)
                    self?.statusLabel.stringValue = "Exported to new \(format.uppercased()): \(url.lastPathComponent)"
                } catch {
                    self?.statusLabel.stringValue = "Could not write \(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
        } else {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [contentType(for: format)]
            panel.begin { [weak self] openResp in
                guard openResp == .OK, let url = panel.url else { return }
                do {
                    // External dependency: D64BrowserViewController.loadDiskImage
                    let disk = try D64BrowserViewController.loadDiskImage(from: url)
                    if arc.exportToDisk(entry, disk: disk) {
                        try disk.save()
                        self?.statusLabel.stringValue = "Added to \(url.lastPathComponent) (\(disk.freeBlocks) blocks free)"
                    } else {
                        self?.statusLabel.stringValue = "Export failed — disk may be full or data damaged."
                    }
                } catch {
                    self?.statusLabel.stringValue = "Could not open disk: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Open in IDE

    @objc private func openInIDE(_ sender: Any?) {
        guard let arc = archive, let entry = selectedEntry() else {
            statusLabel.stringValue = "Select a file to open."
            return
        }
        guard let prgData = arc.extractPRG(for: entry) else {
            statusLabel.stringValue = "Could not decode \"\(entry.name)\" — data may be damaged."
            return
        }
        let tempDir = FileManager.default.temporaryDirectory
        // External dependency: BasicTokenizer
        if BasicTokenizer.isTokenizedBASIC(prgData) {
            if let source = BasicTokenizer.detokenize(prgData) {
                let tempURL = tempDir.appendingPathComponent("\(sanitizeForMacOS(entry.name.lowercased())).bas")
                do {
                    // Was a `try?`, which handed a nonexistent path to the
                    // editor when the write failed.
                    try source.write(to: tempURL, atomically: true, encoding: .utf8)
                } catch {
                    statusLabel.stringValue = "Could not stage \"\(entry.name)\": \(error.localizedDescription)"
                    return
                }
                (NSApp.delegate as? AppDelegate)?.mainWindowController?.loadDocument(from: tempURL)
                statusLabel.stringValue = source.contains("{$")
                    ? "Opened \"\(entry.name)\" — some tokens unrecognized."
                    : "Opened \"\(entry.name)\" as BASIC source."
                return
            }
        }
        let alert = NSAlert()
        alert.messageText     = "\"\(entry.name)\" is a machine language program."
        alert.informativeText = "Open it in the disassembler?"
        alert.addButton(withTitle: "Disassemble")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { disassembleFile(sender) }
    }

    // MARK: - Disassemble

    @objc private func disassembleFile(_ sender: Any?) {
        guard let arc = archive, let entry = selectedEntry() else {
            statusLabel.stringValue = "Select a file to disassemble."
            return
        }
        guard let prgData = arc.extractPRG(for: entry) else {
            statusLabel.stringValue = "Could not decode \"\(entry.name)\"."
            return
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(sanitizeForMacOS(entry.name.lowercased())).prg")
        do {
            try prgData.write(to: tempURL)
        } catch {
            statusLabel.stringValue = "Could not stage \"\(entry.name)\": \(error.localizedDescription)"
            return
        }
        (NSApp.delegate as? AppDelegate)?.openDisassemblerWith(url: tempURL)
        statusLabel.stringValue = "Disassembling \"\(entry.name)\"…"
    }

    // MARK: - Double-click

    @objc private func tableDoubleClicked(_ sender: Any?) {
        guard let entry = selectedEntry(), entry.kind == .program else { return }
        openInIDE(sender)
    }

    // MARK: - Dirty / close handling

    /// Returns true if it's OK to proceed with the destructive action (open, new, close),
    /// false if the user cancelled the save prompt.
    private func promptToSaveIfDirty() -> Bool {
        guard isDirty, let arc = writable else { return true }
        let alert = NSAlert()
        alert.messageText     = "Save changes to \"\(arc.archiveName)\"?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return performSave(askForLocation: false)
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        return promptToSaveIfDirty()
    }

    // MARK: - Inline string prompt

    /// Modal alert with a text-field accessory. Returns nil on cancel.
    /// Uses an accessory view workaround since NSAlert doesn't support direct text field insertion.
    private func promptForString(title: String,
                                 message: String,
                                 defaultValue: String,
                                 maxLen: Int) -> String? {
        let alert = NSAlert()
        alert.messageText     = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.stringValue = String(defaultValue.prefix(maxLen))
        input.font        = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        return String(input.stringValue.prefix(maxLen))
    }

    // MARK: - Drag destination (drop PRGs onto the table)

    func tableView(_ tableView: NSTableView,
                   validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard writable != nil,
              let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
              urls.contains(where: { $0.pathExtension.lowercased() == "prg" }) else {
            return []
        }
        // Insert "above" semantics doesn't matter — we always append. Use .on for visual feedback.
        tableView.setDropRow(-1, dropOperation: .on)
        return .copy
    }

    func tableView(_ tableView: NSTableView,
                   acceptDrop info: NSDraggingInfo,
                   row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let arc = writable,
              let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else {
            return false
        }
        return addURLs(urls, to: arc) > 0
    }

    // MARK: - Table view

    func numberOfRows(in tableView: NSTableView) -> Int { archive?.entries.count ?? 0 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let entries = archive?.entries,
              row < entries.count,
              let colID = tableColumn?.identifier else { return nil }
        let entry = entries[row]

        // Recycle cells rather than allocating a fresh NSTextField per row
        // per reload.
        let cell: NSTextField
        if let reused = tableView.makeView(withIdentifier: colID, owner: self) as? NSTextField {
            cell = reused
        } else {
            cell = NSTextField(labelWithString: "")
            cell.identifier    = colID
            cell.lineBreakMode = .byTruncatingTail
        }
        cell.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        switch colID {
        case NSUserInterfaceItemIdentifier("idx"):
            cell.stringValue = "\(entry.index + 1)"
            cell.textColor   = dimColor
        case NSUserInterfaceItemIdentifier("name"):
            cell.stringValue = "\"\(entry.name)\""
            cell.textColor   = amberColor
            cell.font        = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        case NSUserInterfaceItemIdentifier("type"):
            cell.stringValue = entry.kind.rawValue
            cell.textColor   = entry.kind == .program ? AppTheme.current.syntaxFunction : dimColor
        case NSUserInterfaceItemIdentifier("addr"):
            cell.stringValue = String(format: "$%04X–$%04X", entry.loadAddress, entry.endAddress)
            cell.textColor   = dimColor
        case NSUserInterfaceItemIdentifier("size"):
            cell.stringValue = entry.sizeBytes < 1024
                ? "\(entry.sizeBytes)b"
                : String(format: "%.1fK", Double(entry.sizeBytes) / 1024.0)
            cell.textColor   = dimColor
        default: break
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateWriteControlsAvailability()
    }
}

// MARK: - Content types

/// UTType for a bare file extension.
///
/// `UTType(filenameExtension:)` is documented as failable, so the bang it
/// replaces was an unnecessary risk; `.data` keeps the panel usable if a
/// system ever declines to vend a type for one of these retro extensions.
private func contentType(for ext: String) -> UTType {
    UTType(filenameExtension: ext) ?? .data
}

// MARK: - Filename sanitizer

/// Sanitizes a string for safe use as a macOS filename.
/// Replaces invalid characters (/ \ : \0) with safe alternatives.
///
/// A corrupt archive can hand us an empty or all-punctuation entry name; the
/// fallback keeps that from becoming a bare ".prg" or a dotfile.
private func sanitizeForMacOS(_ name: String, fallback: String = "untitled") -> String {
    let cleaned = name.map { ch -> String in
        switch ch {
        case "/", "\\", ":", "\0": return "-"
        default: return String(ch)
        }
    }.joined().trimmingCharacters(in: .whitespaces)

    let usable = cleaned.drop { $0 == "." }
    return usable.isEmpty ? fallback : String(cleaned)
}

