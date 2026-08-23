import AppKit

// MARK: - Reference Panel Tabs

/// Represents the available reference documentation tabs.
enum ReferenceTab: Int, CaseIterable {
    case commands = 0
    case memoryMap = 1
    case kernal = 2
    case colors = 3
    case petscii = 4
    case monitor = 5
    case variables = 6

    var title: String {
        switch self {
        case .commands:  return "Commands"
        case .memoryMap: return "Memory"
        case .kernal:    return "ROM"
        case .colors:    return "Colors"
        case .petscii:   return "PETSCII"
        case .monitor:   return "Monitor"
        case .variables: return "Variables"
        }
    }
}

// MARK: - Reference Panel Controller

/// Orchestrates the reference panel, managing tabs, search, and theme updates.
class ReferencePanelController: NSViewController {

    private var tabView: NSTabView!
    private var searchField: NSSearchField!

    // Scrollable tab strip (replaces NSTabView's native tabs, which clip
    // silently when there are more tabs than fit in the panel width)
    private var tabStrip: NSSegmentedControl!
    private var tabStripScrollView: NSScrollView!
    private var leftArrowButton: NSButton!
    private var rightArrowButton: NSButton!
    private var segmentWidths: [CGFloat] = []
    private var commandListController: CommandListViewController!
    private var memoryMapController: MemoryReferenceViewController!
    private var kernalListController: KernalListViewController!
    private var colorPaletteController: ColorPaletteViewController!
    private var petsciiController: PETSCIIViewController!
    private var monitorController: MonitorReferenceViewController!
    private var variableListController: VariableListViewController!

    private var panelBg: NSColor { AppTheme.current.panelBackground }
    
    var onJumpToBasicLine: ((Int) -> Void)?

