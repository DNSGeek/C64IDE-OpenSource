import Cocoa

// MARK: - Bottom Panel Tabs

/// Enum representing the available tabs in the bottom panel.
enum BottomPanelTab: Int, CaseIterable {
    case build = 0
    case messages = 1
    case search = 2
    case claude = 3

    var title: String {
        switch self {
        case .build:    return "Build"
        case .messages: return "Messages"
        case .search:   return "Search"
        case .claude:   return "Claude"
        }
    }
}

// MARK: - Message Type

/// Represents the severity/context of a log message for theming purposes.
enum MessageType {
    case plain
    case info
    case warning
    case error
    case success
    case command    // Shell command echo — e.g. "ca65 --target c64 -o foo.o foo.s"

    var color: NSColor {
        let t = AppTheme.current
        switch self {
        case .plain:   return t.logPlain
        case .info:    return t.logInfo
        case .warning: return t.logWarning
        case .error:   return t.logError
        case .success: return t.logSuccess
        case .command: return t.logCommand
        }
    }
}

// MARK: - Search Match

/// Represents a single find hit, carrying enough information to navigate to it and optionally replace it.
struct SearchMatch {
    let tabIndex: Int           // Index into the editor list provided by `onSearchRequested`
    let displayName: String     // Tab/file name for status display
    let lineNumber: Int         // 1-based line number
    let documentOffset: Int     // Character offset of the match within the document
    let matchLength: Int        // Length of the matched text
}

// MARK: - Bottom Panel Controller

/// Manages the IDE's bottom panel, including build output, log messages, and a find/replace system.
/// Layout strategy: Views are positioned using Auto Layout constraints for responsiveness.
class BottomPanelController: NSViewController, NSTextFieldDelegate {

    private var tabView: NSTabView!

    // Build output
    private var buildTextView: NSTextView!
    private var buildScrollView: NSScrollView!

    // Messages
    private var messagesTextView: NSTextView!
    private var messagesScrollView: NSScrollView!

    // Search / Replace UI
    private var scopeControl: NSSegmentedControl!
    private var caseSensitiveCheckbox: NSButton!
    private var findField: NSTextField!
    private var prevButton: NSButton!
    private var nextButton: NSButton!
    private var statusLabel: NSTextField!
    private var replaceField: NSTextField!
    private var replaceButton: NSButton!
    private var replaceAllButton: NSButton!

    /// Controller for the Claude AI integration tab.
    private(set) var claudeTabController: ClaudeTabController!

    // Search state
    private var matches: [SearchMatch] = []
    private var currentMatchIndex: Int = 0

    /// Determines whether search is scoped to the current tab only.
    private var searchScopeCurrentOnly: Bool { scopeControl?.selectedSegment == 0 }

    // MARK: - Callbacks (wired by MainWindowController)

    /// Called when the user presses Enter in the build output text field.
    var onCommandEntered: ((String) -> Void)?

    /// Called when the user clicks a highlighted error/warning line. Passes the source line number.
    var onErrorClicked: ((Int) -> Void)?

    /// Provides content to search across tabs. Returns an array of (tabIndex, displayName, content).
    var onSearchRequested: ((_ currentOnly: Bool) -> [(tabIndex: Int, name: String, content: String)])?

    /// Navigates the editor to a specific tab and highlights a character range.
    var onNavigateToMatch: ((_ tabIndex: Int, _ range: NSRange) -> Void)?

    /// Applies a single replacement in a specific tab (provides the full new document content).
    var onReplaceRequested: ((_ tabIndex: Int, _ newContent: String) -> Void)?

    /// Applies multiple replacements across one or more tabs.
    var onReplaceAllRequested: ((_ replacements: [(tabIndex: Int, newContent: String)]) -> Void)?

    // MARK: - Private constants

    private var bgColor: NSColor { AppTheme.current.panelBackground }
    private let textFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private static let errorLineAttrKey = NSAttributedString.Key("c64ide.errorLine")

