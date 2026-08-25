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
///
/// The build, single-transfer gate, validation, cancellation and logging all
/// come from `HardwareBuildPipeline`; only the delivery step is U64-specific.
@MainActor
final class U64BuildPipeline: HardwareBuildPipeline {

    static let shared = U64BuildPipeline()
    private override init() {}

    private var settingsWindow: NSWindow?

    // MARK: - Target description

    override var targetName: String { "U64" }

    /// True once a host has been entered. The U64's settings live on the client
    /// rather than in `BuildConfiguration`, so this ignores its argument.
    private var hostIsSet: Bool {
        !U64Client.shared.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    override func configurationError(config: BuildConfiguration) -> String? {
        hostIsSet ? nil : "Host not configured. Use Tools → U64 Settings."
    }

    override func isTransferItem(_ item: NSToolbarItem) -> Bool {
        item.itemIdentifier == .u64RunOnHardware || item.itemIdentifier == .u64LoadOnly
    }

    // MARK: - Delivery

    override func deliver(prgURL: URL, loadOnly: Bool, config: BuildConfiguration) async throws {
        let data = try Data(contentsOf: prgURL)
        logBuild("  POST \(loadOnly ? "v1/runners:load_prg" : "v1/runners:run_prg") "
               + "→ \(U64Client.shared.host)", type: .plain)

        if loadOnly {
            try await U64Client.shared.loadPRG(data)
        } else {
            try await U64Client.shared.runPRG(data)
        }
    }

    // MARK: - Extra actions

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
            settingsWindow = U64SettingsViewController.asWindow()
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(resetMachine):
            // Reset needs a configured host but not an open document.
            return hostIsSet
        case #selector(openSettings):
            return true
        default:
            return super.validateMenuItem(menuItem)
        }
    }

    override func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case .u64Reset:    return hostIsSet
        case .u64Settings: return true
        default:           return super.validateToolbarItem(item)
        }
    }
}