    override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 600))
    }
    
    func updateVariables(_ vars: [BasicVariableInfo]) {
        _ = variableListController.view   // force view load; loadViewIfNeeded() is macOS 14+
        variableListController.update(vars)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeDidChange(_:)),
            name: .appThemeDidChange,
            object: nil
        )

        let bounds = view.bounds

        // Search field
        searchField = NSSearchField(frame: NSRect(x: 8, y: bounds.height - 30, width: bounds.width - 16, height: 24))
        searchField.autoresizingMask = [.width, .minYMargin]
        searchField.placeholderString = "Search reference…"
        searchField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        searchField.focusRingType = .none
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        view.addSubview(searchField)

        // Tab strip: segmented control in a horizontal scroll view, with
        // overflow arrows that appear only when the tabs don't all fit.
        let stripFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        tabStrip = NSSegmentedControl(
            labels: ReferenceTab.allCases.map { $0.title },
            trackingMode: .selectOne,
            target: self,
            action: #selector(tabStripChanged(_:))
        )
        tabStrip.font = stripFont
        tabStrip.selectedSegment = 0

        // Fixed per-segment widths so we can compute scroll offsets reliably
        segmentWidths = []
        for (i, tab) in ReferenceTab.allCases.enumerated() {
            let textWidth = ceil((tab.title as NSString).size(withAttributes: [.font: stripFont]).width)
            let w = textWidth + 18
            tabStrip.setWidth(w, forSegment: i)
            segmentWidths.append(w)
        }
        tabStrip.sizeToFit()
        tabStrip.setFrameOrigin(.zero)

        tabStripScrollView = NSScrollView(frame: .zero)
        tabStripScrollView.hasHorizontalScroller = false
        tabStripScrollView.hasVerticalScroller = false
        tabStripScrollView.horizontalScrollElasticity = .none
        tabStripScrollView.verticalScrollElasticity = .none
        tabStripScrollView.drawsBackground = false
        tabStripScrollView.borderType = .noBorder
        tabStripScrollView.documentView = tabStrip
        view.addSubview(tabStripScrollView)

        leftArrowButton = makeArrowButton(symbolName: "chevron.left", fallbackTitle: "<", action: #selector(scrollTabsLeft(_:)))
        rightArrowButton = makeArrowButton(symbolName: "chevron.right", fallbackTitle: ">", action: #selector(scrollTabsRight(_:)))
        view.addSubview(leftArrowButton)
        view.addSubview(rightArrowButton)

        // Update arrow enabled state as the strip scrolls (arrows, trackpad, or programmatic)
        tabStripScrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(tabStripDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: tabStripScrollView.contentView
        )

        // Tab view (tabless; the strip above drives selection)
        tabView = NSTabView(frame: NSRect(x: 4, y: 4, width: bounds.width - 8, height: bounds.height - 66))
        tabView.autoresizingMask = [.width, .height]
        tabView.tabViewType = .noTabsBezelBorder

        commandListController = CommandListViewController()
        memoryMapController = MemoryReferenceViewController()
        kernalListController = KernalListViewController()
        colorPaletteController = ColorPaletteViewController()
        petsciiController = PETSCIIViewController()
        monitorController = MonitorReferenceViewController()
        variableListController = VariableListViewController()
        
        variableListController.onJumpToLine = { [weak self] line in
            self?.onJumpToBasicLine?(line)
        }

        for tab in ReferenceTab.allCases {
            let item = NSTabViewItem(identifier: tab.title)
            item.label = tab.title
            switch tab {
            case .commands:  item.viewController = commandListController
            case .memoryMap: item.viewController = memoryMapController
            case .kernal:    item.viewController = kernalListController
            case .colors:    item.viewController = colorPaletteController
            case .petscii:   item.viewController = petsciiController
            case .monitor:   item.viewController = monitorController
            case .variables: item.viewController = variableListController
            }
            tabView.addTabViewItem(item)
        }

        view.addSubview(tabView)

        layoutTabStrip()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutTabStrip()
    }

    // MARK: - Tab Strip

    private func makeArrowButton(symbolName: String, fallbackTitle: String, action: Selector) -> NSButton {
        let button = NSButton(frame: .zero)
        button.setButtonType(.momentaryPushIn)
        button.isBordered = false
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: fallbackTitle) {
            button.image = image
        } else {
            button.title = fallbackTitle
            button.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        }
        button.target = self
        button.action = action
        return button
    }

    /// Positions the tab strip and shows/hides the overflow arrows.
    /// The overflow decision is based on the full available width, so it
    /// cannot oscillate when arrows appear and shrink the scroll area.
    private func layoutTabStrip() {
        guard tabStrip != nil else { return }

        let bounds = view.bounds
        let stripHeight: CGFloat = 24
        let stripY = bounds.height - 58
        let margin: CGFloat = 4
        let arrowWidth: CGFloat = 18
        let fullWidth = bounds.width - margin * 2
        let docWidth = tabStrip.frame.width

        let overflows = docWidth > fullWidth
        leftArrowButton.isHidden = !overflows
        rightArrowButton.isHidden = !overflows

        leftArrowButton.frame = NSRect(x: margin, y: stripY, width: arrowWidth, height: stripHeight)
        rightArrowButton.frame = NSRect(x: bounds.width - margin - arrowWidth, y: stripY, width: arrowWidth, height: stripHeight)

        if overflows {
            tabStripScrollView.frame = NSRect(
                x: margin + arrowWidth + 2,
                y: stripY,
                width: fullWidth - (arrowWidth + 2) * 2,
                height: stripHeight
            )
        } else {
            tabStripScrollView.frame = NSRect(x: margin, y: stripY, width: fullWidth, height: stripHeight)
        }

        // Clamp scroll position if the panel just got wider
        let clipView = tabStripScrollView.contentView
        let maxOffset = max(0, docWidth - clipView.bounds.width)
        if clipView.bounds.origin.x > maxOffset {
            clipView.setBoundsOrigin(NSPoint(x: maxOffset, y: clipView.bounds.origin.y))
            tabStripScrollView.reflectScrolledClipView(clipView)
        }

        updateArrowEnabledState()
    }

    private func updateArrowEnabledState() {
        let clipView = tabStripScrollView.contentView
        let offset = clipView.bounds.origin.x
        let maxOffset = max(0, tabStrip.frame.width - clipView.bounds.width)
        leftArrowButton.isEnabled = offset > 1
        rightArrowButton.isEnabled = offset < maxOffset - 1
    }

    @objc private func tabStripDidScroll(_ note: Notification) {
        updateArrowEnabledState()
    }

    @objc private func scrollTabsLeft(_ sender: NSButton) {
        scrollTabStrip(by: -tabStripScrollView.contentView.bounds.width * 0.75)
    }

    @objc private func scrollTabsRight(_ sender: NSButton) {
        scrollTabStrip(by: tabStripScrollView.contentView.bounds.width * 0.75)
    }

    private func scrollTabStrip(by delta: CGFloat) {
        let clipView = tabStripScrollView.contentView
        let maxOffset = max(0, tabStrip.frame.width - clipView.bounds.width)
        var origin = clipView.bounds.origin
        origin.x = max(0, min(origin.x + delta, maxOffset))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            clipView.animator().setBoundsOrigin(origin)
        }
        tabStripScrollView.reflectScrolledClipView(clipView)
    }

    /// Scrolls the strip so the given segment is fully visible.
    private func scrollSegmentToVisible(_ index: Int) {
        guard index >= 0, index < segmentWidths.count else { return }
        let clipView = tabStripScrollView.contentView
        let start = segmentWidths.prefix(index).reduce(0, +)
        let end = start + segmentWidths[index]
        var origin = clipView.bounds.origin
        let maxOffset = max(0, tabStrip.frame.width - clipView.bounds.width)

        if start < origin.x {
            origin.x = max(0, start - 8)
        } else if end > origin.x + clipView.bounds.width {
            origin.x = min(end + 8 - clipView.bounds.width, maxOffset)
        } else {
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            clipView.animator().setBoundsOrigin(origin)
        }
        tabStripScrollView.reflectScrolledClipView(clipView)
    }

    /// Single path for all tab selection so the strip and the tab view
    /// never get out of sync, and programmatic jumps scroll into view.
    private func selectTabIndex(_ index: Int) {
        tabView.selectTabViewItem(at: index)
        tabStrip.selectedSegment = index
        scrollSegmentToVisible(index)
    }

    @objc private func tabStripChanged(_ sender: NSSegmentedControl) {
        selectTabIndex(sender.selectedSegment)
    }

    /// Tabs the cursor-tracking callbacks are allowed to switch between on
    /// their own. Anything else (Variables, Colors, PETSCII, ROM, Monitor) is
    /// a deliberate choice, so we leave the selection where the user put it.
    private static let autoNavigableTabs: Set<Int> = [
        ReferenceTab.commands.rawValue,
        ReferenceTab.memoryMap.rawValue,
    ]

    private var selectedTabIndex: Int {
        guard let item = tabView.selectedTabViewItem else { return 0 }
        return tabView.indexOfTabViewItem(item)
    }

    /// Cursor-driven tab switch. Honors the user's tab choice: the content of
    /// the target tab is still refreshed by the caller, so it's already correct
    /// whenever they do switch back to it.
    private func autoSelectTabIndex(_ index: Int) {
        guard Self.autoNavigableTabs.contains(selectedTabIndex) else { return }
        selectTabIndex(index)
    }

    /// Filters the currently visible tab's content based on the search query.
    @objc private func searchChanged(_ sender: NSSearchField) {
        guard let selectedItem = tabView.selectedTabViewItem,
              let selectedView = selectedItem.viewController else { return }

        let query = sender.stringValue
        let idx = tabView.indexOfTabViewItem(selectedItem)
        switch idx {
        case 0: (selectedView as? CommandListViewController)?.filter(by: query)
        case 1: (selectedView as? MemoryReferenceViewController)?.filter(by: query)
        case 2: (selectedView as? KernalListViewController)?.filter(by: query)
        case 6: (selectedView as? VariableListViewController)?.filter(by: query)
        default: break
        }
    }

    /// Highlights a keyword in the Commands tab if it matches a BASIC or ASM reference.
    /// Switches to the Commands tab only when the panel is already showing one
    /// of the cursor-tracking tabs — see `autoSelectTabIndex`.
    func highlightEntry(for word: String, fileType: C64FileType) {
        let upper = word.uppercased()

        // Update the Commands tab mode to match the current editor file type
        commandListController.setMode(forFileType: fileType)

        if fileType.usesBasicHighlighting, C64BasicSyntax.lookup(upper) != nil {
            autoSelectTabIndex(0)
            commandListController.scrollTo(keyword: upper)
        } else if fileType.usesAssemblyHighlighting, C64AssemblySyntax.lookup(upper) != nil {
            autoSelectTabIndex(0)
            commandListController.scrollTo(keyword: upper)
        }
    }

    /// Scrolls the Memory tab to the specified address, switching to that tab
    /// only if the panel isn't parked on a deliberately chosen one.
    func showMemoryMapEntry(for address: Int) {
        autoSelectTabIndex(1)
        memoryMapController.scrollTo(address: address)
    }

    /// Programmatically selects a specific reference tab.
    func selectTab(_ tab: ReferenceTab) {
        selectTabIndex(tab.rawValue)
    }

    @objc private func themeDidChange(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.commandListController.applyTheme()
            self.memoryMapController.applyTheme()
            self.kernalListController.applyTheme()
            self.colorPaletteController.applyTheme()
            self.monitorController.applyTheme()
            self.variableListController.applyTheme()
        }
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - Command List
// ═══════════════════════════════════════════════════════════

