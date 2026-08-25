import AppKit

// MARK: - MEGA65 Settings View Controller

/// A preferences panel for the MEGA65 etherload integration.
/// Allows the user to browse for (or type) the path to the `etherload` binary,
/// the MEGA65's network address, and any extra etherload flags.
///
/// Edits the window's shared `BuildConfiguration` in place, the same way
/// `BuildPreferencesViewModel` does, so a change takes effect on the next Run
/// without a restart.
final class MEGA65SettingsViewController: NSViewController {

    // MARK: - Configuration

    /// The live build configuration this panel edits. Assigned by `asWindow(config:)`.
    private var config: BuildConfiguration = BuildConfiguration()

    // MARK: - UI Elements

    private let pathLabel: NSTextField = {
        let l = NSTextField(labelWithString: "etherload:")
        l.alignment = .right
        return l
    }()

    private let pathField: NSTextField = {
        let f = NSTextField()
        f.placeholderString = "/usr/local/bin/etherload  (leave blank to auto-detect)"
        f.bezelStyle        = .roundedBezel
        return f
    }()

    private let browseButton: NSButton = {
        let b = NSButton(title: "Browse…", target: nil, action: nil)
        b.bezelStyle = .rounded
        return b
    }()

    private let hostLabel: NSTextField = {
        let l = NSTextField(labelWithString: "MEGA65 host:")
        l.alignment = .right
        return l
    }()

    private let hostField: NSTextField = {
        let f = NSTextField()
        f.placeholderString = "192.168.1.65  (blank = auto-discover)"
        f.bezelStyle        = .roundedBezel
        return f
    }()

    private let argsLabel: NSTextField = {
        let l = NSTextField(labelWithString: "Extra flags:")
        l.alignment = .right
        return l
    }()

    private let argsField: NSTextField = {
        let f = NSTextField()
        f.placeholderString = "passed to etherload before the PRG path"
        f.bezelStyle        = .roundedBezel
        return f
    }()

    private let noteLabel: NSTextField = {
        let l = NSTextField(wrappingLabelWithString:
            "etherload is an optional third-party tool provided by the MEGA65 project. "
          + "Leave the path blank and the IDE looks in the usual install locations "
          + "(Homebrew, /usr/local/bin, ~/.local/bin). "
          + "Set a host when the MEGA65 isn't reachable by broadcast on your subnet.")
        l.textColor = .secondaryLabelColor
        l.font      = .systemFont(ofSize: 11)
        return l
    }()

