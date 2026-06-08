import Cocoa

// ═══════════════════════════════════════════════════════════
// MARK: - DisassemblerWindowController
// ═══════════════════════════════════════════════════════════

/// NSWindowController hosting the 6502 disassembler interface.
class DisassemblerWindowController: NSWindowController {

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "6502 Disassembler"
        window.center()
        window.minSize = NSSize(width: 550, height: 400)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = AppTheme.current.panelBackground

        self.init(window: window)
        window.contentViewController = DisassemblerViewController()
    }

    @objc func closeTab(_ sender: Any?) {
        window?.performClose(sender)
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - DisassemblerViewController
// ═══════════════════════════════════════════════════════════

/// NSViewController managing the disassembler UI, file loading, and rendering.
class DisassemblerViewController: NSViewController {

    private var disassembler = Disassembler6502()
    private var currentLines: [DisassembledLine] = []
    private var startAddress: UInt16 = 0
    private var lastLoadedFilename: String?

    private var textView: NSTextView!
    private var scrollView: NSScrollView!
    private var infoLabel: NSTextField!
    private var cycleLabel: NSTextField!

    /// Maps character ranges in the text view to `DisassembledLine` indices.
    /// Built during rendering to enable selection-to-cycle-count mapping.
    private var charIndexToLineIndex: [(range: NSRange, lineIndex: Int)] = []

    private var bgColor: NSColor { AppTheme.current.panelBackground }

    override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 600))
        view.wantsLayer = true
        view.layer?.backgroundColor = bgColor.cgColor
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
        view.window?.backgroundColor = AppTheme.current.panelBackground
        view.layer?.backgroundColor  = AppTheme.current.panelBackground.cgColor
        infoLabel?.textColor         = AppTheme.current.statusLabel
        cycleLabel?.textColor        = AppTheme.current.syntaxFunction
        textView?.backgroundColor    = AppTheme.current.panelDetailBackground
        scrollView?.backgroundColor  = AppTheme.current.panelDetailBackground
        // Re-render attributed content with new colors
        if currentLines.isEmpty {
            showWelcome()
        } else {
            renderDisassembly(currentLines)
        }
    }

    private func buildUI() {
        let w = view.bounds.width
        var y = view.bounds.height - 8

        // ── Toolbar row ──────────────────────────────────────
        y -= 30

        let loadBtn = NSButton(title: "Load PRG…", target: self, action: #selector(loadPRG(_:)))
        loadBtn.frame = NSRect(x: 12, y: y, width: 95, height: 24)
        loadBtn.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        loadBtn.autoresizingMask = [.minYMargin]
        view.addSubview(loadBtn)

        let exportAsmBtn = NSButton(title: "Export ASM…", target: self, action: #selector(exportASM(_:)))
        exportAsmBtn.frame = NSRect(x: 115, y: y, width: 100, height: 24)
        exportAsmBtn.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        exportAsmBtn.autoresizingMask = [.minYMargin]
        view.addSubview(exportAsmBtn)

        let copyBtn = NSButton(title: "Copy All", target: self, action: #selector(copyAll(_:)))
        copyBtn.frame = NSRect(x: 223, y: y, width: 75, height: 24)
        copyBtn.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        copyBtn.autoresizingMask = [.minYMargin]
        view.addSubview(copyBtn)

        let editBtn = NSButton(title: "Edit in IDE", target: self, action: #selector(editInIDE(_:)))
        editBtn.frame = NSRect(x: 306, y: y, width: 95, height: 24)
        editBtn.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        editBtn.autoresizingMask = [.minYMargin]
        view.addSubview(editBtn)

        infoLabel = NSTextField(labelWithString: "No file loaded")
        infoLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        infoLabel.textColor = AppTheme.current.statusLabel
        infoLabel.frame = NSRect(x: 412, y: y + 3, width: w - 430, height: 18)
        infoLabel.autoresizingMask = [.width, .minYMargin]
        view.addSubview(infoLabel)

        // ── Cycle info row ───────────────────────────────────
        y -= 26

        cycleLabel = NSTextField(labelWithString: "Select instructions to see cycle count")
        cycleLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        cycleLabel.textColor = AppTheme.current.syntaxFunction
        cycleLabel.frame = NSRect(x: 12, y: y + 3, width: w - 24, height: 18)
        cycleLabel.autoresizingMask = [.width, .minYMargin]
        view.addSubview(cycleLabel)

        // ── Disassembly text view ────────────────────────────
        y -= 8

        textView = NSTextView(frame: NSRect(x: 0, y: 0, width: w - 24, height: y - 8))
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = AppTheme.current.panelDetailBackground
        textView.textColor = AppTheme.current.syntaxFunction
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false

        // Observe text selection changes for cycle counting
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(selectionDidChange(_:)),
            name: NSTextView.didChangeSelectionNotification,
            object: textView
        )

        scrollView = NSScrollView(frame: NSRect(x: 12, y: 8, width: w - 24, height: y - 8))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        view.addSubview(scrollView)

        // Show welcome text
        showWelcome()
    }

    private func showWelcome() {
        let text = NSMutableAttributedString()
        let cyan = AppTheme.current.syntaxKeyword
        let gray = AppTheme.current.statusLabel
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let boldFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)

        text.append(NSAttributedString(string: "6502 Disassembler\n\n", attributes: [.font: boldFont, .foregroundColor: cyan]))
        text.append(NSAttributedString(string: "Click \"Load PRG…\" to open a Commodore 64 program file.\n\n", attributes: [.font: font, .foregroundColor: gray]))
        text.append(NSAttributedString(string: "Features:\n", attributes: [.font: font, .foregroundColor: cyan]))
        text.append(NSAttributedString(string: "  • Auto-detects load address from PRG header\n", attributes: [.font: font, .foregroundColor: gray]))
        text.append(NSAttributedString(string: "  • Annotates KERNAL routines (CHROUT, GETIN, etc.)\n", attributes: [.font: font, .foregroundColor: gray]))
        text.append(NSAttributedString(string: "  • Labels VIC-II, SID, and CIA registers\n", attributes: [.font: font, .foregroundColor: gray]))
        text.append(NSAttributedString(string: "  • Identifies branch targets\n", attributes: [.font: font, .foregroundColor: gray]))
        text.append(NSAttributedString(string: "  • Flags illegal/undocumented opcodes\n", attributes: [.font: font, .foregroundColor: gray]))
        text.append(NSAttributedString(string: "  • Export as ca65-compatible assembly source\n", attributes: [.font: font, .foregroundColor: gray]))
        text.append(NSAttributedString(string: "  • Edit in IDE — open disassembly as editable, buildable assembly\n", attributes: [.font: font, .foregroundColor: gray]))

        textView.textStorage?.setAttributedString(text)
    }

    // MARK: - Actions

    @objc private func loadPRG(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .init(filenameExtension: "prg")!,
            .init(filenameExtension: "bin")!,
            .init(filenameExtension: "p00")!,
        ]
        panel.allowsMultipleSelection = false
        panel.title = "Load PRG for Disassembly"

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.disassembleFile(url)
        }
    }

    @objc private func exportASM(_ sender: Any?) {
        guard !currentLines.isEmpty else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "asm")!]
        panel.nameFieldStringValue = "disassembly.asm"
        panel.title = "Export Assembly Source"

        panel.begin { [weak self] response in
            guard let self = self, response == .OK, let url = panel.url else { return }
            let source = self.disassembler.exportAsAssembly(lines: self.currentLines, startAddress: self.startAddress)
            try? source.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    @objc private func copyAll(_ sender: Any?) {
        let text = currentLines.map { $0.formatted }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func editInIDE(_ sender: Any?) {
        guard !currentLines.isEmpty else { return }

        // Generate buildable assembly source with proper ca65 header
        let source = disassembler.generateAssembly(
            lines: currentLines, startAddress: startAddress, buildable: true
        )

        // Open in the main editor as a new tab
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let wc = appDelegate.mainWindowController else { return }

        let doc = C64Document(fileType: .assembly, content: source)
        let baseName = lastLoadedFilename?.replacingOccurrences(of: ".prg", with: "")
                                          .replacingOccurrences(of: ".bin", with: "") ?? "disassembly"
        doc.customTitle = "\(baseName)_disasm.s"
        wc.addNewTab(with: doc)

        // Bring the main window to front
        wc.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Disassembly

    /// Loads and disassembles a PRG file (can be called externally).
    func loadFile(_ url: URL) {
        disassembleFile(url)
    }

    private func disassembleFile(_ url: URL) {
        do {
            let (loadAddr, data) = try Disassembler6502.loadPRG(from: url)
            startAddress = loadAddr
            lastLoadedFilename = url.deletingPathExtension().lastPathComponent

            let lines = disassembler.disassemble(data: data, startAddress: loadAddr)
            currentLines = lines

            infoLabel.stringValue = String(format: "%@ — $%04X-%04X (%d bytes, %d instructions)",
                                           url.lastPathComponent, loadAddr, loadAddr + UInt16(data.count) - 1,
                                           data.count, lines.count)

            renderDisassembly(lines)
        } catch {
            infoLabel.stringValue = "Error: \(error.localizedDescription)"
        }
    }

    private func renderDisassembly(_ lines: [DisassembledLine]) {
        let result = NSMutableAttributedString()
        charIndexToLineIndex = []

        let addrColor     = AppTheme.current.statusLabel
        let hexColor      = AppTheme.current.syntaxComment
        let mnemonicColor = AppTheme.current.syntaxKeyword
        let operandColor  = AppTheme.current.defaultText
        let commentColor  = AppTheme.current.syntaxComment
        let illegalColor  = AppTheme.current.logError
        let dataColor     = AppTheme.current.syntaxOperator
        let labelColor    = AppTheme.current.syntaxLineNumber
        let cycleColor    = AppTheme.current.syntaxFunction
        let font     = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let boldFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)

        for (lineIndex, line) in lines.enumerated() {
            // Branch target label (not a selectable instruction line)
            if disassembler.branchTargets.contains(line.address) {
                let labelStr = String(format: "L_%04X:\n", line.address)
                result.append(NSAttributedString(string: labelStr,
                    attributes: [.font: boldFont, .foregroundColor: labelColor]))
            }

            let lineStart = result.length

            // Address
            let addrStr = String(format: "$%04X  ", line.address)
            result.append(NSAttributedString(string: addrStr,
                attributes: [.font: font, .foregroundColor: addrColor]))

            // Hex bytes
            let hexStr = line.bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            let hexPadded = hexStr.padding(toLength: 9, withPad: " ", startingAt: 0) + "  "
            result.append(NSAttributedString(string: hexPadded,
                attributes: [.font: font, .foregroundColor: hexColor]))

            if line.isData {
                let dataStr = "\(line.mnemonic) \(line.operand)"
                result.append(NSAttributedString(string: dataStr,
                    attributes: [.font: font, .foregroundColor: dataColor]))
            } else {
                // Mnemonic
                let mColor = line.isIllegal ? illegalColor : mnemonicColor
                result.append(NSAttributedString(string: line.mnemonic,
                    attributes: [.font: boldFont, .foregroundColor: mColor]))

                // Operand
                if !line.operand.isEmpty {
                    result.append(NSAttributedString(string: " \(line.operand)",
                        attributes: [.font: font, .foregroundColor: operandColor]))
                }
            }

            // Comment
            if let comment = line.comment {
                let padding = max(1, 30 - line.mnemonic.count - line.operand.count - 1)
                let pad = String(repeating: " ", count: padding)
                result.append(NSAttributedString(string: "\(pad); \(comment)",
                    attributes: [.font: font, .foregroundColor: commentColor]))
            }

            // Cycle count column — right-pad to fixed position then show cycles
            if !line.isData && line.cycles > 0 {
                let currentLen = result.length - lineStart
                let targetCol = 55
                let pad = max(1, targetCol - currentLen)
                result.append(NSAttributedString(
                    string: String(repeating: " ", count: pad),
                    attributes: [.font: font, .foregroundColor: cycleColor]))

                let cycleStr: String
                if line.pageCrossPenalty > 0 {
                    cycleStr = "[\(line.cycles)/\(line.cycles + line.pageCrossPenalty)]"
                } else {
                    cycleStr = "[\(line.cycles)]"
                }
                result.append(NSAttributedString(string: cycleStr,
                    attributes: [.font: font, .foregroundColor: cycleColor]))
            }

            result.append(NSAttributedString(string: "\n",
                attributes: [.font: font, .foregroundColor: operandColor]))

            // Record the character range for this line
            let lineEnd = result.length
            charIndexToLineIndex.append((range: NSRange(location: lineStart, length: lineEnd - lineStart), lineIndex: lineIndex))
        }

        textView.textStorage?.setAttributedString(result)
        textView.scrollToBeginningOfDocument(nil)
        cycleLabel.stringValue = "Select instructions to see cycle count"
    }

    // MARK: - Cycle Count Selection

    @objc private func selectionDidChange(_ notification: Notification) {
        let sel = textView.selectedRange()
        guard sel.length > 0 else {
            cycleLabel.stringValue = "Select instructions to see cycle count"
            return
        }

        let selEnd = sel.location + sel.length
        var selected: [DisassembledLine] = []
        for entry in charIndexToLineIndex {
            let entryEnd = entry.range.location + entry.range.length
            if entry.range.location < selEnd && entryEnd > sel.location,
               entry.lineIndex < currentLines.count {
                selected.append(currentLines[entry.lineIndex])
            }
        }

        let executable = selected.filter { !$0.isData }
        guard !executable.isEmpty else {
            cycleLabel.stringValue = "Selection contains no executable instructions"
            return
        }

        let timing: C64Timing
        if let wc = (NSApp.delegate as? AppDelegate)?.mainWindowController {
            timing = C64Timing.from(config: wc.buildConfig)
        } else {
            timing = .pal
        }

        let baseCycles  = executable.reduce(0) { $0 + $1.cycles }
        let worstCycles = executable.reduce(0) { $0 + $1.cycles + $1.pageCrossPenalty }
        let n = executable.count

        let cycleStr: String
        if baseCycles == worstCycles {
            cycleStr = "\(n) instruction\(n == 1 ? "" : "s") · \(baseCycles) cycles · \(timing.rasterLines(for: baseCycles)) raster lines (\(timing.name))"
        } else {
            cycleStr = "\(n) instruction\(n == 1 ? "" : "s") · \(baseCycles)–\(worstCycles) cycles (page cross) · \(timing.rasterLines(for: baseCycles))–\(timing.rasterLines(for: worstCycles)) raster lines (\(timing.name))"
        }
        cycleLabel.stringValue = cycleStr
    }
}

