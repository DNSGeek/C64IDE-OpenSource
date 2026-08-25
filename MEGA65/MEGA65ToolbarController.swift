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
final class MEGA65BuildPipeline: NSObject, NSMenuItemValidation, NSToolbarItemValidation {

    static let shared = MEGA65BuildPipeline()
    private override init() {}

    private var settingsWindow: NSWindow?

    /// The in-flight transfer, if any.
    ///
    /// etherload talks to one machine over the network; two concurrent
    /// invocations fight over the same MEGA65 and produce a corrupt load. The
    /// task handle also gives Stop something to cancel.
    private var transferTask: Task<Void, Never>?

    /// True while a build-and-send is in progress.
    var isTransferring: Bool { transferTask != nil }

    // MARK: - Toolbar Actions

    /// Triggers a full build and immediate execution on MEGA65 hardware.
    @objc func runOnHardware() {
        startTransfer { [weak self] in await self?.buildAndSend(loadOnly: false) }
    }

    /// Triggers a build and transfers the PRG to MEGA65 without executing.
    @objc func loadOnHardware() {
        startTransfer { [weak self] in await self?.buildAndSend(loadOnly: true) }
    }

    /// Opens the MEGA65 configuration panel.
    @objc func openSettings() {
        guard let wc = Self.windowController else {
            NSSound.beep()
            return
        }
        if settingsWindow == nil {
            settingsWindow = MEGA65SettingsViewController.asWindow(config: wc.buildConfig)
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Cancels an in-flight transfer, terminating etherload.
    func cancelTransfer() {
        guard let task = transferTask else { return }
        task.cancel()
        logBuild("Cancelling MEGA65 transfer…", type: .info)
    }

    // MARK: - Menu / toolbar validation

    /// Disables the hardware actions while a transfer is running or when there
    /// is nothing to build, so a second ⌃⌘M can't start an overlapping load.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(runOnHardware), #selector(loadOnHardware):
            return !isTransferring && Self.windowController != nil
        case #selector(openSettings):
            return Self.windowController != nil
        default:
            return true
        }
    }

    /// `NSToolbarItem` validates through this when its target implements it.
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case .mega65RunOnHardware, .mega65LoadOnly:
            return !isTransferring && Self.windowController != nil
        default:
            return Self.windowController != nil
        }
    }

    // MARK: - Core Pipeline

    /// Runs `body` as the one in-flight transfer, refusing to start a second.
    private func startTransfer(_ body: @escaping () async -> Void) {
        guard transferTask == nil else {
            logBuild("MEGA65: a transfer is already in progress.", type: .warning)
            return
        }
        transferTask = Task { [weak self] in
            await body()
            self?.transferTask = nil
        }
    }

    /// Executes the build-and-transfer pipeline for MEGA65.
    private func buildAndSend(loadOnly: Bool) async {
        guard let wc = Self.windowController else {
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

        await send(prgURL: prgURL, loadOnly: loadOnly, config: wc.buildConfig)
    }

    /// Sends an already-built PRG. Used by `MainWindowController.performRun`,
    /// which has tokenised and bundled disks already — re-entering the pipeline
    /// there would throw that work away and build the same file twice.
    func sendPrebuilt(prgURL: URL, loadOnly: Bool, config: BuildConfiguration) {
        startTransfer { [weak self] in
            await self?.send(prgURL: prgURL, loadOnly: loadOnly, config: config)
        }
    }

    /// Resolves the transfer options and hands the PRG to etherload.
    private func send(prgURL: URL, loadOnly: Bool, config: BuildConfiguration) async {
        let sizeBytes = (try? prgURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard sizeBytes > 2 else {
            // A PRG is a 2-byte load address plus at least one byte of payload.
            logMessage("MEGA65: built PRG is empty (\(sizeBytes) bytes) — nothing to send.",
                       type: .error)
            logBuild("✗ MEGA65: empty PRG (see Messages tab).", type: .error)
            return
        }
        logBuild("✓ Built PRG (\(sizeBytes) bytes)", type: .success)

        let options = Self.transferOptions(config: config, loadOnly: loadOnly)

        let modeLabel = options.m65Mode ? "--m65mode" : "--c64mode"
        let tvLabel   = options.ntsc    ? "NTSC"      : "PAL"
        logBuild("  Mode: \(modeLabel)  TV: \(tvLabel)  Run: \(!loadOnly)", type: .plain)
        logBuild("  etherload \(MEGA65Client.arguments(for: prgURL, options: options).joined(separator: " "))",
                 type: .plain)

        do {
            let result = try await MEGA65Client.sendPRG(at: prgURL, options: options)

            // Surface etherload's own output — previously discarded on success,
            // which left transfer problems invisible until they became failures.
            for line in result.combinedOutput.split(separator: "\n") {
                logBuild("etherload: \(line)", type: .plain)
            }

            if loadOnly {
                logBuild("✓ Loaded on MEGA65. Type RUN to start.", type: .success)
            } else {
                logBuild("✓ Running on MEGA65!", type: .success)
            }
        } catch is CancellationError {
            logBuild("✗ MEGA65: transfer cancelled.", type: .warning)
        } catch {
            logMessage("MEGA65 transfer failed: \(error.localizedDescription)", type: .error)
            logBuild("✗ MEGA65: transfer failed (see Messages tab).", type: .error)
        }
    }

    // MARK: - Option resolution

    /// Resolves the etherload flags for the active dialect and configuration.
    ///
    /// Mode is decided by `RunTarget`, the one place that knows how to tell a
    /// MEGA65 program from a C64 one. Deciding it here from the load address
    /// alone put every Final Cartridge III program into `--m65mode`, because
    /// FC3 BASIC and MEGA65 BASIC 65 both load at $2001 — the exact ambiguity
    /// `RunTarget` resolves by consulting the dialect's declared machine first
    /// and falling back to the address only for plugins that omit it.
    static func transferOptions(config: BuildConfiguration, loadOnly: Bool) -> MEGA65TransferOptions {
        let dialect  = BasicDialectManager.shared.activeDialect
        let isMEGA65 = RunTarget.preferred(forLoadAddress: dialect?.loadAddress,
                                           machine: dialect?.targetMachine) == .xemu

        return MEGA65TransferOptions(
            toolPath:  config.etherloadPath,
            host:      config.mega65Host,
            m65Mode:   isMEGA65,
            ntsc:      config.viceVideoStandard.lowercased().contains("ntsc"),
            run:       !loadOnly,
            extraArgs: config.etherloadExtraArgs)
    }

    // MARK: - Logging

    /// The active main window, or nil when there is no editor to build from.
    private static var windowController: MainWindowController? {
        (NSApp.delegate as? AppDelegate)?.mainWindowController
    }

    private func logBuild(_ message: String, type: MessageType) {
        Self.windowController?.bottomPanelController.appendBuildOutput(message, type: type)
    }

    private func logMessage(_ message: String, type: MessageType) {
        Self.windowController?.bottomPanelController.appendMessage(message, type: type)
    }
}
