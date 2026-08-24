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
    private var lastSteppedPC: UInt16? = nil

    // Execution control buttons
    private var stepBtn: NSButton!
    private var stepOverBtn: NSButton!
    private var stepOutBtn: NSButton!
    private var continueBtn: NSButton!
    private var pauseBtn: NSButton!

    /// Breakpoints to set when connecting (address list)
    private var pendingBreakpoints: [UInt16] = []
    private var regBg:    NSView!
    private var dimLabels: [NSTextField] = []
    /// Entry point for the current program
    var entryPoint: UInt16 = 0x0810

    /// Debug info from the last build (.dbg file).
    /// Set by `AppDelegate` after a build so we can map PC → source line.
    var debugInfo: DebugInfoParser?

    /// Called when the debug execution line changes.
    /// Int = source line (1-indexed) to highlight, nil = clear highlight.
    var onDebugLineChanged: ((Int?) -> Void)?

    private var consoleBg:    NSColor { AppTheme.current.panelDetailBackground }
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
            let regs = t.registers
            self.updateRegisters(regs)
            self.annotateStepCycles(at: pc, target: t)
        }

        t.onJam = { [weak self, weak t] pc in
            guard let self, let t else { return }
            self.appendConsole(
                String(format: "✗ CPU JAMMED at $%04X (illegal opcode)", pc),
                color: .red)
            // Reuse the exact breakpoint highlight path: show registers and
            // highlight the source line for the jammed PC.
            self.updateRegisters(t.registers)
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
        appendConsole("(C:$) \(cmd)", color: promptCyan)
        if let vice = debugTarget as? VICERunTarget {
            vice.sendRawMonitorCommand(cmd)
        } else if let vc64 = debugTarget as? VC64RunTarget {
            vc64.retroShellExec(cmd)
        }
        sender.stringValue = ""
    }

    // MARK: - Execution Control

    @objc private func continueAction(_ sender: Any?) {
        appendConsole("▶ Continue", color: promptCyan)
        onDebugLineChanged?(nil)
        debugTarget?.resume()
    }

    @objc private func pauseAction(_ sender: Any?) {
        // Sending any command while running causes VICE to break
        appendConsole("⏸ Pause (requesting registers)", color: promptCyan)
        let _ = debugTarget?.registers
    }

    @objc private func stepAction(_ sender: Any?) {
        debugTarget?.stepInto()
        let _ = debugTarget?.registers
    }

    @objc private func stepOverAction(_ sender: Any?) {
        debugTarget?.stepOver()
        let _ = debugTarget?.registers
    }

    @objc private func stepOutAction(_ sender: Any?) {
        debugTarget?.finishLine()
        let _ = debugTarget?.registers
    }

    @objc private func regsAction(_ sender: Any?) {
        let _ = debugTarget?.registers
    }

    // MARK: - Breakpoints & Memory

    private func getAddress() -> UInt16 {
        var s = addrField.stringValue.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("$") { s.removeFirst() }
        return UInt16(s, radix: 16) ?? 0x0800
    }

    @objc private func setBP(_ sender: Any?) {
        let addr = getAddress()
        debugTarget?.setBreakpoint(at: addr)
        appendConsole(String(format: "Setting breakpoint at $%04X", addr), color: warnYellow)
    }

    @objc private func delBP(_ sender: Any?) {
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

        var s = field.stringValue.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("$") { s.removeFirst() }
        guard let addr = UInt16(s, radix: 16) else {
            appendConsole("Invalid breakpoint address: \(field.stringValue)", color: .red)
            return
        }
        debugTarget?.deleteBreakpoint(at: addr)
        appendConsole(String(format: "Deleting breakpoint at $%04X", addr), color: warnYellow)
    }

    @objc private func listBP(_ sender: Any?) {
        appendConsole("Breakpoints: (see editor gutter)", color: warnYellow)
    }

    @objc private func memAction(_ sender: Any?) {
        let addr = getAddress()
        // Clamp the end so addr + 0x7F can't trap past $FFFF (e.g. user typed FFFF)
        let end = UInt16(min(Int(addr) + 0x7F, 0xFFFF))
        guard let data = debugTarget?.readMemory(from: addr, to: end) else { return }
        let bytesPerRow = 16
        for rowStart in stride(from: 0, to: data.count, by: bytesPerRow) {
            let rowEnd = min(rowStart + bytesPerRow, data.count)
            let hex = data[rowStart..<rowEnd].map { String(format: "%02X", $0) }.joined(separator: " ")
            appendConsole(String(format: "$%04X  %@", addr &+ UInt16(rowStart), hex as CVarArg), color: consoleGreen)
        }
    }

    @objc private func disasmAction(_ sender: Any?) {
        let addr = getAddress()
        guard let lines = debugTarget?.disassemble(count: 16, from: addr) else { return }
        for line in lines {
            appendConsole(line, color: consoleGreen)
        }
    }

    @objc private func stackAction(_ sender: Any?) {
        appendConsole("Stack trace not yet available in this target.", color: .gray)
    }

    // MARK: - Console

    func appendConsole(_ text: String, color: NSColor?) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: color ?? consoleGreen,
        ]
        consoleTextView.textStorage?.append(NSAttributedString(string: text + "\n", attributes: attrs))
        consoleTextView.scrollToEndOfDocument(nil)
    }

    // MARK: - Register Display

    private func updateRegisters(_ regs: RegisterState) {
        regLabels["PC"]?.stringValue = String(format: "%04X", regs.pc)
        regLabels["A"]?.stringValue = String(format: "%02X", regs.a)
        regLabels["X"]?.stringValue = String(format: "%02X", regs.x)
        regLabels["Y"]?.stringValue = String(format: "%02X", regs.y)
        regLabels["SP"]?.stringValue = String(format: "%02X", regs.sp)
        flagsLabel.stringValue = regs.flagsString

        // Source-level debugging: map PC → source location via .dbg info
        if let info = debugInfo, let loc = info.location(forAddress: regs.pc) {
            let file = info.fileName(forId: loc.fileId)
                .map { ($0 as NSString).lastPathComponent } ?? "?"
            appendConsole(String(format: "  → %@:%d (PC=$%04X)", file, loc.line, regs.pc), color: warnYellow)
            // Only highlight primary-file lines; a line number from an
            // include would highlight the wrong line in the main editor.
            onDebugLineChanged?(loc.fileId == info.primaryFileId ? loc.line : nil)
        } else {
            // PC is in ROM or code without debug info — clear highlight
            onDebugLineChanged?(nil)
        }
    }

    /// True while a jam alert is on screen, so a CPU that keeps re-jamming
    /// (or a duplicate message) can't stack a pile of modal sheets.
    private var isShowingJamAlert = false

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
            updateRegisters(target.registers)
            appendConsole("Inspect registers and memory above; Reset when done.",
                          color: warnYellow)

        case .alertSecondButtonReturn:  // Reset
            appendConsole("↻ Resetting after jam.", color: promptCyan)
            onDebugLineChanged?(nil)     // clear the stale highlight
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
            onDebugLineChanged?(nil)
        }
    }

    @objc private func goAction(_ sender: Any?) {
        guard let target = debugTarget else {
            appendConsole("No debug session attached.", color: warnYellow)
            return
        }
        let addr = getAddress()
        appendConsole(String(format: "→ PC = $%04X", addr), color: promptCyan)
        onDebugLineChanged?(nil)
        target.goto(address: addr)
    }

    // MARK: - Cycle Counter

    @objc private func resetCycles(_ sender: Any?) {
        cycleAccumulator = 0
        let timing = C64Timing.from(config: (NSApp.delegate as? AppDelegate)?.mainWindowController?.buildConfig ?? BuildConfiguration())
        cycleCountLabel?.stringValue = "0 cycles  ·  0.00 raster lines (\(timing.name))"
    }

    /// Annotate cycle cost from a `RegisterState` — reads the opcode at PC
    /// from the target's memory so we don't need to parse VICE text output.
    private func annotateStepCycles(at pc: UInt16, target: any DebuggableTarget) {
        let data = target.readMemory(from: pc, to: pc)
        guard let opcode = data.first else { return }
        let info = Disassembler6502.opcodeTable[Int(opcode)]
        guard info.mnemonic != "???" else { return }
        let timing = C64Timing.from(config: (NSApp.delegate as? AppDelegate)?.mainWindowController?.buildConfig ?? BuildConfiguration())
        cycleAccumulator += info.cycles
        // maxCycles applies the branch rule (+1 taken, +1 again across a page),
        // so a branch reports "+2" rather than understating it as "+1".
        let penalty = info.maxCycles - info.cycles
        let penaltyStr = penalty > 0 ? "+\(penalty)" : ""
        let rasterStr = timing.rasterLines(for: cycleAccumulator)
        cycleCountLabel?.stringValue = "last: \(info.cycles)\(penaltyStr)  ·  total: \(cycleAccumulator)  ·  \(rasterStr) lines (\(timing.name))"
    }

    /// Parse the opcode byte from a VICE step/disassembly response line and
    /// accumulate its cycle cost.
    /// VICE format: "(C:$fd7c) .C:fd7e  D0 08       BNE $FD88   - A:AB ..."
    private func annotateStepCycles(from response: String) {
        guard let dotCRange = response.range(of: ".C:") ?? response.range(of: ".c:") else { return }

        let afterDotC = response[dotCRange.upperBound...]
        let addrPart = afterDotC.prefix(4)
        guard addrPart.count == 4, addrPart.allSatisfy({ $0.isHexDigit }) else { return }

        let afterAddr = afterDotC.dropFirst(4).drop(while: { $0 == " " })
        let opcodeStr = String(afterAddr.prefix(2))
        guard opcodeStr.count == 2, let opcode = UInt8(opcodeStr, radix: 16) else { return }

        let info = Disassembler6502.opcodeTable[Int(opcode)]
        guard info.mnemonic != "???" else { return }

        let timing = C64Timing.from(config: (NSApp.delegate as? AppDelegate)?.mainWindowController?.buildConfig ?? BuildConfiguration())
        cycleAccumulator += info.cycles

        // maxCycles applies the branch rule (+1 taken, +1 again across a page),
        // so a branch reports "+2" rather than understating it as "+1".
        let penalty = info.maxCycles - info.cycles
        let penaltyStr = penalty > 0 ? "+\(penalty)" : ""
        let rasterStr = timing.rasterLines(for: cycleAccumulator)
        cycleCountLabel?.stringValue = "last: \(info.cycles)\(penaltyStr)  ·  total: \(cycleAccumulator)  ·  \(rasterStr) lines (\(timing.name))"
    }
}

