import AppKit

// MARK: - Toolbar Item Identifiers

extension NSToolbarItem.Identifier {
    static let u64RunOnHardware = NSToolbarItem.Identifier("u64RunOnHardware")
    static let u64LoadOnly      = NSToolbarItem.Identifier("u64LoadOnly")
    static let u64Reset         = NSToolbarItem.Identifier("u64Reset")
    static let u64Settings      = NSToolbarItem.Identifier("u64Settings")
}

// MARK: - U64 Toolbar Controller

/// Provides toolbar items for Ultimate 64 hardware integration.
@MainActor
final class U64ToolbarController {

    static let shared = U64ToolbarController()
    private init() {}

    static let identifiers: [NSToolbarItem.Identifier] = [
        .u64RunOnHardware, .u64LoadOnly, .u64Reset, .u64Settings
    ]

    /// Factory method to create a configured NSToolbarItem for the given identifier.
    func toolbarItem(for identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        switch identifier {
        case .u64RunOnHardware: return makeRunItem()
        case .u64LoadOnly:      return makeLoadItem()
        case .u64Reset:         return makeResetItem()
        case .u64Settings:      return makeSettingsItem()
        default:                return nil
        }
    }

    private func makeRunItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .u64RunOnHardware)
        item.label   = "Run on U64"
        item.toolTip = "Build and run on Ultimate 64 hardware (⌃⌘R)"
        item.image   = NSImage(systemSymbolName: "play.rectangle.fill", accessibilityDescription: "Run on U64")
        item.target  = U64BuildPipeline.shared
        item.action  = #selector(U64BuildPipeline.runOnHardware)
        return item
    }

    private func makeLoadItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .u64LoadOnly)
        item.label   = "Load on U64"
        item.toolTip = "Build and load (don't run) on Ultimate 64"
        item.image   = NSImage(systemSymbolName: "tray.and.arrow.down.fill", accessibilityDescription: "Load on U64")
        item.target  = U64BuildPipeline.shared
        item.action  = #selector(U64BuildPipeline.loadOnHardware)
        return item
    }

    private func makeResetItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .u64Reset)
        item.label   = "Reset C64"
        item.toolTip = "Send reset to the Ultimate 64"
        item.image   = NSImage(systemSymbolName: "arrow.counterclockwise.circle", accessibilityDescription: "Reset C64")
        item.target  = U64BuildPipeline.shared
        item.action  = #selector(U64BuildPipeline.resetMachine)
        return item
    }

    private func makeSettingsItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .u64Settings)
        item.label   = "U64 Settings"
        item.toolTip = "Configure Ultimate 64 connection"
        item.image   = NSImage(systemSymbolName: "cpu", accessibilityDescription: "U64 Settings")
        item.target  = U64BuildPipeline.shared
        item.action  = #selector(U64BuildPipeline.openSettings)
        return item
    }
}

// MARK: - U64 Build Pipeline

/// Bridges the IDE's build system to the U64Client.
/// Builds the current file (BASIC tokenize or ca65 assemble),
/// then sends the PRG to the Ultimate 64 via REST API.
@MainActor
final class U64BuildPipeline: NSObject {

    static let shared = U64BuildPipeline()
    private override init() {}

    private var settingsWindow: NSWindow?

    // MARK: - Toolbar Actions

    @objc func runOnHardware() {
        Task { await buildAndSend(loadOnly: false) }
    }

    @objc func loadOnHardware() {
        Task { await buildAndSend(loadOnly: true) }
    }

    @objc func resetMachine() {
        Task {
            do {
                try await U64Client.shared.reset()
                logBuild("✓ U64: C64 reset.", type: .success)
            } catch {
                logMessage("U64 reset failed: \(error.localizedDescription)", type: .error)
                logBuild("✗ U64: reset failed (see Messages tab).", type: .error)
            }
        }
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            settingsWindow = U64SettingsViewController.asSheet()
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Core Pipeline

    /// Orchestrates the build process and transfers the resulting PRG to the U64.
    private func buildAndSend(loadOnly: Bool) async {
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let wc = appDelegate.mainWindowController else {
            logMessage("U64: No active editor.", type: .error)
            return
        }

        let doc = wc.editorViewController.document
        wc.bottomPanelController.selectTab(.build)

        logBuild("═══════════════════════════════════════", type: .plain)
        logBuild("Building for Ultimate 64…", type: .plain)
        logBuild("═══════════════════════════════════════", type: .plain)

        // Step 1: Build the PRG (shared helper — see BuildPipelineSupport)
        guard let prgURL = await BuildPipelineSupport.buildPRG(windowController: wc,
                                                                document: doc) else {
            logBuild("✗ U64: Build failed.", type: .error)
            return
        }

        // U64Client expects raw bytes, not a URL — read the freshly-built PRG.
        guard let prgData = try? Data(contentsOf: prgURL) else {
            logBuild("✗ U64: PRG file not readable after build.", type: .error)
            return
        }
        logBuild("✓ Built PRG (\(prgData.count) bytes)", type: .success)

        // Step 2: Check connection
        guard !U64Client.shared.host.isEmpty else {
            logMessage("U64: Host not configured. Use Tools → U64 Settings.", type: .error)
            logBuild("✗ U64: not configured (see Messages tab).", type: .error)
            return
        }

        // Step 3: Send to hardware
        do {
            if loadOnly {
                try await U64Client.shared.loadPRG(prgData)
                logBuild("✓ Loaded on U64. Type RUN to start.", type: .success)
            } else {
                try await U64Client.shared.runPRG(prgData)
                logBuild("✓ Running on U64!", type: .success)
            }
        } catch {
            logMessage("U64 transfer failed: \(error.localizedDescription)", type: .error)
            logBuild("✗ U64: transfer failed (see Messages tab).", type: .error)
        }
    }

    // MARK: - Logging

    /// Appends a message to the build output panel.
    private func logBuild(_ message: String, type: MessageType) {
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let wc = appDelegate.mainWindowController else { return }
        wc.bottomPanelController.appendBuildOutput(message, type: type)
    }

    /// Appends a message to the general messages panel.
    private func logMessage(_ message: String, type: MessageType) {
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let wc = appDelegate.mainWindowController else { return }
        wc.bottomPanelController.appendMessage(message, type: type)
    }
}

