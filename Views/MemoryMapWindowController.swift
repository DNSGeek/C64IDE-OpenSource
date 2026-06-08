import Cocoa

// ═══════════════════════════════════════════════════════════
// MARK: - Memory Map Window Controller
// ═══════════════════════════════════════════════════════════

/// A floating window that displays a side-by-side comparison of:
///   • LEFT  — Planned memory layout (from cc65 `.cfg` linker configuration)
///   • RIGHT — Built memory layout (from ld65 `.map` file segments)
///
/// Both columns render the 64K address space vertically, with the same
/// scale so users can visually correlate planned regions with actual placement.
/// The view automatically rebuilds on successful builds via the
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

    // ─── Toolbar row ───────────────────────────────────────
    private var statusLabel:   NSTextField!
    private var zoomSlider:    NSSlider!
    private var refreshButton: NSButton!

    // ─── Inspector strip ───────────────────────────────────
    private var inspectorStrip:    NSView!
    private var inspectorRegion:   NSTextField!   // Read-only region name
    private var inspectorStartLbl: NSTextField!
    private var inspectorSizeLbl:  NSTextField!
    private var inspectorStart:    NSTextField!   // Editable (or greyed if expression-based)
    private var inspectorSize:     NSTextField!   // Editable (or greyed if expression-based)
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

    // ─── Data sources ──────────────────────────────────────
    private var cfg: CfgFileInfo?
    private var map: MapFileInfo?

    // ─── Layout constants ──────────────────────────────────
    private let toolbarH: CGFloat = 36
    private let inspectorH: CGFloat = 56
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
    }

    private func applyThemeColors() {
        let theme = AppTheme.current
        view.window?.appearance        = theme.nsAppearance
        view.window?.backgroundColor   = theme.panelBackground
        view.layer?.backgroundColor    = theme.panelBackground.cgColor
        statusLabel?.textColor         = theme.panelText
        plannedTitle?.textColor        = theme.syntaxKeyword
        builtTitle?.textColor          = theme.syntaxKeyword
        plannedScroll?.backgroundColor = theme.panelDetailBackground
        builtScroll?.backgroundColor   = theme.panelDetailBackground
        inspectorStrip?.layer?.backgroundColor = theme.panelDetailBackground.cgColor
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
        statusLabel.frame = NSRect(x: 100, y: toolbarY + 9, width: W - 280, height: 18)
        statusLabel.autoresizingMask = [.width, .minYMargin]
        view.addSubview(statusLabel)

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
        // Top border line
        let border = CALayer()
        border.frame = CGRect(x: 0, y: inspectorH - 1, width: W, height: 1)
        border.backgroundColor = NSColor.separatorColor.cgColor
        inspectorStrip.layer?.addSublayer(border)
        inspectorStrip.autoresizingMask = [.width, .minYMargin]
        view.addSubview(inspectorStrip)

        inspectorRegion = NSTextField(labelWithString: "Click a region in the PLANNED column to edit it")
        inspectorRegion.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        inspectorRegion.textColor = theme.syntaxKeyword
        inspectorRegion.frame = NSRect(x: margin, y: 30, width: 220, height: 18)
        inspectorStrip.addSubview(inspectorRegion)

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
        exportButton.frame = NSRect(x: W - 130, y: 14, width: 118, height: 24)
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
        let columnsH  = titlesY - margin - 6
        let columnFrame = NSRect(x: margin, y: margin, width: halfWidth, height: columnsH)

        plannedView = MemoryMapColumnView()
        plannedView.role = .planned
        plannedView.onSelect = { [weak self] region in
            self?.handlePlannedSelection(region)
        }
        plannedScroll = makeScroll(framed: columnFrame, content: plannedView)
        plannedScroll.autoresizingMask = [.width, .height]
        view.addSubview(plannedScroll)

        var rightFrame = columnFrame
        rightFrame.origin.x = W / 2 + 6
        builtView = MemoryMapColumnView()
        builtView.role = .built
        builtScroll = makeScroll(framed: rightFrame, content: builtView)
        builtScroll.autoresizingMask = [.width, .height]
        view.addSubview(builtScroll)

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
        let halfWidth = W / 2 - 18
        let titlesY   = (view.bounds.height - toolbarH - inspectorH) - 26
        let columnsH  = titlesY - margin - 6

        plannedTitle.frame = NSRect(x: margin,     y: titlesY, width: halfWidth, height: 18)
        builtTitle.frame   = NSRect(x: W / 2 + 6, y: titlesY, width: halfWidth, height: 18)
        plannedScroll.frame = NSRect(x: margin,     y: margin, width: halfWidth, height: columnsH)
        builtScroll.frame   = NSRect(x: W / 2 + 6, y: margin, width: halfWidth, height: columnsH)
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
            exportButton.isEnabled = false
            return
        }

        inspectorRegion.stringValue = region.name

        // Start field — editable only if it's a plain hex literal
        if let start = region.start, isPlainHex(region.rawStart) {
            setField(inspectorStart, value: String(format: "$%04X", start), editable: true)
        } else {
            setField(inspectorStart, value: region.rawStart.isEmpty ? "—" : region.rawStart,
                     editable: false,
                     tooltip: "start uses an expression and cannot be edited here")
        }

        // Size field — editable only if it's a plain hex literal
        if let size = region.size, isPlainHex(region.rawSize) {
            setField(inspectorSize, value: String(format: "$%04X", size), editable: true)
        } else {
            setField(inspectorSize, value: region.rawSize.isEmpty ? "—" : region.rawSize,
                     editable: false,
                     tooltip: "size uses an expression and cannot be edited here")
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

    // ─── Validation ────────────────────────────────────────

    /// Returns the parsed `UInt32` if the field contains a valid `$XXXX` value, else `nil`.
    private func parsedHex(_ field: NSTextField) -> UInt32? {
        let s = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("$") else { return UInt32(s) }
        return UInt32(s.dropFirst(), radix: 16)
    }

    private func isPlainHex(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("$")                     { return UInt32(s.dropFirst(), radix: 16) != nil }
        if s.lowercased().hasPrefix("0x")       { return UInt32(s.dropFirst(2), radix: 16) != nil }
        return UInt32(s) != nil
    }

    private func validateAndUpdateExportButton() {
        guard let region = selectedRegion,
              cfg?.sourceURL != nil else {
            exportButton.isEnabled = false
            return
        }

        var startOK = true
        var sizeOK  = true

        if inspectorStart.isEditable {
            startOK = parsedHex(inspectorStart) != nil
            setFieldError(inspectorStart, hasError: !startOK)
        }
        if inspectorSize.isEditable {
            sizeOK = parsedHex(inspectorSize) != nil
            setFieldError(inspectorSize, hasError: !sizeOK)
        }

        guard startOK && sizeOK else {
            exportButton.isEnabled = false
            return
        }

        // Enable only if at least one editable field differs from the stored value
        let newStart = inspectorStart.isEditable ? parsedHex(inspectorStart) : nil
        let newSize  = inspectorSize.isEditable  ? parsedHex(inspectorSize)  : nil
        let startChanged = newStart != nil && newStart != region.start
        let sizeChanged  = newSize  != nil && newSize  != region.size
        exportButton.isEnabled = startChanged || sizeChanged
    }

    private func setFieldError(_ field: NSTextField, hasError: Bool) {
        field.wantsLayer = true
        field.layer?.borderColor = hasError
            ? NSColor.systemRed.cgColor
            : NSColor.controlColor.cgColor
        field.layer?.borderWidth = hasError ? 1.5 : 0
    }

    private func clearFieldError(_ field: NSTextField) {
        field.wantsLayer = false
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

        do {
            try CfgFileEditor.patch(url: cfgURL,
                                    regionName: region.name,
                                    newStart: newStart,
                                    newSize: newSize)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Could not write to .cfg"
            alert.informativeText = error.localizedDescription
            alert.beginSheetModal(for: view.window!) { _ in }
            return
        }

        // Reparse and redraw so the map immediately reflects the edit.
        loadFromActiveBuild()

        // Re-select the same region in the refreshed data so the inspector
        // stays populated rather than blanking out.
        selectedRegion = cfg?.memory.first { $0.name == region.name }
    }

    // ═══════════════════════════════════════════════════════
    // MARK: - Build / refresh
    // ═══════════════════════════════════════════════════════

    @objc private func refreshTapped() { loadFromActiveBuild() }

    @objc private func buildDidProduceMap(_ note: Notification) {
        loadFromActiveBuild()
    }

    private func loadFromActiveBuild() {
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let build = appDelegate.mainWindowController?.buildManager else {
            statusLabel.stringValue = "No active project."
            return
        }

        if let cfgURL = build.lastLinkerConfigPath {
            cfg = CfgFileParser.parse(contentsOf: cfgURL)
        } else {
            cfg = nil
        }
        if let mapURL = build.lastMapFile {
            map = MapFileParser.parse(contentsOf: mapURL)
        } else {
            map = nil
        }

        plannedView.setLayout(memory: cfg?.memory ?? [], segmentLoads: cfg?.segments ?? [])
        builtView.setSegments(map?.segments ?? [], memoryRegions: cfg?.memory ?? [])

        let source    = build.lastSourceFile?.lastPathComponent ?? "—"
        let mapStatus = map.map { "✓ \($0.segments.count) segments" } ?? "no .map yet"
        let cfgStatus = cfg.map { "✓ \($0.memory.count) MEMORY regions" } ?? "no .cfg yet"
        statusLabel.stringValue = "Source: \(source)   |   \(cfgStatus)   |   \(mapStatus)"
    }

    @objc private func zoomChanged() { applyZoom() }

    private func applyZoom() {
        let z = CGFloat(zoomSlider?.doubleValue ?? 0.04)
        plannedView.pixelsPerByte = z
        builtView.pixelsPerByte   = z
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - Column View (a single 64K vertical strip)
// ═══════════════════════════════════════════════════════════

/// Renders a single column of memory regions (either planned or built).
/// Uses flipped coordinates: Y=0 is at the bottom, increasing upward.
final class MemoryMapColumnView: NSView {

    enum Role { case planned, built }
    var role: Role = .planned

    /// Fired when the user clicks a region in a `.planned` column.
    /// Passes the region name, or `nil` when clicking empty space (deselect).
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

    private func resizeForScale() {
        invalidateIntrinsicContentSize()
        let width  = superview?.bounds.width ?? frame.width
        let height = max(intrinsicContentSize.height,
                         superview?.bounds.height ?? 0)
        frame = NSRect(x: 0, y: 0, width: width, height: height)
    }

    private struct Box {
        let start: UInt32
        let end: UInt32       // inclusive
        let label: String
        let tooltip: String
        let fillAlpha: CGFloat
        let dashed: Bool      // when size is unknown (cfg expression)
    }

    private var boxes: [Box] = []
    private var trackingArea: NSTrackingArea?

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

    func setLayout(memory: [CfgMemoryRegion], segmentLoads: [CfgSegmentMapping]) {
        var segsForRegion: [String: [String]] = [:]
        for seg in segmentLoads {
            segsForRegion[seg.load, default: []].append(seg.name)
        }
        boxes = memory.compactMap { region -> Box? in
            guard let start = region.start else { return nil }
            let size = region.size ?? 0
            let end: UInt32 = size > 0
                ? min(UInt32(0xFFFF), start &+ size &- 1)
                : start
            let segNames = segsForRegion[region.name] ?? []
            let segLabel = segNames.isEmpty ? "(no segments)" : segNames.joined(separator: ", ")
            let sizeText = region.size == nil ? region.rawSize : String(format: "$%X", size)
            let tip = """
            \(region.name)
            start  \(region.rawStart)\(region.start.map { String(format: "  ($%04X)", $0) } ?? "")
            size   \(sizeText)
            file   \(region.file ?? "—")
            seg    \(segLabel)
            """
            return Box(start: start, end: end, label: region.name,
                       tooltip: tip, fillAlpha: 0.55, dashed: region.size == nil)
        }
        // Keep selection live after a reload — clear only if the region is gone.
        if let sel = selectedLabel, !boxes.contains(where: { $0.label == sel }) {
            selectedLabel = nil
        }
        resizeForScale()
        needsDisplay = true
    }

    func setSegments(_ segments: [MapFileSegment], memoryRegions: [CfgMemoryRegion]) {
        boxes = segments.compactMap { seg in
            guard seg.size > 0 else { return nil }
            let region = memoryRegions.first { mr in
                guard let s = mr.start, let sz = mr.size else { return false }
                return seg.start >= s && seg.start < s &+ sz
            }
            let parent = region.map { "  ⇒ \($0.name)" } ?? ""
            let tip = String(
                format: "%@\nstart  $%04X\nend    $%04X\nsize   $%X (%d bytes)%@",
                seg.name, seg.start, seg.end, seg.size, Int(seg.size), parent
            )
            return Box(start: seg.start, end: seg.end, label: seg.name,
                       tooltip: tip, fillAlpha: 0.85, dashed: false)
        }
        resizeForScale()
        needsDisplay = true
    }

    // ─── Mouse handling ───────────────────────────────────

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        toolTip = box(at: p)?.tooltip
    }

    override func mouseDown(with event: NSEvent) {
        guard role == .planned else { return }
        let p   = convert(event.locationInWindow, from: nil)
        let hit = box(at: p)
        // Toggle off if clicking the already-selected region
        if let hit = hit, hit.label == selectedLabel {
            selectedLabel = nil
            onSelect?(nil)
        } else {
            selectedLabel = hit?.label
            onSelect?(hit?.label)
        }
    }

    /// Maps a screen point (flipped Y) to a memory address and finds the containing region.
    private func box(at point: NSPoint) -> Box? {
        let address = UInt32(max(0, min(0xFFFF, lround(point.y / pixelsPerByte))))
        for box in boxes.reversed() where address >= box.start && address <= box.end {
            return box
        }
        return nil
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
        let leftGutterWidth: CGFloat = 44
        for major in stride(from: 0, through: 0x10000, by: 0x1000) {
            let y = CGFloat(major) * pixelsPerByte
            ctx.beginPath()
            ctx.move(to:    CGPoint(x: leftGutterWidth, y: y))
            ctx.addLine(to: CGPoint(x: bounds.width,    y: y))
            ctx.strokePath()
            let label = String(format: "$%04X", min(major, 0xFFFF))
            (label as NSString).draw(at: CGPoint(x: 4, y: y + 1), withAttributes: addrAttrs)
        }

        // Boxes — sort by size desc so small inner boxes draw on top.
        let labelFont  = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font:            labelFont,
            .foregroundColor: theme.defaultText
        ]
        let xLeft    = leftGutterWidth + 4
        let boxWidth = bounds.width - xLeft - 4

        for b in boxes.sorted(by: { ($0.end - $0.start) > ($1.end - $1.start) }) {
            let yTop = CGFloat(b.start) * pixelsPerByte
            let h    = max(1, CGFloat(b.end - b.start + 1) * pixelsPerByte)
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

