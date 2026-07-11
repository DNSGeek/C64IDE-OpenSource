import Cocoa

// MARK: - Map Editor Window Controller

/// Manages the main Map Editor window lifecycle, file I/O, and menu actions.
public final class MapEditorWindowController: NSWindowController {

    private var mapEditorVC: MapEditorViewController!

    /// Creates a new Map Editor window with default dimensions.
    public init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 660),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Map Editor - Untitled"
        window.minSize = NSSize(width: 640, height: 480)
        window.center()

        super.init(window: window)

        mapEditorVC = MapEditorViewController()
        window.contentViewController = mapEditorVC

        // Required so windowShouldClose fires and unsaved changes prompt
        // before the window closes.
        window.delegate = self
    }

    /// Required for storyboard/xib loading. Not supported in this programmatic UI.
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented. This window is created programmatically.")
    }

    /// Overrides the standard "Close Tab" (⌘W) behavior to close this editor window
    /// instead of propagating to the main application delegate.
    @objc public func closeTab(_ sender: Any?) {
        window?.performClose(sender)
    }

    // MARK: - Public API (called from AppDelegate menu actions)

    /// Creates a new blank map with the specified dimensions.
    /// Prompts to save unsaved changes first; does nothing if cancelled.
    public func newMap(width: Int = 40, height: Int = 25) {
        guard promptToSaveIfNeeded() else { return }
        mapEditorVC.newDocument(width: width, height: height)
        window?.title = "Map Editor - Untitled"
    }

    /// Opens a file dialog to load a `.c64map` document.
    @objc public func openMap() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "c64map")!]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.loadMap(from: url)
        }
    }

    /// Loads a map document from the given URL and updates the window title.
    /// Prompts to save unsaved changes first; does nothing if cancelled.
    /// (openMap routes through here, so it is covered too.)
    public func loadMap(from url: URL) {
        guard promptToSaveIfNeeded() else { return }
        do {
            try mapEditorVC.loadDocument(from: url)
            window?.title = "Map Editor - \(url.deletingPathExtension().lastPathComponent)"
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    /// Saves the current map to its last known URL.
    public func saveMap() {
        mapEditorVC.saveDocument()
        if let name = mapEditorVC.fileURL?.deletingPathExtension().lastPathComponent {
            window?.title = "Map Editor - \(name)"
        }
    }

    /// Opens a save panel for exporting the current map as a new `.c64map` file.
    public func saveMapAs() {
        mapEditorVC.saveDocumentAs()
    }

    /// Opens a file dialog to load a custom character set (`.chr`, `.bin`, or `.charset`).
    @objc public func loadCharset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .init(filenameExtension: "chr")!,
            .init(filenameExtension: "bin")!,
            .init(filenameExtension: "charset")!,
        ]
        panel.title = "Load Character Set"
        panel.message = "Select a 2048-byte (or larger) character set file."
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.mapEditorVC.loadCharset(from: url)
        }
    }

    /// Exports the current map as ca65-compatible assembly source.
    public func exportAssembly() {
        mapEditorVC.exportAssembly()
    }

    /// Exports the current map as raw Screen RAM and Color RAM binaries.
    public func exportBinary() {
        mapEditorVC.exportBinary()
    }

    /// Prompts the user to save unsaved changes before a destructive
    /// operation (close, new, open). Returns `true` if the operation should
    /// proceed, `false` if cancelled or if a requested save failed.
    public func promptToSaveIfNeeded() -> Bool {
        guard mapEditorVC.isModified else { return true }

        let alert = NSAlert()
        alert.messageText = "Do you want to save changes to the map?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            // Must be synchronous: the async saveDocument()/saveDocumentAs()
            // path would return before the save panel completes, and the
            // window would close out from under it. Only proceed if the
            // save actually succeeded.
            return mapEditorVC.saveDocumentModally()
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }
}

// MARK: - NSWindowDelegate

extension MapEditorWindowController: NSWindowDelegate {
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        promptToSaveIfNeeded()
    }
}

