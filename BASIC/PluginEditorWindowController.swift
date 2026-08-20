import Cocoa

// ═══════════════════════════════════════════════════════════
// MARK: - Plugin Editor Window Controller
// ═══════════════════════════════════════════════════════════

class PluginEditorWindowController: NSWindowController, NSWindowDelegate {

    var isModified = false

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Plugin Editor — New Plugin"
        window.center()
        window.minSize = NSSize(width: 780, height: 550)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = AppTheme.current.panelBackground
        self.init(window: window)
        window.delegate = self

        let editor = PluginEditorViewController()
        editor.onModified = { [weak self] in
            self?.isModified = true
            self?.window?.title = "Plugin Editor — \(editor.pluginName) •"
        }
        editor.onSaved = { [weak self] name in
            self?.isModified = false
            self?.window?.title = "Plugin Editor — \(name)"
        }
        window.contentViewController = editor
    }

    /// Open with an existing plugin loaded
    func loadDialect(_ dialect: BasicDialect, from url: URL?) {
        (window?.contentViewController as? PluginEditorViewController)?.loadDialect(dialect, from: url)
        window?.title = "Plugin Editor — \(dialect.name)"
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard isModified else { return true }
        let alert = NSAlert()
        alert.messageText = "You have unsaved changes in the Plugin Editor."
        alert.informativeText = "Close without saving?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc func closeTab(_ sender: Any?) {
        window?.performClose(sender)
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - Plugin Editor View Controller
// ═══════════════════════════════════════════════════════════

class PluginEditorViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    // MARK: - Outlets & UI Elements

    // Plugin metadata fields
    private var nameField: NSTextField!
    private var versionField: NSTextField!
    private var authorField: NSTextField!
    private var descriptionField: NSTextField!
    private var tokenBaseField: NSTextField!
    private var activationSYSField: NSTextField!

    // Keyword table
    private var keywordTable: NSTableView!
    private var keywords: [EditableKeyword] = []

    // Keyword detail fields
    private var kwNameField: NSTextField!
    private var kwTokenField: NSTextField!
    private var kwTypePopup: NSPopUpButton!
    private var kwCategoryField: NSTextField!
    private var kwSyntaxField: NSTextField!
    private var kwDescField: NSTextField!
    private var kwExampleField: NSTextField!
    private var kwNotesField: NSTextField!

    // State
    private var selectedKeywordIndex: Int = -1
    private var sourceURL: URL?
    private var originalVersion: String = "1.0"

    // Passthrough fields — preserved on load, round-tripped on save
    private var preservedTokenPrefixes: [TokenPrefix]? = nil
    private var preservedURL: String? = nil
    private var preservedLoadAddress: Int? = nil
    private var preservedMachine: String? = nil
    private var preservedAssemblerMnemonics: [String]? = nil
    private var preservedCompositeKeywords: [CompositeKeyword]? = nil
    private var preservedShortcuts: [BasicShortcutExpander.Shortcut]? = nil

    var onModified: (() -> Void)?
    var onSaved: ((String) -> Void)?

    var pluginName: String { nameField?.stringValue ?? "New Plugin" }

    private var bgColor: NSColor { AppTheme.current.panelBackground }
    private var sectionLabels: [NSTextField] = []
    private var dimLabels:     [NSTextField] = []

    // MARK: - Editable Keyword Model

    class EditableKeyword {
        var keyword: String = ""
        var token: Int? = nil
        var prefixes: [Int] = []
        var type: String = "command"
        var category: String = ""
        var syntax: String = ""
        var description: String = ""
        var example: String = ""
        var notes: String = ""
        var documented: Bool = true

        init() {}

        init(from kw: BasicDialectKeyword) {
            keyword = kw.keyword
            token = kw.token
            prefixes = kw.prefixes ?? (kw.prefix.map { [$0] }) ?? []
            type = kw.type ?? "command"
            category = kw.category ?? ""
            syntax = kw.syntax ?? ""
            description = kw.description ?? ""
            example = kw.example ?? ""
            notes = kw.notes ?? ""
            documented = kw.documented ?? true
        }

        func toDialectKeyword() -> BasicDialectKeyword {
            return BasicDialectKeyword(
                keyword: keyword,
                prefix: nil,
                prefixes: prefixes.isEmpty ? nil : prefixes,
                token: token,
                type: type.isEmpty ? nil : type,
                category: category.isEmpty ? nil : category,
                syntax: syntax.isEmpty ? nil : syntax,
                description: description.isEmpty ? nil : description,
                parameters: nil,
                example: example.isEmpty ? nil : example,
                notes: notes.isEmpty ? nil : notes,
                documented: documented ? nil : false
            )
        }
    }

    // MARK: - Lifecycle

    override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
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

    // MARK: - Theme Application

    private func applyThemeColors() {
        view.window?.appearance      = AppTheme.current.nsAppearance
        view.window?.backgroundColor = AppTheme.current.panelBackground
        view.layer?.backgroundColor  = AppTheme.current.panelBackground.cgColor
        sectionLabels.forEach { $0.textColor = AppTheme.current.syntaxKeyword }
        dimLabels.forEach     { $0.textColor = AppTheme.current.statusLabel }
        keywordTable?.backgroundColor   = AppTheme.current.panelDetailBackground
        jsonPreviewView?.backgroundColor = AppTheme.current.panelDetailBackground
        jsonPreviewView?.textColor       = AppTheme.current.syntaxFunction
        // Update input fields
        for field in [nameField, versionField, authorField, descriptionField,
                      tokenBaseField, activationSYSField, kwNameField,
                      kwTokenField, kwCategoryField, kwSyntaxField,
                      kwDescField, kwExampleField, kwNotesField] {
            field?.backgroundColor = AppTheme.current.panelDetailBackground
            field?.textColor       = AppTheme.current.defaultText
        }
        keywordTable?.reloadData()
    }

    // MARK: - Build UI

    private func buildUI() {
        let w = view.bounds.width
        var y = view.bounds.height - 15

        // ── Plugin Metadata ──────────────────────────────
        y -= 18
        let metaLabel = makeLabel("PLUGIN METADATA", bold: true, color: AppTheme.current.syntaxKeyword)
        metaLabel.frame = NSRect(x: 12, y: y, width: 200, height: 16)
        view.addSubview(metaLabel)

        y -= 26
        nameField = addFormRow(y: y, label: "Name:", width: 200, placeholder: "My BASIC Extension")
        versionField = addFormRow(y: y, label: "Version:", x: 330, width: 80, placeholder: "1.0")
        authorField = addFormRow(y: y, label: "Author:", x: 520, width: 150, placeholder: "Your Name")

        y -= 26
        descriptionField = addFormRow(y: y, label: "Description:", width: w - 110, placeholder: "A brief description of this BASIC extension")

        y -= 26
        tokenBaseField = addFormRow(y: y, label: "Token Base:", width: 80, placeholder: "203")
        activationSYSField = addFormRow(y: y, label: "SYS Addr:", x: 230, width: 80, placeholder: "2368")

        // ── Buttons ──────────────────────────────────────
        let btnY = y
        let newBtn = NSButton(title: "New Plugin", target: self, action: #selector(newPlugin(_:)))
        newBtn.frame = NSRect(x: w - 310, y: btnY, width: 90, height: 22)
        newBtn.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        view.addSubview(newBtn)

        let loadBtn = NSButton(title: "Load…", target: self, action: #selector(loadPlugin(_:)))
        loadBtn.frame = NSRect(x: w - 215, y: btnY, width: 60, height: 22)
        loadBtn.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        view.addSubview(loadBtn)

        let saveBtn = NSButton(title: "Save…", target: self, action: #selector(savePlugin(_:)))
        saveBtn.frame = NSRect(x: w - 150, y: btnY, width: 60, height: 22)
        saveBtn.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
        view.addSubview(saveBtn)

        let installBtn = NSButton(title: "Save & Install", target: self, action: #selector(saveAndInstall(_:)))
        installBtn.frame = NSRect(x: w - 85, y: btnY, width: 80, height: 22)
        installBtn.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
        view.addSubview(installBtn)

        // ── Keyword List (left) ──────────────────────────
        y -= 30
        let kwLabel = makeLabel("KEYWORDS", bold: true, color: AppTheme.current.syntaxOperator)
        kwLabel.frame = NSRect(x: 12, y: y, width: 100, height: 16)
        view.addSubview(kwLabel)

        let addKwBtn = NSButton(title: "+", target: self, action: #selector(addKeyword(_:)))
        addKwBtn.frame = NSRect(x: 115, y: y - 2, width: 24, height: 20)
        addKwBtn.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .bold)
        view.addSubview(addKwBtn)

        let delKwBtn = NSButton(title: "−", target: self, action: #selector(deleteKeyword(_:)))
        delKwBtn.frame = NSRect(x: 142, y: y - 2, width: 24, height: 20)
        delKwBtn.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .bold)
        view.addSubview(delKwBtn)

        let dupKwBtn = NSButton(title: "Dup", target: self, action: #selector(duplicateKeyword(_:)))
        dupKwBtn.frame = NSRect(x: 170, y: y - 2, width: 36, height: 20)
        dupKwBtn.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        view.addSubview(dupKwBtn)

        y -= 22

        // Table
        let tableWidth: CGFloat = 280
        keywordTable = NSTableView()
        keywordTable.backgroundColor = AppTheme.current.panelDetailBackground
        keywordTable.style = .plain
        keywordTable.rowHeight = 20
        keywordTable.dataSource = self
        keywordTable.delegate = self
        keywordTable.target = self
        keywordTable.action = #selector(keywordSelected(_:))

        let kwCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("keyword"))
        kwCol.title = "Keyword"
        kwCol.width = 120
        keywordTable.addTableColumn(kwCol)

        let tokCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("token"))
        tokCol.title = "Token"
        tokCol.width = 50
        keywordTable.addTableColumn(tokCol)

        let typeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("type"))
        typeCol.title = "Type"
        typeCol.width = 80
        keywordTable.addTableColumn(typeCol)

        let tableScroll = NSScrollView(frame: NSRect(x: 12, y: 12, width: tableWidth, height: y - 12))
        tableScroll.documentView = keywordTable
        tableScroll.hasVerticalScroller = true
        tableScroll.borderType = .noBorder
        tableScroll.autoresizingMask = [.height]
        view.addSubview(tableScroll)

        // ── Keyword Detail (right) ───────────────────────
        let detailX = tableWidth + 24
        let detailW = w - detailX - 12

        let detLabel = makeLabel("KEYWORD DETAIL", bold: true, color: AppTheme.current.syntaxOperator)
        detLabel.frame = NSRect(x: detailX, y: y + 22, width: 150, height: 16)
        view.addSubview(detLabel)

        var dy = y
        kwNameField = addFormRow(y: dy, label: "Keyword:", x: detailX, width: 150, placeholder: "SPRITE")
        kwNameField.target = self; kwNameField.action = #selector(kwDetailChanged(_:))

        kwTokenField = addFormRow(y: dy, label: "Token:", x: detailX + 270, width: 60, placeholder: "203")
        kwTokenField.target = self; kwTokenField.action = #selector(kwDetailChanged(_:))

        dy -= 26
        kwTypePopup = NSPopUpButton(frame: NSRect(x: detailX + 70, y: dy, width: 130, height: 22))
        kwTypePopup.addItems(withTitles: [
            "command", "procedure", "function", "conditional", "loop",
            "operator", "io", "graphics", "sound", "math", "string", "system"
        ])
        kwTypePopup.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        kwTypePopup.target = self; kwTypePopup.action = #selector(kwDetailChanged(_:))
        let typeLabel = makeLabel("Type:", bold: false, color: AppTheme.current.statusLabel)
        typeLabel.frame = NSRect(x: detailX, y: dy + 3, width: 65, height: 16)
        view.addSubview(typeLabel)
        view.addSubview(kwTypePopup)

        kwCategoryField = addFormRow(y: dy, label: "Category:", x: detailX + 270, width: 120, placeholder: "graphics")
        kwCategoryField.target = self; kwCategoryField.action = #selector(kwDetailChanged(_:))

        dy -= 26
        kwSyntaxField = addFormRow(y: dy, label: "Syntax:", x: detailX, width: detailW - 70, placeholder: "SPRITE n, x, y, color")
        kwSyntaxField.target = self; kwSyntaxField.action = #selector(kwDetailChanged(_:))

        dy -= 26
        kwDescField = addFormRow(y: dy, label: "Desc:", x: detailX, width: detailW - 70, placeholder: "Description of the command")
        kwDescField.target = self; kwDescField.action = #selector(kwDetailChanged(_:))

        dy -= 26
        kwExampleField = addFormRow(y: dy, label: "Example:", x: detailX, width: detailW - 70, placeholder: "SPRITE 0, 160, 100, 1")
        kwExampleField.target = self; kwExampleField.action = #selector(kwDetailChanged(_:))

        dy -= 26
        kwNotesField = addFormRow(y: dy, label: "Notes:", x: detailX, width: detailW - 70, placeholder: "Optional notes or caveats")
        kwNotesField.target = self; kwNotesField.action = #selector(kwDetailChanged(_:))

        // JSON preview
        dy -= 30
        let previewLabel = makeLabel("JSON PREVIEW", bold: true, color: AppTheme.current.syntaxOperator)
        previewLabel.frame = NSRect(x: detailX, y: dy, width: 150, height: 16)
        view.addSubview(previewLabel)

        dy -= 4
        let previewTV = NSTextView(frame: NSRect(x: 0, y: 0, width: detailW, height: dy - 12))
        previewTV.isEditable = false
        previewTV.isSelectable = true
        previewTV.backgroundColor = AppTheme.current.panelDetailBackground
        previewTV.textColor = AppTheme.current.syntaxFunction
        previewTV.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        previewTV.textContainerInset = NSSize(width: 6, height: 4)
        jsonPreviewView = previewTV

        let previewScroll = NSScrollView(frame: NSRect(x: detailX, y: 12, width: detailW, height: dy - 12))
        previewScroll.documentView = previewTV
        previewScroll.hasVerticalScroller = true
        previewScroll.borderType = .noBorder
        previewScroll.autoresizingMask = [.width, .height]
        view.addSubview(previewScroll)

        clearDetailFields()
    }

    private var jsonPreviewView: NSTextView!

    // MARK: - Form Helpers

    @discardableResult
    private func addFormRow(y: CGFloat, label: String, x: CGFloat = 12, width: CGFloat, placeholder: String) -> NSTextField {
        let lbl = makeLabel(label, bold: false, color: AppTheme.current.statusLabel)
        lbl.frame = NSRect(x: x, y: y + 3, width: 65, height: 16)
        view.addSubview(lbl)

        let field = NSTextField(string: "")
        field.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        field.frame = NSRect(x: x + 70, y: y, width: width, height: 22)
        field.placeholderString = placeholder
        field.backgroundColor = AppTheme.current.panelDetailBackground
        field.textColor = AppTheme.current.defaultText
        field.focusRingType = .none
        view.addSubview(field)
        return field
    }

    private func makeLabel(_ text: String, bold: Bool, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: bold ? .bold : .regular)
        label.textColor = color
        if bold { sectionLabels.append(label) } else { dimLabels.append(label) }
        return label
    }

    // MARK: - Load / Save

    func loadDialect(_ dialect: BasicDialect, from url: URL?) {
        sourceURL = url
        originalVersion = dialect.version ?? "1.0"

        nameField.stringValue = dialect.name
        versionField.stringValue = dialect.version ?? "1.0"
        authorField.stringValue = dialect.author ?? ""
        descriptionField.stringValue = dialect.description ?? ""
        tokenBaseField.stringValue = dialect.tokenBase != nil ? "\(dialect.tokenBase!)" : ""
        activationSYSField.stringValue = dialect.activationSYS != nil ? "\(dialect.activationSYS!)" : ""

        // Preserve fields the editor doesn't expose, so they survive a save round-trip
        preservedTokenPrefixes = dialect.tokenPrefixes
        preservedURL = dialect.url
        preservedLoadAddress = dialect.loadAddress
        preservedMachine = dialect.machine
        preservedAssemblerMnemonics = dialect.assemblerMnemonics
        preservedCompositeKeywords = dialect.compositeKeywords
        preservedShortcuts = dialect.shortcuts

        keywords = dialect.keywords.map { EditableKeyword(from: $0) }
        keywordTable.reloadData()

        if !keywords.isEmpty {
            selectedKeywordIndex = 0
            keywordTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            loadKeywordDetail(0)
        }

        updateJSONPreview()
    }

    private func buildDialect() -> BasicDialect {
        return BasicDialect(
            name: nameField.stringValue,
            version: versionField.stringValue.isEmpty ? nil : versionField.stringValue,
            author: authorField.stringValue.isEmpty ? nil : authorField.stringValue,
            description: descriptionField.stringValue.isEmpty ? nil : descriptionField.stringValue,
            url: preservedURL,
            requiresSYSStub: nil,
            tokenBase: Int(tokenBaseField.stringValue),
            tokenPrefixes: preservedTokenPrefixes,
            extendsBasicV2: true,
            loadAddress: preservedLoadAddress,
            machine: preservedMachine,
            activationSYS: Int(activationSYSField.stringValue),
            keywords: keywords.map { $0.toDialectKeyword() },
            assemblerMnemonics: preservedAssemblerMnemonics,
            compositeKeywords: preservedCompositeKeywords,
            shortcuts: preservedShortcuts
        )
    }

    @objc private func newPlugin(_ sender: Any?) {
        nameField.stringValue = "My BASIC Extension"
        versionField.stringValue = "1.0"
        authorField.stringValue = ""
        descriptionField.stringValue = ""
        tokenBaseField.stringValue = ""
        activationSYSField.stringValue = ""
        keywords = []
        selectedKeywordIndex = -1
        sourceURL = nil
        originalVersion = "1.0"
        preservedTokenPrefixes = nil
        preservedURL = nil
        preservedLoadAddress = nil
        preservedMachine = nil
        preservedAssemblerMnemonics = nil
        preservedCompositeKeywords = nil
        preservedShortcuts = nil
        keywordTable.reloadData()
        clearDetailFields()
        updateJSONPreview()
        onModified?()
    }

    @objc private func loadPlugin(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "c64basic")!]
        panel.title = "Load Plugin"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            guard let dialect = BasicDialectManager.shared.loadPlugin(from: url) else {
                let alert = NSAlert()
                alert.messageText = "Failed to load plugin"
                alert.informativeText = "The file could not be parsed."
                alert.runModal()
                return
            }
            self?.loadDialect(dialect, from: url)
        }
    }

    @objc private func savePlugin(_ sender: Any?) {
        // Check version bump
        if !checkVersionBump() { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "c64basic")!]
        let safeName = nameField.stringValue.replacingOccurrences(of: " ", with: "_")
        panel.nameFieldStringValue = "\(safeName).c64basic"

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.writePlugin(to: url)
        }
    }

    @objc private func saveAndInstall(_ sender: Any?) {
        if !checkVersionBump() { return }

        let dialect = buildDialect()
        let safeName = nameField.stringValue.replacingOccurrences(of: " ", with: "_")
        let destURL = BasicDialectManager.pluginDirectory.appendingPathComponent("\(safeName).c64basic")

        try? FileManager.default.createDirectory(at: BasicDialectManager.pluginDirectory, withIntermediateDirectories: true)

        // Remove old version if exists
        if FileManager.default.fileExists(atPath: destURL.path) {
            try? FileManager.default.removeItem(at: destURL)
        }

        writePlugin(to: destURL)

        // Register with manager
        let manager = BasicDialectManager.shared
        manager.removeDialect(named: dialect.name)
        manager.addDialect(dialect)

        let alert = NSAlert()
        alert.messageText = "Plugin Installed"
        alert.informativeText = "\"\(dialect.name)\" v\(dialect.version ?? "1.0") installed with \(dialect.keywords.count) keywords."
        alert.runModal()
    }

    private func writePlugin(to url: URL) {
        let dialect = buildDialect()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(dialect)
            try data.write(to: url)
            sourceURL = url
            originalVersion = versionField.stringValue
            onSaved?(dialect.name)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Save Failed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    /// Check if version needs bumping — returns true if OK to proceed
    private func checkVersionBump() -> Bool {
        let currentVersion = versionField.stringValue

        // If this is a new plugin or version was already changed, OK
        if sourceURL == nil || currentVersion != originalVersion { return true }

        let alert = NSAlert()
        alert.messageText = "Bump Version Number?"
        alert.informativeText = "You've made changes but the version is still \(currentVersion). It's recommended to bump the version before saving."
        alert.addButton(withTitle: "Bump to \(bumpVersion(currentVersion))")
        alert.addButton(withTitle: "Save Anyway")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            let newVersion = bumpVersion(currentVersion)
            versionField.stringValue = newVersion
            return true
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    /// Increment the last number in a version string
    private func bumpVersion(_ version: String) -> String {
        let parts = version.split(separator: ".")
        guard !parts.isEmpty else { return "1.1" }

        var mutableParts = parts.map { String($0) }
        if let last = Int(mutableParts.last!) {
            mutableParts[mutableParts.count - 1] = "\(last + 1)"
        } else {
            mutableParts.append("1")
        }
        return mutableParts.joined(separator: ".")
    }

    // MARK: - Keyword Management

    @objc private func addKeyword(_ sender: Any?) {
        let kw = EditableKeyword()
        kw.keyword = "NEW_KEYWORD"
        // Auto-assign next token
        let maxToken = keywords.compactMap { $0.token }.max() ?? (Int(tokenBaseField.stringValue) ?? 203) - 1
        kw.token = maxToken + 1
        keywords.append(kw)
        keywordTable.reloadData()
        selectedKeywordIndex = keywords.count - 1
        keywordTable.selectRowIndexes(IndexSet(integer: selectedKeywordIndex), byExtendingSelection: false)
        loadKeywordDetail(selectedKeywordIndex)
        onModified?()
        updateJSONPreview()
    }

    @objc private func deleteKeyword(_ sender: Any?) {
        guard selectedKeywordIndex >= 0, selectedKeywordIndex < keywords.count else { return }
        keywords.remove(at: selectedKeywordIndex)
        keywordTable.reloadData()
        selectedKeywordIndex = min(selectedKeywordIndex, keywords.count - 1)
        if selectedKeywordIndex >= 0 {
            keywordTable.selectRowIndexes(IndexSet(integer: selectedKeywordIndex), byExtendingSelection: false)
            loadKeywordDetail(selectedKeywordIndex)
        } else {
            clearDetailFields()
        }
        onModified?()
        updateJSONPreview()
    }

    @objc private func duplicateKeyword(_ sender: Any?) {
        guard selectedKeywordIndex >= 0, selectedKeywordIndex < keywords.count else { return }
        let original = keywords[selectedKeywordIndex]
        let copy = EditableKeyword()
        copy.keyword = original.keyword + "_COPY"
        copy.token = (keywords.compactMap { $0.token }.max() ?? 202) + 1
        copy.type = original.type
        copy.category = original.category
        copy.syntax = original.syntax
        copy.description = original.description
        copy.example = original.example
        copy.notes = original.notes
        keywords.append(copy)
        keywordTable.reloadData()
        selectedKeywordIndex = keywords.count - 1
        keywordTable.selectRowIndexes(IndexSet(integer: selectedKeywordIndex), byExtendingSelection: false)
        loadKeywordDetail(selectedKeywordIndex)
        onModified?()
        updateJSONPreview()
    }

    @objc private func keywordSelected(_ sender: Any?) {
        let row = keywordTable.selectedRowIndexes.first ?? -1
        guard row >= 0, row < keywords.count else { return }
        saveCurrentKeywordDetail()
        selectedKeywordIndex = row
        loadKeywordDetail(row)
    }

    @objc private func kwDetailChanged(_ sender: Any?) {
        saveCurrentKeywordDetail()
        keywordTable.reloadData()
        onModified?()
        updateJSONPreview()
    }

    private func loadKeywordDetail(_ index: Int) {
        guard index >= 0, index < keywords.count else { clearDetailFields(); return }
        let kw = keywords[index]
        kwNameField.stringValue = kw.keyword
        kwTokenField.stringValue = kw.token != nil ? "\(kw.token!)" : ""
        kwTypePopup.selectItem(withTitle: kw.type)
        kwCategoryField.stringValue = kw.category
        kwSyntaxField.stringValue = kw.syntax
        kwDescField.stringValue = kw.description
        kwExampleField.stringValue = kw.example
        kwNotesField.stringValue = kw.notes
    }

    private func saveCurrentKeywordDetail() {
        guard selectedKeywordIndex >= 0, selectedKeywordIndex < keywords.count else { return }
        let kw = keywords[selectedKeywordIndex]
        kw.keyword = kwNameField.stringValue.uppercased()
        kw.token = Int(kwTokenField.stringValue)
        kw.type = kwTypePopup.titleOfSelectedItem ?? "command"
        kw.category = kwCategoryField.stringValue
        kw.syntax = kwSyntaxField.stringValue
        kw.description = kwDescField.stringValue
        kw.example = kwExampleField.stringValue
        kw.notes = kwNotesField.stringValue
    }

    private func clearDetailFields() {
        kwNameField?.stringValue = ""
        kwTokenField?.stringValue = ""
        kwTypePopup?.selectItem(at: 0)
        kwCategoryField?.stringValue = ""
        kwSyntaxField?.stringValue = ""
        kwDescField?.stringValue = ""
        kwExampleField?.stringValue = ""
        kwNotesField?.stringValue = ""
    }

    private func updateJSONPreview() {
        let dialect = buildDialect()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(dialect),
           let json = String(data: data, encoding: .utf8) {
            jsonPreviewView?.string = json
        }
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        keywords.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < keywords.count else { return nil }
        let kw = keywords[row]

        let cell = NSTextField(labelWithString: "")
        cell.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        cell.textColor = AppTheme.current.defaultText

        switch tableColumn?.identifier.rawValue {
        case "keyword": cell.stringValue = kw.keyword
        case "token":   cell.stringValue = kw.token != nil ? String(format: "$%02X", kw.token!) : "—"
        case "type":    cell.stringValue = kw.type; cell.textColor = AppTheme.current.statusLabel
        default: break
        }

        return cell
    }
}

