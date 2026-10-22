// MARK: - EditorViewController+Completion.swift
//
// The opt-in code completion popup. Candidates come from
// CodeCompletionProvider (offline and deterministic: dialect keywords,
// in-file variables and line numbers for BASIC; mnemonics, directives,
// labels and ROM symbols for assembly) and are shown in a
// CodeCompletionPanel under the caret. Nothing reaches the text storage
// until an entry is accepted: moving through the list never inserts
// provisional text, Escape leaves the document as it was, and accepting
// inserts the word alone through the normal insertText path, so
// auto-numbering and shortcut expansion (which hang off Return) are
// unaffected.

import Cocoa

extension EditorViewController {

    // MARK: - Setting

    /// UserDefaults key for the View > Code Completion toggle. Off until the
    /// user switches it on.
    static let codeCompletionDefaultsKey = "CodeCompletionEnabled"

    /// Posted after the toggle changes.
    static let codeCompletionSettingDidChange =
        Notification.Name("C64IDE.codeCompletionSettingDidChange")

    static var codeCompletionEnabled: Bool {
        get { UserDefaults.standard.object(forKey: codeCompletionDefaultsKey) as? Bool ?? false }
        set {
            UserDefaults.standard.set(newValue, forKey: codeCompletionDefaultsKey)
            NotificationCenter.default.post(name: codeCompletionSettingDidChange, object: nil)
        }
    }

    /// Pause after the last typed character before the list appears.
    static let automaticCompletionDelay: TimeInterval = 0.25

    // MARK: - Edit tracking

    /// Called at the top of `textView(_:shouldChangeTextIn:replacementString:)`
    /// for every edit. Any edit cancels a pending automatic popup; a single
    /// typed identifier character arms the next one.
    func noteEditForCompletion(range: NSRange, replacement: String?) {
        completionWorkItem?.cancel()
        completionWorkItem = nil
        completionEditInProgress = true
        lastEditWasTyping = false
        guard range.length == 0, let replacement, replacement.utf16.count == 1,
              let scalar = replacement.unicodeScalars.first else { return }
        lastEditWasTyping = Self.completionTriggerCharacters.contains(scalar)
    }