/// Displays and filters BASIC commands and 6502 opcodes.
class CommandListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    private var segmentedControl: NSSegmentedControl!
    private var tableView: NSTableView!
    private var tableScrollView: NSScrollView!
    private var detailView: NSTextView!
    private var detailScrollView: NSScrollView!

    private(set) var basicEntries: [(keyword: String, category: String, detail: String)] = []
    private var asmEntries: [(keyword: String, category: String, detail: String)] = []
    private(set) var filteredEntries: [(keyword: String, category: String, detail: String)] = []

    /// 0 = BASIC, 1 = Assembly
    private var currentMode: Int = 0
    private var currentSearchQuery: String = ""

    private var bgColor: NSColor { AppTheme.current.panelBackground }

    override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 500))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildEntries()
        setupUI()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(dialectDidChange(_:)),
            name: .basicDialectDidChange,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Rebuilds the BASIC list when the user switches dialect, keeping the
    /// current mode and search query applied.
    ///
    /// Delivered on whichever thread changed the dialect. Today that is always
    /// the main thread (the Tools menu), so the rebuild runs inline; the hop is
    /// there so a future off-main caller cannot touch the table view from a
    /// background thread.
    @objc private func dialectDidChange(_ note: Notification) {
        if Thread.isMainThread {
            rebuildForDialectChange()
        } else {
            DispatchQueue.main.async { [weak self] in self?.rebuildForDialectChange() }
        }
    }

    private func rebuildForDialectChange() {
        buildEntries()
        applyFilter()
    }

    private func buildEntries() {
        basicEntries.removeAll()
        asmEntries.removeAll()

        // Start from BASIC V2, then let the active dialect extend it. Every
        // bundled dialect sets extendsBasicV2, so the V2 keywords stay valid
        // alongside the plugin's own; where a dialect redefines a keyword, its
        // definition wins because that is the machine the user is targeting.
        var merged: [String: (keyword: String, category: String, detail: String)] = [:]
        for (key, ref) in C64BasicSyntax.commandReference {
            merged[key] = (key, ref.category.rawValue, formatBasic(ref))
        }

        if let dialect = BasicDialectManager.shared.activeDialect {
            for kw in dialect.keywords {
                let key = kw.keyword.uppercased()
                merged[key] = (key,
                               kw.category?.capitalized ?? dialect.name,
                               formatDialectKeyword(kw, dialectName: dialect.name))
            }
        }

        basicEntries = merged.values.sorted { $0.keyword < $1.keyword }

        for (key, ref) in C64AssemblySyntax.opcodeReference.sorted(by: { $0.key < $1.key }) {
            asmEntries.append((key, ref.fullName, formatOpcode(ref)))
        }
        filteredEntries = basicEntries
    }

    /// Indents every line of a field so that continuation lines of a multi-line
    /// example or note stay aligned under the first one.
    private func indented(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "  " + $0 }
            .joined(separator: "\n")
    }

    /// Renders one PARAMETERS line. Shared by the built-in V2 entries and the
    /// dialect plugin entries so both read the same way.
    private func parameterLine(name: String,
                               type: String?,
                               range: String?,
                               description: String?,
                               optional: Bool) -> String {
        var line = "  \(name)"
        if let type = type { line += " (\(type))" }
        if let range = range { line += " [\(range)]" }
        if let description = description { line += " — \(description)" }
        if optional { line += " (optional)" }
        return line
    }

    private func formatBasic(_ r: C64CommandRef) -> String {
        var s = "━━━ \(r.keyword) ━━━\nCategory: \(r.category.rawValue)"
        s += "\n\nSYNTAX\n\(indented(r.syntax))"
        s += "\n\nDESCRIPTION\n\(indented(r.description))"

        if let params = r.parameters, !params.isEmpty {
            s += "\n\nPARAMETERS"
            for p in params {
                s += "\n" + parameterLine(name: p.name,
                                          type: p.type,
                                          range: p.range,
                                          description: p.description,
                                          optional: p.optional)
            }
        }

        if let ex = r.example { s += "\n\nEXAMPLE\n\(indented(ex))" }
        if let n = r.notes { s += "\n\nNOTES\n\(indented(n))" }
        if let token = r.token { s += String(format: "\n\nTOKEN\n  $%02X", token) }
        return s
    }

    private func formatOpcode(_ r: OpcodeRef) -> String {
        var s = "━━━ \(r.mnemonic) — \(r.fullName) ━━━"
        if r.isIllegal {
            s += "\nStatus: Undocumented (\"illegal\") — not specified by MOS, but executes on the C64's 6510"
        }
        if let aliases = r.aliases { s += "\nAlso known as: \(aliases)" }

        s += "\n\nDESCRIPTION\n\(indented(r.description))"
        s += "\n\nFLAGS AFFECTED\n  \(r.flags)"
        s += "\n\nCYCLES\n  \(r.cycles)"
        s += "\n\nADDRESSING MODES\n  \(r.addressingModes)"

        let encodings = r.encodings
        if !encodings.isEmpty {
            // A documented mnemonic can own undocumented encodings too -- NOP
            // has 27 of them and SBC one -- and only there does a per-row
            // marker say anything: on an undocumented entry every row would
            // carry it, which the Status line has already established.
            let mixed = !r.isIllegal && encodings.contains { $0.isIllegal }
            s += "\n\nENCODINGS\n" + encodingTable(encodings, markUndocumented: mixed)
            if mixed { s += "\n  († undocumented encoding)" }
        }

        if let ex = r.example { s += "\n\nEXAMPLE\n\(indented(ex))" }
        if let n = r.notes { s += "\n\nNOTES\n\(indented(n))" }
        return s
    }

    /// Renders one aligned row per opcode byte: mode, hex byte, length, cycles.
    ///
    /// The columns are padded rather than tab-separated because the detail
    /// view is a plain monospaced text view with no tab stops set.
    private func encodingTable(_ encodings: [OpcodeEncoding],
                               markUndocumented: Bool) -> String {
        let modeWidth = encodings.map { $0.mode.displayName.count }.max() ?? 0
        return encodings.map { e in
            let mode = e.mode.displayName.padding(toLength: modeWidth, withPad: " ", startingAt: 0)
            let byte = String(format: "$%02X", e.opcode)
            let size = "\(e.bytes) byte\(e.bytes == 1 ? " " : "s")"
            let mark = (markUndocumented && e.isIllegal) ? " †" : ""
            return "  \(mode)  \(byte)  \(size)  \(e.cycleText)\(mark)"
        }.joined(separator: "\n")
    }

    /// Renders a dialect plugin's keyword documentation in the same shape as
    /// the built-in V2 entries. Every field is optional in the plugin schema,
    /// so each section appears only when the plugin supplies it.
    private func formatDialectKeyword(_ kw: BasicDialectKeyword, dialectName: String) -> String {
        var s = "━━━ \(kw.keyword) ━━━\nDialect: \(dialectName)"
        if let category = kw.category { s += "\nCategory: \(category.capitalized)" }
        if let syntax = kw.syntax { s += "\n\nSYNTAX\n\(indented(syntax))" }
        if let description = kw.description { s += "\n\nDESCRIPTION\n\(indented(description))" }

        if let params = kw.parameters, !params.isEmpty {
            s += "\n\nPARAMETERS"
            for p in params {
                s += "\n" + parameterLine(name: p.name,
                                          type: p.type,
                                          range: p.range,
                                          description: p.description,
                                          optional: p.optional ?? false)
            }
        }

        if let example = kw.example { s += "\n\nEXAMPLE\n\(indented(example))" }
        if let notes = kw.notes { s += "\n\nNOTES\n\(indented(notes))" }

        if let token = kw.token {
            let prefixes = kw.resolvedPrefixes.map { String(format: "$%02X ", $0) }.joined()
            s += String(format: "\n\nTOKEN\n  %@$%02X", prefixes, token & 0xFF)
        }
        return s
    }

    private func setupUI() {
        // ── Segmented control at top ─────────────────────────
        segmentedControl = NSSegmentedControl(
            labels: ["BASIC", "6502 ASM"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(modeChanged(_:))
        )
        segmentedControl.selectedSegment = 0
        segmentedControl.segmentStyle = .texturedSquare
        segmentedControl.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        segmentedControl.frame = NSRect(x: 8, y: 0, width: 200, height: 24) // Positioned in viewDidLayout
        view.addSubview(segmentedControl)

        // ── Table ────────────────────────────────────────────
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("cmd"))
        column.width = 300

        tableView = NSTableView()
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 28
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = bgColor
        tableView.style = .plain

        tableScrollView = NSScrollView(frame: .zero)
        tableScrollView.documentView = tableView
        tableScrollView.hasVerticalScroller = true
        tableScrollView.borderType = .noBorder
        tableScrollView.backgroundColor = bgColor
        view.addSubview(tableScrollView)

        // ── Detail ───────────────────────────────────────────
        detailView = NSTextView(frame: .zero)
        detailView.isEditable = false
        detailView.isSelectable = true
        detailView.backgroundColor = AppTheme.current.panelDetailBackground
        detailView.textColor = AppTheme.current.panelText
        detailView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        detailView.textContainerInset = NSSize(width: 8, height: 8)

        detailScrollView = NSScrollView(frame: .zero)
        detailScrollView.documentView = detailView
        detailScrollView.hasVerticalScroller = true
        detailScrollView.borderType = .noBorder
        view.addSubview(detailScrollView)

        selectFirstEntry()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let bounds = view.bounds
        guard bounds.height > 0 else { return }

        let segHeight: CGFloat = 28
        let listHeight = (bounds.height - segHeight) * 0.55
        let detailHeight = bounds.height - segHeight - listHeight

        segmentedControl.frame = NSRect(x: 8, y: bounds.height - segHeight, width: bounds.width - 16, height: segHeight)
        tableScrollView.frame = NSRect(x: 0, y: detailHeight, width: bounds.width, height: listHeight)
        detailScrollView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: detailHeight)
    }

    // MARK: - Mode Switching

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        currentMode = sender.selectedSegment
        applyFilter()
    }

    /// Called by ReferencePanelController when the editor file type changes.
    func setMode(forFileType fileType: C64FileType) {
        let newMode = fileType.usesAssemblyHighlighting ? 1 : 0
        if currentMode != newMode {
            currentMode = newMode
            segmentedControl?.selectedSegment = newMode
            applyFilter()
        }
    }

    private func currentSourceEntries() -> [(keyword: String, category: String, detail: String)] {
        return currentMode == 0 ? basicEntries : asmEntries
    }

    private func applyFilter() {
        let source = currentSourceEntries()
        if currentSearchQuery.isEmpty {
            filteredEntries = source
        } else {
            let q = currentSearchQuery.uppercased()
            filteredEntries = source.filter {
                $0.keyword.contains(q) || $0.category.uppercased().contains(q) || $0.detail.uppercased().contains(q)
            }
        }
        tableView?.reloadData()
        selectFirstEntry()
    }

    private func selectFirstEntry() {
        if !filteredEntries.isEmpty {
            tableView?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            showDetail(for: 0)
        } else {
            detailView?.string = ""
        }
    }

    // MARK: - Data Source

    func numberOfRows(in tableView: NSTableView) -> Int { filteredEntries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = filteredEntries[row]
        let cellID = NSUserInterfaceItemIdentifier("CommandCell")
        var cell = tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView

        if cell == nil {
            let c = NSTableCellView()
            c.identifier = cellID
            let tf = NSTextField(labelWithString: "")
            tf.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
            tf.textColor = AppTheme.current.refAccentBasic
            tf.lineBreakMode = .byTruncatingTail
            tf.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(tf)
            c.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 8),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            cell = c
        }

        cell?.textField?.stringValue = "\(entry.keyword)  —  \(entry.category)"
        // Color: cyan/blue for BASIC, green for ASM
        cell?.textField?.textColor = currentMode == 0
            ? AppTheme.current.refAccentBasic
            : AppTheme.current.refAccentAsm
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        showDetail(for: row)
    }

    /// Formats and displays the detailed reference text for a given row.
    private func showDetail(for row: Int) {
        guard row < filteredEntries.count else { return }
        let entry = filteredEntries[row]

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: AppTheme.current.panelText,
        ]
        let attributed = NSMutableAttributedString(string: entry.detail, attributes: attrs)

        let nsText = entry.detail as NSString
        // Highlight structural headers in the detail view
        for header in ["SYNTAX", "DESCRIPTION", "EXAMPLE", "NOTES", "FLAGS AFFECTED", "CYCLES",
                       "ADDRESSING MODES", "ENCODINGS", "Category:", "Status:", "Also known as:"] {
            var searchRange = NSRange(location: 0, length: nsText.length)
            while true {
                let range = nsText.range(of: header, options: [], range: searchRange)
                if range.location == NSNotFound { break }
                attributed.addAttributes([
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
                    .foregroundColor: AppTheme.current.refAccentBasic,
                ], range: range)
                searchRange = NSRange(location: range.upperBound, length: nsText.length - range.upperBound)
            }
        }

        detailView?.textStorage?.setAttributedString(attributed)
    }

    // MARK: - Public

    /// Filters the displayed entries by the given query.
    func filter(by query: String) {
        currentSearchQuery = query
        applyFilter()
    }

    /// Scrolls to and selects the entry matching the keyword.
    func scrollTo(keyword: String) {
        if let idx = filteredEntries.firstIndex(where: { $0.keyword == keyword.uppercased() }) {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            tableView.scrollRowToVisible(idx)
            showDetail(for: idx)
        }
    }

    /// Applies the current theme colors to all UI elements.
    func applyTheme() {
        guard view.window != nil else { return }
        tableView.backgroundColor = AppTheme.current.panelBackground
        tableScrollView.backgroundColor = AppTheme.current.panelBackground
        detailView.backgroundColor = AppTheme.current.panelDetailBackground
        detailView.textColor = AppTheme.current.panelText
        tableView.reloadData()
        if tableView.selectedRow >= 0 { showDetail(for: tableView.selectedRow) }
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - Memory Map
// ═══════════════════════════════════════════════════════════

/// Displays and filters C64 memory map entries.
class MemoryReferenceViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    private var tableView: NSTableView!
    private var tableScrollView: NSScrollView!
    private var detailView: NSTextView!
    private var detailScrollView: NSScrollView!

    private var allEntries: [MemoryMapEntry] = []
    private var filteredEntries: [MemoryMapEntry] = []

    private var bgColor: NSColor { AppTheme.current.panelBackground }

    override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 500))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildEntries()
        setupUI()
    }

    private func buildEntries() {
        allEntries = C64Reference.zeroPageEntries + C64Reference.stackAndBufferEntries +
            C64Reference.screenMemoryEntries + C64Reference.basicAreaEntries +
            C64Reference.vicRegisters + C64Reference.sidRegisters +
            C64Reference.colorRAMEntries + C64Reference.cia1Registers +
            C64Reference.cia2Registers + C64Reference.kernalAreaEntries
        allEntries.sort { $0.address < $1.address }
        filteredEntries = allEntries
    }

    private func setupUI() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("mem"))
        column.width = 300

        tableView = NSTableView()
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 24
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = bgColor

        tableScrollView = NSScrollView(frame: .zero)
        tableScrollView.documentView = tableView
        tableScrollView.hasVerticalScroller = true
        tableScrollView.borderType = .noBorder
        tableScrollView.backgroundColor = bgColor
        view.addSubview(tableScrollView)

        detailView = NSTextView(frame: .zero)
        detailView.isEditable = false
        detailView.isSelectable = true
        detailView.backgroundColor = AppTheme.current.panelDetailBackground
        detailView.textColor = AppTheme.current.panelText
        detailView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        detailView.textContainerInset = NSSize(width: 8, height: 8)

        detailScrollView = NSScrollView(frame: .zero)
        detailScrollView.documentView = detailView
        detailScrollView.hasVerticalScroller = true
        detailScrollView.borderType = .noBorder
        view.addSubview(detailScrollView)

        if !filteredEntries.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            showDetail(for: 0)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let bounds = view.bounds
        guard bounds.height > 0 else { return }
        let listHeight = bounds.height * 0.55
        let detailHeight = bounds.height - listHeight
        tableScrollView.frame = NSRect(x: 0, y: detailHeight, width: bounds.width, height: listHeight)
        detailScrollView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: detailHeight)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filteredEntries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = filteredEntries[row]
        let cellID = NSUserInterfaceItemIdentifier("MemCell")
        var cell = tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView
        if cell == nil {
            let c = NSTableCellView()
            c.identifier = cellID
            let tf = NSTextField(labelWithString: "")
            tf.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            tf.textColor = AppTheme.current.panelText
            tf.lineBreakMode = .byTruncatingTail
            tf.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(tf)
            c.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 8),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            cell = c
        }
        cell?.textField?.stringValue = "\(entry.addressString)  \(entry.name)"
        // Color VIC/SID/CIA entries differently
        switch entry.chip {
        case .vic:  cell?.textField?.textColor = AppTheme.current.asmVIC
        case .sid:  cell?.textField?.textColor = AppTheme.current.asmSID
        case .cia1, .cia2: cell?.textField?.textColor = AppTheme.current.asmDirective
        default: cell?.textField?.textColor = AppTheme.current.panelText
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        showDetail(for: row)
    }

    private func showDetail(for row: Int) {
        guard row < filteredEntries.count else { return }
        let e = filteredEntries[row]
        var lines = ["━━━ \(e.addressString) (\(e.decimalString)) ━━━", e.name, "Chip: \(e.chip.rawValue)", "", e.description]
        if let bits = e.bits, !bits.isEmpty {
            lines.append("\nBIT FIELDS:")
            for b in bits { lines.append("  Bit \(b.bits): \(b.name)\n    \(b.description)") }
        }
        detailView.string = lines.joined(separator: "\n")
    }

    /// Filters entries by name, address, or description.
    func filter(by query: String) {
        if query.isEmpty { filteredEntries = allEntries }
        else {
            let q = query.uppercased()
            filteredEntries = allEntries.filter { $0.name.uppercased().contains(q) || $0.addressString.contains(q) || $0.description.uppercased().contains(q) || "\($0.address)".contains(q) }
        }
        tableView.reloadData()
        if !filteredEntries.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            showDetail(for: 0)
        }
    }

    /// Applies the current theme colors to all UI elements.
    func applyTheme() {
        guard view.window != nil else { return }
        tableView.backgroundColor = AppTheme.current.panelBackground
        tableScrollView.backgroundColor = AppTheme.current.panelBackground
        detailView.backgroundColor = AppTheme.current.panelDetailBackground
        detailView.textColor = AppTheme.current.panelText
        tableView.reloadData()
    }

    /// Scrolls to the memory map entry covering the specified address.
    func scrollTo(address: Int) {
        let addr = UInt16(clamping: address)
        if let idx = filteredEntries.firstIndex(where: {
            if let end = $0.endAddress { return addr >= $0.address && addr <= end }
            return addr == $0.address
        }) {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            tableView.scrollRowToVisible(idx)
            showDetail(for: idx)
        }
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - KERNAL List
// ═══════════════════════════════════════════════════════════

/// Displays and filters KERNAL ROM symbols and jump table routines.
class KernalListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    private var tableView: NSTableView!
    private var tableScrollView: NSScrollView!
    private var detailView: NSTextView!
    private var detailScrollView: NSScrollView!
    private var categoryPopup: NSPopUpButton!

    /// Unified display item — either a ROM symbol or a KERNAL jump table entry
    struct DisplayItem {
        let address: UInt16
        let name: String
        let category: C64ROMSymbols.Category
        let romSymbol: C64ROMSymbols.Symbol?
        let kernalRoutine: C64Reference.KernalRoutine?
    }

    private var allItems: [DisplayItem] = []
    private var filteredItems: [DisplayItem] = []

    private var bgColor: NSColor { AppTheme.current.panelBackground }

    override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 500))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildItemList()
        filteredItems = allItems
        setupUI()
    }

    private func buildItemList() {
        // Build a lookup of KERNAL jump table routines by address for merging
        var kernalByAddr: [UInt16: C64Reference.KernalRoutine] = [:]
        for kr in C64Reference.kernalRoutines { kernalByAddr[kr.address] = kr }

        // Create display items from ROM symbols, attaching KERNAL detail where available
        for sym in C64ROMSymbols.allSymbols {
            allItems.append(DisplayItem(
                address: sym.address,
                name: sym.name,
                category: sym.category,
                romSymbol: sym,
                kernalRoutine: kernalByAddr[sym.address]
            ))
        }

        // Add any KERNAL routines not already in ROM symbols
        let romAddrs = Set(C64ROMSymbols.allSymbols.map { $0.address })
        for kr in C64Reference.kernalRoutines where !romAddrs.contains(kr.address) {
            allItems.append(DisplayItem(
                address: kr.address,
                name: kr.name,
                category: .kernalJumpTable,
                romSymbol: nil,
                kernalRoutine: kr
            ))
        }

        allItems.sort { $0.address < $1.address }
    }

    private func setupUI() {
        // Category filter popup
        categoryPopup = NSPopUpButton(frame: NSRect(x: 0, y: view.bounds.height - 24, width: view.bounds.width, height: 22))
        categoryPopup.autoresizingMask = [.width, .minYMargin]
        categoryPopup.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        categoryPopup.addItem(withTitle: "All Categories")
        for cat in C64ROMSymbols.Category.allCases {
            categoryPopup.addItem(withTitle: cat.rawValue)
        }
        categoryPopup.target = self
        categoryPopup.action = #selector(categoryChanged(_:))
        view.addSubview(categoryPopup)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("krn"))
        column.width = 300

        tableView = NSTableView()
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 26
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = bgColor

        tableScrollView = NSScrollView(frame: .zero)
        tableScrollView.documentView = tableView
        tableScrollView.hasVerticalScroller = true
        tableScrollView.borderType = .noBorder
        tableScrollView.backgroundColor = bgColor
        view.addSubview(tableScrollView)

        detailView = NSTextView(frame: .zero)
        detailView.isEditable = false
        detailView.isSelectable = true
        detailView.backgroundColor = AppTheme.current.panelDetailBackground
        detailView.textColor = AppTheme.current.panelText
        detailView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        detailView.textContainerInset = NSSize(width: 8, height: 8)

        detailScrollView = NSScrollView(frame: .zero)
        detailScrollView.documentView = detailView
        detailScrollView.hasVerticalScroller = true
        detailScrollView.borderType = .noBorder
        view.addSubview(detailScrollView)

        if !filteredItems.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            showDetail(for: 0)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let bounds = view.bounds
        guard bounds.height > 0 else { return }
        let popupH: CGFloat = 26
        let listHeight = (bounds.height - popupH) * 0.55
        let detailHeight = bounds.height - popupH - listHeight
        categoryPopup.frame = NSRect(x: 0, y: bounds.height - popupH, width: bounds.width, height: popupH)
        tableScrollView.frame = NSRect(x: 0, y: detailHeight, width: bounds.width, height: listHeight)
        detailScrollView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: detailHeight)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filteredItems.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = filteredItems[row]
        let cellID = NSUserInterfaceItemIdentifier("KrnCell")
        var cell = tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView
        if cell == nil {
            let c = NSTableCellView()
            c.identifier = cellID
            let tf = NSTextField(labelWithString: "")
            tf.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            tf.textColor = AppTheme.current.asmLabel
            tf.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(tf)
            c.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 8),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            cell = c
        }
        cell?.textField?.stringValue = String(format: "$%04X  %@", item.address, item.name)

        // Color-code by category
        let color: NSColor
        switch item.category {
        case .kernalJumpTable: color = AppTheme.current.asmLabel
        case .basicCommand:    color = AppTheme.current.syntaxKeyword
        case .basicFunction:   color = AppTheme.current.syntaxFunction
        case .floatingPoint:   color = AppTheme.current.syntaxNumber
        case .stringHandling:  color = AppTheme.current.syntaxString
        case .kernalIO:        color = AppTheme.current.syntaxOperator
        case .kernalIRQ:       color = AppTheme.current.syntaxPoke
        case .kernalEditor:    color = AppTheme.current.syntaxFunction
        case .romTable:        color = AppTheme.current.syntaxComment
        default:               color = AppTheme.current.panelText
        }
        cell?.textField?.textColor = color

        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < filteredItems.count else { return }
        showDetail(for: row)
    }

    /// Wraps `text` to `width` columns and indents every line by two spaces,
    /// so long notes stay readable in the narrow detail pane.
    private func wrapped(_ text: String, width: Int = 46) -> String {
        var out: [String] = []
        for paragraph in text.components(separatedBy: "\n") {
            var line = ""
            for word in paragraph.split(separator: " ", omittingEmptySubsequences: true) {
                if line.isEmpty {
                    line = String(word)
                } else if line.count + 1 + word.count <= width {
                    line += " " + word
                } else {
                    out.append("  " + line)
                    line = String(word)
                }
            }
            out.append("  " + line)
        }
        return out.joined(separator: "\n")
    }

    private func showDetail(for row: Int) {
        let item = filteredItems[row]
        var lines: [String] = []

        lines.append("━━━ \(item.name) ━━━")
        lines.append(String(format: "Address:  $%04X (%d)", item.address, item.address))
        lines.append("Category: \(item.category.rawValue)")

        let sym = item.romSymbol

        // The jump table entries carry the real implementation address.
        if let real = item.kernalRoutine?.realAddress {
            lines.append(String(format: "Behind:   $%04X", real))
        }

        // Description — prefer the curated KERNAL text, fall back to the symbol.
        let description = item.kernalRoutine?.description ?? sym?.description
        if let description {
            lines.append("")
            lines.append(wrapped(description))
        }

        // Signature. The KERNAL routine table and the ROM symbol table both
        // carry these; the KERNAL one wins where both exist.
        let input  = item.kernalRoutine?.input  ?? sym?.input
        let output = item.kernalRoutine?.output ?? sym?.output
        let regs   = item.kernalRoutine?.usedRegisters ?? sym?.registers
        if input != nil || output != nil || regs != nil {
            lines.append("")
            lines.append("─── Signature ───")
            if let input  { lines.append("INPUT:"); lines.append(wrapped(input)) }
            if let output { lines.append("OUTPUT:"); lines.append(wrapped(output)) }
            if let regs   { lines.append("REGISTERS USED:"); lines.append(wrapped(regs)) }
        }

        // Call syntax, plus the banking the call depends on.
        lines.append("")
        let isData = item.category == .romTable || item.category == .hardwareVector
        lines.append(isData ? "─── Access ───" : "─── Call syntax ───")
        lines.append("  " + (sym?.callSyntax
                             ?? String(format: "jsr $%04X        ; %@", item.address, item.name)))
        if item.category == .kernalJumpTable {
            lines.append("  ; from BASIC: SYS \(item.address)")
        }
        if let banking = sym?.bankingRequirement {
            lines.append("")
            lines.append("BANKING:")
            lines.append(wrapped(banking))
        }

        if let notes = sym?.notes {
            lines.append("")
            lines.append("─── Notes ───")
            lines.append(wrapped(notes))
        }

        if let example = sym?.example {
            lines.append("")
            lines.append("─── Example ───")
            lines.append(example
                .components(separatedBy: "\n")
                .map { "  " + $0 }
                .joined(separator: "\n"))
        }

        detailView.string = lines.joined(separator: "\n")
    }

    @objc private func categoryChanged(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        if idx == 0 {
            filteredItems = allItems
        } else {
            let cats = C64ROMSymbols.Category.allCases
            let selectedCat = cats[idx - 1]
            filteredItems = allItems.filter { $0.category == selectedCat }
        }
        tableView.reloadData()
        if !filteredItems.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            showDetail(for: 0)
        }
    }

    /// Filters items by query and selected category.
    func filter(by query: String) {
        let selectedCat: C64ROMSymbols.Category?
        if categoryPopup.indexOfSelectedItem > 0 {
            selectedCat = C64ROMSymbols.Category.allCases[categoryPopup.indexOfSelectedItem - 1]
        } else {
            selectedCat = nil
        }

        var base = allItems
        if let cat = selectedCat {
            base = base.filter { $0.category == cat }
        }

        if query.isEmpty {
            filteredItems = base
        } else {
            let q = query.uppercased()
            filteredItems = base.filter {
                $0.name.uppercased().contains(q) ||
                $0.romSymbol?.description.uppercased().contains(q) == true ||
                $0.romSymbol?.notes?.uppercased().contains(q) == true ||
                $0.romSymbol?.input?.uppercased().contains(q) == true ||
                $0.romSymbol?.output?.uppercased().contains(q) == true ||
                $0.kernalRoutine?.description.uppercased().contains(q) == true ||
                String(format: "$%04X", $0.address).contains(q)
            }
        }
        tableView.reloadData()
    }

    /// Applies the current theme colors to all UI elements.
    func applyTheme() {
        guard view.window != nil else { return }
        tableView.backgroundColor = AppTheme.current.panelBackground
        tableScrollView.backgroundColor = AppTheme.current.panelBackground
        detailView.backgroundColor = AppTheme.current.panelDetailBackground
        detailView.textColor = AppTheme.current.panelText
        tableView.reloadData()
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - Color Palette
// ═══════════════════════════════════════════════════════════

/// Displays the C64 16-color palette with usage hints.
class ColorPaletteViewController: NSViewController {

    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 500))
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let title = NSTextField(labelWithString: "C64 COLOR PALETTE")
        title.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
        title.textColor = AppTheme.current.refAccentBasic
        title.frame = NSRect(x: 0, y: view.bounds.height - 30, width: view.bounds.width, height: 20)
        title.alignment = .center
        title.autoresizingMask = [.width, .minYMargin]
        view.addSubview(title)

        let swatchSize: CGFloat = 65
        let spacing: CGFloat = 8
        let cols = 4
        let gridWidth = CGFloat(cols) * swatchSize + CGFloat(cols - 1) * spacing
        let startX = (view.bounds.width - gridWidth) / 2

        for i in 0..<16 {
            let row = i / cols
            let col = i % cols
            let color = C64Reference.colorPalette[i]
            let x = startX + CGFloat(col) * (swatchSize + spacing)
            let y = view.bounds.height - 60 - CGFloat(row) * (swatchSize + 22)

            let swatch = NSView(frame: NSRect(x: x, y: y - swatchSize, width: swatchSize, height: swatchSize))
            swatch.wantsLayer = true
            swatch.layer?.backgroundColor = NSColor(hex: color.hex)?.cgColor ?? NSColor.black.cgColor
            swatch.layer?.cornerRadius = 6
            swatch.layer?.borderColor = NSColor(white: AppTheme.current.isDark ? 0.3 : 0.6, alpha: 1).cgColor
            swatch.layer?.borderWidth = 1
            view.addSubview(swatch)

            let label = NSTextField(labelWithString: "\(color.index): \(color.name)")
            label.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)
            label.textColor = AppTheme.current.refDescription
            label.alignment = .center
            label.frame = NSRect(x: x, y: y - swatchSize - 16, width: swatchSize, height: 14)
            view.addSubview(label)
        }

        let usage = NSTextField(wrappingLabelWithString: "POKE 53280,color  Border\nPOKE 53281,color  Background\nPOKE 646,color    Text color\nColor RAM: $D800-$DBE7")
        usage.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        usage.textColor = AppTheme.current.statusLabel
        usage.frame = NSRect(x: 16, y: 10, width: view.bounds.width - 32, height: 70)
        view.addSubview(usage)
    }

    func applyTheme() {
        // Color swatches don't need reloading — they use fixed C64 palette colors.
        // Just update the title and usage label tints.
        view.subviews.forEach { $0.needsDisplay = true }
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - PETSCII
// ═══════════════════════════════════════════════════════════

/// Displays PETSCII control codes, printable characters, and usage examples.
class PETSCIIViewController: NSViewController {

    override func loadView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 500))
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let content = """
        COMMON PETSCII CONTROL CODES
        ════════════════════════════════

          5  $05  White text
         13  $0D  Return
         14  $0E  Switch to lowercase
         17  $11  Cursor down
         18  $12  Reverse on
         19  $13  Home
         20  $14  Delete
         28  $1C  Red text
         29  $1D  Cursor right
         30  $1E  Green text
         31  $1F  Blue text
        129  $81  Orange text
        142  $8E  Switch to uppercase
        144  $90  Black text
        145  $91  Cursor up
        146  $92  Reverse off
        147  $93  Clear screen
        148  $94  Insert
        149  $95  Brown text
        150  $96  Light red text
        151  $97  Dark gray text
        152  $98  Medium gray text
        153  $99  Light green text
        154  $9A  Light blue text
        155  $9B  Light gray text
        156  $9C  Purple text
        157  $9D  Cursor left
        158  $9E  Yellow text
        159  $9F  Cyan text

        PRINTABLE CHARACTERS
        ════════════════════════════════

         32-64:  Space, digits, punctuation
         65-90:  A-Z (uppercase mode)
         91-95:  [ £ ] ↑ ←
         96-127: Graphics characters
        160-191: Shifted graphics
        192-223: Same as 96-127

        USAGE
        ════════════════════════════════

        PRINT CHR$(147)   Clear screen
        PRINT CHR$(18)    Reverse on
        PRINT CHR$(146)   Reverse off
        A = ASC("A")      Get PETSCII code
        """

        let tv = NSTextView(frame: view.bounds)
        tv.autoresizingMask = [.width, .height]
        tv.isEditable = false
        tv.isSelectable = true
        tv.backgroundColor = AppTheme.current.panelBackground
        tv.textColor = AppTheme.current.panelText
        tv.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.string = content

        let sv = NSScrollView(frame: view.bounds)
        sv.autoresizingMask = [.width, .height]
        sv.documentView = tv
        sv.hasVerticalScroller = true
        sv.borderType = .noBorder
        view.addSubview(sv)
    }
}

