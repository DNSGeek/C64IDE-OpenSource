//  HardwareBuildPipeline.swift
//  C64 IDE
//
//  Common machinery for the "build, then deliver to a machine over the
//  network" targets: Ultimate 64 and MEGA65. The two pipelines were written
//  as siblings and drifted anyway — a fix applied to one kept missing the
//  other — so the shared half lives here and each target supplies only the
//  part that is genuinely different: how it delivers the PRG.

import AppKit

// ═══════════════════════════════════════════════════════════
// MARK: - HardwareBuildPipeline
// ═══════════════════════════════════════════════════════════

/// Base class for hardware delivery pipelines.
///
/// Subclasses override `targetName`, `deliver(prgURL:loadOnly:config:)` and,
/// where useful, `configurationError(config:)`. Everything else — the build
/// step, the single-transfer gate, menu and toolbar validation, cancellation
/// and logging — is handled here.
@MainActor
class HardwareBuildPipeline: NSObject, NSMenuItemValidation, NSToolbarItemValidation {

    // MARK: - Subclass interface

    /// Short name used in log lines, e.g. "MEGA65" or "U64".
    var targetName: String { "hardware" }

    /// Reason this target can't be used right now, or nil when it's ready.
    ///
    /// Checked *before* building. Discovering an unconfigured host only after
    /// a full assemble wastes the user's time for no reason.
    func configurationError(config: BuildConfiguration) -> String? { nil }

    /// Sends the built PRG to the machine.
    ///
    /// Target-specific logging (flags, device output) belongs here; the caller
    /// handles the size check, the success line and error reporting.
    func deliver(prgURL: URL, loadOnly: Bool, config: BuildConfiguration) async throws {
        preconditionFailure("\(type(of: self)) must override deliver(prgURL:loadOnly:config:)")
    }

    /// Line logged after a successful delivery.
    func successMessage(loadOnly: Bool) -> String {
        loadOnly
            ? "✓ Loaded on \(targetName). Type RUN to start."
            : "✓ Running on \(targetName)!"
    }

    // MARK: - Transfer state

    /// The in-flight transfer, if any.
    ///
    /// These targets talk to one machine over the network; two concurrent
    /// deliveries fight over it and produce a corrupt load. The handle also
    /// gives Stop something to cancel.
    private var transferTask: Task<Void, Never>?

    /// True while a build-and-send is in progress.
    var isTransferring: Bool { transferTask != nil }

    /// The active main window, or nil when there is no editor to build from.
    static var windowController: MainWindowController? {
        (NSApp.delegate as? AppDelegate)?.mainWindowController
    }

    // MARK: - Actions

    /// Builds the current file and runs it on the machine.
    @objc func runOnHardware() {
        startTransfer { [weak self] in await self?.buildAndSend(loadOnly: false) }
    }

    /// Builds the current file and loads it without running.
    @objc func loadOnHardware() {
        startTransfer { [weak self] in await self?.buildAndSend(loadOnly: true) }
    }

    /// Sends an already-built PRG.
    ///
    /// Used by `MainWindowController.performRun`, which has tokenised and
    /// bundled disks already — re-entering the pipeline there would throw that
    /// work away and build the same file a second time.
    func sendPrebuilt(prgURL: URL, loadOnly: Bool, config: BuildConfiguration) {
        startTransfer { [weak self] in
            await self?.send(prgURL: prgURL, loadOnly: loadOnly, config: config)
        }
    }

    /// Cancels an in-flight transfer.
    func cancelTransfer() {
        guard let task = transferTask else { return }
        task.cancel()
        logBuild("Cancelling \(targetName) transfer…", type: .info)
    }

    // MARK: - Validation

    /// Disables the hardware actions while a transfer is running or when there
    /// is nothing to build, so a second keystroke can't start an overlapping
    /// delivery to the same machine.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(runOnHardware), #selector(loadOnHardware):
            return canStartTransfer
        default:
            return Self.windowController != nil
        }
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        isTransferItem(item) ? canStartTransfer : Self.windowController != nil
    }

    /// Whether the given toolbar item starts a build-and-send.
    /// Subclasses list their own identifiers.
    func isTransferItem(_ item: NSToolbarItem) -> Bool { false }

    /// True when a new transfer may begin.
    var canStartTransfer: Bool { !isTransferring && Self.windowController != nil }

    // MARK: - Core pipeline

    /// Runs `body` as the one in-flight transfer, refusing to start a second.
    private func startTransfer(_ body: @escaping () async -> Void) {
        guard transferTask == nil else {
            logBuild("\(targetName): a transfer is already in progress.", type: .warning)
            return
        }
        transferTask = Task { [weak self] in
            await body()
            self?.transferTask = nil
        }
    }

    /// Builds the active document, then delivers it.
    private func buildAndSend(loadOnly: Bool) async {
        guard let wc = Self.windowController else {
            logMessage("\(targetName): No active editor.", type: .error)
            return
        }

        let doc = wc.editorViewController.document
        wc.bottomPanelController.selectTab(.build)

        logBuild("═══════════════════════════════════════", type: .plain)
        logBuild("Building for \(targetName)…", type: .plain)
        logBuild("═══════════════════════════════════════", type: .plain)

        // Refuse before building rather than after: an unconfigured target
        // can't be helped by a successful assemble.
        if let problem = configurationError(config: wc.buildConfig) {
            logMessage("\(targetName): \(problem)", type: .error)
            logBuild("✗ \(targetName): not configured (see Messages tab).", type: .error)
            return
        }

        guard let prgURL = await BuildPipelineSupport.buildPRG(windowController: wc,
                                                               document: doc) else {
            logBuild("✗ \(targetName): Build failed.", type: .error)
            return
        }

        await send(prgURL: prgURL, loadOnly: loadOnly, config: wc.buildConfig)
    }

    /// Validates the build product and hands it to the subclass for delivery.
    private func send(prgURL: URL, loadOnly: Bool, config: BuildConfiguration) async {
        if let problem = configurationError(config: config) {
            logMessage("\(targetName): \(problem)", type: .error)
            logBuild("✗ \(targetName): not configured (see Messages tab).", type: .error)
            return
        }

        let sizeBytes = (try? prgURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard sizeBytes > 2 else {
            // A PRG is a 2-byte load address plus at least one byte of payload.
            logMessage("\(targetName): built PRG is empty (\(sizeBytes) bytes) — nothing to send.",
                       type: .error)
            logBuild("✗ \(targetName): empty PRG (see Messages tab).", type: .error)
            return
        }
        logBuild("✓ Built PRG (\(sizeBytes) bytes)", type: .success)

        do {
            try await deliver(prgURL: prgURL, loadOnly: loadOnly, config: config)
            logBuild(successMessage(loadOnly: loadOnly), type: .success)
        } catch is CancellationError {
            logBuild("✗ \(targetName): transfer cancelled.", type: .warning)
        } catch {
            logMessage("\(targetName) transfer failed: \(error.localizedDescription)", type: .error)
            logBuild("✗ \(targetName): transfer failed (see Messages tab).", type: .error)
        }
    }

    // MARK: - Logging

    func logBuild(_ message: String, type: MessageType) {
        Self.windowController?.bottomPanelController.appendBuildOutput(message, type: type)
    }

    func logMessage(_ message: String, type: MessageType) {
        Self.windowController?.bottomPanelController.appendMessage(message, type: type)
    }
}
