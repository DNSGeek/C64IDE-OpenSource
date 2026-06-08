import Cocoa

// ═══════════════════════════════════════════════════════════
// MARK: - Number Converter Window Controller
// ═══════════════════════════════════════════════════════════

/// A utility window for converting between DEC, HEX, BIN, and OCT representations
/// of 16-bit values, with a visual bit toggler, quick presets, and bitwise operators.
class NumberConverterWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "Number Converter"
        window.center()
        window.titlebarAppearsTransparent = true
        window.backgroundColor = AppTheme.current.panelBackground
        self.init(window: window)
        window.contentViewController = NumberConverterViewController()
    }

    @objc func closeTab(_ sender: Any?) {
        window?.performClose(sender)
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - Number Converter View Controller
// ═══════════════════════════════════════════════════════════

class NumberConverterViewController: NSViewController {

    private var decField: NSTextField!
    private var hexField: NSTextField!
    private var binField: NSTextField!
    private var octField: NSTextField!

    // Bit display
    private var bitButtons: [NSButton] = []
    private var bitLabels: [NSTextField] = []

    // Operations
    private var opValueField: NSTextField!
    private var resultLabel: NSTextField!

    // Current value
    private var currentValue: UInt16 = 0
    private var sectionLabels: [NSTextField] = []
    private var dimLabels:     [NSTextField] = []
    private var titleLabel:    NSTextField!
    private var inputHints:    [NSTextField] = []

    private var bgColor: NSColor { AppTheme.current.panelBackground }
    private var fieldBg: NSColor { AppTheme.current.panelDetailBackground }

    override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 420))
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
        view.window?.appearance     = AppTheme.current.nsAppearance
        view.layer?.backgroundColor = AppTheme.current.panelBackground.cgColor
        titleLabel?.textColor       = AppTheme.current.syntaxKeyword
        sectionLabels.forEach { $0.textColor = AppTheme.current.syntaxOperator }
        dimLabels.forEach     { $0.textColor = AppTheme.current.statusLabel }
        inputHints.forEach    { $0.textColor = AppTheme.current.statusLabel }
        bitLabels.forEach     { $0.textColor = AppTheme.current.statusLabel }
        resultLabel?.textColor = AppTheme.current.syntaxFunction
        for f in [decField, hexField, binField, octField, opValueField] {
            f?.backgroundColor = AppTheme.current.panelDetailBackground
            f?.textColor       = AppTheme.current.defaultText
        }
        updateAllDisplays()
    }

    private func buildUI() {
        let w = view.bounds.width
        var y = view.bounds.height - 15

        // ── Title ────────────────────────────────────────
        y -= 18
        titleLabel = makeLabel("NUMBER CONVERTER", bold: true, color: AppTheme.current.syntaxKeyword)
        titleLabel.frame = NSRect(x: 12, y: y, width: 200, height: 16)
        view.addSubview(titleLabel)

        // ── Input fields ─────────────────────────────────
        y -= 32
        decField = addFieldRow(y: y, label: "DEC:", tag: 10, placeholder: "0")
        y -= 30
        hexField = addFieldRow(y: y, label: "HEX:", tag: 16, placeholder: "$0000")
        y -= 30
        binField = addFieldRow(y: y, label: "BIN:", tag: 2, placeholder: "0000000000000000")
        y -= 30
        octField = addFieldRow(y: y, label: "OCT:", tag: 8, placeholder: "0")

        // ── Bit display (clickable) ──────────────────────
        y -= 28
        let bitTitle = makeLabel("BITS (click to toggle)", bold: true, color: AppTheme.current.syntaxOperator)
        bitTitle.frame = NSRect(x: 12, y: y, width: 200, height: 16)
        sectionLabels.append(bitTitle)
        view.addSubview(bitTitle)

        y -= 22
        // High byte: bits 15-8
        let highLabel = makeLabel("HI:", bold: false, color: AppTheme.current.statusLabel)
        highLabel.frame = NSRect(x: 12, y: y, width: 24, height: 16)
        dimLabels.append(highLabel)
        view.addSubview(highLabel)

        for i in (8...15).reversed() {
            let idx = 15 - i  // Visual position
            let btn = NSButton(title: "0", target: self, action: #selector(bitToggled(_:)))
            btn.tag = i
            btn.frame = NSRect(x: 40 + CGFloat(idx) * 44, y: y - 2, width: 40, height: 22)
            btn.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
            btn.bezelStyle = .recessed
            view.addSubview(btn)
            bitButtons.append(btn)

            let lbl = makeLabel("\(i)", bold: false, color: AppTheme.current.statusLabel)
            lbl.alignment = .center
            lbl.frame = NSRect(x: 40 + CGFloat(idx) * 44, y: y - 16, width: 40, height: 12)
            lbl.font = NSFont.monospacedSystemFont(ofSize: 8, weight: .regular)
            view.addSubview(lbl)
            bitLabels.append(lbl)
        }

        y -= 42
        // Low byte: bits 7-0
        let loLabel = makeLabel("LO:", bold: false, color: AppTheme.current.statusLabel)
        loLabel.frame = NSRect(x: 12, y: y, width: 24, height: 16)
        dimLabels.append(loLabel)
        view.addSubview(loLabel)

        for i in (0...7).reversed() {
            let idx = 7 - i
            let btn = NSButton(title: "0", target: self, action: #selector(bitToggled(_:)))
            btn.tag = i
            btn.frame = NSRect(x: 40 + CGFloat(idx) * 44, y: y - 2, width: 40, height: 22)
            btn.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
            btn.bezelStyle = .recessed
            view.addSubview(btn)
            bitButtons.append(btn)

            let lbl = makeLabel("\(i)", bold: false, color: AppTheme.current.statusLabel)
            lbl.alignment = .center
            lbl.frame = NSRect(x: 40 + CGFloat(idx) * 44, y: y - 16, width: 40, height: 12)
            lbl.font = NSFont.monospacedSystemFont(ofSize: 8, weight: .regular)
            view.addSubview(lbl)
            bitLabels.append(lbl)
        }

        // ── Quick values ─────────────────────────────────
        y -= 38
        let quickLabel = makeLabel("QUICK:", bold: true, color: AppTheme.current.syntaxOperator)
        quickLabel.frame = NSRect(x: 12, y: y, width: 60, height: 16)
        sectionLabels.append(quickLabel)
        view.addSubview(quickLabel)

        let quickValues: [(String, UInt16)] = [
            ("$00", 0), ("$01", 1), ("$0F", 0x0F), ("$FF", 0xFF), ("$FFFF", 0xFFFF),
        ]
        var qx: CGFloat = 70
        for (title, val) in quickValues {
            let btn = NSButton(title: title, target: self, action: #selector(quickValue(_:)))
            btn.tag = Int(val)
            btn.frame = NSRect(x: qx, y: y - 2, width: 55, height: 22)
            btn.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
            view.addSubview(btn)
            qx += 60
        }

        // ── Bitwise operations ───────────────────────────
        y -= 34
        let opsLabel = makeLabel("OPERATIONS", bold: true, color: AppTheme.current.syntaxOperator)
        opsLabel.frame = NSRect(x: 12, y: y, width: 120, height: 16)
        sectionLabels.append(opsLabel)
        view.addSubview(opsLabel)

        y -= 28
        let valLabel = makeLabel("Value:", bold: false, color: AppTheme.current.statusLabel)
        valLabel.frame = NSRect(x: 12, y: y + 2, width: 50, height: 16)
        dimLabels.append(valLabel)
        view.addSubview(valLabel)

        opValueField = NSTextField(string: "0")
        opValueField.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        opValueField.frame = NSRect(x: 65, y: y, width: 100, height: 22)
        opValueField.backgroundColor = AppTheme.current.panelDetailBackground
        opValueField.textColor = AppTheme.current.defaultText
        opValueField.focusRingType = .none
        view.addSubview(opValueField)

        let hint = makeLabel("(dec, $hex, %bin)", bold: false, color: AppTheme.current.statusLabel)
        hint.frame = NSRect(x: 170, y: y + 2, width: 130, height: 16)
        hint.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        inputHints.append(hint)
        view.addSubview(hint)

        y -= 28
        let ops: [(String, Selector)] = [
            ("AND", #selector(opAND(_:))),
            ("OR",  #selector(opOR(_:))),
            ("XOR", #selector(opXOR(_:))),
            ("NOT", #selector(opNOT(_:))),
            ("SHL", #selector(opSHL(_:))),
            ("SHR", #selector(opSHR(_:))),
        ]
        var ox: CGFloat = 12
        for (title, action) in ops {
            let btn = NSButton(title: title, target: self, action: action)
            btn.frame = NSRect(x: ox, y: y, width: 55, height: 24)
            btn.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
            view.addSubview(btn)
            ox += 60
        }

        // ── Result ───────────────────────────────────────
        y -= 30
        resultLabel = makeLabel("", bold: false, color: AppTheme.current.syntaxFunction)
        resultLabel.frame = NSRect(x: 12, y: y, width: w - 24, height: 16)
        view.addSubview(resultLabel)

        updateAllDisplays()
    }

    // MARK: - Field Creation

    private func addFieldRow(y: CGFloat, label: String, tag: Int, placeholder: String) -> NSTextField {
        let lbl = makeLabel(label, bold: true, color: AppTheme.current.statusLabel)
        lbl.frame = NSRect(x: 12, y: y + 2, width: 38, height: 16)
        dimLabels.append(lbl)
        view.addSubview(lbl)

        let field = NSTextField(string: "0")
        field.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        field.frame = NSRect(x: 55, y: y, width: view.bounds.width - 70, height: 24)
        field.backgroundColor = AppTheme.current.panelDetailBackground
        field.textColor = AppTheme.current.defaultText
        field.placeholderString = placeholder
        field.focusRingType = .none
        field.tag = tag  // Base: 2, 8, 10, 16
        field.target = self
        field.action = #selector(fieldChanged(_:))
        view.addSubview(field)

        return field
    }

    private func makeLabel(_ text: String, bold: Bool, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: bold ? .bold : .regular)
        label.textColor = color
        return label
    }

    // MARK: - Input Parsing

    /// Parses a value from a string, supporting `$hex`, `%bin`, `0x` hex, `0o` octal, and plain decimal.
    private func parseValue(_ str: String) -> UInt16? {
        let trimmed = str.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return 0 }

        if trimmed.hasPrefix("$") || trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") {
            let hex = trimmed.hasPrefix("$") ? String(trimmed.dropFirst()) : String(trimmed.dropFirst(2))
            return UInt16(hex, radix: 16)
        }
        if trimmed.hasPrefix("%") || trimmed.hasPrefix("0b") || trimmed.hasPrefix("0B") {
            let bin = trimmed.hasPrefix("%") ? String(trimmed.dropFirst()) : String(trimmed.dropFirst(2))
            return UInt16(bin, radix: 2)
        }
        if trimmed.hasPrefix("0o") {
            return UInt16(String(trimmed.dropFirst(2)), radix: 8)
        }
        return UInt16(trimmed)
    }

    // MARK: - Display Update

    private func updateAllDisplays() {
        let v = currentValue

        // Update text fields (without triggering actions)
        decField.stringValue = "\(v)"
        hexField.stringValue = String(format: "$%04X", v)

        let binStr = String(v, radix: 2)
        let padded = String(repeating: "0", count: 16 - binStr.count) + binStr
        binField.stringValue = padded

        octField.stringValue = String(v, radix: 8)

        // Update bit buttons
        for btn in bitButtons {
            let bit = btn.tag
            let isSet = (v >> bit) & 1 == 1
            btn.title = isSet ? "1" : "0"
            btn.contentTintColor = isSet ? AppTheme.current.syntaxKeyword : AppTheme.current.statusLabel
        }

        // Signed/Unsigned interpretation
        let signed: Int16 = Int16(bitPattern: v)
        resultLabel.stringValue = "Signed: \(signed) | Unsigned: \(v) | Lo: \(v & 0xFF) Hi: \(v >> 8)"
    }

    // MARK: - Actions

    @objc private func fieldChanged(_ sender: NSTextField) {
        let text = sender.stringValue.trimmingCharacters(in: .whitespaces)

        switch sender.tag {
        case 10: // Decimal
            if let v = UInt16(text) { currentValue = v }
        case 16: // Hex
            let hex = text.hasPrefix("$") ? String(text.dropFirst()) : text
            if let v = UInt16(hex, radix: 16) { currentValue = v }
        case 2:  // Binary
            let bin = text.replacingOccurrences(of: " ", with: "")
            if let v = UInt16(bin, radix: 2) { currentValue = v }
        case 8:  // Octal
            if let v = UInt16(text, radix: 8) { currentValue = v }
        default: break
        }

        updateAllDisplays()
    }

    @objc private func bitToggled(_ sender: NSButton) {
        let bit = sender.tag
        currentValue ^= (1 << bit)
        updateAllDisplays()
    }

    @objc private func quickValue(_ sender: NSButton) {
        currentValue = UInt16(sender.tag & 0xFFFF)
        updateAllDisplays()
    }

    private func getOperand() -> UInt16 {
        return parseValue(opValueField.stringValue) ?? 0
    }

    @objc private func opAND(_ sender: Any?) {
        let operand = getOperand()
        currentValue &= operand
        resultLabel.stringValue = "AND $\(String(format: "%04X", operand)) → $\(String(format: "%04X", currentValue))"
        updateAllDisplays()
    }

    @objc private func opOR(_ sender: Any?) {
        let operand = getOperand()
        currentValue |= operand
        resultLabel.stringValue = "OR $\(String(format: "%04X", operand)) → $\(String(format: "%04X", currentValue))"
        updateAllDisplays()
    }

    @objc private func opXOR(_ sender: Any?) {
        let operand = getOperand()
        currentValue ^= operand
        resultLabel.stringValue = "XOR $\(String(format: "%04X", operand)) → $\(String(format: "%04X", currentValue))"
        updateAllDisplays()
    }

    @objc private func opNOT(_ sender: Any?) {
        currentValue = ~currentValue
        resultLabel.stringValue = "NOT → $\(String(format: "%04X", currentValue))"
        updateAllDisplays()
    }

    @objc private func opSHL(_ sender: Any?) {
        let amount = getOperand()
        currentValue <<= (amount & 0xF)
        resultLabel.stringValue = "SHL \(amount) → $\(String(format: "%04X", currentValue))"
        updateAllDisplays()
    }

    @objc private func opSHR(_ sender: Any?) {
        let amount = getOperand()
        currentValue >>= (amount & 0xF)
        resultLabel.stringValue = "SHR \(amount) → $\(String(format: "%04X", currentValue))"
        updateAllDisplays()
    }
}

