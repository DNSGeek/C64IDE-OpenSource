import Cocoa
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Main Window Controller

/// The primary window controller for the C64 IDE. Manages the main window layout,
/// editor tabs, split views, toolbar, build system integration, and panel coordination.
class MainWindowController: NSWindowController, NSToolbarDelegate {

    // MARK: - Child Controllers

    /// The currently active editor, pointing to the selected tab's editor.
    /// Falls back to the first editor if no tab is selected.
    var editorViewController: EditorViewController! {
        guard let tab = editorTabView?.selectedTabViewItem,
              let editor = tab.viewController as? EditorViewController else {
            return editors.first
        }
        return editor
    }

    private(set) var referencePanelController: ReferencePanelController!
    private(set) var bottomPanelController: BottomPanelController!

    // MARK: - Tab Management

    private(set) var editorTabView: NSTabView!
    private var editors: [EditorViewController] = []
    var allEditors: [EditorViewController] { editors }
    private var tabCounter = 0  // Used to generate unique tab identifiers

    // MARK: - Split Views

    private var outerSplitView: NSSplitView!  // Vertical split: Editor Area | Console
    private var innerSplitView: NSSplitView!  // Horizontal split: Tabs/Editor | Reference Panel

    // MARK: - State

    private var isRightPanelVisible = true
    private var isBottomPanelVisible = true

    // MARK: - Build System

    private(set) var buildConfig: BuildConfiguration!
    private(set) var buildManager: BuildManager!
    private var lastBuildResult: BuildResult?
    private var asmToDataDialog: AsmToDataDialog?

    // MARK: - Layout Constants

    private let editorMinWidth: CGFloat = 400
    private let rightPanelMinWidth: CGFloat = 280
    private let rightPanelDefaultWidth: CGFloat = 380
    private let topMinHeight: CGFloat = 300
    private let bottomMinHeight: CGFloat = 100
    private let bottomDefaultHeight: CGFloat = 160

    private var bgColor: NSColor { AppTheme.current.editorBackground }

    // MARK: - Init

    /// Initializes the main IDE window, sets up the toolbar, split views, and default document.
    convenience init() {
        let windowRect = NSRect(x: 0, y: 0, width: 1280, height: 820)
        let window = NSWindow(
            contentRect: windowRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "C64 IDE"
        window.center()
        window.minSize = NSSize(width: 800, height: 500)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = AppTheme.current.editorBackground

        self.init(window: window)
        window.delegate = self

        setupBuildSystem()
        setupToolbar()
        setupSplitViews()
        loadDefaultDocument()
    }

    // MARK: - Build System Setup

    private func setupBuildSystem() {
        buildConfig = BuildConfiguration.load()
        buildConfig.autoDetect()
        buildManager = BuildManager(config: buildConfig)

        // Forward build output to the console panel
        buildManager.onOutput = { [weak self] message, type in
            DispatchQueue.main.async {
                self?.bottomPanelController.appendBuildOutput(message, type: type)
            }
        }
        
        // Handle build completion
        buildManager.onBuildComplete = { [weak self] result in
            DispatchQueue.main.async {
                self?.lastBuildResult = result
                let msgType: MessageType = result.success ? .success : .error
                self?.bottomPanelController.appendMessage(result.summaryString, type: msgType)
            }
        }
    }

    // MARK: - Split View Setup

    private func setupSplitViews() {
        guard let window = window, let contentView = window.contentView else { return }

        let contentRect = window.contentLayoutRect
        let width = contentRect.width > 0 ? contentRect.width : 1280
        let height = contentRect.height > 0 ? contentRect.height : 780

        // ── Create shared controllers ─────────────────────────
        referencePanelController = ReferencePanelController()
        bottomPanelController = BottomPanelController()

        // Wire error click-to-navigate
        bottomPanelController.onErrorClicked = { [weak self] lineNum in
            self?.navigateToLine(lineNum)
        }

        // Provide document content for search/replacement operations
        bottomPanelController.onSearchRequested = { [weak self] currentOnly in
            guard let self = self else { return [] }
            if currentOnly {
                guard let editor = self.editorViewController,
                      let idx = self.allEditors.firstIndex(where: { $0 === editor }) else { return [] }
                return [(tabIndex: idx,
                         name: editor.document.displayTitle,
                         content: editor.document.content)]
            } else {
                return self.allEditors.enumerated().map { idx, editor in
                    (tabIndex: idx,
                     name: editor.document.displayTitle,
                     content: editor.document.content)
                }
            }
        }

        // Navigate to a match: switch tab if needed, select & flash the exact character range
        bottomPanelController.onNavigateToMatch = { [weak self] tabIndex, range in
            guard let self = self else { return }
            let currentIdx = self.allEditors.firstIndex(where: { $0 === self.editorViewController })
            if tabIndex != currentIdx {
                self.editorTabView.selectTabViewItem(at: tabIndex)
            }
            guard tabIndex < self.allEditors.count else { return }
            let editor   = self.allEditors[tabIndex]
            let textView = editor.textView
            textView?.setSelectedRange(range)
            textView?.scrollRangeToVisible(range)
            textView?.showFindIndicator(for: range)   // System yellow flash
        }

        // Replace a single occurrence (full new content for the tab)
        bottomPanelController.onReplaceRequested = { [weak self] tabIndex, newContent in
            guard let self = self, tabIndex < self.allEditors.count else { return }
            let editor = self.allEditors[tabIndex]
            editor.document.content    = newContent
            editor.document.isModified = true
            editor.loadDocument(editor.document)
            self.updateWindowTitle()
        }

        // Replace all occurrences across one or more tabs
        bottomPanelController.onReplaceAllRequested = { [weak self] replacements in
            guard let self = self else { return }
            for replacement in replacements {
                guard replacement.tabIndex < self.allEditors.count else { continue }
                let editor = self.allEditors[replacement.tabIndex]
                editor.document.content    = replacement.newContent
                editor.document.isModified = true
                editor.loadDocument(editor.document)
            }
            self.updateWindowTitle()
        }

        // ── Create tab view for editors ───────────────────────
        editorTabView = NSTabView()
        editorTabView.tabViewType = .topTabsBezelBorder
        editorTabView.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        editorTabView.delegate = self
        editorTabView.allowsTruncatedLabels = true

        // Create initial tab
        addNewTab(with: nil)

        // ── Calculate initial sizes ──────────────────────────
        let topHeight = height - bottomDefaultHeight
        let editorWidth = width - rightPanelDefaultWidth

        // ── Inner split (horizontal): Tabs+Editor | Reference ──
        innerSplitView = NSSplitView(frame: NSRect(x: 0, y: 0, width: width, height: topHeight))
        innerSplitView.isVertical = true
        innerSplitView.dividerStyle = .thin
        innerSplitView.delegate = self
        innerSplitView.autoresizingMask = [.width, .height]

        editorTabView.frame = NSRect(x: 0, y: 0, width: editorWidth, height: topHeight)

        let referenceView = referencePanelController.view
        referenceView.frame = NSRect(x: editorWidth, y: 0, width: rightPanelDefaultWidth, height: topHeight)

        innerSplitView.addArrangedSubview(editorTabView)
        innerSplitView.addArrangedSubview(referenceView)
        innerSplitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        innerSplitView.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        innerSplitView.adjustSubviews()
        innerSplitView.setPosition(editorWidth, ofDividerAt: 0)

        // ── Outer split (vertical): Top | Bottom ─────────────
        outerSplitView = NSSplitView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        outerSplitView.isVertical = false
        outerSplitView.dividerStyle = .thin
        outerSplitView.delegate = self
        outerSplitView.autoresizingMask = [.width, .height]

        innerSplitView.frame = NSRect(x: 0, y: bottomDefaultHeight, width: width, height: topHeight)

        let bottomView = bottomPanelController.view
        bottomView.frame = NSRect(x: 0, y: 0, width: width, height: bottomDefaultHeight)

        // Ensure bottom panel's Claude context provider is ready for injection
        bottomPanelController.claudeTabController.contextProvider = self

        // Handle Claude-generated code snippets
        bottomPanelController.claudeTabController.onOpenInNewTab = { [weak self] code, fileType in
            guard let self else { return }
            let doc = C64Document(fileType: fileType, content: code)
            let ext = fileType == .assembly ? "asm" : "bas"
            doc.customTitle = "claude_snippet.\(ext)"
            self.addNewTab(with: doc)
        }

        outerSplitView.addArrangedSubview(innerSplitView)
        outerSplitView.addArrangedSubview(bottomView)
        outerSplitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        outerSplitView.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        outerSplitView.adjustSubviews()
        outerSplitView.setPosition(topHeight, ofDividerAt: 0)

        contentView.addSubview(outerSplitView)
        contentView.frame = NSRect(x: 0, y: 0, width: width, height: height)

        // Force positions again after a layout pass to avoid initial sizing glitches
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.outerSplitView.setPosition(topHeight, ofDividerAt: 0)
            self.innerSplitView.setPosition(editorWidth, ofDividerAt: 0)
        }
    }

