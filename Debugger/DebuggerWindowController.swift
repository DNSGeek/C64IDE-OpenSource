import Cocoa

// ═══════════════════════════════════════════════════════════
// MARK: - DebuggerWindowController
// ═══════════════════════════════════════════════════════════

/// NSWindowController hosting the C64 debugger interface.
///
/// Initializes a resizable, theme-aware window configured for register
/// inspection, execution control, and console interaction.
class DebuggerWindowController: NSWindowController {

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Debugger"
        window.center()
        window.minSize = NSSize(width: 600, height: 420)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = AppTheme.current.panelBackground

        self.init(window: window)
        window.contentViewController = DebuggerViewController()
    }

    var debuggerVC: DebuggerViewController? {
        window?.contentViewController as? DebuggerViewController
    }

    @objc func closeTab(_ sender: Any?) {
        window?.performClose(sender)
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - DebuggerViewController
// ═══════════════════════════════════════════════════════════

/// NSViewController managing the debugger UI, execution state, and console.
///
/// Binds to a `DebuggableTarget` (VICE or VC64) to receive register updates,
/// breakpoint hits, and CPU jam events. Drives the UI via frame-based layout
/// for predictable rendering of dynamic console and register views.
class DebuggerViewController: NSViewController {

    /// The active debuggable target. Set by `EmulatorCoordinator` after launch.
    /// `nil` when no debug session is active.
    ///
    /// Weak: EmulatorCoordinator owns the target's lifetime. A strong
    /// reference here pinned the last session (bridge, VCCore thread, window
    /// controller) after the emulator stopped, because nothing cleared this
    /// property on stop.
    weak var debugTarget: (any DebuggableTarget)? {
        didSet {
            // Detach OUR callbacks from the previously-bound target so a
            // detached or replaced session can't drive this view anymore.
            // Only debugger-owned hooks are cleared here. onDidStop belongs
            // to EmulatorCoordinator (it clears `active` there) and must
            // survive a detach; onLog is chained, so restore the closure we
            // wrapped rather than nilling it.
            if let old = oldValue, old !== debugTarget {
                old.onBreakpoint = nil
                old.onJam        = nil
                old.onPause      = nil
                old.onLog        = chainedForwardLog
                chainedForwardLog = nil
            }
            bindToTarget()
        }
    }

    /// The target's onLog closure as it was at bind time (the coordinator's
    /// build-panel routing), so detaching can put it back instead of leaving
    /// our console-mirroring wrapper installed.
    private var chainedForwardLog: ((String, MessageType) -> Void)?

    private var consoleTextView: NSTextView!
    private var consoleScrollView: NSScrollView!
    private var commandField: NSTextField!
    private var connectButton: NSButton!
    private var statusLabel: NSTextField!
    private var addrField: NSTextField!

    // Register labels
    private var regLabels: [String: NSTextField] = [:]
    private var flagsLabel: NSTextField!

    // Cycle counter
    private var cycleAccumulator: Int = 0
    private var cycleCountLabel: NSTextField!

    /// PC of the stop we last reported. Used to (a) drop duplicate `onPause`
    /// callbacks for one stop and (b) know which instruction just executed,
    /// so the cycle counter charges for the instruction that *ran* rather
    /// than the one we're about to run. `nil` means "no baseline" — set on
    /// continue/goto/reset so a resumed run doesn't bill one stale opcode.
    private var lastSteppedPC: UInt16?

    /// True while a jam alert is on screen, so a CPU that keeps re-jamming
    /// (or a duplicate message) can't stack a pile of modal sheets.
    private var isShowingJamAlert = false

    /// The console is append-only and a busy session produces thousands of
    /// lines. Past this many, the oldest fifth is dropped: an unbounded
    /// text storage makes every append re-lay-out the whole document.
    private let maxConsoleLines = 5000
    private var consoleLineCount = 0

    // Execution control buttons
    private var stepBtn: NSButton!
    private var stepOverBtn: NSButton!
    private var stepOutBtn: NSButton!
    private var continueBtn: NSButton!
    private var pauseBtn: NSButton!

    private var regBg:    NSView!
    private var dimLabels: [NSTextField] = []

    /// Debug info from the last build (.dbg file).
    /// Set by `AppDelegate` after a build so we can map PC → source line.
    var debugInfo: DebugInfoParser?

    /// Called when the debug execution line changes.
    /// Int = source line (1-indexed) to highlight, nil = clear highlight.
    var onDebugLineChanged: ((Int?) -> Void)?

    /// Cycle/raster arithmetic depends on the PAL/NTSC choice in the build
    /// configuration, which the user can change mid-session.
    private var timing: C64Timing {
        C64Timing.from(config: (NSApp.delegate as? AppDelegate)?
            .mainWindowController?.buildConfig ?? BuildConfiguration())
    }

    private var consoleGreen: NSColor { AppTheme.current.syntaxFunction }
    private var promptCyan:   NSColor { AppTheme.current.syntaxKeyword }
    private var warnYellow:   NSColor { AppTheme.current.syntaxOperator }

    // MARK: - View Lifecycle

    override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 560))
        view.wantsLayer = true
        view.layer?.backgroundColor = AppTheme.current.panelBackground.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange(_:)),
            name: .appThemeDidChange, object: nil)
        // Posted by EmulatorCoordinator whenever the active target starts or
        // stops. This is how we detach when a session ends, now that we no
        // longer overwrite the target's onDidStop.
        NotificationCenter.default.addObserver(
            self, selector: #selector(coordinatorTargetDidChange(_:)),
            name: .debuggerTargetDidChange, object: nil)
    }

    /// Detach when our session is no longer the coordinator's active target.
    /// Going through the setter runs the didSet teardown; the weak property
    /// alone would zero silently without it.
    @objc private func coordinatorTargetDidChange(_ note: Notification) {
        let live = EmulatorCoordinator.shared.debuggable
        if let bound = debugTarget {
            if bound !== live { debugTarget = nil }
        } else if live == nil {
            // The weak reference can zero before this notification arrives
            // (didSet does not fire on weak zeroing) - sync the UI manually.
            updateConnectionStatus(false)
        }
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

    // MARK: - Theming

    private func applyThemeColors() {
        view.window?.appearance       = AppTheme.current.nsAppearance
        view.window?.backgroundColor  = AppTheme.current.panelBackground
        view.layer?.backgroundColor   = AppTheme.current.panelBackground.cgColor
        regBg?.layer?.backgroundColor = AppTheme.current.editorBackground.cgColor
        dimLabels.forEach { $0.textColor = AppTheme.current.statusLabel }
        flagsLabel?.textColor         = AppTheme.current.syntaxOperator
        cycleCountLabel?.textColor    = AppTheme.current.syntaxFunction
        // Update register value labels (stored by key in regLabels dict)
        regLabels.values.forEach { $0.textColor = AppTheme.current.syntaxKeyword }
        consoleTextView?.backgroundColor = AppTheme.current.panelDetailBackground
        consoleTextView?.textColor       = AppTheme.current.syntaxFunction
        consoleScrollView?.backgroundColor = AppTheme.current.panelDetailBackground
        commandField?.backgroundColor    = AppTheme.current.panelDetailBackground
        commandField?.textColor          = AppTheme.current.syntaxKeyword
    }

    // MARK: - UI Construction

    private func buildUI() {
        let w = view.bounds.width
        var y = view.bounds.height - 8

        // ── Row 1: Connection & Address ──────────────────────
        y -= 30
        connectButton = NSButton(title: "Connect", target: self, action: #selector(toggleConnectionAction(_:)))
        connectButton.frame = NSRect(x: 12, y: y, width: 90, height: 24)
        connectButton.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        connectButton.autoresizingMask = [.minYMargin]
        view.addSubview(connectButton)

        statusLabel = NSTextField(labelWithString: "● Disconnected")
        statusLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = .red
        statusLabel.frame = NSRect(x: 110, y: y + 3, width: 150, height: 18)
        statusLabel.autoresizingMask = [.minYMargin]
        view.addSubview(statusLabel)

        let addrLbl = makeLabel("Address:")
        addrLbl.frame = NSRect(x: 280, y: y + 3, width: 65, height: 18)
        addrLbl.autoresizingMask = [.minYMargin]
        view.addSubview(addrLbl)

        addrField = NSTextField(string: "0800")
        addrField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        addrField.frame = NSRect(x: 350, y: y, width: 70, height: 22)
        addrField.autoresizingMask = [.minYMargin]
        view.addSubview(addrField)

        let goBtn = NSButton(title: "Go", target: self, action: #selector(goAction(_:)))
        goBtn.frame = NSRect(x: 425, y: y, width: 40, height: 22)
        goBtn.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        goBtn.autoresizingMask = [.minYMargin]
        addrField.target = self
        addrField.action = #selector(goAction(_:))
        view.addSubview(goBtn)

        // ── Row 2: Execution Control ─────────────────────────
        y -= 32
        let execLabel = makeLabel("EXECUTION")
        execLabel.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .bold)
        execLabel.textColor = AppTheme.current.statusLabel
        execLabel.frame = NSRect(x: 12, y: y + 3, width: 80, height: 14)
        execLabel.autoresizingMask = [.minYMargin]
        dimLabels.append(execLabel)
        view.addSubview(execLabel)

        let execBtns: [(String, Selector)] = [
            ("▶ Continue", #selector(continueAction(_:))),
            ("⏸ Pause", #selector(pauseAction(_:))),
            ("Step", #selector(stepAction(_:))),
            ("Step Over", #selector(stepOverAction(_:))),
            ("Step Out", #selector(stepOutAction(_:))),
            ("⟳ Regs", #selector(regsAction(_:))),
        ]
        var btnX: CGFloat = 95
        for (i, (title, action)) in execBtns.enumerated() {
            let btn = NSButton(title: title, target: self, action: action)
            let btnW: CGFloat = title.count > 8 ? 85 : 75
            btn.frame = NSRect(x: btnX, y: y, width: btnW, height: 24)
            btn.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
            btn.autoresizingMask = [.minYMargin]
            view.addSubview(btn)
            btnX += btnW + 4

            switch i {
            case 0: continueBtn = btn
            case 1: pauseBtn = btn
            case 2: stepBtn = btn
            case 3: stepOverBtn = btn
            case 4: stepOutBtn = btn
            default: break
            }
        }

        // ── Row 3: Registers ─────────────────────────────────
        y -= 28
        regBg = NSView(frame: NSRect(x: 12, y: y - 2, width: w - 24, height: 24))
        regBg.wantsLayer = true
        regBg.layer?.backgroundColor = AppTheme.current.editorBackground.cgColor
        regBg.layer?.cornerRadius = 4
        regBg.autoresizingMask = [.width, .minYMargin]
        view.addSubview(regBg)

        var regX: CGFloat = 20
        for name in ["PC", "A", "X", "Y", "SP"] {
            let lbl = makeLabel(name + ":")
            lbl.frame = NSRect(x: regX, y: y, width: 28, height: 18)
            lbl.autoresizingMask = [.minYMargin]
            view.addSubview(lbl)

            let val = NSTextField(labelWithString: "----")
            val.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .bold)
            val.textColor = AppTheme.current.syntaxKeyword
            let valW: CGFloat = name == "PC" ? 45 : 25
            val.frame = NSRect(x: regX + 28, y: y, width: valW, height: 18)
            val.autoresizingMask = [.minYMargin]
            view.addSubview(val)
            regLabels[name] = val
            regX += name == "PC" ? 85 : 65
        }

        let fLbl = makeLabel("FL:")
        fLbl.frame = NSRect(x: regX, y: y, width: 25, height: 18)
        fLbl.autoresizingMask = [.minYMargin]
        view.addSubview(fLbl)

        flagsLabel = NSTextField(labelWithString: "--------")
        flagsLabel.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .bold)
        flagsLabel.textColor = AppTheme.current.syntaxOperator
        flagsLabel.frame = NSRect(x: regX + 25, y: y, width: 80, height: 18)
        flagsLabel.autoresizingMask = [.minYMargin]
        view.addSubview(flagsLabel)

        // ── Row 4: Breakpoint & Memory buttons ───────────────
        y -= 30
        let toolLabel = makeLabel("TOOLS")
        toolLabel.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .bold)
        toolLabel.textColor = AppTheme.current.statusLabel
        toolLabel.frame = NSRect(x: 12, y: y + 3, width: 50, height: 14)
        toolLabel.autoresizingMask = [.minYMargin]
        dimLabels.append(toolLabel)
        view.addSubview(toolLabel)

        let toolBtns: [(String, Selector)] = [
            ("Set BP", #selector(setBP(_:))),
            ("Del BP", #selector(delBP(_:))),
            ("List BP", #selector(listBP(_:))),
            ("Memory", #selector(memAction(_:))),
            ("Disasm", #selector(disasmAction(_:))),
            ("Stack", #selector(stackAction(_:))),
        ]
        var toolX: CGFloat = 65
        for (title, action) in toolBtns {
            let btn = NSButton(title: title, target: self, action: action)
            btn.frame = NSRect(x: toolX, y: y, width: 62, height: 22)
            btn.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
            btn.autoresizingMask = [.minYMargin]
            view.addSubview(btn)
            toolX += 66
        }

        // ── Row 5: Cycle counter ─────────────────────────────
        y -= 28
        let cycLabel = makeLabel("CYCLES")
        cycLabel.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .bold)
        cycLabel.textColor = AppTheme.current.statusLabel
        cycLabel.frame = NSRect(x: 12, y: y + 3, width: 50, height: 14)
        cycLabel.autoresizingMask = [.minYMargin]
        dimLabels.append(cycLabel)
        view.addSubview(cycLabel)

        cycleCountLabel = NSTextField(labelWithString: "0 cycles  ·  0.00 raster lines (PAL)")
        cycleCountLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        cycleCountLabel.textColor = AppTheme.current.syntaxFunction
        cycleCountLabel.frame = NSRect(x: 65, y: y + 3, width: 280, height: 16)
        cycleCountLabel.autoresizingMask = [.minYMargin]
        view.addSubview(cycleCountLabel)

        let resetCycBtn = NSButton(title: "Reset", target: self, action: #selector(resetCycles(_:)))
        resetCycBtn.frame = NSRect(x: 353, y: y, width: 55, height: 20)
        resetCycBtn.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        resetCycBtn.autoresizingMask = [.minYMargin]
        view.addSubview(resetCycBtn)

        // ── Console ──────────────────────────────────────────
        y -= 10

        consoleTextView = NSTextView(frame: NSRect(x: 0, y: 0, width: w - 24, height: y - 40))
        consoleTextView.isEditable = false
        consoleTextView.isSelectable = true
        consoleTextView.backgroundColor = AppTheme.current.panelDetailBackground
        consoleTextView.textColor = AppTheme.current.syntaxFunction
        consoleTextView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        consoleTextView.textContainerInset = NSSize(width: 8, height: 4)

        consoleScrollView = NSScrollView(frame: NSRect(x: 12, y: 38, width: w - 24, height: y - 38))
        consoleScrollView.autoresizingMask = [.width, .height]
        consoleScrollView.documentView = consoleTextView
        consoleScrollView.hasVerticalScroller = true
        consoleScrollView.borderType = .noBorder
        view.addSubview(consoleScrollView)

        // ── Command input ────────────────────────────────────
        let cmdPrompt = makeLabel("(C:$)")
        cmdPrompt.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        cmdPrompt.textColor = AppTheme.current.syntaxKeyword
        cmdPrompt.frame = NSRect(x: 12, y: 10, width: 45, height: 18)
        view.addSubview(cmdPrompt)

        commandField = NSTextField(string: "")
        commandField.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        commandField.textColor = AppTheme.current.syntaxKeyword
        commandField.backgroundColor = AppTheme.current.panelDetailBackground
        commandField.focusRingType = .none
        commandField.frame = NSRect(x: 60, y: 8, width: w - 80, height: 22)
        commandField.autoresizingMask = [.width]
        commandField.placeholderString = "Type a monitor command…"
        commandField.target = self
        commandField.action = #selector(sendCommand(_:))
        view.addSubview(commandField)

        // Initial message
        appendConsole("C64 IDE Debugger", color: promptCyan)
        appendConsole("1. Build & Debug your program (⌘R)", color: .gray)
        appendConsole("2. The debugger attaches automatically on launch", color: .gray)
        appendConsole("3. Use buttons or type commands directly", color: .gray)
        appendConsole("", color: nil)
    }

    private func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = AppTheme.current.statusLabel
        dimLabels.append(label)
        return label
    }

    // MARK: - Client Setup

    private func bindToTarget() {
        guard let t = debugTarget else {
            updateConnectionStatus(false)
            return
        }

        // [weak t] everywhere below: these closures are STORED ON the target,
        // so a strong capture of `t` is a self-retain cycle - the target would
        // keep itself alive through its own callback even after everyone else
        // released it.
        t.onBreakpoint = { [weak self, weak t] pc in
            guard let self, let t else { return }
            self.appendConsole(String(format: "⚑ BREAK at $%04X", pc), color: .yellow)
            // Ask, don't wait. `t.registers` blocks the caller on a monitor
            // round trip, and for VICE the reply is delivered by way of this
            // very thread — reading it here deadlocked until the 2s timeout
            // and then displayed stale registers. The answer arrives via
            // onPause, which refreshes the register view, the source
            // highlight and the cycle counter.
            t.requestRegisters()
        }

        t.onJam = { [weak self, weak t] pc in
            guard let self, let t else { return }
            self.appendConsole(
                String(format: "✗ CPU JAMMED at $%04X (illegal opcode)", pc),
                color: .red)
            // Reuse the exact breakpoint highlight path: show registers and
            // highlight the source line for the jammed PC.
            t.requestRegisters()
            self.presentJamAlert(pc: pc, target: t)
        }

        t.onPause = { [weak self] regs in
            self?.updateRegisters(regs)
        }

        // Chain onLog, don't replace it: EmulatorCoordinator routes target
        // logs to the build panel; we additionally mirror them here. The
        // original closure is stashed so a detach can restore it.
        chainedForwardLog = t.onLog
        let forward = chainedForwardLog
        t.onLog = { [weak self] msg, type in
            forward?(msg, type)
            self?.appendConsole(msg, color: nil)
        }

        // Deliberately NOT touching t.onDidStop: the coordinator installed
        // its cleanup there (clears `active`, posts .debuggerTargetDidChange).
        // Overwriting it kept `active` pointing at dead sessions forever.
        // We learn about stops via that notification instead - see
        // coordinatorTargetDidChange(_:).

        updateConnectionStatus(true)
        appendConsole("Debugger attached to \(t.runTarget.displayName).", color: promptCyan)

        // Reflect the active target in the window title.
        self.view.window?.title = "\(t.runTarget.displayName) Debugger"

        // Command syntax differs: VICE uses its text monitor, VC64 uses
        // RetroShell. Hint the right one in the field.
        if t is VICERunTarget {
            commandField.placeholderString = "Type a VICE monitor command…"
        } else {
            commandField.placeholderString = "Type a RetroShell command…"
        }
    }

    // MARK: - Connection

    @objc private func toggleConnectionAction(_ sender: Any?) {
        if debugTarget != nil {
            // Currently attached → DETACH the debugger view only. This does
            // NOT stop the emulator; the emulator window owns its own
            // lifecycle. Clearing debugTarget tears down our callbacks.
            appendConsole("Detached from session (emulator left running).", color: warnYellow)
            debugTarget = nil
        } else if let live = EmulatorCoordinator.shared.debuggable {
            // Not attached but something is running → attach to it.
            debugTarget = live
        } else {
            appendConsole("Nothing to attach to — launch a program with Build & Debug (⌘R).",
                          color: warnYellow)
        }
    }

    // MARK: - Command Input

    @objc private func sendCommand(_ sender: NSTextField) {
        let cmd = sender.stringValue.trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty else { return }
        guard let t = requireTarget() else { return }
        appendConsole("(C:$) \(cmd)", color: promptCyan)
        sendMonitorCommand(cmd, to: t)
        sender.stringValue = ""
    }

    // MARK: - Execution Control

    @objc private func continueAction(_ sender: Any?) {
        guard let t = requireTarget() else { return }
        appendConsole("▶ Continue", color: promptCyan)
        onDebugLineChanged?(nil)
        // The CPU is about to run an unknown number of instructions, so the
        // PC we were stopped at is no longer "the instruction just executed".
        lastSteppedPC = nil
        t.resume()
    }

    @objc private func pauseAction(_ sender: Any?) {
        guard let t = requireTarget() else { return }
        appendConsole("⏸ Pause", color: promptCyan)
        // Actually pause. Previously this only read the registers, which
        // happens to drop VICE into its monitor but does nothing at all to
        // VirtualC64 — the Pause button simply didn't pause it.
        t.pause()
        t.requestRegisters()
    }

    @objc private func stepAction(_ sender: Any?) {
        guard let t = requireTarget() else { return }
        t.stepInto()
    }

    @objc private func stepOverAction(_ sender: Any?) {
        guard let t = requireTarget() else { return }
        t.stepOver()
    }

    @objc private func stepOutAction(_ sender: Any?) {
        guard let t = requireTarget() else { return }
        t.finishLine()
    }

    @objc private func regsAction(_ sender: Any?) {
        guard let t = requireTarget() else { return }
        t.requestRegisters()
    }

    // MARK: - Breakpoints & Memory

    /// Parses a hex address, accepting a leading `$` or `0x`.
    private func parseHexAddress(_ raw: String) -> UInt16? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("$") { s.removeFirst() }
        if s.lowercased().hasPrefix("0x") { s.removeFirst(2) }
        guard !s.isEmpty else { return nil }
        return UInt16(s, radix: 16)
    }

    /// The address field's contents, or `nil` after complaining to the console.
    ///
    /// Deliberately not a silent fallback to `$0800`: `goAction` sets the PC
    /// from this, so a typo used to quietly jump the CPU into the BASIC area
    /// and destroy the session the user was trying to debug.
    private func requireAddress() -> UInt16? {
        guard let addr = parseHexAddress(addrField.stringValue) else {
            appendConsole("Invalid address: '\(addrField.stringValue)' — expected hex, e.g. 0810",
                          color: .red)
            return nil
        }
        return addr
    }

    /// The attached target, or `nil` after saying so. Every button used to
    /// no-op in silence when nothing was attached.
    private func requireTarget() -> (any DebuggableTarget)? {
        guard let t = debugTarget else {
            appendConsole("No debug session attached — launch with Build & Debug (⌘R).",
                          color: warnYellow)
            return nil
        }
        return t
    }

    /// Routes a raw command to whichever console the target speaks: VICE's
    /// text monitor or VirtualC64's RetroShell. Replies stream back into our
    /// console through the target's normal log path.
    private func sendMonitorCommand(_ cmd: String, to target: any DebuggableTarget) {
        if let vice = target as? VICERunTarget {
            vice.sendRawMonitorCommand(cmd)
        } else if let vc64 = target as? VC64RunTarget {
            vc64.retroShellExec(cmd)
        } else {
            appendConsole("\(target.runTarget.displayName) has no command console.",
                          color: warnYellow)
        }
    }

    @objc private func setBP(_ sender: Any?) {
        guard let t = requireTarget(), let addr = requireAddress() else { return }
        t.setBreakpoint(at: addr)
        appendConsole(String(format: "Setting breakpoint at $%04X", addr), color: warnYellow)
    }

    @objc private func delBP(_ sender: Any?) {
        guard let t = requireTarget() else { return }
        // Address-based to mirror setBP and DebuggableTarget.deleteBreakpoint(at:).
        let alert = NSAlert()
        alert.messageText = "Delete Breakpoint"
        alert.informativeText = "Enter breakpoint address (hex):"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
        field.stringValue = addrField.stringValue
        alert.accessoryView = field
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        guard let addr = parseHexAddress(field.stringValue) else {
            appendConsole("Invalid breakpoint address: '\(field.stringValue)'", color: .red)
            return
        }
        t.deleteBreakpoint(at: addr)
        appendConsole(String(format: "Deleting breakpoint at $%04X", addr), color: warnYellow)
    }

    @objc private func listBP(_ sender: Any?) {
        guard let t = requireTarget() else { return }
        appendConsole("Breakpoints:", color: warnYellow)
        // Both monitors spell the listing the same way. This used to be a
        // placeholder string that told the user to go look at the gutter.
        sendMonitorCommand("break", to: t)
    }

    @objc private func memAction(_ sender: Any?) {
        guard let t = requireTarget(), let addr = requireAddress() else { return }
        // Clamp the end so addr + 0x7F can't trap past $FFFF (e.g. user typed FFFF)
        let end = UInt16(min(Int(addr) + 0x7F, 0xFFFF))
        let data = t.readMemory(from: addr, to: end)
        guard !data.isEmpty else {
            appendConsole(String(format: "No response reading $%04X-$%04X.", addr, end), color: .red)
            return
        }
        let bytesPerRow = 16
        for rowStart in stride(from: 0, to: data.count, by: bytesPerRow) {
            let rowEnd = min(rowStart + bytesPerRow, data.count)
            let hex = data[rowStart..<rowEnd].map { String(format: "%02X", $0) }.joined(separator: " ")
            appendConsole(String(format: "$%04X  %@", addr &+ UInt16(rowStart), hex as CVarArg), color: consoleGreen)
        }
    }

    @objc private func disasmAction(_ sender: Any?) {
        guard let t = requireTarget(), let addr = requireAddress() else { return }
        let lines = t.disassemble(count: 16, from: addr)
        guard !lines.isEmpty else {
            appendConsole(String(format: "No response disassembling $%04X.", addr), color: .red)
            return
        }
        for line in lines {
            appendConsole(line, color: consoleGreen)
        }
    }

    @objc private func stackAction(_ sender: Any?) {
        guard let t = requireTarget() else { return }
        guard let vice = t as? VICERunTarget else {
            appendConsole("Stack trace isn't available for \(t.runTarget.displayName).", color: .gray)
            return
        }
        appendConsole("Call stack:", color: warnYellow)
        vice.sendRawMonitorCommand("bt")
    }

    // MARK: - Console

    func appendConsole(_ text: String, color: NSColor?) {
        guard let storage = consoleTextView?.textStorage else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: color ?? consoleGreen,
        ]

        // Only follow the tail if the user is already at the tail. Scrolling
        // unconditionally yanked them back down mid-read every time a log
        // line arrived.
        let follow = isConsoleAtBottom()

        storage.append(NSAttributedString(string: text + "\n", attributes: attrs))
        consoleLineCount += 1
        if consoleLineCount > maxConsoleLines { trimConsole() }

        if follow { consoleTextView.scrollToEndOfDocument(nil) }
    }

    private func isConsoleAtBottom() -> Bool {
        guard let clip = consoleScrollView?.contentView,
              let doc  = consoleScrollView?.documentView else { return true }
        // A document shorter than the viewport is trivially "at the bottom".
        guard doc.frame.height > clip.bounds.height else { return true }
        return clip.bounds.maxY >= doc.frame.height - 4
    }

    /// Drops the oldest fifth of the console in one splice. Trimming a line at
    /// a time would re-lay-out the document on every append once the cap is
    /// reached; this pays that cost once per 1000 lines instead.
    private func trimConsole() {
        guard let storage = consoleTextView?.textStorage else { return }
        let text = storage.string as NSString
        let target = maxConsoleLines / 5

        var cut = 0
        var dropped = 0
        while dropped < target && cut < text.length {
            let found = text.range(of: "\n", options: [],
                                   range: NSRange(location: cut, length: text.length - cut))
            guard found.location != NSNotFound else { break }
            cut = found.location + 1
            dropped += 1
        }
        guard cut > 0 else { return }

        storage.deleteCharacters(in: NSRange(location: 0, length: cut))
        // Counted from real newlines, so multi-line log messages can't drift
        // the count away from the document's actual size.
        consoleLineCount = max(0, consoleLineCount - dropped)
    }

    // MARK: - Register Display

    private func updateRegisters(_ regs: RegisterState) {
        regLabels["PC"]?.stringValue = String(format: "%04X", regs.pc)
        regLabels["A"]?.stringValue = String(format: "%02X", regs.a)
        regLabels["X"]?.stringValue = String(format: "%02X", regs.x)
        regLabels["Y"]?.stringValue = String(format: "%02X", regs.y)
        regLabels["SP"]?.stringValue = String(format: "%02X", regs.sp)
        flagsLabel?.stringValue = regs.flagsString

        // A single stop can produce more than one onPause — VirtualC64
        // publishes registers on a breakpoint hit and again when we ask for
        // them. Everything below is once-per-stop work, so gate it on the PC
        // actually having moved.
        guard regs.pc != lastSteppedPC else { return }
        let executedPC = lastSteppedPC
        lastSteppedPC = regs.pc

        accumulateCycles(forInstructionAt: executedPC)
        reportSourceLocation(pc: regs.pc)
    }

    /// Logs the source location for `pc` and drives the editor highlight.
    private func reportSourceLocation(pc: UInt16) {
        guard let info = debugInfo, let loc = info.location(forAddress: pc) else {
            // PC is in ROM, an IRQ handler, or code with no debug info. Clear
            // the highlight rather than pointing at whichever line happened to
            // be nearest — that used to light up the last line of the file
            // every time execution left the program.
            onDebugLineChanged?(nil)
            return
        }
        let file = info.fileName(forId: loc.fileId)
            .map { ($0 as NSString).lastPathComponent } ?? "?"
        appendConsole(String(format: "  → %@:%d (PC=$%04X)", file, loc.line, pc), color: warnYellow)
        // Only highlight primary-file lines; a line number from an
        // include would highlight the wrong line in the main editor.
        onDebugLineChanged?(loc.fileId == info.primaryFileId ? loc.line : nil)
    }

    /// Present the "CPU jammed" alert with three choices. Default is the
    /// non-destructive Open Debugger so a reflexive Return doesn't wipe the
    /// state the user needs to diagnose the crash.
    private func presentJamAlert(pc: UInt16, target: any DebuggableTarget) {
        guard !isShowingJamAlert else { return }
        isShowingJamAlert = true

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "CPU Jammed"
        alert.informativeText = String(
            format: "The processor halted on an illegal instruction at $%04X. "
                  + "The machine won't continue until it's reset.", pc)

        // Order matters: first added is the default (rightmost, Return-bound).
        alert.addButton(withTitle: "Open Debugger")  // default — non-destructive
        let resetButton = alert.addButton(withTitle: "Reset")
        let dismissButton = alert.addButton(withTitle: "Dismiss")

        // Tag Reset as destructive (macOS 11+) and bind Dismiss to Escape.
        if #available(macOS 11.0, *) { resetButton.hasDestructiveAction = true }
        dismissButton.keyEquivalent = "\u{1b}"   // Esc

        let finish: () -> Void = { [weak self] in self?.isShowingJamAlert = false }

        // Sheet-attach to our window if we have one; otherwise run modal.
        if let window = self.view.window {
            alert.beginSheetModal(for: window) { [weak self] response in
                self?.handleJamChoice(response, pc: pc, target: target)
                finish()
            }
        } else {
            let response = alert.runModal()
            handleJamChoice(response, pc: pc, target: target)
            finish()
        }
    }

    private func handleJamChoice(_ response: NSApplication.ModalResponse,
                                 pc: UInt16,
                                 target: any DebuggableTarget) {
        switch response {
        case .alertFirstButtonReturn:   // Open Debugger
            // Bring the debugger window forward and re-assert the PC highlight.
            // The machine stays frozen; we're just surfacing the corpse.
            self.view.window?.makeKeyAndOrderFront(nil)
            // Clearing the baseline makes the next update re-log the trace and
            // re-assert the highlight for a PC we've already reported.
            lastSteppedPC = nil
            target.requestRegisters()
            appendConsole("Inspect registers and memory above; Reset when done.",
                          color: warnYellow)

        case .alertSecondButtonReturn:  // Reset
            appendConsole("↻ Resetting after jam.", color: promptCyan)
            onDebugLineChanged?(nil)     // clear the stale highlight
            lastSteppedPC = nil
            target.reset()

        default:                        // Dismiss (Esc / third button)
            // Leave everything frozen and untouched. The highlight set by
            // updateRegisters stays, so the user can still see where it died.
            break
        }
    }

    private func updateConnectionStatus(_ connected: Bool) {
        if connected {
            statusLabel.stringValue = "● Connected"
            statusLabel.textColor = AppTheme.current.syntaxFunction
            connectButton.title = "Disconnect"
        } else {
            statusLabel.stringValue = "● Disconnected"
            statusLabel.textColor = .red
            connectButton.title = "Connect"
            for (_, label) in regLabels { label.stringValue = "----" }
            flagsLabel?.stringValue = "--------"
            lastSteppedPC = nil
            onDebugLineChanged?(nil)
        }
    }

    @objc private func goAction(_ sender: Any?) {
        guard let target = requireTarget(), let addr = requireAddress() else { return }
        appendConsole(String(format: "→ PC = $%04X", addr), color: promptCyan)
        onDebugLineChanged?(nil)
        lastSteppedPC = nil
        target.goto(address: addr)
    }

    // MARK: - Cycle Counter

    @objc private func resetCycles(_ sender: Any?) {
        cycleAccumulator = 0
        // Drop the baseline too, so the next stop starts a fresh count
        // instead of immediately billing the instruction we're sitting on.
        lastSteppedPC = nil
        let t = timing
        cycleCountLabel?.stringValue = "0 cycles  ·  0.00 raster lines (\(t.name))"
    }

    /// Adds the cost of the instruction that just executed.
    ///
    /// `pc` is where we were stopped *before* this update, not where we are
    /// now: charging for the opcode at the new PC bills an instruction that
    /// hasn't run yet. `nil` means there's no baseline (fresh attach, or we
    /// just resumed and ran an unknown number of instructions), so there's
    /// nothing meaningful to charge.
    ///
    /// This runs from `updateRegisters`, which fires on every stop. It used
    /// to be wired only into the breakpoint callback, so the counter never
    /// moved while stepping — the thing it exists to measure.
    private func accumulateCycles(forInstructionAt pc: UInt16?) {
        guard let pc, let target = debugTarget else { return }

        let data = target.readMemory(from: pc, to: pc)
        guard let opcode = data.first else { return }
        let info = Disassembler6502.opcodeTable[Int(opcode)]
        guard info.mnemonic != "???" else { return }

        cycleAccumulator += info.cycles
        // maxCycles applies the branch rule (+1 taken, +1 again across a page),
        // so a branch reports "+2" rather than understating it as "+1".
        let penalty = info.maxCycles - info.cycles
        let penaltyStr = penalty > 0 ? "+\(penalty)" : ""
        let t = timing
        cycleCountLabel?.stringValue =
            "last: \(info.cycles)\(penaltyStr)  ·  total: \(cycleAccumulator)"
            + "  ·  \(t.rasterLines(for: cycleAccumulator)) lines (\(t.name))"
    }
}
