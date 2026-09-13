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

            // Whole-line marks skip the leading whitespace.
            var location = lineStart + (diagnostic.column ?? leadingWhitespace(text, from: lineStart, to: lineEnd))
            var length = diagnostic.length ?? (lineEnd - location)
            location = min(max(location, lineStart), lineEnd)
            length = min(length, lineEnd - location)
            if length <= 0 {
                // An error at end of line (missing ')' etc.): mark the last
                // character so there is something to see.
                if location > lineStart { location -= 1; length = 1 }
                else if lineEnd > lineStart { length = 1 }
            }

            if length > 0 {
                layoutManager.addTemporaryAttributes([
                    .underlineStyle: style,
                    .underlineColor: Self.color(for: diagnostic.severity),
                    .syntaxDiagnostic: diagnostic.message,
                ], forCharacterRange: NSRange(location: location, length: length))
            }

            let gutterLine = diagnostic.line + 1
            if let existing = gutterMarks[gutterLine], existing >= diagnostic.severity { continue }
            gutterMarks[gutterLine] = diagnostic.severity
        }

        gutter?.diagnosticLines = gutterMarks
        gutter?.needsDisplay = true
    }

    private func leadingWhitespace(_ text: NSString, from start: Int, to end: Int) -> Int {
        var i = start
        while i < end, text.character(at: i) == 0x20 || text.character(at: i) == 0x09 { i += 1 }
        return i - start
    }
}