    // MARK: - Tab Management

    /// Creates a new editor tab with an optional document.
    @discardableResult
    func addNewTab(with document: C64Document?) -> EditorViewController {
        tabCounter += 1
        let editor = EditorViewController()

        // Wire editor callbacks to the reference panel
        wireEditorCallbacks(editor)

        let doc = document ?? C64Document(fileType: .basic, content: "")
        editor.loadDocument(doc)

        let tabItem = NSTabViewItem(identifier: "tab_\(tabCounter)")
        tabItem.label = doc.displayTitle
        tabItem.viewController = editor

        editors.append(editor)
        editorTabView.addTabViewItem(tabItem)
        editorTabView.selectTabViewItem(tabItem)

        updateWindowTitle()
        refreshDiskHint()
        return editor
    }

    /// Connects an editor's context callbacks to the reference panel and UI updates.
    private func wireEditorCallbacks(_ editor: EditorViewController) {
        editor.onWordUnderCursor = { [weak self] word, fileType in
            self?.referencePanelController.highlightEntry(for: word, fileType: fileType)
        }
        editor.onAddressUnderCursor = { [weak self] address in
            self?.referencePanelController.showMemoryMapEntry(for: address)
        }
        editor.onDocumentModified = { [weak self] in
            self?.updateWindowTitle()
        }
        // Refresh the tab label and title bar after a silent external-change reload
        editor.onExternalReload = { [weak self] in
            self?.updateWindowTitle()
            self?.refreshDiskHint()
        }
        refreshDiskHint()
    }

    /// Closes the active tab, prompting to save unsaved changes if necessary.
    func closeActiveTab() {
        guard let selectedItem = editorTabView.selectedTabViewItem,
              let editor = selectedItem.viewController as? EditorViewController else { return }

        // Check for unsaved changes
        if editor.document.isModified {
            let alert = NSAlert()
            alert.messageText = "Save changes to \"\(editor.document.displayTitle)\"?"
            alert.informativeText = "Your changes will be lost if you don't save them."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Don't Save")
            alert.addButton(withTitle: "Cancel")

            let response = alert.runModal()
            switch response {
            case .alertFirstButtonReturn:
                editor.saveDocument()
            case .alertSecondButtonReturn:
                break  // Discard
            default:
                return  // Cancel — don't close
            }
        }

        // If this is the last tab, create a new empty one first to prevent empty window
        if editors.count <= 1 {
            addNewTab(with: nil)
        }

        // Remove the tab
        if let idx = editors.firstIndex(where: { $0 === editor }) {
            editors.remove(at: idx)
        }
        editorTabView.removeTabViewItem(selectedItem)
        updateWindowTitle()
        refreshDiskHint()
    }

    // MARK: - Default Document

    /// Loads a sample BASIC program on first launch if enabled in settings.
    private func loadDefaultDocument() {
        let showExample = UserDefaults.standard.object(forKey: "showExampleOnLaunch") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "showExampleOnLaunch")
        guard showExample else { return }
        