    private let statusLabel: NSTextField = {
        let l = NSTextField(labelWithString: "")
        l.textColor = .secondaryLabelColor
        l.font      = .systemFont(ofSize: 11)
        return l
    }()

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 280))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildLayout()
        loadSettings()
    }

    // MARK: - Layout

    /// Arranges UI elements using explicit frames for a compact, fixed-size panel.
    private func buildLayout() {
        let labelWidth: CGFloat = 94
        let rowHeight:  CGFloat = 24
        let labelX:     CGFloat = 12
        let fieldX:     CGFloat = 114
        var y:          CGFloat = view.frame.height - 40

        // Path row: label + field + browse button
        pathLabel.frame    = NSRect(x: labelX, y: y, width: labelWidth, height: rowHeight)
        pathField.frame    = NSRect(x: fieldX, y: y, width: 274, height: rowHeight)
        browseButton.frame = NSRect(x: 396, y: y - 2, width: 88, height: 28)

        browseButton.target = self
        browseButton.action = #selector(browseTapped)

        view.addSubview(pathLabel)
        view.addSubview(pathField)
        view.addSubview(browseButton)
        y -= rowHeight + 12

        // Host row
        hostLabel.frame = NSRect(x: labelX, y: y, width: labelWidth, height: rowHeight)
        hostField.frame = NSRect(x: fieldX, y: y, width: 274, height: rowHeight)
        view.addSubview(hostLabel)
        view.addSubview(hostField)
        y -= rowHeight + 12

        // Extra flags row
        argsLabel.frame = NSRect(x: labelX, y: y, width: labelWidth, height: rowHeight)
        argsField.frame = NSRect(x: fieldX, y: y, width: 274, height: rowHeight)
        view.addSubview(argsLabel)
        view.addSubview(argsField)
        y -= rowHeight + 12

        // Status
        statusLabel.frame = NSRect(x: fieldX, y: y, width: 370, height: rowHeight)
        view.addSubview(statusLabel)
        y -= rowHeight + 8

        // Note
        noteLabel.frame = NSRect(x: fieldX, y: y - 44, width: 370, height: 66)
        view.addSubview(noteLabel)

        // Buttons: Save (default) + Cancel, bottom-right
        let cancelBtn = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancelBtn.bezelStyle    = .rounded
        cancelBtn.keyEquivalent = "\u{1b}"          // Escape
        cancelBtn.frame = NSRect(x: view.frame.width - 196, y: 14, width: 80, height: 28)

        let saveBtn = NSButton(title: "Save", target: self, action: #selector(saveTapped))
        saveBtn.bezelStyle    = .rounded
        saveBtn.keyEquivalent = "\r"
        saveBtn.frame = NSRect(x: view.frame.width - 108, y: 14, width: 88, height: 28)

        view.addSubview(cancelBtn)
        view.addSubview(saveBtn)

        // Re-validate as the user types, not only on load and browse.
        pathField.delegate = self
    }

    // MARK: - Data

    private func loadSettings() {
        pathField.stringValue = config.etherloadPath
        hostField.stringValue = config.mega65Host
        argsField.stringValue = config.etherloadExtraArgs.joined(separator: " ")
        validatePath(pathField.stringValue)
    }

    /// Validates the entered path and updates the status label accordingly.
    ///
    /// Auto-detection is a filesystem scan rather than a `which` subprocess:
    /// spawning a process from `viewDidLoad` blocked the main thread while the
    /// panel opened, and `which` reads a `PATH` that a Finder-launched app
    /// doesn't have.
    private func validatePath(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            if let found = MEGA65Client.autoDetectPath() {
                statusLabel.stringValue = "Auto-detected at \(found)"
                statusLabel.textColor   = .systemGreen
            } else {
                statusLabel.stringValue = "Not found automatically — browse to set the path."
                statusLabel.textColor   = .systemOrange
            }
        } else if FileManager.default.isExecutableFile(atPath: trimmed) {
            statusLabel.stringValue = "✓ Binary found and executable."
            statusLabel.textColor   = .systemGreen
        } else if FileManager.default.fileExists(atPath: trimmed) {
            statusLabel.stringValue = "⚠ File exists but is not executable."
            statusLabel.textColor   = .systemOrange
        } else {
            statusLabel.stringValue = "✗ File not found at this path."
            statusLabel.textColor   = .systemRed
        }
    }

    // MARK: - Actions

    @objc private func browseTapped() {
        let panel = NSOpenPanel()
        panel.title              = "Locate etherload"
        panel.canChooseFiles     = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message            = "Select the etherload binary"

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.pathField.stringValue = url.path
            self?.validatePath(url.path)
        }

        // Fall back to a modal panel rather than force-unwrapping the window.
        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    @objc private func saveTapped() {
        let trimmed = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        // Refuse to persist a path that can't work — silently saving it meant
        // the failure only showed up at transfer time.
        if !trimmed.isEmpty, !FileManager.default.isExecutableFile(atPath: trimmed) {
            validatePath(trimmed)
            NSSound.beep()
            return
        }

        config.etherloadPath      = trimmed
        config.mega65Host         = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        config.etherloadExtraArgs = argsField.stringValue
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
        config.save()

        view.window?.performClose(self)
    }

    @objc private func cancelTapped() {
        view.window?.performClose(self)
    }
}

// MARK: - Live validation

extension MEGA65SettingsViewController: NSTextFieldDelegate {

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === pathField else { return }
        validatePath(pathField.stringValue)
    }
}

// MARK: - Convenience

extension MEGA65SettingsViewController {

    /// Handles the standard "Close Tab" (⌘W) gesture for this settings window.
    @objc func closeTab(_ sender: Any?) {
        view.window?.performClose(sender)
    }

    /// Creates a standalone window instance for this settings view controller.
    ///
    /// - Parameter config: The live build configuration to edit.
    static func asWindow(config: BuildConfiguration) -> NSWindow {
        let vc  = MEGA65SettingsViewController()
        vc.config = config

        let win = NSWindow(contentViewController: vc)
        win.title     = "MEGA65 Settings"
        win.styleMask = [.titled, .closable]
        win.setContentSize(NSSize(width: 500, height: 280))

        // A programmatic NSWindow defaults to isReleasedWhenClosed = true, which
        // over-releases under ARC once the caller also holds it — closing the
        // panel then left a dangling reference for the next open to message.
        win.isReleasedWhenClosed = false

        return win
    }
}
