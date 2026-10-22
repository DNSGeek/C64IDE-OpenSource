// MARK: - EditorViewController+Diagnostics.swift
//
// Presents live syntax-check results in the editor: dotted underlines under
// the offending text (layout-manager temporary attributes, so they never
// touch the document or its undo stack), a marker in the gutter, and a
// message the tooltip provider shows on hover. Results also go to the
// window via `onDiagnosticsUpdated` for the Problems tab.

import Cocoa

extension NSAttributedString.Key {
    /// Temporary attribute carrying a diagnostic's message for hover lookup.
    static let syntaxDiagnostic = NSAttributedString.Key("C64IDE.syntaxDiagnostic")
}

/// The editor's layout manager. It exists to draw the diagnostics' dotted
/// underline itself, as a row of filled dots. AppKit draws a dotted
/// underline as a dashed stroke, and during an edit that stroke can be
/// issued with no segments left in it (a dashed line clipped to nothing).
/// The empty draw is harmless in normal runs, but Xcode's Metal API
/// Validation treats it as fatal ("instanceCount(0) must be non-zero",
/// raised from CoreAnimation's CoreGraphics backend), which froze debug
/// sessions after typing a line the checker flags. Filled dots never go
/// through the line renderer. Other underline styles still go to AppKit.
final class DiagnosticLayoutManager: NSLayoutManager {

    override func drawUnderline(forGlyphRange glyphRange: NSRange,
                                underlineType: NSUnderlineStyle,
                                baselineOffset: CGFloat,
                                lineFragmentRect: CGRect,
                                lineFragmentGlyphRange: NSRange,
                                containerOrigin: CGPoint) {
        guard underlineType.contains(.patternDot) else {
            super.drawUnderline(forGlyphRange: glyphRange, underlineType: underlineType,
                                baselineOffset: baselineOffset, lineFragmentRect: lineFragmentRect,
                                lineFragmentGlyphRange: lineFragmentGlyphRange,
                                containerOrigin: containerOrigin)
            return
        }

        let visible = NSIntersectionRange(glyphRange, lineFragmentGlyphRange)
        guard visible.length > 0,
              let container = textContainer(forGlyphAt: visible.location, effectiveRange: nil) else { return }
        let bounds = boundingRect(forGlyphRange: visible, in: container)
        guard bounds.width >= 1 else { return }

        let charIndex = characterIndexForGlyph(at: visible.location)
        let color = (temporaryAttribute(.underlineColor, atCharacterIndex: charIndex, effectiveRange: nil) as? NSColor)
            ?? (textStorage?.attribute(.underlineColor, at: charIndex, effectiveRange: nil) as? NSColor)
            ?? .systemRed
        let font = (textStorage?.attribute(.font, at: charIndex, effectiveRange: nil) as? NSFont)
            ?? NSFont.userFixedPitchFont(ofSize: 0) ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)

        // Dots sit just under the baseline, which the first glyph's location
        // gives relative to the line fragment's origin. underlinePosition is
        // negative (below the baseline) and the view is flipped, hence the
        // subtraction.
        let diameter = max(2, (font.pointSize / 6).rounded())
        let baseline = lineFragmentRect.minY + location(forGlyphAt: visible.location).y + containerOrigin.y
        let top = baseline - font.underlinePosition
        let left = bounds.minX + containerOrigin.x
        let right = bounds.maxX + containerOrigin.x

        color.setFill()
        var x = left
        while x + diameter <= right + 0.5 {
            NSBezierPath(ovalIn: NSRect(x: x, y: top, width: diameter, height: diameter)).fill()
            x += diameter * 2
        }
    }
}

extension EditorViewController {

    // MARK: - Setting

    /// UserDefaults key for the View > Check Syntax While Typing toggle.
    static let syntaxCheckDefaultsKey = "SyntaxCheckWhileTyping"

    /// Posted after the toggle changes so every open editor re-checks (or
    /// clears its marks).
    static let syntaxCheckSettingDidChange =
        Notification.Name("C64IDE.syntaxCheckSettingDidChange")

    static var syntaxCheckEnabled: Bool {
        get { UserDefaults.standard.object(forKey: syntaxCheckDefaultsKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: syntaxCheckDefaultsKey)
            NotificationCenter.default.post(name: syntaxCheckSettingDidChange, object: nil)
        }
    }

