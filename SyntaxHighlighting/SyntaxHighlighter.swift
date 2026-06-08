import Foundation
import AppKit

/// Manages syntax highlighting for C64 source code (BASIC or Assembly) within an `NSTextView`.
/// Delegates tokenization to `C64BasicSyntax` or `C64AssemblySyntax` based on the active file type.
class SyntaxHighlighter {

    private let textStorage: NSTextStorage
    private var fileType: C64FileType

    /// The monospaced font used for source code — delegates to EditorFontManager.
    static var codeFont: NSFont {
        EditorFontManager.shared.codeFont
    }

    /// Bold variant for keywords / opcodes.
    static var codeFontBold: NSFont {
        EditorFontManager.shared.codeFontBold
    }

    /// Default text attributes for the editor.
    static var defaultAttributes: [NSAttributedString.Key: Any] {
        EditorFontManager.shared.defaultAttributes
    }

    /// Initializes a new highlighter for a specific `NSTextStorage`.
    /// - Parameters:
    ///   - textStorage: The text storage to highlight.
    ///   - fileType: The language syntax to apply.
    init(textStorage: NSTextStorage, fileType: C64FileType) {
        self.textStorage = textStorage
        self.fileType = fileType
    }

    /// Updates the active file type and triggers a full re-highlight.
    func setFileType(_ type: C64FileType) {
        self.fileType = type
        highlightAll()
    }

    // MARK: - Full Document Highlighting

    /// Applies syntax highlighting to every line in the document.
    func highlightAll() {
        let fullRange = NSRange(location: 0, length: textStorage.length)
        guard fullRange.length > 0 else { return }

        textStorage.beginEditing()

        // Reset to default attributes first
        textStorage.setAttributes(Self.defaultAttributes, range: fullRange)

        let text = textStorage.string
        let lines = text.components(separatedBy: "\n")
        var lineStart = 0

        for line in lines {
            let lineRange = NSRange(location: lineStart, length: (line as NSString).length)
            highlightLine(line, at: lineStart)
            lineStart += lineRange.length + 1 // +1 for newline
        }

        textStorage.endEditing()
    }

    // MARK: - Incremental Highlighting

    /// Re-highlights the lines affected by a text edit.
    /// - Parameter editedRange: The NSRange of the inserted/deleted text.
    func highlightRange(_ editedRange: NSRange) {
        let text = textStorage.string as NSString
        let totalLength = text.length
        guard totalLength > 0 else { return }

        // Expand to full lines for accurate tokenization
        let clampedLocation = min(editedRange.location, totalLength - 1)
        let lineRange = text.lineRange(for: NSRange(location: clampedLocation, length: 0))

        // Also include the next line in case a newline was inserted/deleted
        var expandedEnd = NSMaxRange(lineRange)
        if expandedEnd < totalLength {
            let nextLineRange = text.lineRange(for: NSRange(location: expandedEnd, length: 0))
            expandedEnd = NSMaxRange(nextLineRange)
        }

        let highlightRange = NSRange(location: lineRange.location, length: expandedEnd - lineRange.location)

        textStorage.beginEditing()

        // Reset the range to default attributes
        textStorage.setAttributes(Self.defaultAttributes, range: highlightRange)

        // Re-tokenize affected lines
        let affectedText = text.substring(with: highlightRange)
        let lines = affectedText.components(separatedBy: "\n")
        var lineStart = highlightRange.location

        for line in lines {
            highlightLine(line, at: lineStart)
            lineStart += (line as NSString).length + 1
        }

        textStorage.endEditing()
    }

    // MARK: - Line-Level Highlighting

    /// Dispatches line highlighting based on the active file type.
    private func highlightLine(_ line: String, at offset: Int) {
        if fileType.usesBasicHighlighting {
            highlightBasicLine(line, at: offset)
        } else if fileType.usesAssemblyHighlighting {
            highlightAssemblyLine(line, at: offset)
        }
        // .text type gets no highlighting
    }

    /// Applies BASIC syntax highlighting to a line.
    private func highlightBasicLine(_ line: String, at offset: Int) {
        let tokens = C64BasicSyntax.tokenize(line)

        for token in tokens {
            let range = NSRange(location: offset + token.range.location, length: token.range.length)
            guard range.location + range.length <= textStorage.length else { continue }

            var attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: token.type.color,
            ]

            // Bold keywords and POKE/PEEK for visual emphasis
            switch token.type {
            case .keyword, .poke:
                attrs[.font] = Self.codeFontBold
            default:
                attrs[.font] = Self.codeFont
            }

            textStorage.addAttributes(attrs, range: range)
        }
    }

    /// Applies Assembly syntax highlighting to a line.
    private func highlightAssemblyLine(_ line: String, at offset: Int) {
        let tokens = C64AssemblySyntax.tokenize(line)

        for token in tokens {
            let range = NSRange(location: offset + token.range.location, length: token.range.length)
            guard range.location + range.length <= textStorage.length else { continue }

            var attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: token.type.color,
            ]

            switch token.type {
            case .opcode, .macro:
                attrs[.font] = Self.codeFontBold
            default:
                attrs[.font] = Self.codeFont
            }

            textStorage.addAttributes(attrs, range: range)
        }
    }
}