        let sampleBasic = [
            "10 REM ══════════════════════════════",
            "20 REM  WELCOME TO C64 IDE",
            "30 REM ══════════════════════════════",
            "40 PRINT CHR$(147) : REM CLEAR SCREEN",
            "50 POKE 53280,0 : POKE 53281,0",
            "60 POKE 646,1 : REM WHITE TEXT",
            "70 PRINT \"*** C64 IDE ***\"",
            "80 PRINT",
            "90 FOR I = 0 TO 15",
            "100   POKE 53280,I",
            "110   FOR D = 1 TO 200 : NEXT D",
            "120 NEXT I",
            "130 POKE 53280,0",
            "140 PRINT \"READY.\"",
            "150 GET A$ : IF A$ = \"\" THEN 150",
            "160 END",
        ].joined(separator: "\n")

        let doc = C64Document(fileType: .basic, content: sampleBasic)
        // Load into the existing first tab
        if let editor = editors.first {
            editor.loadDocument(doc)
            editorTabView.selectedTabViewItem?.label = doc.displayTitle
        }
        updateWindowTitle()
        refreshDiskHint()
    }

    // MARK: - Toolbar

    private let toolbarRun = NSToolbarItem.Identifier("run")
    private let toolbarStop = NSToolbarItem.Identifier("stop")
    private let toolbarToggleRef = NSToolbarItem.Identifier("toggleRef")
    private let toolbarToggleBottom = NSToolbarItem.Identifier("toggleBottom")
    private let toolbarGitStatus = NSToolbarItem.Identifier("gitStatus")
    private let toolbarThemeToggle = NSToolbarItem.Identifier("themeToggle")

    // MARK: - Git status dot

    /// The button that lives in the toolbar showing git repo state.
    /// Held strongly so we can update it without going through the toolbar delegate.
    private var gitStatusButton: NSButton?
    private var currentGitStatus: GitStatus = .noRepo

    private func setupToolbar() {
        guard let window = window else { return }
        let toolbar = NSToolbar(identifier: "C64IDEToolbar")
        toolbar.displayMode = .iconAndLabel
        toolbar.delegate = self
        window.toolbar = toolbar
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)

        switch id {
        case toolbarRun:
            item.label = "Run"
            // Tooltip reflects the current target. Re-evaluated each time the
            // toolbar asks for the item (on validation), so it stays accurate.
            let runsInXemu = XemuToolbarController.shouldReplaceViceRun
            item.toolTip = runsInXemu
                ? "Build and run in xemu (xmega65) (⌘R)"
                : "Build and run in VICE (⌘R)"
            item.image = NSImage(
                systemSymbolName: runsInXemu ? "play.rectangle.fill" : "play.fill",
                accessibilityDescription: "Run")
            item.target = self
            item.action = #selector(runProgram(_:))
            
        case toolbarStop:
            item.label = "Stop"
            item.toolTip = "Stop running emulator"
            item.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "Stop")
            item.target = self
            item.action = #selector(stopProgram(_:))
            
        case toolbarToggleRef:
            item.label = "Reference"
            item.toolTip = "Toggle reference panel (⌥⌘R)"
            item.image = NSImage(systemSymbolName: "book.fill", accessibilityDescription: "Reference")
            item.target = self
            item.action = #selector(toggleRightPanel(_:))
            
        case toolbarToggleBottom:
            item.label = "Console"
            item.toolTip = "Toggle bottom panel (⇧⌘Y)"
            item.image = NSImage(systemSymbolName: "rectangle.bottomhalf.filled", accessibilityDescription: "Console")
            item.target = self
            item.action = #selector(toggleBottomPanel(_:))

        case toolbarThemeToggle:
            let isDark = AppTheme.current.isDark
            item.label = isDark ? "Light Mode" : "Dark Mode"
            item.toolTip = isDark ? "Switch to light mode" : "Switch to dark mode"
            item.image = NSImage(
                systemSymbolName: isDark ? "sun.max.fill" : "moon.fill",
                accessibilityDescription: item.label)
            item.target = self
            item.action = #selector(toggleTheme(_:))

        case toolbarGitStatus:
            let btn = NSButton(frame: .zero)
            btn.bezelStyle = .inline
            btn.font = NSFont.systemFont(ofSize: 11)
            btn.target = self
            btn.action = #selector(gitStatusClicked(_:))
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
            gitStatusButton = btn
            applyGitStatusAppearance()
            item.label = "Git"
            item.toolTip = "Git repository status"
            item.view = btn
            
        default:
            // Delegate to hardware-specific target controllers (U64, MEGA65, xemu)
            if let u64Item = U64ToolbarController.shared.toolbarItem(for: id) { return u64Item }
            if let m65Item = MEGA65ToolbarController.shared.toolbarItem(for: id) { return m65Item }
            if let xemuItem = XemuToolbarController.shared.toolbarItem(for: id) { return xemuItem }
            return nil
        }
        return item
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [toolbarRun, toolbarStop, .flexibleSpace,
         .u64RunOnHardware, .mega65RunOnHardware,
         .flexibleSpace, toolbarGitStatus, toolbarThemeToggle, toolbarToggleRef, toolbarToggleBottom]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
            + U64ToolbarController.identifiers
            + MEGA65ToolbarController.identifiers
            + XemuToolbarController.identifiers
            + [.space]
    }

    // MARK: - Theme Toggle

    @objc private func toggleTheme(_ sender: Any?) {
        AppTheme.toggle()
        window?.toolbar?.items
            .first(where: { $0.itemIdentifier == toolbarThemeToggle })
            .map { item in
                let isDark = AppTheme.current.isDark
                item.label = isDark ? "Light Mode" : "Dark Mode"
                item.toolTip = isDark ? "Switch to light mode" : "Switch to dark mode"
                item.image = NSImage(
                    systemSymbolName: isDark ? "sun.max.fill" : "moon.fill",
                    accessibilityDescription: item.label)
            }
        NSApp.appearance = AppTheme.current.nsAppearance
        window?.appearance = AppTheme.current.nsAppearance
        window?.backgroundColor = AppTheme.current.editorBackground
    }

    // MARK: - Git Status

    /// Refreshes the git status indicator by querying the repository in the background.
    func refreshGitStatus() {
        let searchRoot: URL?
        if let root = ProjectManager.shared.projectRoot {
            searchRoot = root
        } else if let fileURL = editorViewController?.document.fileURL {
            searchRoot = fileURL.deletingLastPathComponent()
        } else {
            clearGitStatus()
            return
        }

        guard let root = searchRoot else {
            clearGitStatus()
            return
        }

        GitManager.shared.status(in: root) { [weak self] status in
            self?.currentGitStatus = status
            self?.applyGitStatusAppearance()
        }
    }

    /// Removes the git status indicator (no project / not a repo).
    func clearGitStatus() {
        currentGitStatus = .noRepo
        applyGitStatusAppearance()
    }

    private func applyGitStatusAppearance() {
        guard let btn = gitStatusButton else { return }
        switch currentGitStatus {
        case .noRepo:
            btn.title = "⬤  no git"
            btn.contentTintColor = NSColor.secondaryLabelColor
            btn.isEnabled = false
            btn.toolTip = "No git repository found in project folder"
        case .clean:
            btn.title = "⬤  clean"
            btn.contentTintColor = NSColor.systemGreen
            btn.isEnabled = true
            btn.toolTip = "Working tree clean — click to commit"
        case .modified:
            btn.title = "⬤  modified"
            btn.contentTintColor = NSColor.systemOrange
            btn.isEnabled = true
            btn.toolTip = "Uncommitted changes — click to commit"
        case .untracked:
            btn.title = "⬤  untracked"
            btn.contentTintColor = NSColor.systemYellow
            btn.isEnabled = true
            btn.toolTip = "Untracked files present — click to commit"
        case .unknown:
            btn.title = "⬤  git"
            btn.contentTintColor = NSColor.secondaryLabelColor
            btn.isEnabled = false
            btn.toolTip = "Git status unavailable"
        }
    }

    @objc private func gitStatusClicked(_ sender: Any?) {
        let root: URL?
        if let projectRoot = ProjectManager.shared.projectRoot {
            root = projectRoot
        } else if let fileURL = editorViewController?.document.fileURL {
            root = fileURL.deletingLastPathComponent()
        } else {
            root = nil
        }
        guard let root else { return }

        if currentGitStatus == .noRepo {
            let alert = NSAlert()
            alert.messageText = "Initialise Git Repository?"
            alert.informativeText = "Create a new git repository in the project folder?\n\n\(root.path)"
            alert.addButton(withTitle: "Initialise")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            
            GitManager.shared.initRepo(in: root) { [weak self] result in
                switch result {
                case .success:
                    self?.refreshGitStatus()
                    self?.bottomPanelController.appendBuildOutput("✓ Git repository initialised.", type: .success)
                case .failure(let error):
                    self?.bottomPanelController.appendBuildOutput("✗ git init failed: \(error.localizedDescription)", type: .error)
                }
            }
            return
        }

        showCommitSheet(repoRoot: root)
    }

    private func showCommitSheet(repoRoot: URL) {
        guard let window else { return }

        let sheetWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 160),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        sheetWindow.title = "Commit Changes"

        let container = NSView(frame: sheetWindow.contentRect(forFrameRect: sheetWindow.frame))
        sheetWindow.contentView = container

        let label = NSTextField(labelWithString: "Commit message:")
        label.font = NSFont.systemFont(ofSize: 12)
        label.frame = NSRect(x: 16, y: 110, width: 390, height: 18)
        container.addSubview(label)

        let field = NSTextField(frame: NSRect(x: 16, y: 70, width: 390, height: 32))
        field.placeholderString = "Describe your changes…"
        field.font = NSFont.systemFont(ofSize: 13)
        container.addSubview(field)
        sheetWindow.initialFirstResponder = field

        let pushBtn = NSButton(title: "Push", target: self, action: #selector(gitPush(_:)))
        pushBtn.frame = NSRect(x: 16, y: 16, width: 70, height: 32)
        pushBtn.bezelStyle = .rounded
        container.addSubview(pushBtn)

        let pullBtn = NSButton(title: "Pull", target: self, action: #selector(gitPull(_:)))
        pullBtn.frame = NSRect(x: 94, y: 16, width: 70, height: 32)
        pullBtn.bezelStyle = .rounded
        container.addSubview(pullBtn)

        let cancelBtn = NSButton(title: "Cancel", target: self, action: #selector(dismissCommitSheet(_:)))
        cancelBtn.frame = NSRect(x: 258, y: 16, width: 70, height: 32)
        cancelBtn.bezelStyle = .rounded
        cancelBtn.keyEquivalent = "\u{1b}"
        container.addSubview(cancelBtn)

        let commitBtn = NSButton(title: "Commit", target: self, action: #selector(performCommit(_:)))
        commitBtn.frame = NSRect(x: 336, y: 16, width: 70, height: 32)
        commitBtn.bezelStyle = .rounded
        commitBtn.keyEquivalent = "\r"
        container.addSubview(commitBtn)

        commitMessageField = field
        activeCommitSheetWindow = sheetWindow

        window.beginSheet(sheetWindow)
    }

    // Weak storage for the commit sheet's text field and window
    private weak var commitMessageField: NSTextField?
    private weak var activeCommitSheetWindow: NSWindow?

    @objc private func performCommit(_ sender: Any?) {
        guard let root = ProjectManager.shared.projectRoot
                      ?? editorViewController?.document.fileURL?.deletingLastPathComponent(),
              let field = commitMessageField,
              let sheetWindow = activeCommitSheetWindow else { return }

        let message = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            field.shake()   // Visual feedback for empty message
            return
        }

        window?.endSheet(sheetWindow)
        GitManager.shared.commitAll(message: message, in: root) { [weak self] result in
            switch result {
            case .success(let summary):
                self?.bottomPanelController.appendBuildOutput("✓ \(summary)", type: .success)
                self?.refreshGitStatus()
            case .failure(let error):
                self?.bottomPanelController.appendBuildOutput("✗ Commit failed: \(error.localizedDescription)", type: .error)
            }
        }
    }

    @objc private func dismissCommitSheet(_ sender: Any?) {
        if let sheet = activeCommitSheetWindow {
            window?.endSheet(sheet)
        }
    }

    @objc private func gitPush(_ sender: Any?) {
        if let sheet = activeCommitSheetWindow { window?.endSheet(sheet) }
        guard let root = ProjectManager.shared.projectRoot
                      ?? editorViewController?.document.fileURL?.deletingLastPathComponent()
        else { return }
        bottomPanelController.appendBuildOutput("Pushing…", type: .info)
        GitManager.shared.push(in: root) { [weak self] result in
            switch result {
            case .success:
                self?.bottomPanelController.appendBuildOutput("✓ Push complete.", type: .success)
            case .failure(let error):
                self?.bottomPanelController.appendBuildOutput("✗ Push failed: \(error.localizedDescription)", type: .error)
            }
        }
    }

    @objc private func gitPull(_ sender: Any?) {
        if let sheet = activeCommitSheetWindow { window?.endSheet(sheet) }
        guard let root = ProjectManager.shared.projectRoot
                      ?? editorViewController?.document.fileURL?.deletingLastPathComponent()
        else { return }
        bottomPanelController.appendBuildOutput("Pulling…", type: .info)
        GitManager.shared.pull(in: root) { [weak self] result in
            switch result {
            case .success:
                self?.bottomPanelController.appendBuildOutput("✓ Pull complete.", type: .success)
                self?.refreshGitStatus()
            case .failure(let error):
                self?.bottomPanelController.appendBuildOutput("✗ Pull failed: \(error.localizedDescription)", type: .error)
            }
        }
    }

    // MARK: - Project Session Support

    /// Closes all editor tabs without prompting. Used when switching projects.
    /// Unsaved-changes prompts are handled by the caller before this is invoked.
    func closeAllTabs() {
        while editors.count > 1 {
            let last = editors.removeLast()
            if let item = editorTabView.tabViewItems.last {
                editorTabView.removeTabViewItem(item)
            }
            _ = last  // Silence unused warning
        }
        if let first = editors.first {
            first.loadDocument(C64Document(fileType: .basic, content: ""))
            editorTabView.tabViewItems.first?.label = "Untitled.bas"
        }
        updateWindowTitle()
        refreshDiskHint()
    }

    /// Restores breakpoint line numbers into the editor for a given file URL.
    func restoreBreakpoints(_ lines: [Int], forFileURL url: URL) {
        guard let editor = editors.first(where: { $0.document.fileURL == url }),
              let gutter = editor.gutter else { return }
        for line in lines {
            gutter.breakpointLines.insert(line)
        }
        editor.gutter?.setNeedsDisplay(editor.gutter?.bounds ?? .zero)
    }

    // MARK: - Toolbar Actions

    @objc private func runProgram(_ sender: Any?) {
        bottomPanelController.selectTab(.build)
        bottomPanelController.clearBuildOutput()

        if editorViewController.document.fileURL == nil {
            bottomPanelController.appendBuildOutput("File must be saved before building.", type: .warning)
            editorViewController.saveDocumentAs { [weak self] success in
                if success {
                    self?.performRun()
                }
            }
            return
        }

        performRun()
    }

    /// Builds and runs the current document in the target emulator.
    private func performRun(debugBreakpoint: UInt16? = nil) {
        guard let fileURL = editorViewController.document.fileURL else { return }

        // Save any unsaved changes first
        editorViewController.saveDocument()

        let doc = editorViewController.document
        if doc.fileType.usesAssemblyHighlighting {
            let asmTarget = RunTarget.forActiveDialect(
                c64Preference:   buildConfig.preferredC64Emulator,
                projectOverride: ProjectManager.shared.activeProject?.buildOptions.preferredC64Emulator
            )
            let debugOpts: DebugOptions? = debugBreakpoint.map {
                DebugOptions(entryPoint: $0)
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                self.buildManager.buildAndRun(sourceFile: fileURL,
                                              type: .assemblyPrg,
                                              target: asmTarget,
                                              debugOptions: debugOpts)
            }
        } else if doc.fileType.usesBasicHighlighting {
            bottomPanelController.selectTab(.build)
            bottomPanelController.clearBuildOutput()
            bottomPanelController.appendBuildOutput("═══════════════════════════════════════", type: .plain)
            bottomPanelController.appendBuildOutput("Tokenizing: \(fileURL.lastPathComponent)", type: .plain)
            bottomPanelController.appendBuildOutput("═══════════════════════════════════════", type: .plain)

            let source = doc.content
            let buildDir = fileURL.deletingLastPathComponent().appendingPathComponent("build")
            let baseName = fileURL.deletingPathExtension().lastPathComponent
            let prgURL = buildDir.appendingPathComponent("\(baseName).prg")

            do {
                try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
                let startTime = Date()
                try BasicTokenizer.tokenizeToFile(source, outputURL: prgURL,
                    stripWhitespace: buildConfig.basicStripWhitespace)
                let elapsed = Date().timeIntervalSince(startTime)

                let fileSize = (try? FileManager.default.attributesOfItem(atPath: prgURL.path)[.size] as? Int) ?? 0
                let stripNote = buildConfig.basicStripWhitespace ? " (whitespace stripped)" : ""
                bottomPanelController.appendBuildOutput(
                    "✓ Tokenized OK → \(prgURL.lastPathComponent) (\(fileSize) bytes, \(String(format: "%.2f", elapsed))s)\(stripNote)",
                    type: .success)

                if let w = window {
                    buildManager.bundleDisksWithRecovery(outputPRG: prgURL, buildDir: buildDir, parentWindow: w)
                } else {
                    _ = buildManager.bundleDisks(outputPRG: prgURL, buildDir: buildDir)
                }

                // ── Dialect-aware emulator dispatch ──
                let runTarget = RunTarget.forActiveDialect(
                    c64Preference:   buildConfig.preferredC64Emulator,
                    projectOverride: ProjectManager.shared.activeProject?.buildOptions.preferredC64Emulator
                )

                switch runTarget {
                case .xemu:
                    XemuBuildPipeline.shared.runPRGWithDiskSupport(at: prgURL, autoRun: true, config: buildConfig)
                case .vc64, .viceX64sc, .viceX128, viceXpet:
                    let plan: DiskMountPlan? = {
                        guard let proj = ProjectManager.shared.activeProject,
                              let root = ProjectManager.shared.projectRoot,
                              let diskConfig = proj.diskConfig,
                              let p = EmulatorMountAdapter.plan(for: diskConfig, projectRoot: root),
                              p.hasMounts else { return nil }
                        return p
                    }()
                    let options = RunOptions(
                        prgURL:       prgURL,
                        diskPlan:     plan,
                        autoRun:      buildConfig.viceAutoRun,
                        debugOptions: debugBreakpoint.map { DebugOptions(entryPoint: $0) }
                    )
                    do {
                        try EmulatorCoordinator.shared.run(target: runTarget,
                                                           options: options,
                                                           config:  buildConfig)
                    } catch {
                        bottomPanelController.appendBuildOutput(
                            "✗ Launch failed: \(error.localizedDescription)", type: .error)
                    }
                case .u64:
                    U64BuildPipeline.shared.runOnHardware()
                case .mega65:
                    MEGA65BuildPipeline.shared.runOnHardware()
                }
            } catch {
                bottomPanelController.appendMessage(
                    "Tokenization failed: \(error.localizedDescription)", type: .error)
                bottomPanelController.appendBuildOutput(
                    "✗ Tokenization failed (see Messages tab).", type: .error)
            }
        }
    }

    /// Called from AppDelegate for Build & Debug
    func performBuildAndDebug(entryPoint: UInt16) {
        bottomPanelController.selectTab(.build)
        bottomPanelController.clearBuildOutput()
        referencePanelController.selectTab(.monitor)

        if editorViewController.document.fileURL == nil {
            bottomPanelController.appendBuildOutput("File must be saved before building.", type: .warning)
            editorViewController.saveDocumentAs { [weak self] success in
                if success { self?.performRun(debugBreakpoint: entryPoint) }
            }
            return
        }

        performRun(debugBreakpoint: entryPoint)
    }

    @objc private func stopProgram(_ sender: Any?) {
        EmulatorCoordinator.shared.stop()
        if XemuBuildPipeline.shared.isXemuRunning { XemuBuildPipeline.shared.stopXemu() }
        bottomPanelController.appendMessage("No emulator running.", type: .info)
    }

    @objc func toggleRightPanel(_ sender: Any?) {
        isRightPanelVisible.toggle()
        let refView = referencePanelController.view

        if isRightPanelVisible {
            refView.isHidden = false
            innerSplitView.setPosition(innerSplitView.frame.width - rightPanelDefaultWidth, ofDividerAt: 0)
        } else {
            refView.isHidden = true
            innerSplitView.setPosition(innerSplitView.frame.width, ofDividerAt: 0)
        }
        innerSplitView.adjustSubviews()
    }

    @objc func toggleBottomPanel(_ sender: Any?) {
        isBottomPanelVisible.toggle()
        let bottomView = bottomPanelController.view

        if isBottomPanelVisible {
            bottomView.isHidden = false
            outerSplitView.setPosition(outerSplitView.frame.height - bottomDefaultHeight, ofDividerAt: 0)
        } else {
            bottomView.isHidden = true
            outerSplitView.setPosition(outerSplitView.frame.height, ofDividerAt: 0)
        }
        outerSplitView.adjustSubviews()
    }

    // MARK: - Window Title

    func updateWindowTitle() {
        guard let editor = editorViewController else { return }
        let doc = editor.document
        let modified = doc.isModified ? " •" : ""
        window?.title = "\(doc.displayTitle)\(modified) — C64 IDE"

        if let selectedItem = editorTabView?.selectedTabViewItem {
            selectedItem.label = doc.displayTitle + (doc.isModified ? " •" : "")
        }
    }

    // MARK: - File Operations

    func loadDocument(from url: URL) {
        for (i, editor) in editors.enumerated() {
            if editor.document.fileURL == url {
                editorTabView.selectTabViewItem(at: i)
                updateWindowTitle()
                return
            }
        }

        // PRG files need content-based routing: tokenized BASIC goes to the
        // editor (detokenized), ML goes to the disassembler. Extension alone
        // isn't enough — both types share the .prg extension.
        if url.pathExtension.lowercased() == "prg" {
            guard let data = try? Data(contentsOf: url) else {
                let alert = NSAlert()
                alert.messageText = "Could not read \"\(url.lastPathComponent)\""
                alert.informativeText = "The file could not be read from disk."
                alert.runModal()
                return
            }

            if BasicTokenizer.isTokenizedBASIC(data) {
                // Tokenized BASIC PRG: detokenize and open as editable source.
                guard let source = BasicTokenizer.detokenize(data) else {
                    let alert = NSAlert()
                    alert.messageText = "Could not detokenize \"\(url.lastPathComponent)\""
                    alert.informativeText = "The file appears to be a BASIC program but could not be detokenized."
                    alert.runModal()
                    return
                }
                // Write to a temp .bas file so loadDocument picks up the right
                // file type on re-entry. Same pattern used by the disk browser.
                let baseName = url.deletingPathExtension().lastPathComponent
                let tempURL  = FileManager.default.temporaryDirectory
                                   .appendingPathComponent("\(baseName).bas")
                try? source.write(to: tempURL, atomically: true, encoding: .utf8)
                loadDocument(from: tempURL)     // re-enters with .bas, skips PRG block
            } else {
                // Machine language PRG: open in the disassembler.
                if let appDelegate = NSApp.delegate as? AppDelegate {
                    appDelegate.openDisassemblerWith(url: url)
                }
            }
            return
        }

        do {
            let doc = try C64Document(url: url)

            if let currentEditor = editorViewController,
               currentEditor.document.fileURL == nil,
               !currentEditor.document.isModified,
               currentEditor.document.content.isEmpty || currentEditor.document.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                currentEditor.loadDocument(doc)
                editorTabView.selectedTabViewItem?.label = doc.displayTitle
            } else {
                _ = addNewTab(with: doc)
                editorTabView.selectedTabViewItem?.label = doc.displayTitle
            }

            updateWindowTitle()
            refreshGitStatus()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @IBAction func saveDocument(_ sender: Any?) {
        editorViewController.saveDocument()
        updateWindowTitle()
    }

    @IBAction func saveDocumentAs(_ sender: Any?) {
        editorViewController.saveDocumentAs()
        updateWindowTitle()
    }

    // MARK: - Error Navigation

    /// Navigates the active editor to a specific line number (1-based)
    func navigateToLine(_ line: Int) {
        guard let editor = editorViewController,
              let textView = editor.textView,
              let text = textView.string as NSString? else { return }

        var currentLine = 1
        var lineStart = 0
        var lineEnd = 0

        for i in 0..<text.length {
            if currentLine == line {
                lineStart = i
                lineEnd = i
                while lineEnd < text.length && text.character(at: lineEnd) != 0x0A {
                    lineEnd += 1
                }
                break
            }
            if text.character(at: i) == 0x0A {
                currentLine += 1
            }
        }

        guard currentLine == line else { return }

        let range = NSRange(location: lineStart, length: lineEnd - lineStart)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        textView.showFindIndicator(for: range)
    }

    /// Opens the Search tab in the bottom panel and focuses the Find field.
    @objc func showSearchPanel(_ sender: Any?) {
        if !isBottomPanelVisible { toggleBottomPanel(nil) }
        bottomPanelController.focusFindField()
    }

    // MARK: - Debug Line Highlight

    /// Highlights a source line as the current debug execution point.
    func highlightDebugLine(_ line: Int) {
        window?.orderFront(nil)
        editorViewController?.highlightDebugLine(line)
    }

    /// Clears the debug execution highlight.
    func clearDebugHighlight() {
        editorViewController?.clearDebugHighlight()
    }

    // MARK: - Build Preferences

    @objc func showBuildPreferences(_ sender: Any?) {
        let viewModel = BuildPreferencesViewModel(config: buildConfig)

        let hostingController = NSHostingController(rootView: 
            BuildPreferencesView(viewModel: viewModel, onDismiss: { [weak self] in
                guard let self = self, let sheet = self.window?.attachedSheet else { return }
                self.window?.endSheet(sheet)
            }, onSave: { [weak self] in
                guard let self else { return }
                if ProjectManager.shared.isProjectOpen {
                    ProjectManager.shared.captureBuildOptions(from: self.buildConfig)
                }
            })
        )
        let prefsWindow = NSWindow(contentViewController: hostingController)
        prefsWindow.title = "Build Preferences"
        prefsWindow.styleMask = [.titled, .closable]
        prefsWindow.center()

        window?.beginSheet(prefsWindow) { _ in }
    }

    private weak var projectSettingsWindow: NSWindow?

    @objc func showProjectSettings(_ sender: Any?) {
        guard ProjectManager.shared.isProjectOpen,
              let project = ProjectManager.shared.activeProject else { return }

        let hostingController = NSHostingController(rootView:
            ProjectSettingsView(project: project) { [weak self] in
                self?.projectSettingsWindow?.close()
                self?.projectSettingsWindow = nil
            }
        )
        hostingController.sizingOptions = .preferredContentSize

        let settingsWindow = NSWindow(contentViewController: hostingController)
        settingsWindow.title = "Project Settings"
        settingsWindow.styleMask = [.titled, .closable]
        settingsWindow.setContentSize(NSSize(width: 620, height: 680))
        settingsWindow.center()

        projectSettingsWindow = settingsWindow
        settingsWindow.makeKeyAndOrderFront(nil)

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak settingsWindow] event in
            if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "w" {
                if settingsWindow?.isKeyWindow == true {
                    settingsWindow?.close()
                    return nil
                }
            }
            return event
        }
    }

    // MARK: - Menu-Callable Actions

    @objc func performBuildAndRun(_ sender: Any?) { runProgram(sender) }
    @objc func performStop(_ sender: Any?) { stopProgram(sender) }

    @objc func performBuildOnly(_ sender: Any?) {
        bottomPanelController.selectTab(.build)
        bottomPanelController.clearBuildOutput()

        guard let fileURL = editorViewController.document.fileURL else {
            bottomPanelController.appendBuildOutput("Save the file first.", type: .warning)
            editorViewController.saveDocumentAs()
            return
        }

        if editorViewController.document.fileType.usesAssemblyHighlighting {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.buildManager.build(sourceFile: fileURL, type: .assemblyPrg)
            }
        } else {
            bottomPanelController.appendBuildOutput("Only assembly files can be built.", type: .warning)
        }
    }

    // MARK: - Compile Assembly to DATA

    @objc func compileAssemblyToData(_ sender: Any?) {
        guard let fileURL = editorViewController.document.fileURL else {
            bottomPanelController.appendBuildOutput("Save the file first.", type: .warning)
            editorViewController.saveDocumentAs()
            return
        }

        guard editorViewController.document.fileType.usesAssemblyHighlighting else {
            bottomPanelController.appendBuildOutput(
                "Compile Assembly to DATA requires an assembly source file.", type: .warning)
            return
        }

        let dialog = AsmToDataDialog()
        asmToDataDialog = dialog          // retain the controller for the sheet's lifetime
        guard let sheet = dialog.window, let parentWindow = window else { return }

        parentWindow.beginSheet(sheet) { _ in }

        dialog.completionHandler = { [weak self] params in
            self?.asmToDataDialog = nil   // release once the sheet is done
            guard let self, let params else { return }
            self.runAsmToDataPipeline(sourceFile: fileURL, params: params)
        }
    }

    // MARK: - Import PRG as DATA

    @objc func importPRGAsData(_ sender: Any?) {
        guard let parentWindow = window else { return }

        // Step 1: pick the PRG file
        let panel = NSOpenPanel()
        panel.title                   = "Choose a PRG File"
        panel.allowedContentTypes     = [UTType(filenameExtension: "prg") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories    = false

        panel.beginSheetModal(for: parentWindow) { [weak self] response in
            guard let self, response == .OK, let prgURL = panel.url else { return }

            // Step 2: show the parameter dialog
            let dialog = AsmToDataDialog()
            self.asmToDataDialog = dialog
            guard let sheet = dialog.window else { return }

            parentWindow.beginSheet(sheet) { _ in }

            dialog.completionHandler = { [weak self] params in
                self?.asmToDataDialog = nil
                guard let self, let params else { return }

                // Step 3: feed the PRG directly to the generator - no build needed
                self.generateDataTab(
                    from: prgURL,
                    sourceName: prgURL.lastPathComponent,
                    params: params
                )
            }
        }
    }

    private func runAsmToDataPipeline(sourceFile: URL, params: AsmToDataParams) {
        bottomPanelController.selectTab(.build)
        bottomPanelController.clearBuildOutput()
        bottomPanelController.appendBuildOutput("Compiling assembly for DATA export...", type: .info)

        // Use a one-shot NotificationCenter observer rather than swapping onBuildComplete.
        // Swapping the callback is fragile - buildAndRun uses the same pattern internally
        // and a stale interceptor in the chain causes re-entrancy crashes.
        //
        // The observer self-removes on first fire. BuildManager posts .asmToDataBuildComplete
        // for both success and failure so the token is never leaked by a failed build.
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(
            forName: .asmToDataBuildComplete,
            object: buildManager,
            queue: .main
        ) { [weak self] note in
            if let t = token { NotificationCenter.default.removeObserver(t) }
            token = nil

            guard let self else { return }
            guard let result = note.userInfo?["result"] as? BuildResult,
                  result.success,
                  let prgURL = result.outputFile else { return }
            self.generateDataTab(from: prgURL, sourceName: sourceFile.lastPathComponent, params: params)
        }

        buildManager.build(sourceFile: sourceFile, type: .assemblyToData)
    }

    private func generateDataTab(from prgURL: URL, sourceName: String, params: AsmToDataParams) {
        switch AsmToDataGenerator.generate(from: prgURL, sourceName: sourceName, params: params) {
        case .success(let basicText):
            let doc = C64Document(fileType: .basic, content: basicText)
            let baseName = (sourceName as NSString).deletingPathExtension
            doc.customTitle = "\(baseName)_data.bas"
            let editor = addNewTab(with: doc)
            // Output is generated, not user-typed - don't prompt to save unless they edit it
            editor.document.isModified = false
            updateWindowTitle()

            let lineCount = basicText.components(separatedBy: "\n").count
            bottomPanelController.appendBuildOutput(
                "DATA export complete - \(lineCount) lines generated.", type: .success)

        case .failure(let error):
            bottomPanelController.appendBuildOutput("DATA export failed: \(error.localizedDescription)", type: .error)
        }
    }
}

