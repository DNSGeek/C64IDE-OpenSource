import Cocoa

/// A custom NSView that renders line numbers, breakpoint indicators, and debug execution markers.
class LineNumberGutter: NSView {

    /// Standard width for the gutter strip.
    static let gutterWidth: CGFloat = 44

    private weak var textView: NSTextView?

    /// Maps 1-indexed line numbers to their Y positions and heights.
    /// Updated during `draw(_:)` and used for breakpoint hit-testing.
    private var lineYPositions: [(lineNum: Int, y: CGFloat, height: CGFloat)] = []

    // MARK: - Theming

    private var lineNumberFont: NSFont { EditorFontManager.shared.gutterFont }
    private var lineNumberColor: NSColor { AppTheme.current.gutterLineNumber }
    private var currentLineColor: NSColor { AppTheme.current.gutterCurrentLine }
    private var gutterBg: NSColor { AppTheme.current.gutterBackground }
    private var gutterBorder: NSColor { AppTheme.current.gutterBorder }
    private let breakpointColor = NSColor(red: 0.90, green: 0.15, blue: 0.15, alpha: 1.0)

    /// The currently selected/active line number (1-indexed).
    var currentLineNumber: Int = 1

    /// Set of 1-indexed line numbers that have breakpoints.
    var breakpointLines: Set<Int> = []

    /// 1-indexed line number representing the current debug execution point.
    /// Drawing a yellow arrow and highlighting the line background.
    var debugExecutionLine: Int? {
        didSet { needsDisplay = true }
    }

    /// Called when a breakpoint is toggled.
    var onBreakpointToggled: ((Int, Bool) -> Void)?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("Nib loading not supported") }

    // macOS uses Y-down coordinates for NSView; flipping ensures line positions match text layout
    override var isFlipped: Bool { true }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        gutterBg.setFill()
        bounds.fill()

        // Draw right border
        let borderPath = NSBezierPath()
        borderPath.move(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.minY))
        borderPath.line(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
        gutterBorder.setStroke()
        borderPath.stroke()

        guard let tv = textView, let lm = tv.layoutManager else { return }
        let text = tv.string
        guard !text.isEmpty, lm.numberOfGlyphs > 0 else {
            drawLineEntry(1, at: tv.textContainerInset.height, height: 16, current: true)
            return
        }

        guard let sv = tv.enclosingScrollView else { return }
        let visibleRect = sv.contentView.bounds
        let insetY = tv.textContainerInset.height
        let nsText = text as NSString
        let textLength = nsText.length

        lineYPositions.removeAll()

        var charIndex = 0
        var lineNum = 1

        while charIndex <= textLength {
            if charIndex == textLength {
                // Handle final line without trailing newline
                if charIndex > 0 && nsText.character(at: charIndex - 1) == 0x0A {
                    let extra = lm.extraLineFragmentRect
                    if !extra.isEmpty {
                        let y = extra.origin.y + insetY - visibleRect.origin.y
                        if y >= -20 && y < bounds.height + 20 {
                            drawLineEntry(lineNum, at: y, height: extra.height, current: lineNum == currentLineNumber)
                        }
                    }
                }
                break
            }

            let gi = lm.glyphIndexForCharacter(at: charIndex)
            guard gi < lm.numberOfGlyphs else { break }

            let fragRect = lm.lineFragmentRect(forGlyphAt: gi, effectiveRange: nil)
            let y = fragRect.origin.y + insetY - visibleRect.origin.y

            if y >= -20 && y < bounds.height + 20 {
                drawLineEntry(lineNum, at: y, height: fragRect.height, current: lineNum == currentLineNumber)
                lineYPositions.append((lineNum, y, fragRect.height))
            }
            // Stop drawing when lines exit the visible viewport
            if y > bounds.height + 40 { break }

            let lineRange = nsText.lineRange(for: NSRange(location: charIndex, length: 0))
            let nextStart = NSMaxRange(lineRange)
            if nextStart <= charIndex { break }
            charIndex = nextStart
            lineNum += 1
        }
    }

    /// Draws a single line number entry, including breakpoint and debug markers.
    private func drawLineEntry(_ num: Int, at y: CGFloat, height: CGFloat, current: Bool) {
        let centerY = y + (height - lineNumberFont.pointSize) / 2

        // Draw debug execution arrow and background highlight
        if debugExecutionLine == num {
            let arrowColor = AppTheme.current.isDark
                ? NSColor(red: 1.0, green: 0.85, blue: 0.0, alpha: 1.0)
                : NSColor(red: 0.70, green: 0.50, blue: 0.0, alpha: 1.0)
            arrowColor.setFill()
            
            let arrowPath = NSBezierPath()
            let arrowMidY = y + height / 2
            arrowPath.move(to: NSPoint(x: 2, y: arrowMidY - 4))
            arrowPath.line(to: NSPoint(x: 10, y: arrowMidY))
            arrowPath.line(to: NSPoint(x: 2, y: arrowMidY + 4))
            arrowPath.close()
            arrowPath.fill()

            // Highlight the editor background for this line
            let bgColor = AppTheme.current.isDark
                ? NSColor(red: 0.25, green: 0.22, blue: 0.08, alpha: 1.0)
                : NSColor(red: 0.98, green: 0.92, blue: 0.70, alpha: 1.0)
            bgColor.setFill()
            // Note: Drawing to superview bounds may clip if the editor is resized. 
            // For production, consider clipping to the editor's visible rect.
            NSRect(x: Self.gutterWidth, y: y, width: superview?.bounds.width ?? 800, height: height).fill()
        }

        // Draw breakpoint dot
        if breakpointLines.contains(num) {
            let dotSize: CGFloat = 10
            let dotX: CGFloat = 3
            let dotY = y + (height - dotSize) / 2
            breakpointColor.setFill()
            let dot = NSBezierPath(ovalIn: NSRect(x: dotX, y: dotY, width: dotSize, height: dotSize))
            dot.fill()
        }

        // Draw line number
        let attrs: [NSAttributedString.Key: Any] = [
            .font: lineNumberFont,
            .foregroundColor: current ? currentLineColor : lineNumberColor,
        ]
        let s = "\(num)" as NSString
        let sz = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: Self.gutterWidth - sz.width - 8, y: centerY), withAttributes: attrs)
    }

    // MARK: - Mouse Interaction

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)

        // Only respond to clicks in the left portion (breakpoint area)
        guard pt.x < Self.gutterWidth else { return }

        // Find which line was clicked using precomputed positions from draw
        for entry in lineYPositions {
            if pt.y >= entry.y && pt.y < entry.y + entry.height {
                let line = entry.lineNum
                if breakpointLines.contains(line) {
                    breakpointLines.remove(line)
                    onBreakpointToggled?(line, false)
                } else {
                    breakpointLines.insert(line)
                    onBreakpointToggled?(line, true)
                }
                needsDisplay = true
                return
            }
        }
    }

    // MARK: - Current Line Tracking

    /// Updates the gutter's active line indicator based on cursor position.
    func updateCurrentLine(for textView: NSTextView) {
        let text = textView.string as NSString
        let pos = textView.selectedRange().location
        guard pos <= text.length else { return }

        var line = 1, i = 0
        while i < pos && i < text.length {
            if text.character(at: i) == 0x0A { line += 1 }
            i += 1
        }
        if currentLineNumber != line {
            currentLineNumber = line
            needsDisplay = true
        }
    }
}

