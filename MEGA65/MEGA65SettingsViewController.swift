import AppKit

// MARK: - MEGA65 Settings View Controller

/// A preferences panel for the MEGA65 etherload integration.
/// Allows the user to browse for (or type) the path to the `etherload` binary.
final class MEGA65SettingsViewController: NSViewController {

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

    private let noteLabel: NSTextField = {
        let l = NSTextField(wrappingLabelWithString:
            "etherload is an optional third-party tool provided by the MEGA65 project. " +
            "If it is on your $PATH you can leave this blank and it will be found automatically.")
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
        view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 200))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildLayout()
        loadSettings()
    }

    // MARK: - Layout

    /// Arranges UI elements using explicit frames for a compact, fixed-size panel.
    private func buildLayout() {
        let labelWidth: CGFloat = 82
        let rowHeight:  CGFloat = 24
        var y: CGFloat          = view.frame.height - 36

        // Path row: label + field + browse button
        pathLabel.frame  = NSRect(x: 20,  y: y, width: labelWidth, height: rowHeight)
        pathField.frame  = NSRect(x: 108, y: y, width: 254,        height: rowHeight)
        browseButton.frame = NSRect(x: 368, y: y - 2, width: 88, height: 28)

        browseButton.target = self
        browseButton.action = #selector(browseTapped)

        view.addSubview(pathLabel)
        view.addSubview(pathField)
        view.addSubview(browseButton)
        y -= rowHeight + 14

        // Note
        noteLabel.frame = NSRect(x: 108, y: y - 28, width: 350, height: 52)
        view.addSubview(noteLabel)
        y -= 52 + 14

        // Status
        statusLabel.frame = NSRect(x: 108, y: y, width: 350, height: rowHeight)
        view.addSubview(statusLabel)

        // Buttons: Save (default) + Cancel, bottom-right
        let cancelBtn = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.frame = NSRect(x: view.frame.width - 196, y: 14, width: 80, height: 28)

        let saveBtn = NSButton(title: "Save", target: self, action: #selector(saveTapped))
        saveBtn.bezelStyle    = .rounded
        saveBtn.keyEquivalent = "\r"
        saveBtn.frame = NSRect(x: view.frame.width - 108, y: 14, width: 88, height: 28)

        view.addSubview(cancelBtn)
        view.addSubview(saveBtn)
    }

    // MARK: - Data

    private func loadSettings() {
        pathField.stringValue = MEGA65Client.shared.etherloadPath
        validatePath(pathField.stringValue)
    }

    /// Validates the entered path and updates the status label accordingly.
    private func validatePath(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // Check auto-detection via `which`
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            proc.arguments = ["etherload"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError  = Pipe()
            try? proc.run()
            proc.waitUntilExit()
            let found = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                               encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !found.isEmpty {
                statusLabel.stringValue  = "Auto-detected at \(found)"
                statusLabel.textColor    = .systemGreen
            } else {
                statusLabel.stringValue  = "Not found on $PATH — browse to set path manually."
                statusLabel.textColor    = .systemOrange
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

        panel.beginSheetModal(for: view.window!) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.pathField.stringValue = url.path
            self?.validatePath(url.path)
        }
    }

    @objc private func saveTapped() {
        let trimmed = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        MEGA65Client.shared.etherloadPath = trimmed
        view.window?.performClose(self)
    }

    @objc private func cancelTapped() {
        view.window?.performClose(self)
    }
}

// MARK: - Convenience

extension MEGA65SettingsViewController {

    /// Handles the standard "Close Tab" (⌘W) gesture for this settings window.
    @objc func closeTab(_ sender: Any?) {
        view.window?.performClose(sender)
    }

    /// Creates a standalone window instance for this settings view controller.
    static func asWindow() -> NSWindow {
        let vc  = MEGA65SettingsViewController()
        let win = NSWindow(contentViewController: vc)
        win.title     = "MEGA65 Settings"
        win.styleMask = [.titled, .closable]
        win.setContentSize(NSSize(width: 480, height: 200))
        return win
    }
}

