import Foundation
import AppKit

@MainActor
final class EmulatorCoordinator {

    // MARK: - Singleton

    nonisolated static let shared = EmulatorCoordinator()
    private nonisolated init() {}

    // MARK: - State

    private(set) var active: (any RunTargetProtocol)?

    var isActive: Bool { active?.isRunning ?? false }

    var debuggable: (any DebuggableTarget)? { active as? any DebuggableTarget }

    // MARK: - Debugger Binding Hook

    /// Invoked on the main actor immediately after a new target becomes `active`.
    ///
    /// This is the reliable place to bind a debugger window to the session.
    /// It fires synchronously inside `_run` *before* `target.run(options:)`,
    /// guaranteeing it won't miss targets that fire `onDidStart` synchronously
    /// (e.g., `VC64RunTarget`). The closure is cleared after firing to prevent
    /// stale bindings from prior launches.
    var onDidLaunch: ((any RunTargetProtocol) -> Void)?

    // MARK: - Public Launch API

    /// Launch a run target. Safe to call from any thread; dispatches to main.
    ///
    /// The `nonisolated` wrapper allows `BuildManager`'s background callback
    /// to call this without concurrency warnings. The actual execution occurs
    /// on the main actor inside `_run`.
    nonisolated func run(target: RunTarget, options: RunOptions, config: BuildConfiguration?) throws {
        // Capture necessary state before crossing actor boundaries.
        // `BuildConfiguration` is a reference type that isn't `Sendable`.
        // It is only read on the main actor inside `_run`, making this
        // cross-actor hop safe when marked `nonisolated(unsafe)`.
        let capturedTarget  = target
        let capturedOptions = options
        nonisolated(unsafe) let capturedConfig = config

        DispatchQueue.main.async {
            Task { @MainActor in
                do {
                    try EmulatorCoordinator.shared._run(
                        target:  capturedTarget,
                        options: capturedOptions,
                        config:  capturedConfig
                    )
                } catch {
                    // Route launch failures to the build output panel.
                    if let wc = (NSApp.delegate as? AppDelegate)?.mainWindowController {
                        wc.bottomPanelController.appendBuildOutput(
                            "✗ Launch failed: \(error.localizedDescription)", type: .error)
                    }
                }
            }
        }
    }

    // MARK: - Internal Execution

    @MainActor
    private func _run(target: RunTarget, options: RunOptions, config: BuildConfiguration?) throws {
        active?.stop()

        let t: any RunTargetProtocol
        switch target {
        case .vc64:
            // Pass config so VC64RunTarget can read ROM paths. Falls back to
            // embedded OpenROMs with a warning if config is unavailable.
            t = VC64RunTarget(config: config)
        case .viceX64sc, .viceX128, viceXpet:
            guard let cfg = config else { throw RunTargetError.binaryNotFound("no config") }
            t = VICERunTarget(emulator: target, config: cfg)
        default:
            // xemu, u64, mega65 — handled by their existing pipelines in Layer 1.
            // They will be integrated here in Layer 2.
            return
        }

        // Route log output to the IDE's build panel.
        t.onLog = { msg, type in
            guard let wc = (NSApp.delegate as? AppDelegate)?.mainWindowController else { return }
            wc.bottomPanelController.appendBuildOutput(msg, type: type)
        }

        // Handle target lifecycle termination.
        t.onDidStop = { [weak self] in
            Task { @MainActor in
                self?.active = nil
                NotificationCenter.default.post(name: .debuggerTargetDidChange, object: nil)
            }
        }

        active = t

        // Bind debugger BEFORE starting the target.
        // VC64RunTarget fires `onDidStart` synchronously at the end of `run()`.
        // Setting the hook here guarantees the debugger attaches before the first frame.
        let launchHook = onDidLaunch
        onDidLaunch = nil
        launchHook?(t)

        // Notify UI components that adapt to the active emulator (e.g., Monitor reference tab).
        NotificationCenter.default.post(name: .debuggerTargetDidChange, object: nil)

        try t.run(options: options)
    }

    // MARK: - Stop

    func stop() {
        active?.stop()
        active = nil
        NotificationCenter.default.post(name: .debuggerTargetDidChange, object: nil)
    }
}