    // MARK: - Lifecycle

    override func loadView() {
        self.view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = bgColor.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupTabView()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange(_:)),
            name: .appThemeDidChange, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Theme

    @objc private func themeDidChange(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.view.window != nil else { return }
            let bg   = AppTheme.current.panelBackground
            let text = AppTheme.current.panelText
            self.view.layer?.backgroundColor = bg.cgColor
            // Build tab
            self.buildTextView.backgroundColor  = bg
            self.buildTextView.textColor        = text
            self.buildScrollView.backgroundColor = bg
            // Messages tab
            self.messagesTextView.backgroundColor  = bg
            self.messagesTextView.textColor        = text
            self.messagesScrollView.backgroundColor = bg
            self.view.subviews.forEach { $0.needsDisplay = true }
        }
    }

    // MARK: - Tab View Setup

    private func setupTabView() {
        tabView = NSTabView(frame: .zero)
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.tabViewType = .topTabsBezelBorder
        tabView.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)

        tabView.addTabViewItem(makeBuildTab())
        tabView.addTabViewItem(makeMessagesTab())
        tabView.addTabViewItem(makeSearchTab())
        tabView.addTabViewItem(makeClaudeTab())

        view.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: view.topAnchor, constant: 2),
            tabView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            tabView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            tabView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -2),
        ])

        appendMessage("C64 IDE initialized. Ready.", type: .success)
        setupBuildClickHandler()
    }

    // MARK: - Tab Factories

    private func makeBuildTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "Build")
        item.label = "Build"

        buildTextView = createOutputTextView()
        buildScrollView = NSScrollView()
        buildScrollView.documentView = buildTextView
        buildScrollView.hasVerticalScroller = true
        buildScrollView.autohidesScrollers = true
        buildScrollView.borderType = .noBorder
        buildScrollView.backgroundColor = bgColor
        buildScrollView.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(buildScrollView)
        NSLayoutConstraint.activate([
            buildScrollView.topAnchor.constraint(equalTo: container.topAnchor),
            buildScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            buildScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            buildScrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        item.view = container
        return item
    }

    private func makeMessagesTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "Messages")
        item.label = "Messages"

        messagesTextView = createOutputTextView()
        messagesScrollView = NSScrollView()
        messagesScrollView.documentView = messagesTextView
        messagesScrollView.hasVerticalScroller = true
        messagesScrollView.autohidesScrollers = true
        messagesScrollView.borderType = .noBorder
        messagesScrollView.backgroundColor = bgColor
        messagesScrollView.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(messagesScrollView)
        NSLayoutConstraint.activate([
            messagesScrollView.topAnchor.constraint(equalTo: container.topAnchor),
            messagesScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            messagesScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            messagesScrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        item.view = container
        return item
    }

    private func makeSearchTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "Search")
        item.label = "Search"
        item.view = buildSearchPanel()
        return item
    }

    private func makeClaudeTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "Claude")
        item.label = "Claude"

        claudeTabController = ClaudeTabController()
        addChild(claudeTabController)
        claudeTabController.view.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(claudeTabController.view)
        NSLayoutConstraint.activate([
            claudeTabController.view.topAnchor.constraint(equalTo: container.topAnchor),
            claudeTabController.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            claudeTabController.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            claudeTabController.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        item.view = container
        return item
    }

    // MARK: - Search Panel Layout

    private func buildSearchPanel() -> NSView {
        let container = NSView()
        let pad: CGFloat  = 6
        let rowH: CGFloat = 22

        // ── Row 1: Scope segmented control + case-sensitive checkbox ──────
        scopeControl = NSSegmentedControl(
            labels: ["Current Tab", "All Tabs"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(scopeChanged)
        )
        scopeControl.selectedSegment = 0
        scopeControl.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        scopeControl.translatesAutoresizingMaskIntoConstraints = false

        caseSensitiveCheckbox = NSButton(
            checkboxWithTitle: "Case Sensitive",
            target: self,
            action: #selector(searchOptionsChanged)
        )
        caseSensitiveCheckbox.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        caseSensitiveCheckbox.translatesAutoresizingMaskIntoConstraints = false

        // ── Row 2: Find field | status label | ◀ ▶ ──────────────────────
        findField = makeTextField(placeholder: "Find…")
        findField.target = self
        findField.action = #selector(findReturnPressed)
        findField.delegate = self

        prevButton = makeSymbolButton(systemName: "chevron.left",  tip: "Previous match (⇧↩)", action: #selector(prevMatch))
        nextButton = makeSymbolButton(systemName: "chevron.right", tip: "Next match (↩)",       action: #selector(nextMatch))

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        statusLabel.textColor = AppTheme.current.statusLabel
        statusLabel.alignment = .right
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        // ── Row 3: Replace field | Replace | Replace All ─────────────────
        replaceField    = makeTextField(placeholder: "Replace…")
        replaceButton    = makeActionButton(title: "Replace",     action: #selector(replaceNextTapped))
        replaceAllButton = makeActionButton(title: "Replace All", action: #selector(replaceAllTapped))

        let elements: [NSView] = [
            scopeControl!, caseSensitiveCheckbox!,
            findField!, prevButton!, nextButton!, statusLabel!,
            replaceField!, replaceButton!, replaceAllButton!
        ]
        elements.forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview($0)
        }

        NSLayoutConstraint.activate([
            // Row 1
            scopeControl.topAnchor.constraint(equalTo: container.topAnchor, constant: pad),
            scopeControl.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: pad),
            scopeControl.heightAnchor.constraint(equalToConstant: rowH),

            caseSensitiveCheckbox.centerYAnchor.constraint(equalTo: scopeControl.centerYAnchor),
            caseSensitiveCheckbox.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -pad),

            // Row 2
            nextButton.topAnchor.constraint(equalTo: scopeControl.bottomAnchor, constant: pad),
            nextButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -pad),
            nextButton.widthAnchor.constraint(equalToConstant: 28),
            nextButton.heightAnchor.constraint(equalToConstant: rowH),

            prevButton.centerYAnchor.constraint(equalTo: nextButton.centerYAnchor),
            prevButton.trailingAnchor.constraint(equalTo: nextButton.leadingAnchor, constant: -2),
            prevButton.widthAnchor.constraint(equalToConstant: 28),
            prevButton.heightAnchor.constraint(equalToConstant: rowH),

            statusLabel.centerYAnchor.constraint(equalTo: nextButton.centerYAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: prevButton.leadingAnchor, constant: -6),
            statusLabel.widthAnchor.constraint(equalToConstant: 100),

            findField.topAnchor.constraint(equalTo: scopeControl.bottomAnchor, constant: pad),
            findField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: pad),
            findField.trailingAnchor.constraint(equalTo: statusLabel.leadingAnchor, constant: -6),
            findField.heightAnchor.constraint(equalToConstant: rowH),

            // Row 3
            replaceAllButton.topAnchor.constraint(equalTo: findField.bottomAnchor, constant: pad),
            replaceAllButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -pad),
            replaceAllButton.widthAnchor.constraint(equalToConstant: 90),
            replaceAllButton.heightAnchor.constraint(equalToConstant: rowH),

            replaceButton.centerYAnchor.constraint(equalTo: replaceAllButton.centerYAnchor),
            replaceButton.trailingAnchor.constraint(equalTo: replaceAllButton.leadingAnchor, constant: -4),
            replaceButton.widthAnchor.constraint(equalToConstant: 72),
            replaceButton.heightAnchor.constraint(equalToConstant: rowH),

            replaceField.topAnchor.constraint(equalTo: findField.bottomAnchor, constant: pad),
            replaceField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: pad),
            replaceField.trailingAnchor.constraint(equalTo: replaceButton.leadingAnchor, constant: -6),
            replaceField.heightAnchor.constraint(equalToConstant: rowH),
        ])

        return container
    }

    // MARK: - Widget Factories

    private func makeTextField(placeholder: String) -> NSTextField {
        let f = NSTextField()
        f.placeholderString = placeholder
        f.font = textFont
        f.appearance = AppTheme.current.nsAppearance
        f.isBordered = true
        f.bezelStyle = .roundedBezel
        f.focusRingType = .none
        return f
    }

    private func makeSymbolButton(systemName: String, tip: String, action: Selector) -> NSButton {
        let b = NSButton(title: "", target: self, action: action)
        b.image = NSImage(systemSymbolName: systemName, accessibilityDescription: tip)
        b.bezelStyle = .rounded
        b.toolTip = tip
        return b
    }

    private func makeActionButton(title: String, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        return b
    }

    private func createOutputTextView() -> NSTextView {
        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.backgroundColor = bgColor
        tv.textColor = AppTheme.current.panelText
        tv.font = textFont
        tv.textContainerInset = NSSize(width: 8, height: 4)
        tv.isAutomaticSpellingCorrectionEnabled = false
        return tv
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        guard findField === obj.object as? NSTextField else { return }
        // Any edit to the find field invalidates the current match list
        matches = []
        currentMatchIndex = 0
        let query = findField.stringValue.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            setStatus("")
        } else {
            setStatus("↩ to search")
        }
    }

    // MARK: - Scope / Options

    @objc private func scopeChanged() {
        invalidateAndRefind()
    }

    @objc private func searchOptionsChanged() {
        invalidateAndRefind()
    }

    /// Invalidates the current match list and re-runs find if a query is present.
    private func invalidateAndRefind() {
        matches = []
        currentMatchIndex = 0
        let query = findField?.stringValue.trimmingCharacters(in: .whitespaces) ?? ""
        if !query.isEmpty {
            performFind(restoreIndex: false)
        } else {
            setStatus("")
        }
    }

    // MARK: - Find Core

    @objc private func findReturnPressed() {
        let query = findField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }

        if matches.isEmpty {
            // First search — build the list and land on match 0
            performFind(restoreIndex: false)
        } else {
            // Subsequent Enter → move forward
            stepMatch(by: +1)
        }
    }

    @objc private func nextMatch() { stepMatch(by: +1) }
    @objc private func prevMatch() { stepMatch(by: -1) }

    /// Builds (or rebuilds) the match list by searching across provided sources.
    /// - Parameter restoreIndex: If true, clamps the existing index to the new count; otherwise resets to 0.
    private func performFind(restoreIndex: Bool) {
        let query = findField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { setStatus(""); matches = []; return }

        guard let sources = onSearchRequested?(searchScopeCurrentOnly) else {
            setStatus("Unavailable"); return
        }

        let caseSensitive = caseSensitiveCheckbox.state == .on
        let options: String.CompareOptions = caseSensitive ? [] : .caseInsensitive

        var found: [SearchMatch] = []

        for source in sources {
            let content = source.content
            var searchFrom = content.startIndex
            var lineNumber = 1
            var lineStart  = content.startIndex

            while searchFrom < content.endIndex,
                  let range = content.range(of: query, options: options, range: searchFrom..<content.endIndex) {

                // Advance line counter up to the start of this match
                var cursor = lineStart
                while cursor < range.lowerBound {
                    if content[cursor] == "\n" {
                        lineNumber += 1
                        lineStart = content.index(after: cursor)
                    }
                    cursor = content.index(after: cursor)
                }

                let docOffset = content.distance(from: content.startIndex, to: range.lowerBound)
                let matchLen  = content.distance(from: range.lowerBound, to: range.upperBound)

                found.append(SearchMatch(
                    tabIndex:       source.tabIndex,
                    displayName:    source.name,
                    lineNumber:     lineNumber,
                    documentOffset: docOffset,
                    matchLength:    matchLen
                ))

                searchFrom = range.upperBound
            }
        }

        matches = found

        if found.isEmpty {
            currentMatchIndex = 0
            setStatus("No results")
            return
        }

        currentMatchIndex = restoreIndex ? min(currentMatchIndex, found.count - 1) : 0
        navigateToCurrentMatch()
    }

    private func stepMatch(by delta: Int) {
        guard !matches.isEmpty else {
            performFind(restoreIndex: false)
            return
        }
        currentMatchIndex = (currentMatchIndex + delta + matches.count) % matches.count
        navigateToCurrentMatch()
    }

    private func navigateToCurrentMatch() {
        guard !matches.isEmpty else { return }
        let match = matches[currentMatchIndex]
        let range = NSRange(location: match.documentOffset, length: match.matchLength)
        onNavigateToMatch?(match.tabIndex, range)
        updateStatus()
    }

    private func updateStatus() {
        guard !matches.isEmpty else { setStatus("No results"); return }
        let match = matches[currentMatchIndex]
        if searchScopeCurrentOnly {
            setStatus("\(currentMatchIndex + 1) of \(matches.count)")
        } else {
            setStatus("\(match.displayName): \(currentMatchIndex + 1) of \(matches.count)")
        }
    }

    private func setStatus(_ text: String) {
        statusLabel?.stringValue = text
    }

    // MARK: - Replace

    @objc private func replaceNextTapped() {
        let query       = findField.stringValue
        let replacement = replaceField.stringValue
        guard !query.isEmpty else { return }
        guard !matches.isEmpty else { performFind(restoreIndex: false); return }

        let match = matches[currentMatchIndex]

        // Fetch fresh content scoped to the current match's tab
        guard let sources = onSearchRequested?(searchScopeCurrentOnly),
              let source = sources.first(where: { $0.tabIndex == match.tabIndex }) else { return }

        let nsContent  = source.content as NSString
        let matchRange = NSRange(location: match.documentOffset, length: match.matchLength)

        // Validate the range is still within bounds (content may have changed externally)
        guard matchRange.location + matchRange.length <= nsContent.length else {
            invalidateAndRefind(); return
        }

        let newContent = nsContent.replacingCharacters(in: matchRange, with: replacement)
        onReplaceRequested?(match.tabIndex, newContent)

        // Rebuild and stay near the same position
        matches = []
        performFind(restoreIndex: true)
    }

    @objc private func replaceAllTapped() {
        let query       = findField.stringValue.trimmingCharacters(in: .whitespaces)
        let replacement = replaceField.stringValue
        guard !query.isEmpty else { return }

        guard let sources = onSearchRequested?(searchScopeCurrentOnly) else { return }

        let caseSensitive = caseSensitiveCheckbox.state == .on
        let strOptions    = String.CompareOptions(caseSensitive ? [] : [.caseInsensitive])

        var totalCount   = 0
        var replacements: [(tabIndex: Int, newContent: String)] = []

        for source in sources {
            var currentContent = source.content
            var count          = 0
            var searchFrom     = currentContent.startIndex

            // Efficient literal string replacement loop
            while searchFrom < currentContent.endIndex,
                  let range = currentContent.range(of: query, options: strOptions, range: searchFrom..<currentContent.endIndex) {
                count += 1
                currentContent.replaceSubrange(range, with: replacement)
                // Advance past the replacement to avoid infinite loops on empty matches
                let afterReplacement = currentContent.index(range.lowerBound,
                                                            offsetBy: replacement.count,
                                                            limitedBy: currentContent.endIndex) ?? currentContent.endIndex
                searchFrom = afterReplacement
            }

            if count > 0 {
                totalCount += count
                replacements.append((tabIndex: source.tabIndex, newContent: currentContent))
            }
        }

        guard !replacements.isEmpty else { setStatus("No results"); return }

        onReplaceAllRequested?(replacements)

        let tabs = replacements.count
        setStatus("Replaced \(totalCount) in \(tabs) tab\(tabs == 1 ? "" : "s")")
        matches = []
    }

    // MARK: - Build Output

    private func setupBuildClickHandler() {
        let click = NSClickGestureRecognizer(target: self, action: #selector(buildOutputClicked(_:)))
        click.numberOfClicksRequired = 1
        buildTextView.addGestureRecognizer(click)
    }

    @objc private func buildOutputClicked(_ sender: NSClickGestureRecognizer) {
        guard sender.state == .ended else { return }
        let location = sender.location(in: buildTextView)

        guard let layoutManager = buildTextView.layoutManager,
              let textContainer = buildTextView.textContainer else { return }

        // Adjust for text container insets
        let adjustedPoint = NSPoint(
            x: location.x - buildTextView.textContainerInset.width,
            y: location.y - buildTextView.textContainerInset.height
        )
        let charIndex = layoutManager.characterIndex(
            for: adjustedPoint,
            in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: nil
        )
        guard charIndex < buildTextView.textStorage!.length else { return }

        if let lineNum = buildTextView.textStorage?.attribute(
            Self.errorLineAttrKey, at: charIndex, effectiveRange: nil
        ) as? Int {
            onErrorClicked?(lineNum)
        }
    }

    // MARK: - Public API

    /// Appends a formatted message to either the Messages or Build text view.
    func appendMessage(_ text: String, type: MessageType) {
        let tv = messagesTextView ?? buildTextView
        guard let textView = tv, let storage = textView.textStorage else { return }

        let timestamp  = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let fullText   = "[\(timestamp)] \(text)\n"
        let attributed = NSAttributedString(string: fullText, attributes: [
            .font: textFont,
            .foregroundColor: type.color,
        ])
        storage.append(attributed)
        textView.scrollToEndOfDocument(nil)
    }

    /// Appends build output with automatic error/warning highlighting.
    func appendBuildOutput(_ text: String, type: MessageType = .plain) {
        guard let storage = buildTextView.textStorage else { return }

        var attrs: [NSAttributedString.Key: Any] = [
            .font: textFont,
            .foregroundColor: type.color,
        ]
        if (type == .error || type == .warning), let lineNum = parseErrorLine(text) {
            attrs[Self.errorLineAttrKey] = lineNum
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            attrs[.cursor] = NSCursor.pointingHand
        }
        storage.append(NSAttributedString(string: text + "\n", attributes: attrs))
        buildTextView.scrollToEndOfDocument(nil)
    }

    /// Parses common compiler error/warning formats to extract line numbers.
    private func parseErrorLine(_ text: String) -> Int? {
        // Pattern 1: ERROR/WARN/WARNING: <file>:<line>
        if let match = text.firstMatch(of: /(?:ERROR|WARN|WARNING):\s*[^:]+:(\d+)/) {
            return Int(match.1)
        }
        // Pattern 2: <file>(<line>): Error/Warning
        if let match = text.firstMatch(of: /[^(]+\((\d+)\):\s*(?:Error|Warning)/) {
            return Int(match.1)
        }
        // Pattern 3: <file>:<line>:
        if let match = text.firstMatch(of: /[^:]+:(\d+):/) {
            return Int(match.1)
        }
        return nil
    }

    func clearBuildOutput() {
        buildTextView.string = ""
    }

    func selectTab(_ tab: BottomPanelTab) {
        tabView.selectTabViewItem(at: tab.rawValue)
    }

    /// Switches to the Search tab and focuses the Find field.
    func focusFindField() {
        selectTab(.search)
        DispatchQueue.main.async { [weak self] in
            self?.findField?.becomeFirstResponder()
        }
    }
}

