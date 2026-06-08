import Cocoa

/// A custom scroll view that notifies when subviews are added, used to intercept gutter placement.
private class GutterAwareScrollView: NSScrollView {
    /// Called when a subview is added to the scroll view.
    var onSubviewAdded: ((NSView) -> Void)?
    
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        onSubviewAdded?(subview)
    }
}

/// View controller responsible for managing the C64 source editor, including syntax highlighting,
/// gutter rendering, file watching, and C64-specific features like auto-numbering and shortcut expansion.
class EditorViewController: NSViewController, NSTextViewDelegate, NSTextStorageDelegate {

    private var scrollView: NSScrollView!
    private(set) var textView: NSTextView!
    private(set) var gutter: LineNumberGutter!
    private var highlighter: SyntaxHighlighter!
    private var tooltipProvider: TooltipProvider!
    
    /// Prevents delegate callbacks from triggering infinite loops during programmatic text updates.
    private var isSuppressingDelegate = false

    /// Watches the backing file for external changes (e.g., another editor saving).
    private var fileWatcher: FileWatcher?

    // MARK: - External Callbacks

    /// Called when the word under the cursor is identified.
    var onWordUnderCursor: ((String, C64FileType) -> Void)?
    /// Called when a valid memory address under the cursor is identified.
    var onAddressUnderCursor: ((Int) -> Void)?
    /// Called whenever the document content is modified.
    var onDocumentModified: (() -> Void)?
    /// Called after a background reload from disk to refresh UI state.
    var onExternalReload: (() -> Void)?

    // MARK: - Document Binding

    var document: C64Document = C64Document(fileType: .basic) {
        didSet {
            armFileWatcher()
            guard isViewLoaded, !isSuppressingDelegate else { return }
            loadTextIntoEditor()
        }
    }

    // MARK: - Theme Colors

    private var editorBackground:    NSColor { AppTheme.current.editorBackground }
    private var selectionColor:      NSColor { AppTheme.current.selectionBackground }
    private var insertionPointColor: NSColor { AppTheme.current.insertionPoint }
    private var defaultTextColor:    NSColor { AppTheme.current.defaultText }

    // MARK: - Lifecycle