    /// Characters that can extend a completable word: identifier characters
    /// of either language plus the leading '.' / '@' of assembly words.
    private static let completionTriggerCharacters: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "$%#_.@")
        return set
    }()

    /// NSTextDelegate: fires after the storage changed. With the list open,
    /// re-filters it for the new word at once; otherwise schedules the
    /// automatic popup when the edit was a typed character.
    func textDidChange(_ notification: Notification) {
        let typed = lastEditWasTyping
        lastEditWasTyping = false
        completionEditInProgress = false
        guard Self.codeCompletionEnabled else { hideCompletions(); return }
        if completionPanel?.isVisible == true {
            presentCompletions(trigger: .automatic)
        } else if typed {
            scheduleAutomaticCompletion()
        }
    }

    /// Called from textViewDidChangeSelection: the list only makes sense
    /// while the caret sits at the end of the word it was built for. The
    /// caret also moves as part of every edit; those moves are skipped
    /// because textDidChange re-filters the list for the new word.
    func completionSelectionDidChange() {
        guard !completionEditInProgress,
              let panel = completionPanel, panel.isVisible,
              let pending = pendingCompletion, let textView else { return }
        if textView.selectedRange() != NSRange(location: NSMaxRange(pending.range), length: 0) {
            hideCompletions()
        }
    }

    private func scheduleAutomaticCompletion() {
        guard let textView else { return }
        let caret = textView.selectedRange()
        guard caret.length == 0 else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self, let textView = self.textView,
                  textView.selectedRange() == caret,
                  textView.window?.firstResponder === textView else { return }
            self.presentCompletions(trigger: .automatic)
        }
        completionWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.automaticCompletionDelay, execute: item)
    }

    // MARK: - Showing the list

    /// Control-Space, F5 and Option-Escape: open the list for the word at
    /// the caret, beeping when there is nothing to offer.
    func requestManualCompletion() {
        guard Self.codeCompletionEnabled else { return }
        if !presentCompletions(trigger: .manual) { NSSound.beep() }
    }

    /// Computes the completions for the word at the caret and shows or
    /// updates the list. Returns false (and hides the list) when there is
    /// nothing to show.
    @discardableResult
    private func presentCompletions(trigger: CodeCompletionProvider.Trigger) -> Bool {
        completionWorkItem?.cancel()
        completionWorkItem = nil
        guard Self.codeCompletionEnabled, let textView, let window = textView.window,
              let result = computeCompletions(trigger: trigger) else {
            hideCompletions()
            return false
        }
        pendingCompletion = result

        let panel = completionPanel ?? makeCompletionPanel()
        let anchorRect = textView.firstRect(forCharacterRange: NSRange(location: result.range.location, length: 0),
                                            actualRange: nil)
        let lineHeight = max(anchorRect.height, textView.font?.pointSize ?? 12)
        panel.show(items: result.items,
                   anchor: NSPoint(x: anchorRect.minX, y: anchorRect.minY),
                   lineHeight: lineHeight,
                   font: textView.font ?? SyntaxHighlighter.codeFont,
                   parent: window)
        return true
    }

    private func computeCompletions(trigger: CodeCompletionProvider.Trigger) -> CodeCompletionProvider.Result? {
        guard let textView else { return nil }
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return nil }
        let request = CodeCompletionProvider.Request(
            source: textView.string,
            cursor: selection.location,
            fileType: document.fileType,
            dialect: BasicDialectManager.shared.activeDialect,
            variables: latestVariables.map(CodeCompletionProvider.Variable.init))
        return CodeCompletionProvider.complete(request, trigger: trigger)
    }

    private func makeCompletionPanel() -> CodeCompletionPanel {
        let panel = CodeCompletionPanel()
        panel.onAccept = { [weak self] item in self?.acceptCompletion(item) }
        completionPanel = panel

        // Anything that moves the text out from under the list closes it.
        let center = NotificationCenter.default
        if let clipView = textView?.enclosingScrollView?.contentView {
            center.addObserver(self, selector: #selector(completionContextDidChange(_:)),
                               name: NSView.boundsDidChangeNotification, object: clipView)
        }
        if let window = textView?.window {
            center.addObserver(self, selector: #selector(completionContextDidChange(_:)),
                               name: NSWindow.didResignKeyNotification, object: window)
            center.addObserver(self, selector: #selector(completionContextDidChange(_:)),
                               name: NSWindow.didMoveNotification, object: window)
            center.addObserver(self, selector: #selector(completionContextDidChange(_:)),
                               name: NSWindow.didResizeNotification, object: window)
        }
        center.addObserver(self, selector: #selector(completionContextDidChange(_:)),
                           name: NSApplication.didResignActiveNotification, object: nil)
        return panel
    }

    @objc private func completionContextDidChange(_ note: Notification) {
        hideCompletions()
    }

    /// Closes the list and forgets the pending result.
    func hideCompletions() {
        completionWorkItem?.cancel()
        completionWorkItem = nil
        pendingCompletion = nil
        completionPanel?.hide()
    }

    /// Keys the open list claims (arrows, Return, Tab, Escape); everything
    /// else is typing and goes to the text view.
    func handleCompletionKey(_ event: NSEvent) -> Bool {
        guard let panel = completionPanel, panel.isVisible else { return false }
        return panel.handle(event)
    }

    /// Replaces the partial word with the accepted entry. Goes through
    /// insertText so the change is undoable and reaches the document like
    /// any other edit; the replacement is never "\n", so the Return-key
    /// path in shouldChangeTextIn stays out of it.
    private func acceptCompletion(_ item: CodeCompletion) {
        guard let textView, let pending = pendingCompletion else { hideCompletions(); return }
        let range = pending.range
        hideCompletions()
        let length = (textView.string as NSString).length
        guard range.location >= 0, NSMaxRange(range) <= length else { return }
        textView.insertText(item.text, replacementRange: range)
    }
}
