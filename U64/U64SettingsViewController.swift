import AppKit
import Combine

// MARK: - U64 Settings View Controller

/// A settings panel for configuring the Ultimate 64 connection.
/// Designed to be embedded in a preferences window or presented as a standalone sheet.
@MainActor
final class U64SettingsViewController: NSViewController {

    // MARK: - UI Elements

    private let hostLabel: NSTextField = {
        let l = NSTextField(labelWithString: "U64 Host:")
        l.alignment = .right
        return l
    }()

    private let hostField: NSTextField = {
        let f = NSTextField()
        f.placeholderString = "192.168.1.x  or  ultimate64.local"
        f.bezelStyle        = .roundedBezel
        return f
    }()

    private let passwordLabel: NSTextField = {
        let l = NSTextField(labelWithString: "Password:")
        l.alignment = .right
        return l
    }()

    private let passwordField: NSSecureTextField = {
        let f = NSSecureTextField()
        f.placeholderString = "Leave blank if not set"
        f.bezelStyle        = .roundedBezel
        return f
    }()

    private let autoRunCheckbox: NSButton = {
        let b = NSButton(checkboxWithTitle: "Run after build (⌘R)", target: nil, action: nil)
        b.toolTip = "When off, ⌘R loads the program on the U64 without running it. "
                  + "The Run and Load toolbar buttons always do what they say."
        return b
    }()

    private let testButton: NSButton = {
        let b = NSButton(title: "Test Connection", target: nil, action: nil)
        b.bezelStyle = .rounded
        return b
    }()

    private let statusIndicator: NSImageView = {
        let iv = NSImageView()
        iv.imageScaling = .scaleProportionallyDown
        return iv
    }()

    private let statusLabel: NSTextField = {
        let l = NSTextField(labelWithString: "Not connected")
        l.textColor = .secondaryLabelColor
        l.font      = .systemFont(ofSize: 11)
        return l
    }()

    private let infoBox: NSBox = {
        let b = NSBox()
        b.title     = "Device Info"
        b.isHidden  = true
        return b
    }()

    private let infoLabel: NSTextField = {
        let l = NSTextField(labelWithString: "")
        l.isEditable   = false
        l.isBordered   = false
        l.drawsBackground = false
        l.font         = .monospacedSystemFont(ofSize: 11, weight: .regular)
        l.textColor    = .labelColor
        l.maximumNumberOfLines = 0
        return l
    }()

    // MARK: - State