    override func loadView() {
        let w: CGFloat = 700, h: CGFloat = 500
        let gw = LineNumberGutter.gutterWidth

        // Container view holds the gutter strip + scroll view side-by-side.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        container.autoresizingMask = [.width, .height]

        let sv = GutterAwareScrollView(frame: NSRect(x: gw, y: 0, width: w - gw, height: h))
        sv.autoresizingMask = [.width, .height]
        sv.hasVerticalScroller = true
        sv.borderType = .noBorder
        sv.backgroundColor = editorBackground

        let tv = NSTextView(frame: NSRect(origin: .zero, size: sv.contentSize))
        tv.autoresizingMask = [.width, .height]
        tv.isEditable = true
        tv.isSelectable = true
        tv.allowsUndo = true
        tv.isRichText = false
        tv.importsGraphics = false
        tv.usesFindBar = true
        tv.backgroundColor = editorBackground
        tv.textColor = defaultTextColor
        tv.font = SyntaxHighlighter.codeFont
        tv.insertionPointColor = insertionPointColor
        tv.selectedTextAttributes = [.backgroundColor: selectionColor, .foregroundColor: NSColor.white]
        tv.textContainerInset = NSSize(width: 4, height: 8)
        tv.typingAttributes = SyntaxHighlighter.defaultAttributes
        
        // Disable macOS auto-correction to preserve exact C64 BASIC syntax
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticTextCompletionEnabled = false
        tv.smartInsertDeleteEnabled = false

        sv.documentView = tv
        container.addSubview(sv)

        scrollView = sv
        textView = tv
        self.view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        textView.delegate = self
        textView.textStorage?.delegate = self

        highlighter = SyntaxHighlighter(textStorage: textView.textStorage!, fileType: document.fileType)
        tooltipProvider = TooltipProvider(textView: textView, fileType: document.fileType)

        loadTextIntoEditor()

        // Gutter must be added after the text layout is established
        DispatchQueue.main.async { [weak self] in
            self?.setupGutter()
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(editorFontDidChange(_:)),
            name: EditorFontManager.fontDidChangeNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange(_:)),
            name: .appThemeDidChange,
            object: nil
        )
    }

    @objc private func editorFontDidChange(_ note: Notification) {
        let mgr = EditorFontManager.shared
        textView.font = mgr.codeFont
        textView.typingAttributes = mgr.defaultAttributes
        highlighter?.highlightAll()
        gutter?.needsDisplay = true
    }

    @objc private func themeDidChange(_ note: Notification) {
        applyThemeColors()
        highlighter?.highlightAll()
        gutter?.needsDisplay = true
    }

    func applyThemeColors() {
        let t = AppTheme.current
        scrollView?.backgroundColor = t.editorBackground
        textView.backgroundColor    = t.editorBackground
        textView.textColor          = t.defaultText
        textView.insertionPointColor = t.insertionPoint
        textView.selectedTextAttributes = [
            .backgroundColor: t.selectionBackground,
            .foregroundColor: t.selectionForeground,
        ]
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        textView.window?.makeFirstResponder(textView)
    }

    // MARK: - Gutter Management

    /// Callback when a breakpoint is toggled in the gutter.
    var onBreakpointToggled: ((Int, Bool) -> Void)?

    /// Returns all 1-indexed line numbers that have breakpoints set.
    var breakpointLines: Set<Int> {
        gutter?.breakpointLines ?? []
    }

    /// Highlights the current debug execution line with a yellow arrow and background.
    func highlightDebugLine(_ line: Int) {
        gutter?.debugExecutionLine = line
        gutter?.needsDisplay = true
        scrollToLine(line)
    }

    /// Triggers a full re-highlight of the current document.
    func rehighlightAll() {
        highlighter?.highlightAll()
    }

    /// Clears the debug execution highlight.
    func clearDebugHighlight() {
        gutter?.debugExecutionLine = nil
        gutter?.needsDisplay = true
    }

    /// Scrolls the visible viewport to ensure a 1-indexed line is visible.
    private func scrollToLine(_ line: Int) {
        guard let tv = textView else { return }
        let text = tv.string as NSString
        var currentLine = 1
        var charIndex = 0
        while charIndex < text.length && currentLine < line {
            if text.character(at: charIndex) == 0x0A { currentLine += 1 }
            charIndex += 1
        }
        guard currentLine == line else { return }
        
        var lineEnd = charIndex
        while lineEnd < text.length && text.character(at: lineEnd) != 0x0A { lineEnd += 1 }
        let range = NSRange(location: charIndex, length: lineEnd - charIndex)
        tv.scrollRangeToVisible(range)
    }

    private func setupGutter() {
        let g = LineNumberGutter(textView: textView)
        g.onBreakpointToggled = { [weak self] line, isSet in
            self?.onBreakpointToggled?(line, isSet)
        }

        scrollView.superview?.addSubview(g)
        gutter = g
        updateGutterFrame()

        // Observe scroll and frame changes to keep gutter in sync
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipViewFrameDidChange(_:)),
            name: NSView.frameDidChangeNotification,
            object: scrollView.contentView
        )
        scrollView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipViewFrameDidChange(_:)),
            name: NSView.frameDidChangeNotification,
            object: scrollView
        )

        g.needsDisplay = true
        DispatchQueue.main.async { [weak self] in
            self?.updateGutterFrame()
        }
    }

    private func updateGutterFrame() {
        guard let g = gutter, let sv = scrollView, sv.frame.height > 0 else { return }
        let gw = LineNumberGutter.gutterWidth
        g.frame = NSRect(x: 0, y: sv.frame.minY, width: gw, height: sv.frame.height)
    }

    @objc private func clipViewFrameDidChange(_ note: Notification) {
        updateGutterFrame()
        gutter?.needsDisplay = true
    }

    @objc private func scrollDidChange(_ note: Notification) {
        gutter?.needsDisplay = true
    }

    // MARK: - Text Loading

    private func loadTextIntoEditor() {
        guard textView != nil else { return }
        isSuppressingDelegate = true
        textView.string = document.content
        highlighter?.setFileType(document.fileType)
        highlighter?.highlightAll()
        tooltipProvider?.setFileType(document.fileType)
        isSuppressingDelegate = false
    }

    // MARK: - NSTextStorageDelegate

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard !isSuppressingDelegate, editedMask.contains(.editedCharacters) else { return }
        
        DispatchQueue.main.async { [weak self] in
            if abs(delta) > 1 {
                // Large changes (e.g., paste) warrant a full re-highlight
                self?.highlighter?.highlightAll()
            } else {
                self?.highlighter?.highlightRange(editedRange)
            }
            self?.gutter?.needsDisplay = true
        }
        
        isSuppressingDelegate = true
        document.content = textStorage.string
        document.isModified = true
        isSuppressingDelegate = false
        onDocumentModified?()
    }

    // MARK: - NSTextViewDelegate

    func textViewDidChangeSelection(_ notification: Notification) {
        gutter?.updateCurrentLine(for: textView)
        gutter?.needsDisplay = true
        notifyReferencePanel()
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        guard let replacement = replacementString, replacement == "\n" else { return true }
        
        let text = textView.string as NSString
        let lineRange = text.lineRange(for: NSRange(location: range.location, length: 0))
        
        // Extract the portion of the line before the cursor. This represents what will be
        // committed when Return is pressed. Text after the cursor remains on the new line.
        let beforeCursorRange = NSRange(
            location: lineRange.location,
            length: range.location - lineRange.location
        )
        let beforeCursor = text.substring(with: beforeCursorRange)

        var committedLine: String
        var expansionPrefix: String
        var expansionReplaceRange: NSRange
        
        if document.fileType.usesBasicHighlighting {
            // Expand C64 BASIC shortcuts (e.g., `pO` → `POKE`) only at line commit.
            // This matches ROM behavior where abbreviations resolve upon submission.
            let expanded = BasicShortcutExpander.expand(
                beforeCursor,
                dialect: BasicDialectManager.shared.activeDialect
            )
            if expanded != beforeCursor {
                committedLine = expanded
                expansionPrefix = expanded
                expansionReplaceRange = beforeCursorRange
            } else {
                committedLine = beforeCursor
                expansionPrefix = ""
                expansionReplaceRange = range
            }
        } else {
            committedLine = beforeCursor
            expansionPrefix = ""
            expansionReplaceRange = range
        }

        if document.fileType.usesBasicHighlighting {
            // Auto-number the next line if the current line starts with a number
            var numStr = ""
            for ch in committedLine {
                if ch.isNumber { numStr.append(ch) } else { break }
            }

            if let currentNum = Int(numStr) {
                let lines = BasicRenumber.parseLines(textView.string)
                let currentIdx = lines.firstIndex(where: { $0.lineNumber == currentNum })
                let nextLine = currentIdx.flatMap { idx in
                    idx + 1 < lines.count ? lines[idx + 1].lineNumber : nil
                }

                if let nextNum = BasicRenumber.nextLineNumber(after: currentNum, beforeLine: nextLine) {
                    // Replace the entire line break + number region atomically to preserve undo
                    textView.insertText(expansionPrefix + "\n\(nextNum) ", replacementRange: expansionReplaceRange)
                    return false
                } else {
                    textView.insertText(expansionPrefix + "\n", replacementRange: expansionReplaceRange)
                    return false
                }
            }

            // Honour expansion even if auto-numbering can't apply
            if !expansionPrefix.isEmpty {
                textView.insertText(expansionPrefix + "\n", replacementRange: expansionReplaceRange)
                return false
            }
        }

        // Non-BASIC files: preserve leading indentation
        var indent = ""
        for ch in committedLine {
            if ch == " " || ch == "\t" { indent.append(ch) } else { break }
        }
        if !indent.isEmpty {
            textView.insertText("\n" + indent, replacementRange: range)
            return false
        }

        return true
    }

    // MARK: - Renumber

    func performRenumber() {
        guard document.fileType.usesBasicHighlighting else { return }
        let hasSelection = textView.selectedRange().length > 0

        RenumberDialog.show(for: textView, hasSelection: hasSelection) { [weak self] result in
            guard let self = self, let result = result, result.success else { return }

            self.isSuppressingDelegate = true
            self.textView.string = result.newSource
            self.highlighter?.highlightAll()
            self.isSuppressingDelegate = false

            self.document.content = result.newSource
            self.document.isModified = true
            self.gutter?.needsDisplay = true
        }
    }

    // MARK: - Reference Panel Integration

    /// Extracts the word under the cursor and determines if it's a keyword, opcode, or memory address.
    private func notifyReferencePanel() {
        let text = textView.string as NSString
        let pos = textView.selectedRange().location
        guard pos > 0, pos <= text.length else { return }
        
        let charPos = min(pos, text.length - 1)
        var start = charPos, end = charPos

        // Expand to include alphanumerics, $ (hex), and % (binary)
        while start > 0 {
            let c = text.character(at: start - 1)
            if CharacterSet.alphanumerics.contains(Unicode.Scalar(c)!) || c == 0x24 || c == 0x25 { start -= 1 }
            else { break }
        }
        while end < text.length {
            let c = text.character(at: end)
            if CharacterSet.alphanumerics.contains(Unicode.Scalar(c)!) || c == 0x24 || c == 0x25 { end += 1 }
            else { break }
        }
        guard end > start else { return }
        
        let word = text.substring(with: NSRange(location: start, length: end - start))
        var address: Int?

        if word.hasPrefix("$") {
            address = Int(String(word.dropFirst()), radix: 16)
        } else if let num = Int(word), num >= 0, num <= 65535 {
            // Decimal numbers are only treated as addresses in memory-access contexts
            let lineRange = text.lineRange(for: NSRange(location: pos, length: 0))
            let line = text.substring(with: lineRange).uppercased()
            if line.contains("POKE") || line.contains("PEEK") || line.contains("SYS") || line.contains("WAIT") {
                address = num
            }
        }

        if let addr = address, addr >= 0, addr <= 65535 {
            onAddressUnderCursor?(addr)
            return
        }

        if !word.isEmpty && !word.hasPrefix("$") {
            onWordUnderCursor?(word, document.fileType)
        }
    }

    // MARK: - File Watcher

    /// Arms (or re-arms) a FileWatcher for the document's backing URL.
    private func armFileWatcher() {
        fileWatcher = nil
        guard let url = document.fileURL else { return }
        fileWatcher = FileWatcher(url: url) { [weak self] in
            self?.handleExternalFileChange()
        }
    }

    private func handleExternalFileChange() {
        // Ignore events triggered by our own save operation
        if document.isModified {
            let alert = NSAlert()
            alert.messageText = "\"\(document.displayTitle)\" changed on disk"
            alert.informativeText = "The file has been modified by another application. Do you want to reload it and discard your unsaved changes?"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Reload")
            alert.addButton(withTitle: "Keep My Changes")

            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        reloadFromDisk()
    }

    private func reloadFromDisk() {
        do {
            try document.reload()
        } catch {
            let nsError = error as NSError
            if nsError.domain != NSCocoaErrorDomain || nsError.code != NSFileReadNoSuchFileError {
                NSAlert(error: error).runModal()
            }
            return
        }

        isSuppressingDelegate = true
        let savedRange = textView.selectedRange()
        let savedScroll = scrollView.contentView.bounds.origin

        textView.string = document.content
        highlighter?.setFileType(document.fileType)
        highlighter?.highlightAll()

        let len = (textView.string as NSString).length
        let clampedLoc = min(savedRange.location, len)
        let clampedLen = min(savedRange.length, len - clampedLoc)
        textView.setSelectedRange(NSRange(location: clampedLoc, length: clampedLen))
        scrollView.contentView.scroll(to: savedScroll)

        isSuppressingDelegate = false
        gutter?.needsDisplay = true
        onExternalReload?()
    }

    // MARK: - Public API

    func loadDocument(_ doc: C64Document) {
        self.document = doc
    }

    func saveDocument() {
        do {
            if document.fileURL == nil { saveDocumentAs() }
            else { try document.save() }
        } catch { NSAlert(error: error).runModal() }
    }

    func saveDocumentAs() {
        saveDocumentAs { _ in }
    }

    func saveDocumentAs(completion: @escaping (Bool) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: document.fileType.rawValue)!]
        panel.nameFieldStringValue = document.displayTitle
        panel.begin { [weak self] response in
            if response == .OK, let url = panel.url {
                do {
                    try self?.document.save(to: url)
                    completion(true)
                } catch {
                    NSAlert(error: error).runModal()
                    completion(false)
                }
            } else {
                completion(false)
            }
        }
    }
}