    // MARK: - Colours

    static var diagnosticErrorColor: NSColor { .systemRed }
    static var diagnosticWarningColor: NSColor { .systemOrange }

    static func color(for severity: DiagnosticSeverity) -> NSColor {
        severity == .error ? diagnosticErrorColor : diagnosticWarningColor
    }

    // MARK: - Presentation

    /// Replaces the editor's diagnostic marks. `diagnostics` must describe
    /// the text currently in the view (the analysis generation counter
    /// guarantees this for background results).
    func applyDiagnostics(_ diagnostics: [SyntaxDiagnostic]) {
        syntaxDiagnostics = diagnostics
        defer { onDiagnosticsUpdated?(diagnostics) }

        guard let textView, let layoutManager = textView.layoutManager else { return }
        let text = textView.string as NSString
        let full = NSRange(location: 0, length: text.length)
        layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: full)
        layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: full)
        layoutManager.removeTemporaryAttribute(.syntaxDiagnostic, forCharacterRange: full)

        // Start offset of every line, so line/column pairs become ranges.
        var lineStarts = [0]
        for i in 0..<text.length where text.character(at: i) == 0x0A {
            lineStarts.append(i + 1)
        }

        var gutterMarks: [Int: DiagnosticSeverity] = [:]
        let style = NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue

        for diagnostic in diagnostics {
            guard diagnostic.line < lineStarts.count else { continue }
            let lineStart = lineStarts[diagnostic.line]
            let lineEnd = diagnostic.line + 1 < lineStarts.count
                ? lineStarts[diagnostic.line + 1] - 1
                : text.length

            for range in Self.underlineRanges(for: diagnostic, lineStart: lineStart,
                                              lineEnd: lineEnd, in: text) {
                layoutManager.addTemporaryAttributes([
                    .underlineStyle: style,
                    .underlineColor: Self.color(for: diagnostic.severity),
                    .syntaxDiagnostic: diagnostic.message,
                ], forCharacterRange: range)
            }

            let gutterLine = diagnostic.line + 1
            if let existing = gutterMarks[gutterLine], existing >= diagnostic.severity { continue }
            gutterMarks[gutterLine] = diagnostic.severity
        }

        gutter?.diagnosticLines = gutterMarks
        gutter?.needsDisplay = true
    }

    /// The character ranges to underline for `diagnostic` on the line
    /// `lineStart..<lineEnd` of `text`.
    ///
    /// Tab characters are never underlined: a dotted line under a tab is
    /// just a gap in the text, and the layout manager draws it as a
    /// zero-width run (see `DiagnosticLayoutManager`). So an error at the
    /// end of a line marks the last visible character rather than trailing
    /// whitespace, and a range that spans a tab is split around it.
    static func underlineRanges(for diagnostic: SyntaxDiagnostic, lineStart: Int, lineEnd: Int,
                                in text: NSString) -> [NSRange] {
        // Whole-line marks skip the leading whitespace.
        var location = lineStart + (diagnostic.column ?? leadingWhitespace(text, from: lineStart, to: lineEnd))
        var length = diagnostic.length ?? (lineEnd - location)
        location = min(max(location, lineStart), lineEnd)
        length = min(length, lineEnd - location)

        if length <= 0 {
            // An error at end of line (missing ')' etc.): mark the last
            // visible character so there is something to see.
            var i = location
            while i > lineStart, isBlank(text.character(at: i - 1)) { i -= 1 }
            if i > lineStart { return [NSRange(location: i - 1, length: 1)] }
            // Nothing before the error: the first character that is not a
            // tab, if the line has one.
            var j = lineStart
            while j < lineEnd, text.character(at: j) == 0x09 { j += 1 }
            return j < lineEnd ? [NSRange(location: j, length: 1)] : []
        }

        var ranges: [NSRange] = []
        var runStart = location
        let end = location + length
        var i = location
        while i <= end {
            if i == end || text.character(at: i) == 0x09 {
                if i > runStart { ranges.append(NSRange(location: runStart, length: i - runStart)) }
                runStart = i + 1
            }
            i += 1
        }
        return ranges
    }

    private static func isBlank(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 }

    private static func leadingWhitespace(_ text: NSString, from start: Int, to end: Int) -> Int {
        var i = start
        while i < end, isBlank(text.character(at: i)) { i += 1 }
        return i - start
    }
}
