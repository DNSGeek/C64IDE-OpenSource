import Cocoa

// ═══════════════════════════════════════════════════════════
// MARK: - Memory Map Window Controller
// ═══════════════════════════════════════════════════════════

/// A floating window that displays a side-by-side comparison of:
///   • LEFT  — Planned memory layout (from cc65 `.cfg` linker configuration)
///   • RIGHT — Built memory layout (from ld65 `.map` file segments)
///
/// Both columns render the 64K address space vertically at the same scale and
/// scroll together, so users can visually correlate planned regions with actual
/// placement. The view automatically rebuilds on successful builds via the
/// `.buildDidProduceMemoryMap` notification.
///
/// Clicking a region in the PLANNED column opens the inspector strip, where
/// editable `start` and `size` values (if plain hex literals) can be modified
/// and written back to the `.cfg` file via `CfgFileEditor`.
class MemoryMapWindowController: NSWindowController {

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Memory Map"
        window.center()
        window.titlebarAppearsTransparent = true
        window.backgroundColor = AppTheme.current.panelBackground
        self.init(window: window)
        window.contentViewController = MemoryMapViewController()
    }

    @objc func closeTab(_ sender: Any?) {
        window?.performClose(sender)
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - View Controller
// ═══════════════════════════════════════════════════════════

class MemoryMapViewController: NSViewController, NSTextFieldDelegate {

    /// Highest byte the C64 address space can hold. Regions beyond this cannot
    /// be plotted on a 64K strip.
    private static let addressLimit: UInt32 = 0xFFFF
    private static let addressSpace: UInt32 = 0x10000

    // ─── Toolbar row ───────────────────────────────────────
    private var statusLabel:   NSTextField!
    private var zoomSlider:    NSSlider!
    private var zoomLabel:     NSTextField!
    private var refreshButton: NSButton!

    // ─── Inspector strip ───────────────────────────────────
    private var inspectorStrip:    NSView!
    private var inspectorBorder:   NSView!         // Themed 1px top rule
    private var inspectorRegion:   NSTextField!    // Read-only region name
    private var inspectorNote:     NSTextField!    // Validation error / warning
    private var inspectorStartLbl: NSTextField!
    private var inspectorSizeLbl:  NSTextField!
    private var inspectorStart:    NSTextField!    // Editable (or greyed if expression-based)
    private var inspectorSize:     NSTextField!    // Editable (or greyed if expression-based)
    private var exportButton:      NSButton!

    /// The CFG memory region currently selected in the planned column. `nil` = none.
    private var selectedRegion: CfgMemoryRegion? {
        didSet { refreshInspector() }
    }

    // ─── Column titles + scroll views ──────────────────────
    private var plannedTitle:  NSTextField!
    private var builtTitle:    NSTextField!
    private var plannedScroll: NSScrollView!
    private var builtScroll:   NSScrollView!
    private var plannedView:   MemoryMapColumnView!
    private var builtView:     MemoryMapColumnView!

    /// Re-entrancy guard for the two-way scroll synchronisation.
    private var isSyncingScroll = false

    // ─── Data sources ──────────────────────────────────────
    private var cfg: CfgFileInfo?
    private var map: MapFileInfo?

    /// True when the build used the throwaway config in the temp directory,
    /// which the next build overwrites. In-place edits would be lost, so the
    /// inspector offers "save to project" instead.
    private var cfgIsTemporary = false

    /// Directory of the most recent build's source file — where a project
    /// `C64.cfg` would live.
    private var projectDirectory: URL?

    /// Set once the user saves a project `C64.cfg` from this window, so the
    /// planned column keeps showing their edits until the next build picks the
    /// file up on its own.
    private var projectCfgOverride: URL?

    /// Set when a build lands while the window is hidden; consumed on next show.
    private var needsReload = false

    // ─── Layout constants ──────────────────────────────────
    private let toolbarH: CGFloat = 36
    private let inspectorH: CGFloat = 60
    private let margin: CGFloat = 12

    // ═══════════════════════════════════════════════════════
    // MARK: - Lifecycle
    // ═══════════════════════════════════════════════════════

    override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 640))
        view.wantsLayer = true
        view.layer?.backgroundColor = AppTheme.current.panelBackground.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        NotificationCenter.default.addObserver(
            self, selector: #selector(buildDidProduceMap(_:)),
            name: .buildDidProduceMemoryMap, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange(_:)),
            name: .appThemeDidChange, object: nil)
        loadFromActiveBuild()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func themeDidChange(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in self?.applyThemeColors() }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        applyThemeColors()
        // Builds that landed while the window was closed are picked up here
        // rather than re-parsing both files on every build for a hidden window.
        if needsReload { loadFromActiveBuild() }
    }

    private func applyThemeColors() {
        let theme = AppTheme.current
        view.window?.appearance        = theme.nsAppearance
        view.window?.backgroundColor   = theme.panelBackground
        view.layer?.backgroundColor    = theme.panelBackground.cgColor
        statusLabel?.textColor         = theme.panelText
        zoomLabel?.textColor           = theme.panelText
        plannedTitle?.textColor        = theme.syntaxKeyword
        builtTitle?.textColor          = theme.syntaxKeyword
        plannedScroll?.backgroundColor = theme.panelDetailBackground
        builtScroll?.backgroundColor   = theme.panelDetailBackground
        inspectorStrip?.layer?.backgroundColor = theme.panelDetailBackground.cgColor
        inspectorBorder?.layer?.backgroundColor = NSColor.separatorColor.cgColor
        inspectorRegion?.textColor     = theme.syntaxKeyword
        inspectorStartLbl?.textColor   = theme.panelText
        inspectorSizeLbl?.textColor    = theme.panelText
        plannedView?.needsDisplay      = true
        builtView?.needsDisplay        = true
    }

    // ═══════════════════════════════════════════════════════
    // MARK: - UI Construction
    // ═══════════════════════════════════════════════════════

    private func buildUI() {
        let theme  = AppTheme.current
        let W      = view.bounds.width
        let H      = view.bounds.height

        // ── Toolbar row ──────────────────────────────────────
        let toolbarY = H - toolbarH

        refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refreshTapped))
        refreshButton.bezelStyle = .rounded
        refreshButton.font = NSFont.systemFont(ofSize: 11)
        refreshButton.frame = NSRect(x: margin, y: toolbarY + 6, width: 80, height: 24)
        refreshButton.autoresizingMask = [.minYMargin]
        view.addSubview(refreshButton)

        statusLabel = NSTextField(labelWithString: "No build yet — build a project to see its memory map.")
        statusLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = theme.panelText
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.frame = NSRect(x: 100, y: toolbarY + 9, width: W - 320, height: 18)
        statusLabel.autoresizingMask = [.width, .minYMargin]
        view.addSubview(statusLabel)

        zoomLabel = NSTextField(labelWithString: "")
        zoomLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        zoomLabel.textColor = theme.panelText
        zoomLabel.alignment = .right
        zoomLabel.frame = NSRect(x: W - 212, y: toolbarY + 10, width: 48, height: 16)
        zoomLabel.autoresizingMask = [.minXMargin, .minYMargin]
        view.addSubview(zoomLabel)

        zoomSlider = NSSlider(value: 0.04, minValue: 0.01, maxValue: 0.5,
                              target: self, action: #selector(zoomChanged))
        zoomSlider.frame = NSRect(x: W - 160, y: toolbarY + 9, width: 140, height: 18)
        zoomSlider.autoresizingMask = [.minXMargin, .minYMargin]
        zoomSlider.toolTip = "Zoom: pixels per byte"
        view.addSubview(zoomSlider)

        // ── Inspector strip ──────────────────────────────────
        let inspectorY = toolbarY - inspectorH

        inspectorStrip = NSView(frame: NSRect(x: 0, y: inspectorY, width: W, height: inspectorH))
        inspectorStrip.wantsLayer = true
        inspectorStrip.layer?.backgroundColor = theme.panelDetailBackground.cgColor
        inspectorStrip.autoresizingMask = [.width, .minYMargin]
        view.addSubview(inspectorStrip)

        // Top border rule. A real subview rather than a raw CALayer so it
        // autoresizes with the strip and can be re-themed.
        inspectorBorder = NSView(frame: NSRect(x: 0, y: inspectorH - 1, width: W, height: 1))
        inspectorBorder.wantsLayer = true
        inspectorBorder.layer?.backgroundColor = NSColor.separatorColor.cgColor
        inspectorBorder.autoresizingMask = [.width, .minYMargin]
        inspectorStrip.addSubview(inspectorBorder)

        inspectorRegion = NSTextField(labelWithString: "Click a region in the PLANNED column to edit it")
        inspectorRegion.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        inspectorRegion.textColor = theme.syntaxKeyword
        inspectorRegion.frame = NSRect(x: margin, y: 34, width: 300, height: 18)
        inspectorRegion.autoresizingMask = [.minYMargin]
        inspectorStrip.addSubview(inspectorRegion)

        inspectorNote = NSTextField(labelWithString: "")
        inspectorNote.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        inspectorNote.textColor = .secondaryLabelColor
        inspectorNote.lineBreakMode = .byTruncatingTail
        inspectorNote.frame = NSRect(x: margin + 310, y: 35, width: max(0, W - 310 - margin - 150), height: 16)
        inspectorNote.autoresizingMask = [.width, .minYMargin]
        inspectorStrip.addSubview(inspectorNote)

        inspectorStartLbl = makeLabel("start", x: margin, y: 8)
        inspectorStrip.addSubview(inspectorStartLbl)

        inspectorStart = makeHexField(x: margin + 42, y: 6)
        inspectorStart.delegate = self
        inspectorStart.target = self
        inspectorStart.action = #selector(hexFieldCommitted(_:))
        inspectorStrip.addSubview(inspectorStart)

        inspectorSizeLbl = makeLabel("size", x: margin + 155, y: 8)
        inspectorStrip.addSubview(inspectorSizeLbl)

        inspectorSize = makeHexField(x: margin + 197, y: 6)
        inspectorSize.delegate = self
        inspectorSize.target = self
        inspectorSize.action = #selector(hexFieldCommitted(_:))
        inspectorStrip.addSubview(inspectorSize)

        exportButton = NSButton(title: "Write to .cfg", target: self, action: #selector(exportTapped))
        exportButton.bezelStyle = .rounded
        exportButton.font = NSFont.systemFont(ofSize: 11)
        exportButton.frame = NSRect(x: W - 150, y: 14, width: 138, height: 24)
        exportButton.autoresizingMask = [.minXMargin]
        exportButton.isEnabled = false
        inspectorStrip.addSubview(exportButton)

        // ── Column titles ────────────────────────────────────
        let titlesY    = inspectorY - 26
        let halfWidth  = W / 2 - 18

        plannedTitle = NSTextField(labelWithString: "PLANNED  (linker config)")
        plannedTitle.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        plannedTitle.textColor = theme.syntaxKeyword
        plannedTitle.frame = NSRect(x: margin, y: titlesY, width: halfWidth, height: 18)
        plannedTitle.autoresizingMask = [.minYMargin]
        view.addSubview(plannedTitle)

        builtTitle = NSTextField(labelWithString: "BUILT  (.map segments)")
        builtTitle.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        builtTitle.textColor = theme.syntaxKeyword
        builtTitle.frame = NSRect(x: W / 2 + 6, y: titlesY, width: halfWidth, height: 18)
        builtTitle.autoresizingMask = [.minYMargin]
        view.addSubview(builtTitle)

        // ── Column scroll views ──────────────────────────────
        // Frames are driven entirely by `layoutColumns` on frame-change, so the
        // scroll views deliberately carry no autoresizing mask of their own.
        let columnsH  = titlesY - margin - 6
        let columnFrame = NSRect(x: margin, y: margin, width: halfWidth, height: columnsH)

        plannedView = MemoryMapColumnView()
        plannedView.role = .planned
        plannedView.onSelect = { [weak self] region in
            self?.handlePlannedSelection(region)
        }
        plannedScroll = makeScroll(framed: columnFrame, content: plannedView)
        view.addSubview(plannedScroll)

        var rightFrame = columnFrame
        rightFrame.origin.x = W / 2 + 6
        builtView = MemoryMapColumnView()
        builtView.role = .built
        builtScroll = makeScroll(framed: rightFrame, content: builtView)
        view.addSubview(builtScroll)

        // Both columns render the same 64K at the same scale, so keep them
        // locked together — that is the whole point of the side-by-side view.
        for scroll in [plannedScroll!, builtScroll!] {
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(clipViewDidScroll(_:)),
                name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        }

        // Reflow both columns when the window resizes.
        view.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(layoutColumns),
            name: NSView.frameDidChangeNotification, object: view)

        applyZoom()
        refreshInspector()
    }

    // ─── Layout helpers ────────────────────────────────────

    private func makeLabel(_ text: String, x: CGFloat, y: CGFloat) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        f.textColor = AppTheme.current.panelText
        f.frame = NSRect(x: x, y: y, width: 40, height: 18)
        return f
    }

    private func makeHexField(x: CGFloat, y: CGFloat) -> NSTextField {
        let f = NSTextField(frame: NSRect(x: x, y: y, width: 100, height: 22))
        f.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        f.bezelStyle = .roundedBezel
        f.isBordered = true
        f.isEditable = false
        f.isEnabled  = false
        f.placeholderString = "$----"
        return f
    }

    private func makeScroll(framed: NSRect, content: NSView) -> NSScrollView {
        let scroll = NSScrollView(frame: framed)
        scroll.hasVerticalScroller   = true
        scroll.hasHorizontalScroller = false
        scroll.borderType    = .lineBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = AppTheme.current.panelDetailBackground
        content.autoresizingMask = [.width]
        content.frame = NSRect(x: 0, y: 0,
                               width: scroll.contentSize.width,
                               height: max(content.intrinsicContentSize.height,
                                           scroll.contentSize.height))
        scroll.documentView = content
        return scroll
    }

    @objc private func layoutColumns() {
        let W         = view.bounds.width
        let halfWidth = max(40, W / 2 - 18)
        let titlesY   = (view.bounds.height - toolbarH - inspectorH) - 26
        let columnsH  = max(40, titlesY - margin - 6)

        plannedTitle.frame = NSRect(x: margin,     y: titlesY, width: halfWidth, height: 18)
        builtTitle.frame   = NSRect(x: W / 2 + 6, y: titlesY, width: halfWidth, height: 18)
        plannedScroll.frame = NSRect(x: margin,     y: margin, width: halfWidth, height: columnsH)
        builtScroll.frame   = NSRect(x: W / 2 + 6, y: margin, width: halfWidth, height: columnsH)
    }

    /// Mirrors one column's vertical scroll position onto the other.
    @objc private func clipViewDidScroll(_ note: Notification) {
        guard !isSyncingScroll,
              let source = note.object as? NSClipView else { return }
        let other = (source === plannedScroll.contentView) ? builtScroll : plannedScroll
        guard let target = other?.contentView else { return }

        let y = source.bounds.origin.y
        guard abs(target.bounds.origin.y - y) > 0.5 else { return }

        isSyncingScroll = true
        defer { isSyncingScroll = false }
        target.scroll(to: NSPoint(x: target.bounds.origin.x, y: y))
        other?.reflectScrolledClipView(target)
    }

    // ═══════════════════════════════════════════════════════
    // MARK: - Inspector
    // ═══════════════════════════════════════════════════════

    /// Called by `MemoryMapColumnView` when the user clicks a region (or `nil` to deselect).
    private func handlePlannedSelection(_ regionName: String?) {
        selectedRegion = regionName.flatMap { name in
            cfg?.memory.first { $0.name == name }
        }
    }

    private func refreshInspector() {
        guard let region = selectedRegion else {
            inspectorRegion.stringValue = "Click a region in the PLANNED column to edit it"
            setField(inspectorStart, value: nil, editable: false)
            setField(inspectorSize,  value: nil, editable: false)
            setNote(nil, isError: false)
            exportButton.isEnabled = false
            return
        }

        inspectorRegion.stringValue = region.name

        // Start field — editable only if it's a plain numeric literal.
        if let start = region.start, region.isStartLiteral {
            setField(inspectorStart, value: String(format: "$%04X", start), editable: true)
        } else {
            setField(inspectorStart, value: region.rawStart.isEmpty ? "—" : region.rawStart,
                     editable: false,
                     tooltip: region.isStartDerived
                        ? "start is computed from an expression and cannot be edited here"
                        : "start could not be resolved")
        }

        // Size field — editable only if it's a plain numeric literal.
        if let size = region.size, region.isSizeLiteral {
            setField(inspectorSize, value: String(format: "$%04X", size), editable: true)
        } else {
            setField(inspectorSize, value: region.rawSize.isEmpty ? "—" : region.rawSize,
                     editable: false,
                     tooltip: region.isSizeDerived
                        ? "size is computed from an expression and cannot be edited here"
                        : "size could not be resolved")
        }

        validateAndUpdateExportButton()
    }

    private func setField(_ field: NSTextField, value: String?, editable: Bool, tooltip: String? = nil) {
        field.stringValue = value ?? ""
        field.isEditable  = editable
        field.isEnabled   = editable
        field.textColor   = editable ? .labelColor : .disabledControlTextColor
        field.toolTip     = tooltip
        clearFieldError(field)
    }

    private func setNote(_ text: String?, isError: Bool) {
        inspectorNote.stringValue = text ?? ""
        inspectorNote.textColor = isError ? .systemRed : .secondaryLabelColor
        inspectorNote.toolTip = text
    }

    // ─── Validation ────────────────────────────────────────

    /// Returns the parsed address if the field holds a valid `$XXXX`, `0xXXXX`
    /// or decimal value **within the 64K address space**, else `nil`.
    /// Out-of-range values are rejected here so they can never reach the `.cfg`.
    private func parsedHex(_ field: NSTextField) -> UInt32? {
        let s = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard let value = CfgFileParser.parseNumber(s) else { return nil }
        guard value <= Self.addressSpace else { return nil }
        return value
    }

    private func validateAndUpdateExportButton() {
        exportButton.title = cfgIsTemporary ? "Save to Project…" : "Write to .cfg"

        guard let region = selectedRegion else {
            exportButton.isEnabled = false
            return
        }
        guard cfg?.sourceURL != nil else {
            setNote("No linker config loaded.", isError: false)
            exportButton.isEnabled = false
            return
        }
        if cfgIsTemporary && projectDirectory == nil {
            setNote("Built with a temporary config and no project directory to save into.", isError: true)
            exportButton.isEnabled = false
            return
        }

        var startOK = true
        var sizeOK  = true
        var problems: [String] = []

        let newStart = inspectorStart.isEditable ? parsedHex(inspectorStart) : nil
        let newSize  = inspectorSize.isEditable  ? parsedHex(inspectorSize)  : nil

        if inspectorStart.isEditable {
            startOK = newStart != nil && newStart! <= Self.addressLimit
            setFieldError(inspectorStart, hasError: !startOK)
            if !startOK { problems.append("start must be $0000–$FFFF") }
        }
        if inspectorSize.isEditable {
            sizeOK = newSize != nil && newSize! >= 1 && newSize! <= Self.addressSpace
            setFieldError(inspectorSize, hasError: !sizeOK)
            if !sizeOK { problems.append("size must be $0001–$10000") }
        }

        guard startOK && sizeOK else {
            setNote(problems.joined(separator: "; "), isError: true)
            exportButton.isEnabled = false
            return
        }

        // The region must still fit inside the address space after the edit.
        let effectiveStart = newStart ?? region.start
        let effectiveSize  = newSize  ?? region.size
        if let s = effectiveStart, let sz = effectiveSize,
           UInt64(s) + UInt64(sz) > UInt64(Self.addressSpace) {
            setNote(String(format: "$%04X + $%X runs past the end of memory.", s, sz), isError: true)
            setFieldError(inspectorStart, hasError: inspectorStart.isEditable)
            setFieldError(inspectorSize,  hasError: inspectorSize.isEditable)
            exportButton.isEnabled = false
            return
        }

        // Enable only if at least one editable field differs from the stored value
        let startChanged = newStart != nil && newStart != region.start
        let sizeChanged  = newSize  != nil && newSize  != region.size

        // Overlaps are legal in a .cfg (and sometimes intentional), so this is a
        // warning rather than a block.
        if let overlap = overlappingRegionName(for: region, start: effectiveStart, size: effectiveSize) {
            setNote("⚠︎ overlaps \(overlap)", isError: false)
        } else if cfgIsTemporary {
            setNote("Built with a temporary config — saves as \(projectDirectory?.lastPathComponent ?? "project")/C64.cfg",
                    isError: false)
        } else {
            setNote(nil, isError: false)
        }

        exportButton.isEnabled = startChanged || sizeChanged
    }

    /// First other region whose extent intersects the proposed one, if any.
    private func overlappingRegionName(for region: CfgMemoryRegion,
                                       start: UInt32?, size: UInt32?) -> String? {
        guard let s = start, let sz = size, sz > 0, let all = cfg?.memory else { return nil }
        let lo = UInt64(s), hi = UInt64(s) + UInt64(sz)
        for other in all where other.name != region.name {
            guard let os = other.start, let osz = other.size, osz > 0 else { continue }
            let olo = UInt64(os), ohi = UInt64(os) + UInt64(osz)
            if lo < ohi && olo < hi { return other.name }
        }
        return nil
    }

    private func setFieldError(_ field: NSTextField, hasError: Bool) {
        field.wantsLayer = true
        field.layer?.borderColor = hasError
            ? NSColor.systemRed.cgColor
            : NSColor.controlColor.cgColor
        field.layer?.borderWidth = hasError ? 1.5 : 0
    }

    private func clearFieldError(_ field: NSTextField) {
        field.layer?.borderWidth = 0
    }

    // NSTextFieldDelegate — live validation as the user types
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField,
              (field === inspectorStart || field === inspectorSize) else { return }
        validateAndUpdateExportButton()
    }

    // Called when the user presses Return in a hex field
    @objc private func hexFieldCommitted(_ sender: NSTextField) {
        validateAndUpdateExportButton()
    }

    // ─── Export ────────────────────────────────────────────

    @objc private func exportTapped() {
        guard let region = selectedRegion,
              let cfgURL = cfg?.sourceURL else { return }

        let newStart = inspectorStart.isEditable ? parsedHex(inspectorStart) : nil
        let newSize  = inspectorSize.isEditable  ? parsedHex(inspectorSize)  : nil

        // Nothing to write — shouldn't be reachable since the button would be
        // disabled, but defend anyway.
        guard newStart != nil || newSize != nil else { return }

        if cfgIsTemporary {
            saveToProject(from: cfgURL, region: region, newStart: newStart, newSize: newSize)
        } else {
            do {
                try CfgFileEditor.patch(url: cfgURL,
                                        regionName: region.name,
                                        newStart: newStart,
                                        newSize: newSize)
            } catch {
                presentError("Could not write to .cfg", error.localizedDescription)
                return
            }
            reloadAfterEdit()
        }
    }

    /// The build used the throwaway temp config, which the next build
    /// regenerates. Write the patched text into the project as `C64.cfg` —
    /// the name `BuildManager` looks for — so the edit actually survives.
    private func saveToProject(from cfgURL: URL, region: CfgMemoryRegion,
                               newStart: UInt32?, newSize: UInt32?) {
        guard let dir = projectDirectory else { return }
        let target = dir.appendingPathComponent("C64.cfg")

        let patched: String
        do {
            guard let source = try? String(contentsOf: cfgURL, encoding: .utf8) else {
                throw CfgEditorError.fileNotReadable
            }
            patched = try CfgFileEditor.applyPatch(to: source,
                                                   regionName: region.name,
                                                   newStart: newStart,
                                                   newSize: newSize)
        } catch {
            presentError("Could not prepare the linker config", error.localizedDescription)
            return
        }

        let write = { [weak self] in
            guard let self else { return }
            do {
                try patched.write(to: target, atomically: true, encoding: .utf8)
            } catch {
                self.presentError("Could not save C64.cfg", error.localizedDescription)
                return
            }
            // Prefer the saved file from here on; the next build picks it up.
            self.projectCfgOverride = target
            self.reloadAfterEdit()
        }

        guard FileManager.default.fileExists(atPath: target.path) else {
            write()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Replace C64.cfg?"
        alert.informativeText = "\(target.path) already exists. Replace it with the edited configuration?"
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        runAlert(alert) { response in
            if response == .alertFirstButtonReturn { write() }
        }
    }

    /// Reparse and redraw so the map immediately reflects the edit.
    /// `loadFromActiveBuild` re-binds the selection to the freshly parsed
    /// region, so the inspector stays populated rather than blanking out.
    private func reloadAfterEdit() {
        loadFromActiveBuild()
    }

    private func presentError(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        runAlert(alert) { _ in }
    }

    /// Presents as a sheet when the view is in a window, otherwise modally.
    private func runAlert(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    // ═══════════════════════════════════════════════════════
    // MARK: - Build / refresh
    // ═══════════════════════════════════════════════════════

    @objc private func refreshTapped() { loadFromActiveBuild() }

    @objc private func buildDidProduceMap(_ note: Notification) {
        // Avoid re-parsing the .cfg/.map on every build for a window nobody is
        // looking at; `viewWillAppear` picks the work up when it is shown again.
        guard view.window?.isVisible == true else {
            needsReload = true
            return
        }
        loadFromActiveBuild()
    }

    private func loadFromActiveBuild() {
        needsReload = false

        // Captured before the columns reload, since a reload that drops the
        // selected region clears it through `onSelect`.
        let previousSelection = selectedRegion?.name

        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let build = appDelegate.mainWindowController?.buildManager else {
            statusLabel.stringValue = "No active project."
            cfg = nil
            map = nil
            cfgIsTemporary = false
            projectDirectory = nil
            plannedView.setLayout(memory: [], segmentLoads: [])
            builtView.setSegments([], memoryRegions: [])
            return
        }

        projectDirectory = build.lastSourceFile?.deletingLastPathComponent()

        // A config the user saved from this window wins until the next build
        // picks it up on its own.
        var cfgURL = build.lastLinkerConfigPath
        var isTemporary = build.lastLinkerConfigIsTemporary
        // Scoped to the current project directory so an override saved for one
        // project cannot leak into another.
        if isTemporary, let override = projectCfgOverride,
           override.deletingLastPathComponent().standardizedFileURL
               == projectDirectory?.standardizedFileURL,
           FileManager.default.fileExists(atPath: override.path) {
            cfgURL = override
            isTemporary = false
        }
        cfgIsTemporary = isTemporary

        cfg = cfgURL.flatMap { CfgFileParser.parse(contentsOf: $0) }
        map = build.lastMapFile.flatMap { MapFileParser.parse(contentsOf: $0) }

        plannedView.setLayout(memory: cfg?.memory ?? [], segmentLoads: cfg?.segments ?? [])
        builtView.setSegments(map?.segments ?? [], memoryRegions: cfg?.memory ?? [])

        updateStatusLabel(source: build.lastSourceFile, cfgURL: cfgURL)

        // Re-bind the inspector to the freshly parsed region. Without this the
        // selection still holds values from the previous parse, so the "has it
        // changed?" comparison behind the export button would use stale data.
        if let name = previousSelection,
           let refreshed = cfg?.memory.first(where: { $0.name == name }) {
            selectedRegion = refreshed          // didSet refreshes the inspector
            plannedView.selectedLabel = name
        } else {
            refreshInspector()
        }
    }

    private func updateStatusLabel(source: URL?, cfgURL: URL?) {
        let sourceName = source?.lastPathComponent ?? "—"

        let cfgStatus: String
        if let cfg = cfg {
            let placed = plannedView.boxCount
            var text = "\(cfgURL?.lastPathComponent ?? "cfg"): \(placed)/\(cfg.memory.count) regions"
            if cfgIsTemporary { text += " (temporary)" }
            cfgStatus = "✓ " + text
        } else {
            cfgStatus = "no .cfg yet"
        }

        let mapStatus = map != nil ? "✓ \(builtView.boxCount) segments" : "no .map yet"

        // Regions the planner could not place are called out rather than being
        // dropped without a trace.
        let unplaced = (cfg?.memory ?? []).filter { !MemoryMapColumnView.isPlottable($0) }
        var line = "Source: \(sourceName)   |   \(cfgStatus)   |   \(mapStatus)"
        if !unplaced.isEmpty {
            line += "   |   ⚠︎ unplaced: " + unplaced.map(\.name).joined(separator: ", ")
        }
        statusLabel.stringValue = line
        statusLabel.toolTip = unplaced.isEmpty
            ? cfgURL?.path
            : "These regions have a start address that could not be resolved to a "
              + "value inside the 64K address space, so they cannot be drawn: "
              + unplaced.map { "\($0.name) (start = \($0.rawStart.isEmpty ? "—" : $0.rawStart))" }
                        .joined(separator: ", ")
    }

    @objc private func zoomChanged() { applyZoom() }

    private func applyZoom() {
        let z = CGFloat(zoomSlider?.doubleValue ?? 0.04)

        // Keep the address that is currently centred pinned across the zoom
        // change, so zooming does not teleport the user elsewhere in memory.
        let anchor = centeredAddress(of: plannedScroll)

        plannedView.pixelsPerByte = z
        builtView.pixelsPerByte   = z

        if let anchor = anchor {
            scroll(plannedScroll, toCenter: anchor)
            scroll(builtScroll,   toCenter: anchor)
        }

        zoomLabel?.stringValue = String(format: "%.0f B/px", 1 / max(z, 0.0001))
    }

    private func centeredAddress(of scroll: NSScrollView?) -> UInt32? {
        guard let scroll = scroll, let column = scroll.documentView as? MemoryMapColumnView,
              column.pixelsPerByte > 0 else { return nil }
        let clip = scroll.contentView
        let midY = clip.bounds.origin.y + clip.bounds.height / 2
        return column.address(atY: midY)
    }

    private func scroll(_ scroll: NSScrollView?, toCenter address: UInt32) {
        guard let scroll = scroll, let column = scroll.documentView as? MemoryMapColumnView else { return }
        let clip = scroll.contentView
        let targetY = column.y(forAddress: address) - clip.bounds.height / 2
        let maxY = max(0, column.bounds.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(max(0, targetY), maxY)))
        scroll.reflectScrolledClipView(clip)
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - Column View (a single 64K vertical strip)
// ═══════════════════════════════════════════════════════════

/// Renders a single column of memory regions (either planned or built).
/// The view is flipped, so `$0000` sits at the top and Y increases with the
/// address — matching how the address gutter is labelled top-to-bottom.
final class MemoryMapColumnView: NSView {

    /// Highest plottable address. Regions beyond this cannot appear on a 64K strip.
    static let addressLimit: UInt32 = 0xFFFF

    enum Role { case planned, built }
    var role: Role = .planned

    /// Fired when the selected region changes — by a click, by the keyboard, or
    /// because a reload removed the selected region. `nil` means "no selection".
    /// Not called for `.built` columns.
    var onSelect: ((String?) -> Void)?

    /// Name of the currently-selected region (planned column only).
    var selectedLabel: String? {
        didSet { needsDisplay = true }
    }

    /// Vertical scale: pixels per byte.
    var pixelsPerByte: CGFloat = 0.04 {
        didSet { resizeForScale(); needsDisplay = true }
    }

    /// Number of regions/segments actually drawn — which is not necessarily the
    /// number parsed, since unplottable entries are skipped.
    var boxCount: Int { boxes.count }

    private func resizeForScale() {
        invalidateIntrinsicContentSize()
        let width  = superview?.bounds.width ?? frame.width
        let height = max(intrinsicContentSize.height,
                         superview?.bounds.height ?? 0)
        frame = NSRect(x: 0, y: 0, width: width, height: height)
    }

    private struct Box {
        let start: UInt32
        let end: UInt32       // inclusive, always >= start
        let label: String
        let tooltip: String
        let fillAlpha: CGFloat
        let dashed: Bool      // when the value came from an expression, not a literal

        /// Byte count, precomputed so drawing never does unsigned subtraction
        /// on values it did not validate.
        var span: UInt32 { end &- start &+ 1 }
    }

    private var boxes: [Box] = []
    private var trackingArea: NSTrackingArea?

    /// X offset where region boxes begin — everything left of this is the
    /// address gutter, which must not be click-targetable.
    private let leftGutterWidth: CGFloat = 44
    private var boxesOriginX: CGFloat { leftGutterWidth + 4 }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric,
               height: max(400, CGFloat(0x10000) * pixelsPerByte))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    // ─── Public input ─────────────────────────────────────

    /// True when a region can actually be drawn on the 64K strip.
    /// Shared with the controller so the two never disagree about what got
    /// dropped — anything unplottable is reported in the status line.
    static func isPlottable(_ region: CfgMemoryRegion) -> Bool {
        guard let start = region.start else { return false }
        return start <= addressLimit
    }

    func setLayout(memory: [CfgMemoryRegion], segmentLoads: [CfgSegmentMapping]) {
        var segsForRegion: [String: [String]] = [:]
        for seg in segmentLoads {
            segsForRegion[seg.load, default: []].append(seg.name)
        }
        boxes = memory.compactMap { region -> Box? in
            guard Self.isPlottable(region), let start = region.start else { return nil }
            let size = region.size ?? 0
            // Clamp rather than trusting the config: a region running past the
            // top of memory must still produce `end >= start`, since drawing
            // does unsigned arithmetic on the two.
            let end: UInt32 = size > 0
                ? UInt32(min(UInt64(Self.addressLimit), UInt64(start) + UInt64(size) - 1))
                : start
            let segNames = segsForRegion[region.name] ?? []
            let segLabel = segNames.isEmpty ? "(no segments)" : segNames.joined(separator: ", ")
            let sizeText = region.size.map { String(format: "$%X", $0) } ?? (region.rawSize.isEmpty ? "—" : region.rawSize)
            let tip = """
            \(region.name)
            start  \(region.rawStart)\(region.isStartDerived ? String(format: "  → $%04X", start) : "")
            size   \(region.rawSize.isEmpty ? "—" : region.rawSize)\(region.isSizeDerived ? "  → \(sizeText)" : "")
            file   \(region.file ?? "—")
            seg    \(segLabel)
            """
            return Box(start: start, end: max(end, start), label: region.name,
                       tooltip: tip, fillAlpha: 0.55,
                       dashed: !region.isStartLiteral || !region.isSizeLiteral)
        }
        // Keep selection live after a reload — clear only if the region is gone,
        // and tell the controller so the inspector does not keep editing a
        // region that no longer exists.
        if let sel = selectedLabel, !boxes.contains(where: { $0.label == sel }) {
            selectedLabel = nil
            onSelect?(nil)
        }
        resizeForScale()
        needsDisplay = true
    }

    func setSegments(_ segments: [MapFileSegment], memoryRegions: [CfgMemoryRegion]) {
        boxes = segments.compactMap { seg in
            guard seg.size > 0, seg.start <= Self.addressLimit else { return nil }
            let end = UInt32(min(UInt64(Self.addressLimit), max(UInt64(seg.end), UInt64(seg.start))))
            let region = memoryRegions.first { mr in
                guard let s = mr.start, let sz = mr.size, sz > 0 else { return false }
                return UInt64(seg.start) >= UInt64(s) && UInt64(seg.start) < UInt64(s) + UInt64(sz)
            }
            let parent = region.map { "  ⇒ \($0.name)" } ?? ""
            let tip = String(format: "%@\nstart  $%04X\nend    $%04X\nsize   $%X (%lu bytes)%@",
                             seg.name, seg.start, seg.end, seg.size, UInt(seg.size), parent)
            return Box(start: seg.start, end: end, label: seg.name,
                       tooltip: tip, fillAlpha: 0.85, dashed: false)
        }
        resizeForScale()
        needsDisplay = true
    }

    // ─── Address ⇄ geometry ───────────────────────────────

    /// Y offset (flipped: measured from the top) of an address.
    func y(forAddress address: UInt32) -> CGFloat {
        CGFloat(address) * pixelsPerByte
    }

    /// Address at a Y offset, clamped to the address space.
    func address(atY y: CGFloat) -> UInt32 {
        guard pixelsPerByte > 0 else { return 0 }
        let raw = (y / pixelsPerByte).rounded()
        guard raw.isFinite else { return 0 }
        return UInt32(max(0, min(Double(Self.addressLimit), Double(raw))))
    }

    // ─── Mouse handling ───────────────────────────────────

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        toolTip = box(at: p)?.tooltip
    }

    /// Label of the region under a point in view coordinates, or `nil` for the
    /// address gutter and empty space. Shared by the mouse handlers and tests.
    func regionLabel(at point: NSPoint) -> String? { box(at: point)?.label }

    override func mouseDown(with event: NSEvent) {
        guard role == .planned else { return }
        window?.makeFirstResponder(self)
        let p   = convert(event.locationInWindow, from: nil)
        let hit = box(at: p)
        // Toggle off if clicking the already-selected region
        if let hit = hit, hit.label == selectedLabel {
            select(nil)
        } else {
            select(hit?.label)
        }
    }

    private func select(_ label: String?) {
        guard label != selectedLabel else { return }
        selectedLabel = label
        onSelect?(label)
    }

    /// Maps a point to a memory address and finds the region under it.
    ///
    /// Where regions nest, the *smallest* containing region wins — that matches
    /// the drawing order, which paints large regions first so small ones stay
    /// visible on top.
    private func box(at point: NSPoint) -> Box? {
        // The address gutter is not part of any region.
        guard point.x >= boxesOriginX else { return nil }
        let address = address(atY: point.y)
        return boxes
            .filter { address >= $0.start && address <= $0.end }
            .min { $0.span < $1.span }
    }

    // ─── Keyboard handling ────────────────────────────────

    override var acceptsFirstResponder: Bool { role == .planned }

    override func keyDown(with event: NSEvent) {
        guard role == .planned,
              let key = event.charactersIgnoringModifiers?.unicodeScalars.first else {
            super.keyDown(with: event)
            return
        }
        switch Int(key.value) {
        case NSUpArrowFunctionKey:   moveSelection(by: -1)
        case NSDownArrowFunctionKey: moveSelection(by: 1)
        case 0x1B:                   select(nil)   // Escape
        default:                     super.keyDown(with: event)
        }
    }

    /// Moves the selection through the regions in address order.
    private func moveSelection(by delta: Int) {
        let ordered = boxes.sorted { ($0.start, $0.span) < ($1.start, $1.span) }
        guard !ordered.isEmpty else { return }

        let next: Int
        if let current = selectedLabel,
           let index = ordered.firstIndex(where: { $0.label == current }) {
            next = min(max(0, index + delta), ordered.count - 1)
        } else {
            next = delta > 0 ? 0 : ordered.count - 1
        }
        select(ordered[next].label)
        scrollToVisible(rowRect(for: ordered[next]))
    }

    private func rowRect(for box: Box) -> NSRect {
        NSRect(x: 0, y: y(forAddress: box.start),
               width: bounds.width,
               height: max(1, CGFloat(box.span) * pixelsPerByte))
    }

    // ─── Drawing ──────────────────────────────────────────

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let theme = AppTheme.current
        ctx.saveGState()

        // Background
        ctx.setFillColor(theme.panelDetailBackground.cgColor)
        ctx.fill(bounds)

        // Address gridlines every $1000
        ctx.setStrokeColor(theme.gutterBorder.cgColor)
        ctx.setLineWidth(0.5)
        let addrFont  = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        let addrAttrs: [NSAttributedString.Key: Any] = [
            .font:            addrFont,
            .foregroundColor: theme.gutterLineNumber
        ]
        // Labelled lines mark the start of each $1000 page; the strip's bottom
        // edge is drawn unlabelled since it is the end of $FFFF, not an address.
        for major in stride(from: 0, to: 0x10000, by: 0x1000) {
            let y = CGFloat(major) * pixelsPerByte
            ctx.beginPath()
            ctx.move(to:    CGPoint(x: leftGutterWidth, y: y))
            ctx.addLine(to: CGPoint(x: bounds.width,    y: y))
            ctx.strokePath()
            (String(format: "$%04X", major) as NSString)
                .draw(at: CGPoint(x: 4, y: y + 1), withAttributes: addrAttrs)
        }
        let bottomY = CGFloat(0x10000) * pixelsPerByte
        ctx.beginPath()
        ctx.move(to:    CGPoint(x: leftGutterWidth, y: bottomY))
        ctx.addLine(to: CGPoint(x: bounds.width,    y: bottomY))
        ctx.strokePath()

        // Boxes — sort by size desc so small inner boxes draw on top.
        // `box(at:)` mirrors this by picking the smallest hit.
        let labelFont  = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font:            labelFont,
            .foregroundColor: theme.defaultText
        ]
        let xLeft    = boxesOriginX
        let boxWidth = max(1, bounds.width - xLeft - 4)

        for b in boxes.sorted(by: { $0.span > $1.span }) {
            let yTop = CGFloat(b.start) * pixelsPerByte
            let h    = max(1, CGFloat(b.span) * pixelsPerByte)
            let rect = CGRect(x: xLeft, y: yTop, width: boxWidth, height: h)

            let stroke = tint(forName: b.label)
            let fill   = stroke.withAlphaComponent(b.fillAlpha)
            ctx.setFillColor(fill.cgColor)
            ctx.fill(rect)

            ctx.setStrokeColor(stroke.cgColor)
            ctx.setLineWidth(1)
            if b.dashed {
                ctx.setLineDash(phase: 0, lengths: [3, 2])
            } else {
                ctx.setLineDash(phase: 0, lengths: [])
            }
            ctx.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
            ctx.setLineDash(phase: 0, lengths: [])

            // Selection highlight — white ring inset inside the region border
            if role == .planned, b.label == selectedLabel {
                ctx.setStrokeColor(NSColor.white.cgColor)
                ctx.setLineWidth(2)
                ctx.stroke(rect.insetBy(dx: 2.5, dy: 2.5))

                // Outer accent using the tint at full opacity
                ctx.setStrokeColor(stroke.withAlphaComponent(1.0).cgColor)
                ctx.setLineWidth(1)
                ctx.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
            }

            // Label only if there's room
            if h >= 12 {
                let textRect = CGRect(x: rect.minX + 4, y: rect.minY + 1,
                                      width: rect.width - 8, height: min(14, h - 2))
                (b.label as NSString).draw(in: textRect, withAttributes: labelAttrs)
            }
        }

        ctx.restoreGState()
    }

    // ─── Color palette ────────────────────────────────────

    private func tint(forName name: String) -> NSColor {
        let upper = name.uppercased()
        let theme = AppTheme.current
        switch upper {
        case "ZP", "ZEROPAGE":               return theme.syntaxSystemVariable
        case "STARTUP", "EXEHDR", "LOADADDR": return theme.syntaxKeyword
        case "CODE", "MAIN":                 return theme.syntaxFunction
        case "DATA", "RODATA":               return theme.syntaxString
        case "BSS", "STACK":                 return theme.syntaxComment
        case "VIC", "VIDEO":                 return theme.syntaxVIC
        case "SID", "AUDIO":                 return theme.syntaxSID
        case "IO", "CHARROM":                return theme.syntaxPoke
        case "BASIC", "BASICROM":            return theme.syntaxNumber
        case "KERNAL", "KERNALROM":          return theme.syntaxOperator
        case "RAM", "MAINRAM", "HIRAM":      return theme.syntaxVariable
        default:
            var h: UInt32 = 5381
            for ch in upper.unicodeScalars { h = (h &* 33) &+ ch.value }
            let hue = CGFloat(h % 360) / 360.0
            return NSColor(calibratedHue: hue, saturation: 0.55, brightness: 0.85, alpha: 1.0)
        }
    }
}
