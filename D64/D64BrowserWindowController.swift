import Cocoa

// ═══════════════════════════════════════════════════════════
// MARK: - Filename Sanitizer
// ═══════════════════════════════════════════════════════════

/// Converts C64 filenames to macOS-safe paths by replacing reserved characters.
///
/// C64 filenames may contain `/`, `:`, `\`, or null bytes, which are invalid
/// or problematic in macOS paths. This function neutralizes them.
private func sanitizeForMacOS(_ name: String) -> String {
    return name.map { ch -> Character in
        switch ch {
        case "/": return "-"
        case ":": return "-"
        case "\\": return "-"
        case "\0": return "_"
        default: return ch
        }
    }.map { String($0) }.joined()
}

// ═══════════════════════════════════════════════════════════
// MARK: - Uppercase Formatter
// ═══════════════════════════════════════════════════════════

/// NSTextFormatter that forces text field input to uppercase.
///
/// Matches C64 PETSCII filename behavior where case is typically ignored
/// or normalized to upper-case.
private class UppercaseFormatter: Formatter {
    override func string(for obj: Any?) -> String? {
        return (obj as? String)?.uppercased()
    }
    override func getObjectValue(_ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?,
                                 for string: String,
                                 errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        obj?.pointee = string.uppercased() as AnyObject
        return true
    }
    override func isPartialStringValid(_ partialString: String,
                                       newEditingString newString: AutoreleasingUnsafeMutablePointer<NSString?>?,
                                       errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        let upper = partialString.uppercased()
        if upper != partialString {
            newString?.pointee = upper as NSString
            return false
        }
        return true
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - D64 Browser Window Controller
// ═══════════════════════════════════════════════════════════

/// NSWindowController hosting the disk image browser interface.
///
/// Initializes a titled, resizable window configured with the application theme.
class D64BrowserWindowController: NSWindowController {

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Disk Browser"
        window.center()
        window.minSize = NSSize(width: 480, height: 380)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = AppTheme.current.editorBackground

        self.init(window: window)
        window.contentViewController = D64BrowserViewController()
    }

    @objc func closeTab(_ sender: Any?) {
        window?.performClose(sender)
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - D64 Browser View Controller
// ═══════════════════════════════════════════════════════════

/// NSViewController managing the disk browser UI and file operations.
///
/// Uses frame-based layout for predictable rendering of the directory table
/// and avoids Auto Layout constraint overhead for a complex, dynamic view.
class D64BrowserViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    /// The currently loaded disk image (D64 or D81).
    private var diskImage: (any DiskImage)?
    private var directoryEntries: [CBMDirectoryEntry] = []

    /// Modification date of the image file at the time it was last loaded or
    /// saved by this window. Used to detect the image changing underneath us
    /// (e.g. the build pipeline writing through DiskImageService).
    private var loadedModificationDate: Date?

    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var headerLabel: NSTextField!
    private var statusLabel: NSTextField!

    private var bgColor:  NSColor { AppTheme.current.panelBackground }
    private var tableBg:  NSColor { AppTheme.current.panelDetailBackground }

    override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 520))
        view.wantsLayer = true
        view.layer?.backgroundColor = bgColor.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange(_:)),
            name: .appThemeDidChange, object: nil)
        buildUI()
    }

    private func buildUI() {
        let w = view.bounds.width
        var y = view.bounds.height - 8

        // ── Toolbar Buttons ────────────────────────────────
        y -= 28
        let buttons: [(String, Selector)] = [
            ("Open…",    #selector(openDisk(_:))),
            ("New D64…", #selector(newD64(_:))),
            ("New D81…", #selector(newD81(_:))),
            ("Save",     #selector(saveDisk(_:))),
            ("Save As…", #selector(saveDiskAs(_:))),
        ]
        var btnX: CGFloat = 12
        for (title, action) in buttons {
            let btn = NSButton(title: title, target: self, action: action)
            let btnW: CGFloat = CGFloat(title.count) * 8.5 + 16
            btn.frame = NSRect(x: btnX, y: y, width: btnW, height: 24)
            btn.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
            btn.autoresizingMask = [.minYMargin]
            view.addSubview(btn)
            btnX += btnW + 4
        }

        // ── Disk Header ────────────────────────────────────
        y -= 30
        headerLabel = NSTextField(labelWithString: "No disk loaded")
        headerLabel.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .bold)
        headerLabel.textColor = AppTheme.current.syntaxKeyword
        headerLabel.frame = NSRect(x: 12, y: y, width: w - 24, height: 20)
        headerLabel.autoresizingMask = [.width, .minYMargin]
        view.addSubview(headerLabel)

        // ── File Operations Bar ────────────────────────────
        y -= 28
        let fileButtons: [(String, Selector)] = [
            ("Extract PRG…", #selector(extractFile(_:))),
            ("Add File…",    #selector(addFile(_:))),
            ("Rename…",      #selector(renameFile(_:))),
            ("Delete",       #selector(deleteFile(_:))),
            ("Open in IDE",  #selector(openInIDE(_:))),
            ("Disassemble",  #selector(disassembleFile(_:))),
        ]
        var fileBtnX: CGFloat = 12
        for (title, action) in fileButtons {
            let btn = NSButton(title: title, target: self, action: action)
            let btnW: CGFloat = CGFloat(title.count) * 7.5 + 16
            btn.frame = NSRect(x: fileBtnX, y: y, width: btnW, height: 22)
            btn.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
            btn.autoresizingMask = [.minYMargin]
            view.addSubview(btn)
            fileBtnX += btnW + 4
        }

        // ── Directory Table ────────────────────────────────
        y -= 10

        tableView = NSTableView()
        tableView.backgroundColor = tableBg
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.headerView = nil
        tableView.rowHeight = 20
        tableView.intercellSpacing = NSSize(width: 4, height: 2)
        tableView.dataSource = self
        tableView.delegate   = self
        tableView.doubleAction = #selector(tableDoubleClicked(_:))
        tableView.target = self

        let blocksCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("blocks"))
        blocksCol.title = "Blocks"; blocksCol.width = 50; blocksCol.minWidth = 40
        tableView.addTableColumn(blocksCol)

        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameCol.title = "Filename"; nameCol.width = 200; nameCol.minWidth = 100
        tableView.addTableColumn(nameCol)

        let typeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("type"))
        typeCol.title = "Type"; typeCol.width = 50; typeCol.minWidth = 40
        tableView.addTableColumn(typeCol)

        let trackCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("track"))
        trackCol.title = "T/S"; trackCol.width = 50; trackCol.minWidth = 40
        tableView.addTableColumn(trackCol)

        scrollView = NSScrollView(frame: NSRect(x: 12, y: 38, width: w - 24, height: y - 38))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        view.addSubview(scrollView)

        // ── Status Bar ─────────────────────────────────────
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = AppTheme.current.statusLabel
        statusLabel.frame = NSRect(x: 12, y: 12, width: w - 24, height: 18)
        statusLabel.autoresizingMask = [.width]
        view.addSubview(statusLabel)
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
        reloadIfChangedOnDisk()
    }

    private func applyThemeColors() {
        view.window?.appearance     = AppTheme.current.nsAppearance
        view.layer?.backgroundColor = AppTheme.current.panelBackground.cgColor
        headerLabel.textColor       = AppTheme.current.syntaxKeyword
        statusLabel.textColor       = AppTheme.current.statusLabel
        tableView.backgroundColor   = AppTheme.current.panelDetailBackground
        scrollView.backgroundColor  = AppTheme.current.panelDetailBackground
        tableView.reloadData()
    }

    // MARK: - External Change Coordination

    // The browser used to mutate its private in-memory DiskImage and
    // auto-save directly, which made it a second, unserialized writer to
    // files the build pipeline also writes through DiskImageService.
    // Two rules fix that:
    //
    // 1. Mutations on an image that exists on disk are routed through
    //    DiskImageService (serialized on its queue), then the browser
    //    reloads the authoritative on-disk state.
    // 2. Every user action first checks whether the file changed underneath
    //    us (reload-on-access) and reloads if so.
    //
    // Images without a fileURL (freshly created, not yet saved) are mutated
    // in memory as before - there is no file to conflict with.

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Reloads the image from disk if it changed since we last loaded or
    /// saved it. If there are also unsaved in-memory changes, asks the user
    /// which side wins instead of silently discarding either.
    private func reloadIfChangedOnDisk() {
        guard let disk = diskImage, let url = disk.fileURL else { return }
        let current = Self.modificationDate(of: url)
        guard current != loadedModificationDate else { return }

        if disk.isModified {
            let alert = NSAlert()
            alert.messageText     = "\"\(url.lastPathComponent)\" changed on disk"
            alert.informativeText = "The disk image was modified outside this window (possibly by a build), and you have unsaved changes here. Reload from disk and lose your changes, or keep editing in memory?"
            alert.alertStyle      = .warning
            alert.addButton(withTitle: "Reload")
            alert.addButton(withTitle: "Keep My Changes")
            guard alert.runModal() == .alertFirstButtonReturn else {
                // User kept the in-memory copy. Remember the on-disk date so
                // we do not re-prompt until the file changes again.
                loadedModificationDate = current
                return
            }
        }

        do {
            diskImage = try Self.loadDiskImage(from: url)
            loadedModificationDate = current
            refreshDirectory()
            statusLabel.stringValue = "Reloaded \(url.lastPathComponent) (changed on disk)."
        } catch {
            statusLabel.stringValue = "Reload failed: \(error.localizedDescription)"
        }
    }

    /// Reloads the image after a DiskImageService mutation so the browser
    /// reflects the authoritative on-disk state the service just wrote.
    private func reloadAfterServiceMutation(url: URL, status: String) {
        do {
            diskImage = try Self.loadDiskImage(from: url)
            loadedModificationDate = Self.modificationDate(of: url)
            refreshDirectory()
            statusLabel.stringValue = status
        } catch {
            statusLabel.stringValue = "Reload failed: \(error.localizedDescription)"
        }
    }

    var hasUnsavedChanges: Bool { diskImage?.isModified ?? false }

    /// Prompts the user to save unsaved changes before closing.
    /// Returns `true` if the user proceeds (save, don't save, or cancel handled).
    func promptToSaveIfNeeded() -> Bool {
        guard let disk = diskImage, disk.isModified else { return true }

        let ext  = disk is D81Image ? "d81" : "d64"
        let name = disk.fileURL?.lastPathComponent ?? "Untitled.\(ext)"
        let alert = NSAlert()
        alert.messageText     = "Save changes to \"\(name)\"?"
        alert.informativeText = "The disk image has unsaved changes."
        alert.alertStyle      = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let url = disk.fileURL {
                try? disk.save()
                loadedModificationDate = Self.modificationDate(of: url)
            } else {
                saveAs(disk: disk)
            }
            return true
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    // MARK: - Refresh

    private func refreshDirectory() {
        guard let disk = diskImage else {
            directoryEntries = []
            headerLabel.stringValue = "No disk loaded"
            statusLabel.stringValue = ""
            tableView.reloadData()
            return
        }

        directoryEntries = disk.readDirectory()
        headerLabel.stringValue = "0 \"\(disk.diskName)\" \(disk.diskID) \(disk.dosType)"
        statusLabel.stringValue = "\(directoryEntries.count) files, \(disk.freeBlocks) blocks free"

        if let url = disk.fileURL {
            let formatTag = disk is D81Image ? "D81" : "D64"
            view.window?.title = "\(formatTag) — \(url.lastPathComponent)"
        }

        tableView.reloadData()
    }

    private func selectedEntry() -> CBMDirectoryEntry? {
        let row = tableView.selectedRow
        guard row >= 0, row < directoryEntries.count else { return nil }
        return directoryEntries[row]
    }

    // MARK: - Disk Actions

    /// Opens a D64 or D81 disk image via file panel.
    @objc private func openDisk(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .init(filenameExtension: "d64")!,
            .init(filenameExtension: "d81")!,
        ]
        panel.title = "Open Disk Image"

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                self?.diskImage = try Self.loadDiskImage(from: url)
                self?.loadedModificationDate = Self.modificationDate(of: url)
                self?.refreshDirectory()
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    /// Loads the appropriate `DiskImage` subclass based on file extension or size.
    static func loadDiskImage(from url: URL) throws -> any DiskImage {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "d81":
            return try D81Image(contentsOf: url)
        case "d64":
            return try D64Image(contentsOf: url)
        default:
            // Fallback: guess format by file size
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if size >= D81Image.standardSize {
                return try D81Image(contentsOf: url)
            } else {
                return try D64Image(contentsOf: url)
            }
        }
    }

    @objc private func newD64(_ sender: Any?) {
        presentNewDiskDialog(format: "D64") { name, id in
            self.diskImage = D64Image(diskName: name, diskID: id)
            self.refreshDirectory()
            self.statusLabel.stringValue = "New D64 created: \"\(name)\" — save with Save As…"
        }
    }

    @objc private func newD81(_ sender: Any?) {
        presentNewDiskDialog(format: "D81") { name, id in
            self.diskImage = D81Image(diskName: name, diskID: id)
            self.refreshDirectory()
            self.statusLabel.stringValue = "New D81 created: \"\(name)\" — save with Save As…"
        }
    }

    private func presentNewDiskDialog(format: String, completion: @escaping (String, String) -> Void) {
        let alert = NSAlert()
        alert.messageText     = "New \(format) Disk Image"
        alert.informativeText = "Enter disk name and ID:"

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 56))

        let nameLabel = NSTextField(labelWithString: "Name:")
        nameLabel.frame = NSRect(x: 0, y: 32, width: 45, height: 20)
        nameLabel.font  = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        accessory.addSubview(nameLabel)

        let nameField = NSTextField(string: "NEW DISK")
        nameField.font  = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        nameField.frame = NSRect(x: 50, y: 32, width: 200, height: 22)
        accessory.addSubview(nameField)

        let idLabel = NSTextField(labelWithString: "ID:")
        idLabel.frame = NSRect(x: 0, y: 4, width: 45, height: 20)
        idLabel.font  = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        accessory.addSubview(idLabel)

        let idField = NSTextField(string: "C6")
        idField.font  = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        idField.frame = NSRect(x: 50, y: 4, width: 60, height: 22)
        accessory.addSubview(idField)

        alert.accessoryView = accessory
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        completion(nameField.stringValue, idField.stringValue)
    }

    @objc private func saveDisk(_ sender: Any?) {
        guard let disk = diskImage else { return }
        if let url = disk.fileURL {
            do {
                try disk.save()
                loadedModificationDate = Self.modificationDate(of: url)
                statusLabel.stringValue = "Saved."
            } catch {
                NSAlert(error: error).runModal()
            }
        } else {
            saveDiskAs(sender)
        }
    }

    @objc private func saveDiskAs(_ sender: Any?) {
        guard let disk = diskImage else { return }
        saveAs(disk: disk)
    }

    private func saveAs(disk: any DiskImage) {
        let isD81 = disk is D81Image
        let ext   = isD81 ? "d81" : "d64"
        let panel = NSSavePanel()
        panel.allowedContentTypes    = [.init(filenameExtension: ext)!]
        panel.nameFieldStringValue   = "\(disk.diskName.trimmingCharacters(in: .whitespaces)).\(ext)"

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try disk.save(to: url)
                self?.loadedModificationDate = Self.modificationDate(of: url)
                let formatTag = isD81 ? "D81" : "D64"
                self?.view.window?.title = "\(formatTag) — \(url.lastPathComponent)"
                self?.statusLabel.stringValue = "Saved to \(url.lastPathComponent)"
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    // MARK: - File Actions

    @objc private func extractFile(_ sender: Any?) {
        reloadIfChangedOnDisk()
        guard let disk = diskImage, let entry = selectedEntry() else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(sanitizeForMacOS(entry.name.lowercased())).\(entry.isPRG ? "prg" : "seq")"
        panel.title = "Extract \"\(entry.name)\""

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let data = disk.extractPRG(entry)
            try? data.write(to: url)
        }
    }

    @objc private func addFile(_ sender: Any?) {
        guard diskImage != nil else {
            statusLabel.stringValue = "Open or create a disk image first."
            return
        }
        reloadIfChangedOnDisk()
        guard let disk = diskImage else { return }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "prg")!]
        panel.title = "Add PRG to Disk"

        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            guard let fileData = try? Data(contentsOf: url) else { return }

            let filename = String(url.deletingPathExtension().lastPathComponent.uppercased().prefix(16))

            if let imageURL = disk.fileURL {
                // On-disk image: write through DiskImageService so the
                // operation is serialized with the build pipeline, then
                // reload the authoritative state.
                do {
                    try DiskImageService.shared.addFile(named: filename, data: fileData, to: imageURL)
                    self.reloadAfterServiceMutation(url: imageURL, status: "Added \"\(filename)\" to disk.")
                } catch {
                    self.statusLabel.stringValue = "Add failed: \(error.localizedDescription)"
                }
            } else {
                // Unsaved in-memory image: mutate directly. Persisted later
                // via Save As.
                if disk.writeFile(name: filename, type: 0x82, data: Array(fileData)) {
                    self.refreshDirectory()
                    self.statusLabel.stringValue = "Added \"\(filename)\" to disk."
                } else {
                    self.statusLabel.stringValue = "Failed to write - disk may be full."
                }
            }
        }
    }

    @objc private func deleteFile(_ sender: Any?) {
        reloadIfChangedOnDisk()
        guard let disk = diskImage, let entry = selectedEntry() else { return }

        let alert = NSAlert()
        alert.messageText     = "Delete \"\(entry.name)\"?"
        alert.informativeText = "This will free \(entry.fileSizeBlocks) blocks on the disk."
        alert.alertStyle      = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if let imageURL = disk.fileURL {
            do {
                try DiskImageService.shared.deleteFile(named: entry.name, from: imageURL)
                reloadAfterServiceMutation(url: imageURL, status: "Deleted \"\(entry.name)\".")
            } catch {
                statusLabel.stringValue = "Delete failed: \(error.localizedDescription)"
            }
        } else {
            disk.deleteFile(entry)
            refreshDirectory()
            statusLabel.stringValue = "Deleted \"\(entry.name)\"."
        }
    }

    @objc private func renameFile(_ sender: Any?) {
        reloadIfChangedOnDisk()
        guard let disk = diskImage, let entry = selectedEntry() else {
            statusLabel.stringValue = "Select a file to rename."
            return
        }

        let alert = NSAlert()
        alert.messageText     = "Rename \"\(entry.name)\""
        alert.informativeText = "Enter a new name (max 16 characters, PETSCII uppercase):"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let nameField = NSTextField(string: entry.name)
        nameField.font             = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        nameField.frame            = NSRect(x: 0, y: 0, width: 260, height: 24)
        nameField.placeholderString = "NEW NAME"
        nameField.formatter        = UppercaseFormatter()
        alert.accessoryView        = nameField
        alert.window.initialFirstResponder = nameField

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let newName = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty else { statusLabel.stringValue = "Name cannot be empty."; return }
        guard newName.count <= 16 else { statusLabel.stringValue = "Name too long - max 16 characters."; return }

        if let imageURL = disk.fileURL {
            do {
                try DiskImageService.shared.renameFile(named: entry.name, to: newName, on: imageURL)
                reloadAfterServiceMutation(
                    url: imageURL,
                    status: "Renamed \"\(entry.name)\" to \"\(newName.uppercased())\"."
                )
            } catch {
                statusLabel.stringValue = "Rename failed: \(error.localizedDescription)"
            }
        } else {
            if disk.renameFile(entry, to: newName) {
                refreshDirectory()
                statusLabel.stringValue = "Renamed \"\(entry.name)\" to \"\(newName.uppercased())\"."
            } else {
                statusLabel.stringValue = "A file named \"\(newName.uppercased())\" already exists."
            }
        }
    }

    @objc private func openInIDE(_ sender: Any?) {
        reloadIfChangedOnDisk()
        guard let disk = diskImage, let entry = selectedEntry(), entry.isPRG else {
            statusLabel.stringValue = "Select a PRG file to open."
            return
        }

        let prgData = disk.extractPRG(entry)
        let tempDir = FileManager.default.temporaryDirectory

        if BasicTokenizer.isTokenizedBASIC(prgData) {
            if let source = BasicTokenizer.detokenize(prgData) {
                let tempURL = tempDir.appendingPathComponent("\(sanitizeForMacOS(entry.name.lowercased())).bas")
                try? source.write(to: tempURL, atomically: true, encoding: .utf8)

                if let appDelegate = NSApp.delegate as? AppDelegate {
                    appDelegate.mainWindowController?.loadDocument(from: tempURL)
                }

                if source.contains("{$") {
                    let dialectName = BasicDialectManager.shared.activeDialect?.name
                    if dialectName != nil {
                        statusLabel.stringValue = "Opened \"\(entry.name)\" — some tokens not recognized by \(dialectName!)."
                    } else {
                        statusLabel.stringValue = "Opened \"\(entry.name)\" — has extension tokens. Try selecting a BASIC dialect from Tools → BASIC Dialect."
                    }
                } else {
                    statusLabel.stringValue = "Opened \"\(entry.name)\" as BASIC source."
                }
                return
            }
        }

        let alert = NSAlert()
        alert.messageText     = "\"\(entry.name)\" is a machine language program."
        alert.informativeText = "Would you like to open it in the disassembler?"
        alert.addButton(withTitle: "Disassemble")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            disassembleFile(sender)
        }
    }

    @objc private func disassembleFile(_ sender: Any?) {
        reloadIfChangedOnDisk()
        guard let disk = diskImage, let entry = selectedEntry(), entry.isPRG else {
            statusLabel.stringValue = "Select a PRG file to disassemble."
            return
        }

        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent("\(sanitizeForMacOS(entry.name.lowercased())).prg")
        let data    = disk.extractPRG(entry)
        try? data.write(to: tempURL)

        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.openDisassemblerWith(url: tempURL)
        }

        statusLabel.stringValue = "Disassembling \"\(entry.name)\"…"
    }

    @objc private func tableDoubleClicked(_ sender: Any?) {
        guard let entry = selectedEntry(), entry.isPRG else { return }
        openInIDE(sender)
    }

    // MARK: - Table View

    func numberOfRows(in tableView: NSTableView) -> Int { directoryEntries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < directoryEntries.count, let colID = tableColumn?.identifier.rawValue else { return nil }
        let entry = directoryEntries[row]

        let cell = NSTextField(labelWithString: "")
        cell.font          = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        cell.lineBreakMode = .byTruncatingTail

        switch colID {
        case "blocks":
            cell.stringValue = "\(entry.fileSizeBlocks)"
            cell.textColor   = AppTheme.current.statusLabel
        case "name":
            cell.stringValue = "\"\(entry.name)\""
            cell.textColor   = AppTheme.current.syntaxKeyword
            cell.font        = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        case "type":
            cell.stringValue = entry.typeString
            cell.textColor   = entry.isPRG ? AppTheme.current.syntaxFunction : AppTheme.current.statusLabel
        case "track":
            cell.stringValue = "\(entry.dataTrack)/\(entry.dataSector)"
            cell.textColor   = AppTheme.current.statusLabel
        default: break
        }

        return cell
    }
}

