import Cocoa

/// Provides hover tooltips for C64 BASIC commands and 6502 opcodes.
/// Automatically tracks mouse position within the editor and displays contextual
/// help panels. Dismisses tooltips when focus shifts away from the editor window.
class TooltipProvider {

    private weak var textView: NSTextView?
    private var fileType: C64FileType
    private var tooltipWindow: NSPanel?
    private var tooltipTextField: NSTextField?
    private var lastTooltipWord: String?

    // Stores notification observer tokens for safe cleanup in deinit
    private var observers: [NSObjectProtocol] = []

    /// Initializes the tooltip provider for a given text view and file type.
    /// Registers for window focus-change notifications to manage tooltip lifecycle.
    init(textView: NSTextView, fileType: C64FileType) {
        self.textView = textView
        self.fileType = fileType

        // Hide tooltip when the editor window resigns key/main status
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: textView.window,
            queue: .main
        ) { [weak self] _ in self?.hideTooltip() })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignMainNotification,
            object: textView.window,
            queue: .main
        ) { [weak self] _ in self?.hideTooltip() })

        // Hide tooltip when any other window becomes key (focus shift)
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let newWindow = notification.object as? NSWindow,
               newWindow !== self?.textView?.window {
                self?.hideTooltip()
            }
        })
    }

    deinit {
        // Remove all registered observers to prevent dangling callbacks
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        hideTooltip()
    }

    /// Updates the active file type for syntax-aware tooltip lookups.
    func setFileType(_ type: C64FileType) {
        self.fileType = type
    }

    // MARK: - Mouse Handling

    /// Handles mouse movement events to trigger tooltip display.
    func handleMouseMoved(at point: NSPoint, in textView: NSTextView) {
        // Convert screen point to text view coordinate space
        let textPoint = textView.convert(point, from: nil)
        let charIndex = textView.characterIndexForInsertion(at: textPoint)

        guard charIndex < (textView.string as NSString).length else {
            hideTooltip()
            return
        }

        // Extract the word under the cursor
        let text = textView.string as NSString
        let word = extractWord(from: text, at: charIndex)

        guard !word.isEmpty else {
            hideTooltip()
            return
        }

        // Avoid redundant tooltip creation
        if word == lastTooltipWord { return }
        lastTooltipWord = word

        // Look up and display tooltip
        if let tooltip = lookupTooltip(for: word) {
            showTooltip(tooltip, near: point, in: textView)
        } else {
            hideTooltip()
        }
    }

    /// Dismisses the tooltip when the mouse exits the editor area.
    func handleMouseExited() {
        hideTooltip()
    }

    // MARK: - Word Extraction

    /// Extracts a word-like token from the text at the given character index.
    /// Supports alphanumeric characters plus `$`, `%`, `#`, and `.` as valid word characters.
    private func extractWord(from text: NSString, at index: Int) -> String {
        let length = text.length
        guard index < length else { return "" }

        let ch = text.character(at: index)
        guard let scalar = Unicode.Scalar(ch),
              CharacterSet.alphanumerics.contains(scalar) ||
              ch == 0x24 /* $ */ || ch == 0x25 /* % */ || ch == 0x23 /* # */ || ch == 0x2E /* . */ else {
            return ""
        }

        // Expand left to find word start
        var start = index
        while start > 0 {
            let c = text.character(at: start - 1)
            if let scalar = Unicode.Scalar(c),
               CharacterSet.alphanumerics.contains(scalar) ||
               c == 0x24 || c == 0x25 || c == 0x23 || c == 0x2E {
                start -= 1
            } else {
                break
            }
        }

        // Expand right to find word end
        var end = index + 1
        while end < length {
            let c = text.character(at: end)
            if let scalar = Unicode.Scalar(c),
               CharacterSet.alphanumerics.contains(scalar) ||
               c == 0x24 || c == 0x25 || c == 0x23 {
                end += 1
            } else {
                break
            }
        }

        return text.substring(with: NSRange(location: start, length: end - start))
    }

    // MARK: - Lookup

    /// Looks up a tooltip string for the given word based on the active file type.
    private func lookupTooltip(for word: String) -> String? {
        let upper = word.uppercased()

        if fileType.usesBasicHighlighting {
            if let ref = C64BasicSyntax.lookup(upper) {
                return formatBasicTooltip(ref)
            }
            // Check active dialect plugin for extended keywords
            if let dialectKW = BasicDialectManager.shared.lookupKeyword(upper) {
                return formatDialectTooltip(dialectKW)
            }
        } else if fileType.usesAssemblyHighlighting {
            if let ref = C64AssemblySyntax.lookup(upper) {
                return formatAssemblyTooltip(ref)
            }
        }

        return nil
    }

    private func formatBasicTooltip(_ ref: C64CommandRef) -> String {
        var lines: [String] = []
        lines.append("━━━ \(ref.keyword) ━━━")
        lines.append("[\(ref.category.rawValue)]")
        lines.append("")
        lines.append("Syntax: \(ref.syntax)")
        lines.append("")
        lines.append(ref.description)

        if let example = ref.example {
            lines.append("")
            lines.append("Example:")
            lines.append(example)
        }

        if let notes = ref.notes {
            lines.append("")
            lines.append("Note: \(notes)")
        }

        return lines.joined(separator: "\n")
    }

    private func formatAssemblyTooltip(_ ref: OpcodeRef) -> String {
        var lines: [String] = []
        lines.append("━━━ \(ref.mnemonic) — \(ref.fullName) ━━━")
        lines.append("")
        lines.append(ref.description)
        lines.append("")
        lines.append("Flags affected: \(ref.flags)")
        lines.append("Cycles: \(ref.cycles)")
        lines.append("Addressing: \(ref.addressingModes)")
        return lines.joined(separator: "\n")
    }

    private func formatDialectTooltip(_ kw: BasicDialectKeyword) -> String {
        let manager = BasicDialectManager.shared
        let dialectName = manager.activeDialect?.name ?? "Extension"

        var lines: [String] = []
        lines.append("━━━ \(kw.keyword) [\(dialectName)] ━━━")

        if let syntax = kw.syntax {
            lines.append("")
            lines.append("Syntax: \(syntax)")
        }
        if let desc = kw.description {
            lines.append("")
            lines.append(desc)
        }
        if let params = kw.parameters, !params.isEmpty {
            lines.append("")
            for p in params {
                var paramLine = "  \(p.name)"
                if let type = p.type { paramLine += " (\(type))" }
                if let range = p.range { paramLine += " [\(range)]" }
                if let desc = p.description { paramLine += " — \(desc)" }
                lines.append(paramLine)
            }
        }
        if let example = kw.example {
            lines.append("")
            lines.append("Example: \(example)")
        }
        if let notes = kw.notes {
            lines.append("")
            lines.append("Note: \(notes)")
        }
        if let token = kw.token {
            lines.append("")
            lines.append(String(format: "Token: $%02X (%d)", token, token))
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Tooltip Display

    /// Displays a themed tooltip panel near the given cursor position.
    private func showTooltip(_ text: String, near point: NSPoint, in textView: NSTextView) {
        hideTooltip()

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        panel.appearance = AppTheme.current.nsAppearance

        // Background view with rounded corners and theme-aware material
        let backgroundView = NSVisualEffectView(frame: panel.contentView!.bounds)
        backgroundView.autoresizingMask = [.width, .height]
        backgroundView.material = AppTheme.current.isDark ? .hudWindow : .contentBackground
        backgroundView.state = .active
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 8
        backgroundView.layer?.borderColor = NSColor(white: AppTheme.current.isDark ? 0.3 : 0.65, alpha: 0.8).cgColor
        backgroundView.layer?.borderWidth = 1
        panel.contentView?.addSubview(backgroundView)

        // Text field with automatic line wrapping
        let textField = NSTextField(wrappingLabelWithString: text)
        textField.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textField.textColor = AppTheme.current.defaultText
        textField.isEditable = false
        textField.isBordered = false
        textField.backgroundColor = .clear
        textField.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.addSubview(textField)

        NSLayoutConstraint.activate([
            textField.topAnchor.constraint(equalTo: backgroundView.topAnchor, constant: 10),
            textField.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 12),
            textField.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -12),
            textField.bottomAnchor.constraint(lessThanOrEqualTo: backgroundView.bottomAnchor, constant: -10),
        ])

        // Force layout to calculate intrinsic content size
        backgroundView.layoutSubtreeIfNeeded()
        let textSize = textField.intrinsicContentSize
        let panelWidth = min(max(textSize.width + 24, 300), 500)
        let panelHeight = min(textSize.height + 20, 400)

        // Position panel above cursor
        guard let window = textView.window else { return }
        var screenPoint = window.convertPoint(toScreen: point)
        screenPoint.x += 10
        screenPoint.y -= panelHeight + 5

        panel.setFrame(NSRect(x: screenPoint.x, y: screenPoint.y, width: panelWidth, height: panelHeight), display: true)
        panel.orderFront(nil)

        self.tooltipWindow = panel
        self.tooltipTextField = textField
    }

    /// Dismisses and cleans up the active tooltip panel.
    func hideTooltip() {
        tooltipWindow?.orderOut(nil)
        tooltipWindow = nil
        tooltipTextField = nil
        lastTooltipWord = nil
    }
}

