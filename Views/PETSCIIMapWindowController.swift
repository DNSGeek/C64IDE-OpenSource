import Cocoa

// ═══════════════════════════════════════════════════════════
// MARK: - PETSCII Map Window Controller
// ═══════════════════════════════════════════════════════════

/// A utility window that displays a 16x16 grid of C64 PETSCII characters.
/// Provides visual representations, decimal/hex/binary codes, screen code mappings,
/// and quick-copy buttons for common BASIC/assembly syntax patterns.
class PETSCIIMapWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 780),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "PETSCII Character Map"
        window.center()
        window.titlebarAppearsTransparent = true
        window.backgroundColor = AppTheme.current.panelBackground
        self.init(window: window)
        window.contentViewController = PETSCIIMapViewController()
    }

    @objc func closeTab(_ sender: Any?) {
        window?.performClose(sender)
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - PETSCII Map View Controller
// ═══════════════════════════════════════════════════════════

class PETSCIIMapViewController: NSViewController {

    private var gridView: PETSCIIGridView!
    private var infoLabel: NSTextField!
    private var decLabel: NSTextField!
    private var hexLabel: NSTextField!
    private var charPreview: NSTextField!
    private var copyDecBtn: NSButton!
    private var copyHexBtn: NSButton!
    private var copyCharBtn: NSButton!
    private var copyChrBtn: NSButton!
    private var copyPokeBtn: NSButton!

    private var selectedCode: Int = 65  // Default to 'A'
    private var headerLabels: [NSTextField] = []
    private var titleLabel:   NSTextField!
    private var scrCodeLabel: NSTextField!

    private var bgColor: NSColor { AppTheme.current.panelBackground }

    override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 780))
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
        view.window?.backgroundColor = AppTheme.current.panelBackground
        view.layer?.backgroundColor = AppTheme.current.panelBackground.cgColor
        titleLabel?.textColor       = AppTheme.current.syntaxKeyword
        headerLabels.forEach { $0.textColor = AppTheme.current.syntaxOperator }
        decLabel?.textColor         = AppTheme.current.defaultText
        hexLabel?.textColor         = AppTheme.current.defaultText
        infoLabel?.textColor        = AppTheme.current.statusLabel
        scrCodeLabel?.textColor     = AppTheme.current.syntaxKeyword
        charPreview?.textColor      = AppTheme.current.syntaxKeyword
        charPreview?.backgroundColor = AppTheme.current.panelDetailBackground
        if let box = view.subviews.compactMap({ $0 as? NSBox }).first {
            box.fillColor   = AppTheme.current.panelDetailBackground
            box.borderColor = NSColor(white: AppTheme.current.isDark ? 0.2 : 0.65, alpha: 1)
        }
        gridView?.needsDisplay = true
    }

    private func buildUI() {
        let w = view.bounds.width
        var y = view.bounds.height - 15

        // ── Title ────────────────────────────────────────
        y -= 18
        titleLabel = makeLabel("PETSCII CHARACTER MAP", bold: true, color: AppTheme.current.syntaxKeyword)
        titleLabel.frame = NSRect(x: 12, y: y, width: 250, height: 16)
        view.addSubview(titleLabel)

        // ── Column headers (0-F) ─────────────────────────
        y -= 22
        let headerX: CGFloat = 40
        for col in 0..<16 {
            let lbl = makeLabel(String(format: "%X", col), bold: true, color: AppTheme.current.syntaxOperator)
            lbl.alignment = .center
            lbl.frame = NSRect(x: headerX + CGFloat(col) * 33, y: y, width: 30, height: 14)
            lbl.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
            view.addSubview(lbl)
            headerLabels.append(lbl)
        }

        // ── Grid ─────────────────────────────────────────
        y -= 4
        gridView = PETSCIIGridView()
        // Grid positioned below headers; height accounts for 16 rows at 33px each
        gridView.frame = NSRect(x: 12, y: y - 16 * 33 - 2, width: w - 24, height: 16 * 33 + 2)
        gridView.onCharSelected = { [weak self] code in
            self?.selectedCode = code
            self?.updateInfo()
        }
        view.addSubview(gridView)

        // Row headers (0-F_)
        for row in 0..<16 {
            let lbl = makeLabel(String(format: "%X_", row), bold: true, color: AppTheme.current.syntaxOperator)
            // In flipped coordinates, Y increases downward. Offset accounts for grid top margin.
            lbl.frame = NSRect(x: 14, y: gridView.frame.origin.y + CGFloat(15 - row) * 33 + 8, width: 24, height: 14)
            lbl.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
            view.addSubview(lbl)
        }

        y = gridView.frame.origin.y - 10

        // ── Info panel ───────────────────────────────────
        y -= 10
        let infoBox = NSBox(frame: NSRect(x: 12, y: y - 110, width: w - 24, height: 120))
        infoBox.boxType = .custom
        infoBox.fillColor   = AppTheme.current.panelDetailBackground
        infoBox.borderColor = NSColor(white: AppTheme.current.isDark ? 0.2 : 0.65, alpha: 1)
        infoBox.cornerRadius = 6
        infoBox.borderWidth = 1
        infoBox.titlePosition = .noTitle
        view.addSubview(infoBox)

        // Large character preview
        charPreview = NSTextField(labelWithString: "A")
        charPreview.font = NSFont(name: "Menlo", size: 44) ?? NSFont.monospacedSystemFont(ofSize: 44, weight: .bold)
        charPreview.textColor = AppTheme.current.syntaxKeyword
        charPreview.alignment = .center
        charPreview.frame = NSRect(x: 18, y: y - 92, width: 70, height: 65)
        charPreview.drawsBackground = true
        charPreview.backgroundColor = AppTheme.current.panelDetailBackground
        charPreview.isBordered = true
        view.addSubview(charPreview)

        // Code info
        decLabel = makeLabel("DEC: 65", bold: true, color: AppTheme.current.defaultText)
        decLabel.frame = NSRect(x: 95, y: y - 20, width: 120, height: 16)
        view.addSubview(decLabel)

        hexLabel = makeLabel("HEX: $41    BIN: %01000001", bold: true, color: AppTheme.current.defaultText)
        hexLabel.frame = NSRect(x: 95, y: y - 40, width: 280, height: 16)
        view.addSubview(hexLabel)

        scrCodeLabel = makeLabel("Screen code: 1", bold: false, color: AppTheme.current.syntaxKeyword)
        scrCodeLabel.frame = NSRect(x: 95, y: y - 60, width: 200, height: 16)
        view.addSubview(scrCodeLabel)

        infoLabel = makeLabel("Letter A", bold: false, color: AppTheme.current.statusLabel)
        infoLabel.frame = NSRect(x: 95, y: y - 80, width: 280, height: 16)
        view.addSubview(infoLabel)

        // Copy buttons
        let copyBtns: [(String, Selector, String)] = [
            ("Dec", #selector(copyDec(_:)), "Copy decimal value"),
            ("Hex", #selector(copyHex(_:)), "Copy hex value"),
            ("CHR$", #selector(copyCHR(_:)), "Copy CHR$(n)"),
            ("POKE", #selector(copyPOKE(_:)), "Copy POKE statement"),
            (".byte", #selector(copyByte(_:)), "Copy .byte $XX"),
        ]
        var bx: CGFloat = 310
        for (title, action, tooltip) in copyBtns {
            let btn = NSButton(title: title, target: self, action: action)
            btn.frame = NSRect(x: bx, y: y - 65, width: 50, height: 24)
            btn.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
            btn.toolTip = tooltip
            view.addSubview(btn)
            bx += 54
        }

        updateInfo()
    }

    private func makeLabel(_ text: String, bold: Bool, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: bold ? .bold : .regular)
        label.textColor = color
        return label
    }

    // MARK: - Info Update

    private func updateInfo() {
        let code = selectedCode
        decLabel.stringValue = "DEC: \(code)"
        hexLabel.stringValue = String(format: "HEX: $%02X    BIN: %%%@", code, String(code, radix: 2).leftPadded(toLength: 8, with: "0"))

        // Screen code (PETSCII → C64 screen code conversion)
        if let sc = petsciiToScreenCode(code) {
            scrCodeLabel.stringValue = String(format: "Screen code: %d ($%02X)", sc, sc)
        } else {
            scrCodeLabel.stringValue = "Screen code: N/A (control char)"
        }

        // Character preview and description
        let (charStr, desc) = petsciiDescription(code)
        // Fallback to hex representation for non-printable or wide Unicode approximations
        if charStr.isEmpty || charStr.count > 3 {
            charPreview.stringValue = String(format: "%02X", code)
            charPreview.font = NSFont(name: "Menlo", size: 30) ?? NSFont.monospacedSystemFont(ofSize: 30, weight: .bold)
        } else {
            charPreview.stringValue = charStr
            charPreview.font = NSFont(name: "Menlo", size: 44) ?? NSFont.monospacedSystemFont(ofSize: 44, weight: .bold)
        }
        infoLabel.stringValue = desc

        gridView.selectedCode = code
        gridView.needsDisplay = true
    }

    /// Converts a PETSCII code to its corresponding C64 screen code.
    /// Returns `nil` for control codes that don't map to screen characters.
    private func petsciiToScreenCode(_ petscii: Int) -> Int? {
        switch petscii {
        case 0...31:    return nil  // Control codes
        case 32...63:   return petscii - 32
        case 64...95:   return petscii
        case 96...127:  return petscii - 32
        case 128...159: return nil  // Control codes
        case 160...191: return petscii - 64
        case 192...223: return petscii - 128
        case 224...254: return petscii - 128
        case 255:       return 94  // Pi
        default:        return nil
        }
    }

    // MARK: - Actions

    @objc private func copyDec(_ sender: Any?) {
        copyToClipboard("\(selectedCode)")
    }

    @objc private func copyHex(_ sender: Any?) {
        copyToClipboard(String(format: "$%02X", selectedCode))
    }

    @objc private func copyCHR(_ sender: Any?) {
        copyToClipboard("CHR$(\(selectedCode))")
    }

    @objc private func copyPOKE(_ sender: Any?) {
        copyToClipboard("POKE 1024,\(selectedCode)")
    }

    @objc private func copyByte(_ sender: Any?) {
        copyToClipboard(String(format: ".byte $%02X", selectedCode))
    }

    private func copyToClipboard(_ str: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(str, forType: .string)
        infoLabel.stringValue = "Copied: \(str)"
    }

    // MARK: - PETSCII Descriptions

    /// Returns a tuple of (display approximation, human-readable description) for a PETSCII code.
    private func petsciiDescription(_ code: Int) -> (String, String) {
        switch code {
        case 0:     return ("NUL", "NULL")
        case 1...4: return ("", "Control code \(code)")
        case 5:     return ("", "White (color)")
        case 6...7: return ("", "Control code \(code)")
        case 8:     return ("", "Disable SHIFT+C= switching")
        case 9:     return ("", "Enable SHIFT+C= switching")
        case 10:    return ("", "Line Feed")
        case 13:    return ("⏎", "Return / Enter")
        case 14:    return ("", "Switch to lowercase mode")
        case 17:    return ("↓", "Cursor Down")
        case 18:    return ("RVS", "Reverse On")
        case 19:    return ("⌂", "Home (cursor to top-left)")
        case 20:    return ("⌫", "Delete / Backspace")
        case 28:    return ("", "Red (color)")
        case 29:    return ("→", "Cursor Right")
        case 30:    return ("", "Green (color)")
        case 31:    return ("", "Blue (color)")
        case 32:    return ("␣", "Space")
        case 33...90:
            let ch = String(UnicodeScalar(code)!)
            return (ch, "'\(ch)' — screen code \(code - 32)")
        case 91:    return ("[", "Left bracket")
        case 92:    return ("£", "Pound sign")
        case 93:    return ("]", "Right bracket")
        case 94:    return ("↑", "Up arrow")
        case 95:    return ("←", "Left arrow / Back-arrow")
        case 96:    return ("━", "Horizontal line")
        case 97:    return ("♠", "Spade suit")
        case 98:    return ("│", "Vertical line")
        case 99:    return ("━", "Horizontal line (lower)")
        case 100:   return ("▒", "Checkerboard fill")
        case 101:   return ("▒", "Checkerboard alt")
        case 102:   return ("▕", "Right 1/4 block")
        case 103:   return ("▕", "Right 1/4 block alt")
        case 104:   return ("▗", "Lower right quadrant")
        case 105:   return ("╮", "Round corner upper-right")
        case 106:   return ("╰", "Round corner lower-left")
        case 107:   return ("╭", "Round corner upper-left")
        case 108:   return ("▁", "Lower 1/8 block")
        case 109:   return ("╯", "Round corner lower-right")
        case 110:   return ("╳", "Diagonal cross")
        case 111:   return ("╲", "Back diagonal")
        case 112:   return ("╱", "Forward diagonal")
        case 113:   return ("●", "Filled circle / Ball")
        case 114:   return ("▒", "Hatched fill")
        case 115:   return ("♥", "Heart suit")
        case 116:   return ("▎", "Left 1/4 block")
        case 117:   return ("╰", "Round corner variant")
        case 118:   return ("╳", "Cross / X variant")
        case 119:   return ("○", "Circle outline")
        case 120:   return ("♣", "Club suit")
        case 121:   return ("▏", "Left 1/8 block")
        case 122:   return ("♦", "Diamond suit")
        case 123:   return ("┼", "Cross lines")
        case 124:   return ("▏", "Left bar thin")
        case 125:   return ("│", "Vertical bar")
        case 126:   return ("π", "Pi symbol")
        case 127:   return ("◥", "Upper right triangle")
        case 129:   return ("", "Orange (color)")
        case 133:   return ("F1", "Function key F1")
        case 134:   return ("F3", "Function key F3")
        case 135:   return ("F5", "Function key F5")
        case 136:   return ("F7", "Function key F7")
        case 137:   return ("F2", "Function key F2")
        case 138:   return ("F4", "Function key F4")
        case 139:   return ("F6", "Function key F6")
        case 140:   return ("F8", "Function key F8")
        case 141:   return ("⏎", "Shift+Return")
        case 142:   return ("", "Switch to uppercase mode")
        case 144:   return ("", "Black (color)")
        case 145:   return ("↑", "Cursor Up")
        case 146:   return ("", "Reverse Off")
        case 147:   return ("CLR", "Clear Screen")
        case 148:   return ("INS", "Insert")
        case 149:   return ("", "Brown (color)")
        case 150:   return ("", "Light Red / Pink (color)")
        case 151:   return ("", "Dark Gray (color)")
        case 152:   return ("", "Medium Gray (color)")
        case 153:   return ("", "Light Green (color)")
        case 154:   return ("", "Light Blue (color)")
        case 155:   return ("", "Light Gray (color)")
        case 156:   return ("", "Purple (color)")
        case 157:   return ("←", "Cursor Left")
        case 158:   return ("", "Yellow (color)")
        case 159:   return ("", "Cyan (color)")
        case 160:   return ("␣", "Shift+Space (non-breaking)")
        case 161:   return ("▌", "Left half block")
        case 162:   return ("▄", "Lower half block")
        case 163:   return ("▔", "Upper 1/8 block")
        case 164:   return ("▁", "Lower 1/8 block")
        case 165:   return ("▎", "Left 1/4 block")
        case 166:   return ("▒", "Checker pattern")
        case 167:   return ("▕", "Right 1/8 block")
        case 168:   return ("▗", "Lower right quadrant")
        case 169:   return ("▝", "Upper right quadrant")
        case 170:   return ("▘", "Upper left quadrant")
        case 171:   return ("╮", "Round corner")
        case 172:   return ("▂", "Lower 1/4 block")
        case 173:   return ("▖", "Lower left quadrant")
        case 174:   return ("▚", "Diagonal halves")
        case 175:   return ("▐", "Right half block")
        case 176...191:
            return (petsciiGridToUnicode(code), "Shifted graphics char \(code)")
        case 192...223:
            return (petsciiGridToUnicode(code), "Graphics char \(code) (repeat of \(code - 96))")
        case 224...254:
            return (petsciiGridToUnicode(code), "Shifted graphics char \(code) (repeat of \(code - 64))")
        case 255:   return ("π", "Pi")
        default:
            if code < 32 { return ("", "Control code \(code)") }
            return ("?", "Code \(code)")
        }
    }

    private func petsciiGridToUnicode(_ code: Int) -> String {
        // Map to closest Unicode block elements for visual approximation
        let gridChars: [Int: String] = [
            176: "▌", 177: "▄", 178: "▔", 179: "▁", 180: "▎", 181: "▒",
            182: "▕", 183: "▝", 184: "▗", 185: "▘", 186: "▖", 187: "╰",
            188: "▀", 189: "▛", 190: "▜", 191: "▐",
        ]
        if let ch = gridChars[code] { return ch }
        if code >= 192 && code <= 223 { return petsciiGridToUnicode(code - 96) }
        if code >= 224 && code <= 254 { return petsciiGridToUnicode(code - 64) }
        return "▒"
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - PETSCII Grid View
// ═══════════════════════════════════════════════════════════

/// Renders a 16x16 grid of PETSCII characters using Unicode block elements.
/// Uses flipped coordinates (Y increases downward) to align with NSTextView conventions.
final class PETSCIIGridView: NSView {

    var selectedCode: Int = 65
    var onCharSelected: ((Int) -> Void)?

    private let cellSize: CGFloat = 33
    private let gridOffset: CGFloat = 28  // Accounts for row header width

    // Theme colors
    private var bgColor:      NSColor { AppTheme.current.panelDetailBackground }
    private var gridColor:    NSColor { NSColor(white: AppTheme.current.isDark ? 0.15 : 0.70, alpha: 1) }
    private var textColor:    NSColor { AppTheme.current.syntaxKeyword }
    private var selectedBg:   NSColor { AppTheme.current.selectionBackground }
    private var controlColor: NSColor { AppTheme.current.statusLabel }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        bgColor.setFill()
        bounds.fill()

        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let smallFont = NSFont.monospacedSystemFont(ofSize: 8, weight: .regular)

        for row in 0..<16 {
            for col in 0..<16 {
                let code = row * 16 + col
                let x = gridOffset + CGFloat(col) * cellSize
                let y = CGFloat(row) * cellSize
                let rect = NSRect(x: x, y: y, width: cellSize - 1, height: cellSize - 1)

                // Background fill
                if code == selectedCode {
                    selectedBg.setFill()
                    rect.fill()
                } else if code < 32 || (code >= 128 && code < 160) {
                    // Control characters get a subtle background
                    AppTheme.current.panelBackground.setFill()
                    rect.fill()
                }

                // Character display
                let displayChar = petsciiToUnicode(code)
                let color = (code < 32 || (code >= 128 && code < 160)) ? controlColor : textColor

                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                let size = displayChar.size(withAttributes: attrs)
                let cx = x + (cellSize - 1 - size.width) / 2
                let cy = y + 2
                displayChar.draw(at: NSPoint(x: cx, y: cy), withAttributes: attrs)

                // Hex and decimal code in corners
                let hexStr = String(format: "%02X", code)
                hexStr.draw(at: NSPoint(x: x + 1, y: y + cellSize - 12),
                           withAttributes: [.font: smallFont, .foregroundColor: NSColor(white: AppTheme.current.isDark ? 0.30 : 0.55, alpha: 1)])
                let decStr = "\(code)"
                let decAttrs: [NSAttributedString.Key: Any] = [.font: smallFont, .foregroundColor: NSColor(white: AppTheme.current.isDark ? 0.25 : 0.50, alpha: 1)]
                let decSize = decStr.size(withAttributes: decAttrs)
                decStr.draw(at: NSPoint(x: x + cellSize - 2 - decSize.width, y: y + cellSize - 12),
                           withAttributes: decAttrs)
            }
        }

        // Grid lines
        gridColor.setStroke()
        for i in 0...16 {
            let x = gridOffset + CGFloat(i) * cellSize
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x, y: 0))
            path.line(to: NSPoint(x: x, y: 16 * cellSize))
            path.stroke()

            let y = CGFloat(i) * cellSize
            let hPath = NSBezierPath()
            hPath.move(to: NSPoint(x: gridOffset, y: y))
            hPath.line(to: NSPoint(x: gridOffset + 16 * cellSize, y: y))
            hPath.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let col = Int((pt.x - gridOffset) / cellSize)
        let row = Int(pt.y / cellSize)

        guard col >= 0, col < 16, row >= 0, row < 16 else { return }
        let code = row * 16 + col
        selectedCode = code
        needsDisplay = true
        onCharSelected?(code)
    }

    /// Converts a PETSCII code to a displayable Unicode character.
    /// Graphics characters use the closest Unicode block element equivalents.
    /// Note: Exact C64 PETSCII rendering requires a custom font; this is a visual approximation.
    private func petsciiToUnicode(_ code: Int) -> String {
        switch code {
        // Control codes 0-31
        case 0:     return "NUL"
        case 1...4:  return String(format: "%02X", code)
        case 5:     return "wh"
        case 6...7:  return String(format: "%02X", code)
        case 8:     return "d/s"
        case 9:     return "e/s"
        case 10:    return "LF"
        case 11...12: return String(format: "%02X", code)
        case 13:    return "CR"
        case 14:    return "lc"
        case 15...16: return String(format: "%02X", code)
        case 17:    return "↓"
        case 18:    return "RV"
        case 19:    return "HM"
        case 20:    return "DL"
        case 21...27: return String(format: "%02X", code)
        case 28:    return "rd"
        case 29:    return "→"
        case 30:    return "gn"
        case 31:    return "bl"

        // Printable ASCII range 32-95
        case 32:    return " "
        case 33...90: return String(UnicodeScalar(code)!)
        case 91:    return "["
        case 92:    return "£"
        case 93:    return "]"
        case 94:    return "↑"
        case 95:    return "←"

        // Graphics characters 96-127 (C64 PETSCII graphics set)
        case 96:    return "━"
        case 97:    return "♠"
        case 98:    return "│"
        case 99:    return "━"
        case 100:   return "▒"
        case 101:   return "▒"
        case 102:   return "▕"
        case 103:   return "▕"
        case 104:   return "▗"
        case 105:   return "╮"
        case 106:   return "╰"
        case 107:   return "╭"
        case 108:   return "▁"
        case 109:   return "╯"
        case 110:   return "╳"
        case 111:   return "╲"
        case 112:   return "╱"
        case 113:   return "●"
        case 114:   return "▒"
        case 115:   return "♥"
        case 116:   return "▎"
        case 117:   return "╰"
        case 118:   return "╳"
        case 119:   return "○"
        case 120:   return "♣"
        case 121:   return "▏"
        case 122:   return "♦"
        case 123:   return "┼"
        case 124:   return "▏"
        case 125:   return "│"
        case 126:   return "π"
        case 127:   return "◥"

        // Control codes 128-159
        case 128:   return String(format: "%02X", code)
        case 129:   return "or"
        case 130...132: return String(format: "%02X", code)
        case 133:   return "F1"
        case 134:   return "F3"
        case 135:   return "F5"
        case 136:   return "F7"
        case 137:   return "F2"
        case 138:   return "F4"
        case 139:   return "F6"
        case 140:   return "F8"
        case 141:   return "⏎"
        case 142:   return "UC"
        case 143:   return String(format: "%02X", code)
        case 144:   return "bk"
        case 145:   return "↑"
        case 146:   return "rv"
        case 147:   return "CL"
        case 148:   return "IN"
        case 149:   return "bn"
        case 150:   return "lr"
        case 151:   return "g1"
        case 152:   return "g2"
        case 153:   return "lg"
        case 154:   return "lb"
        case 155:   return "g3"
        case 156:   return "pu"
        case 157:   return "←"
        case 158:   return "yl"
        case 159:   return "cy"

        // Shifted graphics 160-191
        case 160:   return "S␣"
        case 161:   return "▌"
        case 162:   return "▄"
        case 163:   return "▔"
        case 164:   return "▁"
        case 165:   return "▎"
        case 166:   return "▒"
        case 167:   return "▕"
        case 168:   return "▗"
        case 169:   return "▝"
        case 170:   return "▘"
        case 171:   return "╮"
        case 172:   return "▂"
        case 173:   return "▖"
        case 174:   return "▚"
        case 175:   return "▐"
        case 176:   return "▌"
        case 177:   return "▄"
        case 178:   return "▔"
        case 179:   return "▁"
        case 180:   return "▎"
        case 181:   return "▒"
        case 182:   return "▕"
        case 183:   return "▝"
        case 184:   return "▗"
        case 185:   return "▘"
        case 186:   return "▖"
        case 187:   return "╰"
        case 188:   return "▀"
        case 189:   return "▛"
        case 190:   return "▜"
        case 191:   return "▐"

        // Codes 192-223 repeat 96-127
        case 192...223:
            return petsciiToUnicode(code - 96)

        // Codes 224-254 repeat 160-190
        case 224...254:
            return petsciiToUnicode(code - 64)

        case 255:   return "π"
        default:    return "·"
        }
    }
}

// MARK: - String Padding Helper

private extension String {
    /// Left-pads the string to the specified length with a given character.
    func leftPadded(toLength length: Int, with pad: Character) -> String {
        if self.count >= length { return self }
        return String(repeating: pad, count: length - self.count) + self
    }
}

