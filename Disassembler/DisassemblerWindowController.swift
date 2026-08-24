import Cocoa
import UniformTypeIdentifiers

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
    /// Payload of the loaded file, kept so the listing can be re-based onto a
    /// different address without going back to disk.
    private var currentData: [UInt8] = []
    private var startAddress: UInt16 = 0
    private var lastLoadedFilename: String?
    private var currentSourceName: String = ""

    private var textView: NSTextView!
    private var scrollView: NSScrollView!
    private var infoLabel: NSTextField!
    private var cycleLabel: NSTextField!
    private var addressCaption: NSTextField!
    private var addressField: NSTextField!

    private enum DefaultsKey {
        /// Last address the user gave a headerless binary, so the next one
        /// starts from the same place rather than a fixed guess.
        static let rawLoadAddress = "DisassemblerRawLoadAddress"
    }

    /// Where a raw dump is assumed to live until the user says otherwise.
    /// $C000 is the usual home for machine language called from BASIC.
    private static let defaultRawLoadAddress: UInt16 = 0xC000

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

    deinit {
        NotificationCenter.default.removeObserver(self)
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
        addressCaption?.textColor    = AppTheme.current.statusLabel
        textView?.backgroundColor    = AppTheme.current.panelDetailBackground
        scrollView?.backgroundColor  = AppTheme.current.panelDetailBackground
        // Re-render attributed content with new colors. Recolouring is not a
        // navigation event, so the reader keeps their place and selection
        // instead of being thrown back to the top of the listing.
        if currentLines.isEmpty {
            showWelcome()
        } else {
            let scrollOrigin = scrollView?.contentView.bounds.origin
            let selection = textView?.selectedRange()
            renderDisassembly(currentLines, preservingPosition: true)
            if let selection, selection.upperBound <= (textView.textStorage?.length ?? 0) {
                textView.setSelectedRange(selection)
            }
            if let scrollOrigin {
                textView.scroll(scrollOrigin)
            }
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

        // ── Load address + cycle info row ────────────────────
        y -= 26

        // Editing this re-bases the listing. A raw dump has no load address of
        // its own, and a .prg can always be relocated, so the address the
        // listing was built with belongs on screen where it can be corrected.
        addressCaption = NSTextField(labelWithString: "Address  $")
        addressCaption.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        addressCaption.textColor = AppTheme.current.statusLabel
        addressCaption.frame = NSRect(x: 12, y: y + 3, width: 68, height: 18)
        addressCaption.autoresizingMask = [.minYMargin]
        view.addSubview(addressCaption)

        addressField = NSTextField(frame: NSRect(x: 80, y: y, width: 54, height: 21))
        addressField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        addressField.alignment = .center
        addressField.placeholderString = "----"
        addressField.isEnabled = false
        addressField.target = self
        addressField.action = #selector(addressFieldChanged(_:))
        addressField.autoresizingMask = [.minYMargin]
        addressField.toolTip = "Address the listing is based at. Edit to re-base it."
        view.addSubview(addressField)

        cycleLabel = NSTextField(labelWithString: "Select instructions to see cycle count")
        cycleLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        cycleLabel.textColor = AppTheme.current.syntaxFunction
        cycleLabel.frame = NSRect(x: 146, y: y + 3, width: w - 158, height: 18)
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
        // A disassembly is a fixed-column dump: wrapping a long line shifts every
        // column on it and ruins the alignment the hex, cycle and PETSCII columns
        // depend on. Let lines run wide and scroll horizontally instead.
        textView.isHorizontallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.size = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                              height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]

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
        scrollView.hasHorizontalScroller = true
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
        text.append(NSAttributedString(string: "  • Auto-detects load address from PRG and P00 headers\n", attributes: [.font: font, .foregroundColor: gray]))
        text.append(NSAttributedString(string: "  • Asks where raw .bin dumps belong, and re-bases on demand\n", attributes: [.font: font, .foregroundColor: gray]))
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
        // compactMap rather than `!`: UTType(filenameExtension:) is documented as
        // failable, and a nil here would take the whole app down at the moment
        // the user tried to open a file.
        panel.allowedContentTypes = ["prg", "bin", "p00"].compactMap { UTType(filenameExtension: $0) }
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
        panel.allowedContentTypes = [UTType(filenameExtension: "asm")].compactMap { $0 }
        panel.nameFieldStringValue = "\(lastLoadedFilename ?? "disassembly").asm"
        panel.title = "Export Assembly Source"

        panel.begin { [weak self] response in
            guard let self = self, response == .OK, let url = panel.url else { return }
            let source = self.disassembler.exportAsAssembly(lines: self.currentLines, startAddress: self.startAddress)
            do {
                try source.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                // A failed export used to be swallowed by `try?`, leaving the
                // user believing the file had been written.
                self.presentError(error, title: "Could not save \(url.lastPathComponent)")
            }
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
        // lastLoadedFilename already has its extension stripped.
        doc.customTitle = "\(lastLoadedFilename ?? "disassembly")_disasm.s"
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
            let file = try Disassembler6502.load(from: url)
            lastLoadedFilename = url.deletingPathExtension().lastPathComponent

            if let loadAddress = file.loadAddress {
                present(data: file.data, at: loadAddress, source: url.lastPathComponent)
            } else {
                // A raw dump does not say where it belongs, and guessing gets
                // every address in the listing wrong. Ask.
                promptForLoadAddress(fileName: url.lastPathComponent, raw: file.data)
            }
        } catch {
            currentLines = []
            currentData = []
            addressField.stringValue = ""
            addressField.isEnabled = false
            infoLabel.stringValue = "Error: \(error.localizedDescription)"
            presentError(error, title: "Could not disassemble \(url.lastPathComponent)")
        }
    }

    /// Disassembles `data` as though it were loaded at `address` and shows it.
    private func present(data: [UInt8], at address: UInt16, source: String) {
        startAddress = address
        currentData = data
        currentSourceName = source

        let lines = disassembler.disassemble(data: data, startAddress: address)
        currentLines = lines

        addressField.isEnabled = true
        addressField.stringValue = String(format: "%04X", address)

        // Computed in Int and masked back: a program that runs up to or past
        // $FFFF (16 KB at $C000, say) overflowed a UInt16 here and trapped.
        let endAddr = (Int(address) + max(data.count, 1) - 1) & 0xFFFF
        infoLabel.stringValue = String(format: "%@ — $%04X-%04X (%ld bytes, %ld instructions)",
                                       source, Int(address), endAddr,
                                       data.count, lines.count)

        renderDisassembly(lines)
    }

    /// Asks where a headerless binary should be based.
    ///
    /// Offers the alternative too: some files carrying a `.bin` extension really
    /// are `.prg`s, so the user can say "read the first two bytes as a load
    /// address" instead of typing one.
    private func promptForLoadAddress(fileName: String, raw: [UInt8]) {
        let stored = UserDefaults.standard.object(forKey: DefaultsKey.rawLoadAddress) as? Int
        let suggested = stored.map { UInt16(truncatingIfNeeded: $0) }
            ?? Self.defaultRawLoadAddress

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 54))

        let caption = NSTextField(labelWithString: "Load address  $")
        caption.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        caption.frame = NSRect(x: 0, y: 32, width: 100, height: 18)
        accessory.addSubview(caption)

        let field = NSTextField(frame: NSRect(x: 100, y: 29, width: 60, height: 21))
        field.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        field.alignment = .center
        field.stringValue = String(format: "%04X", suggested)
        field.tag = Self.addressFieldTag
        accessory.addSubview(field)

        let headerBox = NSButton(checkboxWithTitle: "File begins with a 2-byte load address",
                                 target: self, action: #selector(headerCheckboxToggled(_:)))
        headerBox.font = NSFont.systemFont(ofSize: 11)
        headerBox.frame = NSRect(x: 0, y: 0, width: 300, height: 18)
        accessory.addSubview(headerBox)

        let alert = NSAlert()
        alert.messageText = "Where should \u{201C}\(fileName)\u{201D} be disassembled?"
        alert.informativeText = """
            A raw binary carries no load address, so there is nothing in the file \
            to say where in memory it belongs. Every address, branch target and \
            KERNAL symbol in the listing is derived from this value.
            """
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Disassemble")
        alert.addButton(withTitle: "Cancel")

        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }

            if headerBox.state == .on {
                do {
                    let (address, payload) = try Disassembler6502.splitLoadAddress(from: raw)
                    self.present(data: payload, at: address, source: fileName)
                } catch {
                    self.presentError(error, title: "Could not disassemble \(fileName)")
                }
                return
            }

            guard let address = Self.parseHexAddress(field.stringValue) else {
                self.presentError(DisassemblerError.invalidAddress(field.stringValue),
                                  title: "Could not disassemble \(fileName)")
                return
            }
            UserDefaults.standard.set(Int(address), forKey: DefaultsKey.rawLoadAddress)
            self.present(data: raw, at: address, source: fileName)
        }

        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    private static let addressFieldTag = 4242

    /// Reading the address from the file makes typing one meaningless.
    @objc private func headerCheckboxToggled(_ sender: NSButton) {
        let field = sender.superview?.viewWithTag(Self.addressFieldTag) as? NSTextField
        field?.isEnabled = sender.state != .on
    }

    /// Re-bases the loaded listing when the toolbar address is edited.
    @objc private func addressFieldChanged(_ sender: NSTextField) {
        guard !currentData.isEmpty else { return }
        guard let address = Self.parseHexAddress(sender.stringValue) else {
            NSSound.beep()
            sender.stringValue = String(format: "%04X", startAddress)
            return
        }
        guard address != startAddress else { return }
        present(data: currentData, at: address, source: currentSourceName)
    }

    /// Parses 1-4 hexadecimal digits, tolerating a `$` or `0x` prefix and
    /// surrounding whitespace. Hex-only: a disassembler window is no place to
    /// have to guess whether "1000" meant $1000 or 4096.
    static func parseHexAddress(_ text: String) -> UInt16? {
        var digits = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if digits.hasPrefix("$")       { digits.removeFirst() }
        else if digits.hasPrefix("0X") { digits.removeFirst(2) }

        guard (1...4).contains(digits.count),
              digits.allSatisfy(\.isHexDigit),
              let value = UInt16(digits, radix: 16) else { return nil }
        return value
    }

    /// Surfaces a failure the user needs to know about. The status label alone
    /// is easy to miss, and file errors used to be discarded entirely.
    private func presentError(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func renderDisassembly(_ lines: [DisassembledLine], preservingPosition: Bool = false) {
        let result = NSMutableAttributedString()
        charIndexToLineIndex = []
        charIndexToLineIndex.reserveCapacity(lines.count)

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
            let hexPadded = hexStr.columnPadded(to: 9) + "  "
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

                // `maxCycles` knows a taken branch costs +1 and a taken branch
                // onto another page +1 again, so BNE now reads [2/4] rather than
                // understating its worst case as [2/3].
                let worst = line.maxCycles
                let cycleStr = worst > line.cycles ? "[\(line.cycles)/\(worst)]"
                                                   : "[\(line.cycles)]"
                result.append(NSAttributedString(string: cycleStr,
                    attributes: [.font: font, .foregroundColor: cycleColor]))
            }

            // PETSCII hint column — pad to a fixed position then show |xxx|.
            // Lets you spot string data that the disassembler decoded as (illegal) opcodes:
            // a run of |HEL|, |LO | etc. down the right edge stands out immediately.
            let petsciiTargetCol = 72
            let petsciiPad = max(2, petsciiTargetCol - (result.length - lineStart))
            result.append(NSAttributedString(
                string: String(repeating: " ", count: petsciiPad),
                attributes: [.font: font, .foregroundColor: operandColor]))
            result.append(NSAttributedString(
                string: line.petsciiHint,
                attributes: [.font: font, .foregroundColor: hexColor]))

            result.append(NSAttributedString(string: "\n",
                attributes: [.font: font, .foregroundColor: operandColor]))

            // Record the character range for this line
            let lineEnd = result.length
            charIndexToLineIndex.append((range: NSRange(location: lineStart, length: lineEnd - lineStart), lineIndex: lineIndex))
        }

        textView.textStorage?.setAttributedString(result)
        if !preservingPosition {
            textView.scrollToBeginningOfDocument(nil)
            cycleLabel.stringValue = "Select instructions to see cycle count"
        }
    }

    // MARK: - Cycle Count Selection

    @objc private func selectionDidChange(_ notification: Notification) {
        let sel = textView.selectedRange()
        guard sel.length > 0 else {
            cycleLabel.stringValue = "Select instructions to see cycle count"
            return
        }

        let selEnd = sel.location + sel.length

        // charIndexToLineIndex is built in ascending, non-overlapping order, so
        // the intersecting entries form a contiguous run that binary search can
        // find. Scanning the whole table and copying every matching line was
        // O(lines) work on each of the many notifications a drag-select emits.
        var lo = 0, hi = charIndexToLineIndex.count - 1, first = charIndexToLineIndex.count
        while lo <= hi {
            let mid = (lo + hi) / 2
            let entry = charIndexToLineIndex[mid].range
            if entry.location + entry.length > sel.location {
                first = mid
                hi = mid - 1
            } else {
                lo = mid + 1
            }
        }

        var count = 0
        var baseCycles = 0
        var worstCycles = 0
        var index = first
        while index < charIndexToLineIndex.count,
              charIndexToLineIndex[index].range.location < selEnd {
            let lineIndex = charIndexToLineIndex[index].lineIndex
            index += 1
            guard lineIndex < currentLines.count else { continue }
            let line = currentLines[lineIndex]
            guard !line.isData else { continue }
            count += 1
            baseCycles += line.cycles
            worstCycles += line.maxCycles
        }

        guard count > 0 else {
            cycleLabel.stringValue = "Selection contains no executable instructions"
            return
        }

        let timing: C64Timing
        if let wc = (NSApp.delegate as? AppDelegate)?.mainWindowController {
            timing = C64Timing.from(config: wc.buildConfig)
        } else {
            timing = .pal
        }

        let n = count
        let cycleStr: String
        if baseCycles == worstCycles {
            cycleStr = "\(n) instruction\(n == 1 ? "" : "s") · \(baseCycles) cycles · \(timing.rasterLines(for: baseCycles)) raster lines (\(timing.name))"
        } else {
            cycleStr = "\(n) instruction\(n == 1 ? "" : "s") · \(baseCycles)–\(worstCycles) cycles (branches/page cross) · \(timing.rasterLines(for: baseCycles))–\(timing.rasterLines(for: worstCycles)) raster lines (\(timing.name))"
        }
        cycleLabel.stringValue = cycleStr
    }
}

