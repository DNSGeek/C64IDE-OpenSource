import AppKit

// MARK: - Toolbar Item Identifiers

extension NSToolbarItem.Identifier {
    /// Identifier for the "Run on MEGA65" toolbar button.
    static let mega65RunOnHardware = NSToolbarItem.Identifier("mega65RunOnHardware")
    /// Identifier for the "Load on MEGA65" toolbar button.
    static let mega65LoadOnly      = NSToolbarItem.Identifier("mega65LoadOnly")
    /// Identifier for the "MEGA65 Settings" toolbar button.
    static let mega65Settings      = NSToolbarItem.Identifier("mega65Settings")
}

// MARK: - MEGA65 Toolbar Controller

/// Provides toolbar items for MEGA65 hardware integration via the `etherload` utility.
@MainActor
final class MEGA65ToolbarController {

    static let shared = MEGA65ToolbarController()
    private init() {}

    static let identifiers: [NSToolbarItem.Identifier] = [
        .mega65RunOnHardware, .mega65LoadOnly, .mega65Settings
    ]

    /// Returns the configured toolbar item for the given identifier.
    func toolbarItem(for identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        switch identifier {
        case .mega65RunOnHardware: return makeRunItem()
        case .mega65LoadOnly:      return makeLoadItem()
        case .mega65Settings:      return makeSettingsItem()
        default:                   return nil
        }
    }

    /// Creates the "Run on MEGA65" toolbar item.
    private func makeRunItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .mega65RunOnHardware)
        item.label   = "Run on MEGA65"
        item.toolTip = "Build and run on MEGA65 hardware via etherload (⌃⌘M)"
        item.image   = NSImage(systemSymbolName: "play.rectangle.fill",
                               accessibilityDescription: "Run on MEGA65")
        item.target  = MEGA65BuildPipeline.shared
        item.action  = #selector(MEGA65BuildPipeline.runOnHardware)
        return item
    }

    /// Creates the "Load on MEGA65" toolbar item.
    private func makeLoadItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .mega65LoadOnly)
        item.label   = "Load on MEGA65"
        item.toolTip = "Build and load (don't run) on MEGA65 via etherload"
        item.image   = NSImage(systemSymbolName: "tray.and.arrow.down.fill",
                               accessibilityDescription: "Load on MEGA65")
        item.target  = MEGA65BuildPipeline.shared
        item.action  = #selector(MEGA65BuildPipeline.loadOnHardware)
        return item
    }

    /// Creates the "MEGA65 Settings" toolbar item.
    private func makeSettingsItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .mega65Settings)
        item.label   = "MEGA65 Settings"
        item.toolTip = "Configure MEGA65 etherload path"
        item.image   = NSImage(systemSymbolName: "cpu",
                               accessibilityDescription: "MEGA65 Settings")
        item.target  = MEGA65BuildPipeline.shared
        item.action  = #selector(MEGA65BuildPipeline.openSettings)
        return item
    }
}

// MARK: - MEGA65 Build Pipeline

/// Bridges the IDE's build system to the MEGA65Client (etherload).
/// Builds the current file (BASIC tokenise or ca65 assemble),
/// writes it to a temp PRG, then hands it to etherload.
@MainActor
final class MEGA65BuildPipeline: NSObject {

    static let shared = MEGA65BuildPipeline()
    private override init() {}

    private var settingsWindow: NSWindow?

    // MARK: - Toolbar Actions

    /// Triggers a full build and immediate execution on MEGA65 hardware.
    @objc func runOnHardware() {
        Task { await buildAndSend(loadOnly: false) }
    }

    /// Triggers a build and transfers the PRG to MEGA65 without executing.
    @objc func loadOnHardware() {
        Task { await buildAndSend(loadOnly: true) }
    }

    /// Opens the MEGA65 configuration panel.
    @objc func openSettings() {
        if settingsWindow == nil {
            settingsWindow = MEGA65SettingsViewController.asWindow()
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Core Pipeline

    /// Executes the build-and-transfer pipeline for MEGA65.
    private func buildAndSend(loadOnly: Bool) async {
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let wc = appDelegate.mainWindowController else {
            logMessage("MEGA65: No active editor.", type: .error)
            return
        }

        let doc = wc.editorViewController.document
        wc.bottomPanelController.selectTab(.build)

        logBuild("═══════════════════════════════════════", type: .plain)
        logBuild("Building for MEGA65…", type: .plain)
        logBuild("═══════════════════════════════════════", type: .plain)

        // Step 1: Build the PRG
        guard let prgURL = await BuildPipelineSupport.buildPRG(windowController: wc,
                                                                document: doc) else {
            logBuild("✗ MEGA65: Build failed.", type: .error)
            return
        }
        let sizeBytes = (try? prgURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        logBuild("✓ Built PRG (\(sizeBytes) bytes)", type: .success)

        // Step 2: Resolve mode flags
        // Detects if the active dialect targets MEGA65 BASIC 65 vs standard C64 BASIC
        let activeLoadAddress = BasicDialectManager.shared.activeDialect?.loadAddress
        let m65Mode = activeLoadAddress == Int(BasicTokenizer.mega65StartAddress)
        let ntsc    = wc.buildConfig.viceVideoStandard.lowercased().contains("ntsc")

        let modeLabel = m65Mode ? "--m65mode" : "--c64mode"
        let tvLabel   = ntsc    ? "NTSC"      : "PAL"
        logBuild("  Mode: \(modeLabel)  TV: \(tvLabel)  Run: \(!loadOnly)", type: .plain)

        // Step 3: Send via etherload
        do {
            try await MEGA65Client.shared.sendPRG(at: prgURL, m65Mode: m65Mode,
                                                   ntsc: ntsc, run: !loadOnly)
            if loadOnly {
                logBuild("✓ Loaded on MEGA65. Type RUN to start.", type: .success)
            } else {
                logBuild("✓ Running on MEGA65!", type: .success)
            }
        } catch {
            logMessage("MEGA65 transfer failed: \(error.localizedDescription)", type: .error)
            logBuild("✗ MEGA65: transfer failed (see Messages tab).", type: .error)
        }
    }

    // MARK: - Logging

    private func logBuild(_ message: String, type: MessageType) {
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let wc = appDelegate.mainWindowController else { return }
        wc.bottomPanelController.appendBuildOutput(message, type: type)
    }

    private func logMessage(_ message: String, type: MessageType) {
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let wc = appDelegate.mainWindowController else { return }
        wc.bottomPanelController.appendMessage(message, type: type)
    }
}