    private var cancellables = Set<AnyCancellable>()
    private var isTesting    = false

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 300))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildLayout()
        loadSettings()
        bindClient()
    }

    // MARK: - Layout

    /// Manually positions all UI elements using a top-down coordinate system.
    private func buildLayout() {
        let labelWidth: CGFloat = 80
        let fieldWidth: CGFloat = 280
        let rowHeight:  CGFloat = 24
        let rowGap:     CGFloat = 10
        var y: CGFloat  = view.bounds.height - 36

        // Helper to add a label+field row
        func addRow(label: NSTextField, field: NSView) {
            label.frame = NSRect(x: 20, y: y, width: labelWidth, height: rowHeight)
            field.frame = NSRect(x: 108, y: y, width: fieldWidth, height: rowHeight)
            view.addSubview(label)
            view.addSubview(field)
            y -= rowHeight + rowGap
        }

        addRow(label: hostLabel,     field: hostField)
        addRow(label: passwordLabel, field: passwordField)

        // Auto-run checkbox
        y -= 4
        autoRunCheckbox.frame = NSRect(x: 108, y: y, width: fieldWidth, height: rowHeight)
        view.addSubview(autoRunCheckbox)
        y -= rowHeight + rowGap + 4

        // Test button + status row
        testButton.frame        = NSRect(x: 108, y: y, width: 130, height: 28)
        statusIndicator.frame   = NSRect(x: 248, y: y + 5, width: 16, height: 16)
        statusLabel.frame       = NSRect(x: 270, y: y + 4, width: 160, height: 20)
        testButton.target       = self
        testButton.action       = #selector(testConnectionTapped)
        view.addSubview(testButton)
        view.addSubview(statusIndicator)
        view.addSubview(statusLabel)
        y -= 36 + rowGap

        // Buttons occupy the bottom band; the info box gets whatever is left
        // above it. The old `max(40, y - 40)` anchored the box at y = 12, which
        // put the Save button inside its border.
        let buttonBandTop: CGFloat = 14 + 28 + 12
        let infoHeight = max(40, y - buttonBandTop)
        infoBox.frame = NSRect(x: 16, y: buttonBandTop,
                               width: view.bounds.width - 32, height: infoHeight)
        infoLabel.frame = NSRect(x: 8, y: 8,
                                 width: infoBox.frame.width - 16,
                                 height: infoBox.frame.height - 28)
        infoBox.addSubview(infoLabel)
        view.addSubview(infoBox)

        // Cancel + Save — bottom right
        let cancelBtn = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancelBtn.bezelStyle    = .rounded
        cancelBtn.keyEquivalent = "\u{1b}"          // Escape
        cancelBtn.frame = NSRect(x: view.bounds.width - 188, y: 14, width: 80, height: 28)
        view.addSubview(cancelBtn)

        let saveBtn = NSButton(title: "Save", target: self, action: #selector(saveTapped))
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        saveBtn.frame = NSRect(x: view.bounds.width - 100, y: 14,
                               width: 80, height: 28)
        view.addSubview(saveBtn)
    }

    // MARK: - Data Binding

    /// Subscribes to the U64 client's connection state and updates the UI accordingly.
    ///
    /// No `receive(on: RunLoop.main)`: the client and this controller are both
    /// `@MainActor`, and the hop let the generic "Connected" text land *after*
    /// the detailed "Connected ✓" that `testConnectionTapped` had just set.
    /// While a test is running the sink stands aside entirely, so it can't
    /// overwrite either the progress or the error message.
    private func bindClient() {
        U64Client.shared.$isConnected
            .sink { [weak self] connected in
                guard let self, !self.isTesting else { return }
                self.updateStatusUI(connected: connected)
            }
            .store(in: &cancellables)
    }

    /// Loads persisted settings from UserDefaults and the Keychain.
    private func loadSettings() {
        hostField.stringValue     = U64Client.shared.host
        passwordField.stringValue = U64Client.shared.password
        autoRunCheckbox.state     = U64Client.shared.autoRun ? .on : .off
        updateStatusUI(connected: U64Client.shared.isConnected)
        if let info = U64Client.shared.lastInfo { populateInfoBox(info) }
    }

    // MARK: - Actions

    @objc private func saveTapped() {
        commitFields()

        // Report a Keychain write that didn't land instead of closing on a
        // save that silently didn't happen.
        if U64Client.shared.lastPasswordStoreFailed {
            setStatus(text: "Could not save the password to the Keychain.",
                      color: .systemRed,
                      symbol: NSImage(systemSymbolName: "xmark.circle.fill",
                                      accessibilityDescription: nil))
            NSSound.beep()
            return
        }

        view.window?.performClose(self)
    }

    @objc private func cancelTapped() {
        view.window?.performClose(self)
    }

    @objc private func testConnectionTapped() {
        guard !isTesting else { return }
        commitFields()
        isTesting = true
        testButton.isEnabled = false
        setStatus(text: "Testing…", color: .secondaryLabelColor, symbol: nil)
        infoBox.isHidden = true

        Task {
            defer {
                self.isTesting = false
                self.testButton.isEnabled = true
            }
            do {
                let info = try await U64Client.shared.testConnection()
                setStatus(text: "Connected ✓", color: .systemGreen,
                          symbol: NSImage(systemSymbolName: "checkmark.circle.fill",
                                         accessibilityDescription: nil))
                populateInfoBox(info)
            } catch {
                setStatus(text: error.localizedDescription,
                          color: .systemRed,
                          symbol: NSImage(systemSymbolName: "xmark.circle.fill",
                                         accessibilityDescription: nil))
            }
        }
    }

    // MARK: - Helpers

    /// Commits current UI values to the client and UserDefaults.
    private func commitFields() {
        U64Client.shared.host     = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        U64Client.shared.password = passwordField.stringValue
        // Goes through the client rather than a bare UserDefaults key, so the
        // run path reads the same value the checkbox writes.
        U64Client.shared.autoRun  = autoRunCheckbox.state == .on
    }

    private func updateStatusUI(connected: Bool) {
        if connected {
            setStatus(text: "Connected", color: .systemGreen,
                      symbol: NSImage(systemSymbolName: "checkmark.circle.fill",
                                      accessibilityDescription: nil))
        } else {
            setStatus(text: "Not connected", color: .secondaryLabelColor, symbol: nil)
        }
    }

    private func setStatus(text: String, color: NSColor, symbol: NSImage?) {
        statusLabel.stringValue = text
        statusLabel.textColor   = color
        statusIndicator.image   = symbol
        statusIndicator.contentTintColor = color
    }

    private func populateInfoBox(_ info: U64InfoResponse) {
        var lines: [String] = []
        if let p  = info.product          { lines.append("Product:   \(p)") }
        if let fw = info.firmwareVersion   { lines.append("Firmware:  \(fw)") }
        if let fp = info.fpgaVersion       { lines.append("FPGA:      \(fp)") }
        if let cv = info.coreVersion       { lines.append("Core:      \(cv)") }
        if let h  = info.hostname          { lines.append("Hostname:  \(h)") }
        if let id = info.uniqueId          { lines.append("Unique ID: \(id)") }
        infoLabel.stringValue = lines.joined(separator: "\n")
        infoBox.isHidden      = lines.isEmpty
    }
}

// MARK: - Toolbar integration helper

extension U64SettingsViewController {
    /// Intercepts ⌘W to close this settings window instead of an IDE editor tab.
    @objc func closeTab(_ sender: Any?) {
        view.window?.performClose(sender)
    }

    /// Convenience: wraps the view controller in a standalone settings window.
    ///
    /// Named for what it is — it is opened with `makeKeyAndOrderFront`, never
    /// presented as a sheet.
    static func asWindow() -> NSWindow {
        let vc  = U64SettingsViewController()
        let win = NSWindow(contentViewController: vc)
        win.title = "Ultimate 64 Settings"
        win.styleMask = [.titled, .closable]
        win.setContentSize(NSSize(width: 440, height: 300))

        // A programmatic NSWindow defaults to isReleasedWhenClosed = true, which
        // over-releases under ARC once U64BuildPipeline also holds it — closing
        // the panel then left a dangling reference for the next open to message.
        win.isReleasedWhenClosed = false

        return win
    }
}

