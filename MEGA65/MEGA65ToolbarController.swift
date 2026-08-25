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
///
/// The build, single-transfer gate, validation, cancellation and logging all
/// come from `HardwareBuildPipeline`; only the delivery step is MEGA65-specific.
@MainActor
final class MEGA65BuildPipeline: HardwareBuildPipeline {

    static let shared = MEGA65BuildPipeline()
    private override init() {}

    private var settingsWindow: NSWindow?

    // MARK: - Target description

    override var targetName: String { "MEGA65" }

    override func configurationError(config: BuildConfiguration) -> String? {
        MEGA65Client.resolvedToolPath(configured: config.etherloadPath) == nil
            ? "etherload not found. Set its path in MEGA65 Settings."
            : nil
    }

    override func isTransferItem(_ item: NSToolbarItem) -> Bool {
        item.itemIdentifier == .mega65RunOnHardware || item.itemIdentifier == .mega65LoadOnly
    }

    // MARK: - Delivery

    override func deliver(prgURL: URL, loadOnly: Bool, config: BuildConfiguration) async throws {
        let options = Self.transferOptions(config: config, loadOnly: loadOnly)

        let modeLabel = options.m65Mode ? "--m65mode" : "--c64mode"
        let tvLabel   = options.ntsc    ? "NTSC"      : "PAL"
        logBuild("  Mode: \(modeLabel)  TV: \(tvLabel)  Run: \(!loadOnly)", type: .plain)
        logBuild("  etherload \(MEGA65Client.arguments(for: prgURL, options: options).joined(separator: " "))",
                 type: .plain)

        let result = try await MEGA65Client.sendPRG(at: prgURL, options: options)

        // Surface etherload's own output — previously discarded on success,
        // which left transfer problems invisible until they became failures.
        for line in result.combinedOutput.split(separator: "\n") {
            logBuild("etherload: \(line)", type: .plain)
        }
    }

    // MARK: - Extra actions

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

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(openSettings) { return Self.windowController != nil }
        return super.validateMenuItem(menuItem)
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
}