// MARK: - NSColor Hex Extension

extension NSColor {
    convenience init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6 else { return nil }
        var rgb: UInt64 = 0
        Scanner(string: h).scanHexInt64(&rgb)
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - Monitor Reference
// ═══════════════════════════════════════════════════════════

/// Displays reference documentation for the active emulator's debugger (VICE or VirtualC64).
@MainActor
class MonitorReferenceViewController: NSViewController {

    /// Which command set the Monitor tab is showing.
    private enum Flavor {
        case vice    // VICE text monitor
        case vc64    // VirtualC64 RetroShell debugger console
    }

    override func loadView() {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = AppTheme.current.panelBackground
        textView.textContainerInset = NSSize(width: 10, height: 10)

        scrollView.documentView = textView
        self.view = scrollView

        textView.textStorage?.setAttributedString(monitorReferenceText())
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Refresh when the active emulator changes so the command list always
        // matches whatever the debugger is talking to (VICE vs VirtualC64).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(targetDidChange(_:)),
            name: .debuggerTargetDidChange,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func targetDidChange(_ note: Notification) {
        refresh()
    }

    private func refresh() {
        guard let scrollView = view as? NSScrollView,
              let textView = scrollView.documentView as? NSTextView else { return }
        textView.textStorage?.setAttributedString(monitorReferenceText())
    }

    func applyTheme() {
        refresh()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if let sv = view as? NSScrollView, let tv = sv.documentView as? NSTextView {
            tv.frame.size.width = sv.contentView.bounds.width
        }
    }

    /// Pick the command set from the active debuggable target. Defaults to
    /// VICE when nothing is running, since the panel is most often consulted
    /// while writing code before launch and VICE is the established default.
    private func currentFlavor() -> Flavor {
        switch EmulatorCoordinator.shared.debuggable {
        case is VC64RunTarget:  return .vc64
        case is VICERunTarget:  return .vice
        default:                return .vice
        }
    }

    private func monitorReferenceText() -> NSAttributedString {
        switch currentFlavor() {
        case .vice: return viceReferenceText()
        case .vc64: return vc64ReferenceText()
        }
    }

    // MARK: - Shared styling

    /// Builds a structured attributed string with consistent styling for commands, categories, and descriptions.
    private func makeBuilder() -> (NSMutableAttributedString,
                                   (String) -> Void,    // addHead
                                   (String) -> Void,    // addCat
                                   (String, String) -> Void) {  // addCmd
        let result = NSMutableAttributedString()

        let headFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
        let catFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        let cmdFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        let descFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

        let cyan = AppTheme.current.refAccentBasic
        let green = AppTheme.current.refAccentAsm
        let yellow = AppTheme.current.refCategory
        let gray = AppTheme.current.refDescription

        let addHead: (String) -> Void = { text in
            result.append(NSAttributedString(string: text + "\n", attributes: [.font: headFont, .foregroundColor: cyan]))
        }
        let addCat: (String) -> Void = { text in
            result.append(NSAttributedString(string: "\n" + text + "\n", attributes: [.font: catFont, .foregroundColor: yellow]))
        }
        let addCmd: (String, String) -> Void = { cmd, desc in
            result.append(NSAttributedString(string: "  " + cmd, attributes: [.font: cmdFont, .foregroundColor: green]))
            result.append(NSAttributedString(string: "  " + desc + "\n", attributes: [.font: descFont, .foregroundColor: gray]))
        }
        return (result, addHead, addCat, addCmd)
    }

    // MARK: - VICE monitor reference

    private func viceReferenceText() -> NSAttributedString {
        let (result, addHead, addCat, addCmd) = makeBuilder()

        addHead("VICE MONITOR COMMANDS")

        addCat("── EXECUTION ──")
        addCmd("g [addr]", "Go (continue from addr or current PC)")
        addCmd("x", "Exit monitor, resume execution")
        addCmd("z", "Step one instruction")
        addCmd("n", "Step over (next, skips JSR)")
        addCmd("ret", "Step out (execute until RTS)")
        addCmd("until [addr]", "Run until address is reached")

        addCat("── BREAKPOINTS ──")
        addCmd("break [addr]", "Set breakpoint (or list all)")
        addCmd("watch [addr]", "Set watchpoint (break on access)")
        addCmd("trace [addr]", "Set tracepoint (log, don't stop)")
        addCmd("delete [num]", "Delete breakpoint by number")
        addCmd("enable [num]", "Enable breakpoint")
        addCmd("disable [num]", "Disable breakpoint")
        addCmd("ignore [num] [cnt]", "Ignore BP for count hits")
        addCmd("cond [num] [expr]", "Set condition on breakpoint")

        addCat("── REGISTERS ──")
        addCmd("r", "Display all registers")
        addCmd("r PC=$0810", "Set register value")
        addCmd("r A=$FF", "Set accumulator")

        addCat("── MEMORY ──")
        addCmd("m [start] [end]", "Display memory hex dump")
        addCmd("> [addr] [bytes]", "Write bytes to memory")
        addCmd("f [s] [e] [val]", "Fill memory range")
        addCmd("h [s] [e] [val]", "Hunt (search) for bytes")
        addCmd("c [s] [e] [addr]", "Compare memory ranges")
        addCmd("t [s] [e] [addr]", "Transfer (copy) memory")

        addCat("── DISASSEMBLY ──")
        addCmd("d [addr]", "Disassemble at address")
        addCmd("a [addr] [asm]", "Assemble instruction at addr")

        addCat("── I/O & FILES ──")
        addCmd("l \"file\" 0 [addr]", "Load file from filesystem")
        addCmd("s \"file\" 0 [s] [e]", "Save memory range to file")
        addCmd("@", "Display disk status")

        addCat("── DISPLAY ──")
        addCmd("bank [name]", "Switch memory bank view")
        addCmd("io", "Display I/O register area")
        addCmd("bt", "Show call stack (backtrace)")
        addCmd("screen", "Display screen codes")

        addCat("── MISC ──")
        addCmd("radix [h|d|o|b]", "Set default number radix")
        addCmd("sidefx [on|off]", "Toggle I/O side effects")
        addCmd("log [on|off]", "Toggle instruction logging")
        addCmd("quit", "Quit VICE entirely")

        addCat("── TIPS ──")
        addCmd("break $0810", "Break at common ASM entry")
        addCmd("watch $d020", "Watch border color changes")
        addCmd("m d000 d030", "View VIC-II registers")
        addCmd("m dc00 dc0f", "View CIA1 registers")
        addCmd("m 0400 07e7", "View screen memory")
        addCmd("> 0400 01 02 03", "Write to screen memory")

        return result
    }

    // MARK: - VirtualC64 RetroShell reference

    private func vc64ReferenceText() -> NSAttributedString {
        let (result, addHead, addCat, addCmd) = makeBuilder()

        addHead("VIRTUALC64 DEBUGGER COMMANDS")

        addCat("── EXECUTION ──")
        addCmd("pause  / p", "Pause emulation")
        addCmd("goto [addr] / g", "Continue (or go to address)")
        addCmd("step / s", "Step into the next instruction")
        addCmd("next / n", "Step over the next instruction")
        addCmd("eol", "Run to end of current scanline")
        addCmd("eof", "Run to end of current frame")

        addCat("── BREAKPOINTS ──")
        addCmd("break", "List all breakpoints")
        addCmd("break at [addr]", "Set a breakpoint")
        addCmd("break delete [nr]", "Delete breakpoint by number")
        addCmd("break toggle [nr]", "Enable/disable a breakpoint")

        addCat("── WATCHPOINTS ──")
        addCmd("watch", "List all watchpoints")
        addCmd("watch at [addr]", "Set a watchpoint")
        addCmd("watch delete [nr]", "Delete a watchpoint")
        addCmd("watch toggle [nr]", "Enable/disable a watchpoint")

        addCat("── REGISTERS ──")
        addCmd("r", "Show CPU registers")
        addCmd("r cia1", "Show CIA1 registers")
        addCmd("r cia2", "Show CIA2 registers")
        addCmd("r vicii", "Show VIC-II registers")
        addCmd("r sid", "Show SID registers")

        addCat("── MEMORY ──")
        addCmd("m [addr]", "Dump memory (hex)")
        addCmd("a [addr]", "Dump memory (ASCII)")
        addCmd("w [addr] [val]", "Write into memory")
        addCmd("c [src] [dst] [n]", "Copy a chunk of memory")
        addCmd("f [addr] [bytes]", "Find a sequence in memory")
        addCmd("e [addr] [n]", "Erase memory")

        addCat("── DISASSEMBLY ──")
        addCmd("d [addr]", "Disassemble instructions")

        addCat("── INSPECT (?) ──")
        addCmd("? c64", "Inspect the C64 (overview)")
        addCmd("? cpu", "Inspect the CPU")
        addCmd("? memory", "Inspect memory banking")
        addCmd("? vic", "Inspect the VIC-II")
        addCmd("? sid", "Inspect the SID")
        addCmd("? cia1 / ? cia2", "Inspect a CIA")
        addCmd("? drive8", "Inspect a floppy drive")

        addCat("── SYMBOLS & DEBUG ──")
        addCmd("import symbols", "Import debug symbol data")
        addCmd("checksums", "Show component checksums")
        addCmd("debug", "List debug variable channels")

        addCat("── CONSOLES ──")
        addCmd("commander", "Switch to the Commander console")
        addCmd("debugger", "Switch to the Debugger console")
        addCmd("Shift+Tab", "Toggle between consoles")

        addCat("── NOTES ──")
        addCmd("Tab", "Auto-complete the current command")
        addCmd("[abbrev]", "Most commands accept a short form")
        addCmd("help / ?", "RetroShell built-in help")

        return result
    }
}