// MARK: - NSSplitViewDelegate

extension MainWindowController: NSSplitViewDelegate {

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMin: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if splitView == innerSplitView { return editorMinWidth }
        return topMinHeight
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMax: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if splitView == innerSplitView {
            return splitView.frame.width - rightPanelMinWidth
        }
        return splitView.frame.height - bottomMinHeight
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        if splitView == innerSplitView { return subview == referencePanelController.view }
        if splitView == outerSplitView { return subview == bottomPanelController.view }
        return false
    }
}

// MARK: - NSTabViewDelegate

extension MainWindowController: NSTabViewDelegate {

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        updateWindowTitle()
        refreshGitStatus()
        refreshDiskHint()
    }
}

// MARK: - NSWindowDelegate

extension MainWindowController: NSWindowDelegate {

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        for editor in editors {
            if editor.document.isModified {
                let alert = NSAlert()
                alert.messageText = "Save changes to \"\(editor.document.displayTitle)\"?"
                alert.informativeText = "Your changes will be lost if you don't save them."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Save")
                alert.addButton(withTitle: "Don't Save")
                alert.addButton(withTitle: "Cancel")

                let response = alert.runModal()
                switch response {
                case .alertFirstButtonReturn:
                    editor.saveDocument()
                case .alertSecondButtonReturn:
                    continue
                default:
                    return false
                }
            }
        }
        return true
    }
}

