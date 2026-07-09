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

/// A text view that tracks mouse movement and forwards hover events to a TooltipProvider.
private final class TooltipTextView: NSTextView {
    weak var tooltipProvider: TooltipProvider?
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = hoverTrackingArea {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        tooltipProvider?.handleMouseMoved(at: event.locationInWindow, in: self)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        tooltipProvider?.handleMouseExited()
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

        let tv = TooltipTextView(frame: NSRect(origin: .zero, size: sv.contentSize))
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
        (textView as? TooltipTextView)?.tooltipProvider = tooltipProvider

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
                let committedStart = lineRange.location

                // Classify the committed line BEFORE deciding how to number
                // the next one: an out-of-order or duplicate line takes a
                // plain newline here and gets arranged after the commit
                // settles. Auto-numbering from the wrong file position would
                // propose a number based on the wrong neighbours.
                let arrangeAction: BasicRenumber.AutoArrangeAction =
                    autoArrangeEnabled
                    ? (BasicRenumber.autoArrangeAction(source: textView.string,
                                                       lineStart: committedStart) ?? .none)
                    : .none

                switch arrangeAction {
                case .none:
                    let lines = BasicRenumber.parseLines(textView.string)
                    let currentIdx = lines.firstIndex(where: { $0.lineNumber == currentNum })
                    let nextLine = currentIdx.flatMap { idx in
                        idx + 1 < lines.count ? lines[idx + 1].lineNumber : nil
                    }

                    if let nextNum = BasicRenumber.nextLineNumber(after: currentNum, beforeLine: nextLine) {
                        // Replace the entire line break + number region atomically to preserve undo
                        textView.insertText(expansionPrefix + "\n\(nextNum) ", replacementRange: expansionReplaceRange)
                        return false
                    }
                    // No room before the next line (e.g. editing 790 with a
                    // 791 right below): fall through to a plain newline.
                    // Do NOT call insertText("\n") here — a bare "\n" comes
                    // straight back through this delegate (the guard at the
                    // top matches replacement == "\n"), recomputes the same
                    // nil, and recurses until the stack overflows. That was
                    // the no-gap crash.

                case .move, .duplicate:
                    // Commit the newline first (below), then arrange once the
                    // text has settled. Offsets are re-derived at that point,
                    // so it doesn't matter that the buffer changes in between.
                    DispatchQueue.main.async { [weak self] in
                        self?.performAutoArrange(lineStart: committedStart)
                    }
                }
            }

            // Honour expansion even when auto-numbering can't apply. The
            // inserted string is never exactly "\n", so this cannot recurse.
            if !expansionPrefix.isEmpty {
                textView.insertText(expansionPrefix + "\n", replacementRange: expansionReplaceRange)
                return false
            }

            // Numbered line with no room, or unnumbered line: fall through
            // and let AppKit insert the newline itself. (The indent logic
            // below is a no-op for numbered BASIC lines.)
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

    // MARK: - Auto-Arrange on Commit

    /// UserDefaults key for the "committed line jumps to its sorted position"
    /// behavior. Defaults to enabled; wire a menu item / settings checkbox to
    /// this key to let users opt out.
    static let autoArrangeDefaultsKey = "BasicAutoArrangeOnCommit"