// MARK: - Build Result Reporting

extension MainWindowController {
    /// Called by AppDelegate after any build path so that Claude context always has up-to-date diagnostics.
    func reportBuildResult(_ result: BuildResult) {
        lastBuildResult = result
    }
}

// MARK: - ClaudeIDEContextProvider

extension MainWindowController: ClaudeIDEContextProvider {

    func currentIDEContext() -> ClaudeIDEContext {
        let editor = editorViewController
        let doc    = editor?.document

        var selectedText: String? = nil
        if let tv = editor?.textView {
            let sel = tv.selectedRange()
            if sel.length > 0 {
                selectedText = (tv.string as NSString).substring(with: sel)
            }
        }

        let buildErrors: [String] = lastBuildResult.map { result in
            result.diagnostics.map { diag in
                var parts: [String] = []
                if let file = diag.file { parts.append(file) }
                if let line = diag.line { parts.append("line \(line)") }
                parts.append("[\(diag.severity == .error ? "error" : "warning")] \(diag.message)")
                return parts.joined(separator: " ")
            }
        } ?? []

        return ClaudeIDEContext(
            activeFileName:    doc?.displayTitle,
            activeFileType:    doc?.fileType,
            activeFileContent: doc?.content,
            selectedText:      selectedText,
            buildErrors:       buildErrors,
            basicDialect:      BasicDialectManager.shared.activeDialect?.name
        )
    }
}

// NSTextField.shake() is defined in NSTextField+Shake.swift