    private var autoArrangeEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.autoArrangeDefaultsKey) as? Bool ?? true
    }

    /// Arranges the just-committed BASIC line at `lineStart`:
    ///   - in order and unique → nothing.
    ///   - out of order        → moved to its sorted position, cursor follows,
    ///                           and a fresh auto-numbered line is started
    ///                           there when a number fits.
    ///   - duplicate number    → sheet asking Replace / Renumber / Keep Both.
    ///
    /// Called async after the Return commit so the newline is already in the
    /// buffer; all offsets are re-derived from the current text.
    private func performAutoArrange(lineStart: Int) {
        guard document.fileType.usesBasicHighlighting else { return }
        let text = textView.string as NSString
        guard lineStart < text.length else { return }

        // Guard-let first: switching an Optional whose Wrapped has a `.none`
        // case is a footgun — `case .none` would match Optional.none, not
        // AutoArrangeAction.none.
        guard let action = BasicRenumber.autoArrangeAction(source: textView.string,
                                                           lineStart: lineStart) else { return }
        switch action {
        case .none:
            return
        case .move(let targetOffset):
            moveCommittedLine(from: lineStart, toOffset: targetOffset)
        case .duplicate(let existingStart):
            presentDuplicateLineSheet(committedStart: lineStart, existingStart: existingStart)
        }
    }

    /// Moves the line at `lineStart` (trailing newline included) so it sits
    /// at `targetOffset`, as a single undoable group. The caret lands at the
    /// end of the moved line and, when a line number fits before the new
    /// next neighbour, a fresh numbered line is started — mirroring what the
    /// normal Return path would have done had the line been typed in place.
    private func moveCommittedLine(from lineStart: Int, toOffset targetOffset: Int) {
        let text = textView.string as NSString
        let fullLine = text.lineRange(for: NSRange(location: lineStart, length: 0))
        var lineText = text.substring(with: fullLine)
        if !lineText.hasSuffix("\n") { lineText.append("\n") }

        // Adjust the insertion offset for the deletion below. Targets never
        // land inside the line itself (autoArrangeAction only returns other
        // lines' boundaries), but guard against it anyway.
        var insertAt = targetOffset
        if insertAt >= NSMaxRange(fullLine) {
            insertAt -= fullLine.length
        } else if insertAt > fullLine.location {
            return
        }

        let um = textView.undoManager
        um?.beginUndoGrouping()
        defer { um?.endUndoGrouping() }

        textView.insertText("", replacementRange: fullLine)

        // Clamp against the post-deletion text and normalise to a line
        // boundary: the append-at-end target can overshoot when the file's
        // last line has no trailing newline.
        let after = textView.string as NSString
        insertAt = min(max(0, insertAt), after.length)
        var payload = lineText
        var contentStart = insertAt
        if insertAt > 0, after.character(at: insertAt - 1) != 0x0A {
            payload = "\n" + lineText
            contentStart += 1
        }
        textView.insertText(payload, replacementRange: NSRange(location: insertAt, length: 0))

        // Caret at the end of the moved line's content (before its newline).
        let contentLength = (lineText as NSString).length - 1
        textView.setSelectedRange(NSRange(location: contentStart + contentLength, length: 0))

        continueNumbering(afterLineAt: contentStart)
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    /// Sheet shown when the committed line's number collides with an
    /// existing line. Silent replacement is what real hardware does, but in
    /// an editor that's a destructive surprise, so the user decides.
    private func presentDuplicateLineSheet(committedStart: Int, existingStart: Int) {
        let text = textView.string as NSString
        guard committedStart < text.length, existingStart < text.length else { return }

        let committedRange = text.lineRange(for: NSRange(location: committedStart, length: 0))
        let existingRange  = text.lineRange(for: NSRange(location: existingStart, length: 0))
        let committedLine = text.substring(with: committedRange)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let existingLine = text.substring(with: existingRange)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var numStr = ""
        for ch in committedLine {
            if ch.isNumber { numStr.append(ch) } else { break }
        }

        let alert = NSAlert()
        alert.messageText = "Line \(numStr) already exists"
        alert.informativeText = """
            Existing:  \(existingLine)
            New:       \(committedLine)

            Replace the existing line, renumber the new one to the next \
            free slot, or keep both as typed?
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Replace Existing")
        alert.addButton(withTitle: "Renumber New Line")
        alert.addButton(withTitle: "Keep Both")

        // The sheet blocks editing, so the captured offsets stay valid.
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self = self else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.replaceExistingLine(existingStart: existingStart,
                                         committedStart: committedStart)
            case .alertSecondButtonReturn:
                self.renumberCommittedLine(at: committedStart)
            default:
                break  // Keep both; the tokenizer sorts at build time anyway.
            }
        }
    }

    /// Overwrites the existing line's text with the committed line's text
    /// and removes the committed line, as one undoable group. The caret
    /// lands at the end of the surviving line. No auto-number continuation
    /// here: replacing a line is a correction, not the start of a new block.
    private func replaceExistingLine(existingStart: Int, committedStart: Int) {
        let text = textView.string as NSString
        let committedFull = text.lineRange(for: NSRange(location: committedStart, length: 0))
        var committedBody = committedFull
        if committedBody.length > 0,
           text.character(at: NSMaxRange(committedBody) - 1) == 0x0A {
            committedBody.length -= 1
        }
        let newBody = text.substring(with: committedBody)

        var existingBody = text.lineRange(for: NSRange(location: existingStart, length: 0))
        if existingBody.length > 0,
           text.character(at: NSMaxRange(existingBody) - 1) == 0x0A {
            existingBody.length -= 1
        }

        let um = textView.undoManager
        um?.beginUndoGrouping()
        defer { um?.endUndoGrouping() }

        // Edit the later range first so the earlier offsets stay valid.
        var finalBodyStart = existingBody.location
        if committedFull.location > existingBody.location {
            textView.insertText("", replacementRange: committedFull)
            textView.insertText(newBody, replacementRange: existingBody)
        } else {
            textView.insertText(newBody, replacementRange: existingBody)
            textView.insertText("", replacementRange: committedFull)
            finalBodyStart -= committedFull.length
        }

        let eol = finalBodyStart + (newBody as NSString).length
        textView.setSelectedRange(NSRange(location: eol, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    /// Rewrites the committed line's number to the nearest free slot above
    /// it, then re-runs arrangement so it moves into position. If no slot
    /// exists, informs the user and leaves the line as typed.
    private func renumberCommittedLine(at committedStart: Int) {
        let lines = BasicRenumber.parseLines(textView.string)
        guard let committed = lines.first(where: { $0.range.location == committedStart }) else {
            return
        }
        let n = committed.lineNumber

        // Smallest number above n among the OTHER lines bounds the free slot.
        let following = lines
            .filter { $0.range.location != committedStart }
            .map(\.lineNumber)
            .filter { $0 > n }
            .min()

        guard let newNum = BasicRenumber.nextLineNumber(after: n, beforeLine: following) else {
            let alert = NSAlert()
            alert.messageText = "No room after line \(n)"
            alert.informativeText = "There is no free line number between \(n) and "
                + "\(following.map(String.init) ?? "the end of the program")"
                + ". Run Renumber to open up gaps, then re-enter the line."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            if let window = view.window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
            return
        }

        // Replace the digit run at the start of the line with the new number.
        let text = textView.string as NSString
        let fullLine = text.lineRange(for: NSRange(location: committedStart, length: 0))
        var digitStart = fullLine.location
        while digitStart < NSMaxRange(fullLine) {
            let c = text.character(at: digitStart)
            if c == 0x20 || c == 0x09 { digitStart += 1 } else { break }
        }
        var digitEnd = digitStart
        while digitEnd < NSMaxRange(fullLine) {
            let c = text.character(at: digitEnd)
            if c >= 0x30 && c <= 0x39 { digitEnd += 1 } else { break }
        }
        guard digitEnd > digitStart else { return }

        let um = textView.undoManager
        um?.beginUndoGrouping()
        defer { um?.endUndoGrouping() }

        textView.insertText("\(newNum)",
                            replacementRange: NSRange(location: digitStart,
                                                      length: digitEnd - digitStart))

        // The renumbered line is unique by construction (newNum lies strictly
        // between n and its successor) but may still be out of position.
        // Its start offset is unchanged: only the digits were replaced.
        performAutoArrange(lineStart: committedStart)
    }

    /// After a line has been arranged, offer the same auto-number
    /// continuation the normal Return path provides — computed against the
    /// line's NEW neighbours. Inserts "\n<n> " at the caret when a number
    /// fits; otherwise leaves the caret at the end of the line.
    private func continueNumbering(afterLineAt lineStart: Int) {
        let lines = BasicRenumber.parseLines(textView.string)
        guard let idx = lines.firstIndex(where: { $0.range.location == lineStart }) else { return }
        let nextLine = idx + 1 < lines.count ? lines[idx + 1].lineNumber : nil
        guard let n = BasicRenumber.nextLineNumber(after: lines[idx].lineNumber,
                                                   beforeLine: nextLine) else { return }
        // Never exactly "\n", so the Return-key delegate path can't recurse.
        textView.insertText("\n\(n) ", replacementRange: textView.selectedRange())
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

