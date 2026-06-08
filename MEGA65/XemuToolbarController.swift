import AppKit

// MARK: - Toolbar Item Identifiers

extension NSToolbarItem.Identifier {
    /// Identifier for the "Run in xemu" toolbar button.
    static let xemuRun = NSToolbarItem.Identifier("xemuRun")
    /// Identifier for the "Load in xemu" toolbar button.
    static let xemuLoadOnly = NSToolbarItem.Identifier("xemuLoadOnly")
}

// MARK: - Xemu Toolbar Controller

/// Provides toolbar items for running and loading builds in xemu's MEGA65 emulator (`xmega65`).
/// Intended to replace the VICE Run button on the toolbar whenever the active dialect targets the MEGA65.
/// The toolbar delegate is responsible for swapping the visible identifier; this controller simply vends the items.
@MainActor
final class XemuToolbarController {

    static let shared = XemuToolbarController()
    private init() {}

    static let identifiers: [NSToolbarItem.Identifier] = [
        .xemuRun, .xemuLoadOnly
    ]

    /// Returns the configured toolbar item for the given identifier.
    func toolbarItem(for identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        switch identifier {
        case .xemuRun:      return makeRunItem()
        case .xemuLoadOnly: return makeLoadItem()
        default:            return nil
        }
    }

    /// Creates the "Run in xemu" toolbar item.
    private func makeRunItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .xemuRun)
        item.label   = "Run in xemu"
        item.toolTip = "Build and run the current file in xemu (xmega65)"
        item.image   = NSImage(systemSymbolName: "play.fill",
                               accessibilityDescription: "Run in xemu")
        item.target  = XemuBuildPipeline.shared
        item.action  = #selector(XemuBuildPipeline.runInXemu)
        return item
    }

    /// Creates the "Load in xemu" toolbar item.
    private func makeLoadItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .xemuLoadOnly)
        item.label   = "Load in xemu"
        item.toolTip = "Build and load in xemu without auto-running"
        item.image   = NSImage(systemSymbolName: "tray.and.arrow.down",
                               accessibilityDescription: "Load in xemu")
        item.target  = XemuBuildPipeline.shared
        item.action  = #selector(XemuBuildPipeline.loadInXemu)
        return item
    }

    // MARK: - Dialect Gate

    /// Determines whether the active dialect should run in xemu rather than VICE.
    /// Delegates to `RunTarget.forActiveDialect()` so the dispatch predicate lives in exactly one place,
    /// preventing drift between toolbar visibility checks and actual run routing.
    static var shouldReplaceViceRun: Bool {
        RunTarget.forActiveDialect() == .xemu
    }
}

// MARK: - Xemu Build Pipeline

/// Bridges the IDE's build system to the xemu `xmega65` emulator.
/// Builds the current file (BASIC tokenise or ca65 assemble), writes it to a temp PRG,
/// then launches xmega65 with `-prg <path>` and (when running) `-autoload`.
///
/// Deliberately mirrors the `MEGA65BuildPipeline` structure so the two read as siblings.
/// If a bug is found in one, the other should be checked first.
@MainActor
final class XemuBuildPipeline: NSObject {

    static let shared = XemuBuildPipeline()
    private override init() {}

    /// The currently-running xemu process, if any.
    /// Re-running automatically terminates this instance to prevent multiple windows from fighting for focus.
    public internal(set) var xemuProcess: Process?

    // MARK: - Toolbar Actions

    /// Triggers a full build and immediate execution in xemu.
    @objc func runInXemu() {
        Task { await buildAndLaunch(autoRun: true) }
    }

    /// Triggers a build and transfers the PRG to xemu without auto-executing.
    @objc func loadInXemu() {
        Task { await buildAndLaunch(autoRun: false) }
    }

    // MARK: - Core Pipeline

    /// Executes the build-and-launch pipeline for xemu.
    private func buildAndLaunch(autoRun: Bool) async {
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let wc = appDelegate.mainWindowController else {
            logMessage("xemu: No active editor.", type: .error)
            return
        }

        let doc = wc.editorViewController.document
        wc.bottomPanelController.selectTab(.build)

        logBuild("═══════════════════════════════════════", type: .plain)
        logBuild("Building for xemu (xmega65)…", type: .plain)
        logBuild("═══════════════════════════════════════", type: .plain)

        // Step 1: Build the PRG (shared helper — see BuildPipelineSupport)
        guard let prgURL = await BuildPipelineSupport.buildPRG(windowController: wc,
                                                                document: doc) else {
            logBuild("✗ xemu: Build failed.", type: .error)
            return
        }

        let sizeBytes = (try? prgURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        logBuild("✓ Built PRG (\(sizeBytes) bytes)", type: .success)

        // Step 2: Launch xemu
        launchXemu(prgFile: prgURL, autoRun: autoRun, config: wc.buildConfig)
    }

    // MARK: - xemu Launch

    /// Public entry point: launches xemu with an already-built PRG.
    /// Used by `MainWindowController.performRun` to hand off a freshly tokenised
    /// BASIC 65 program without triggering this pipeline's own build step.
    public func runPRG(at prgFile: URL, autoRun: Bool, config: BuildConfiguration) {
        launchXemu(prgFile: prgFile, autoRun: autoRun, config: config)
    }

    /// Core xemu launch logic. Handles binary validation, argument assembly, process spawning,
    /// stderr capture, and termination handling.
    private func launchXemu(prgFile: URL, autoRun: Bool, config: BuildConfiguration) {
        stopXemu()

        guard !config.xemuPath.isEmpty,
              FileManager.default.isExecutableFile(atPath: config.xemuPath) else {
            logMessage("xemu not found at: \(config.xemuPath). Set the path in Preferences → Build → Tool Paths.",
                       type: .error)
            logBuild("✗ xemu: binary not found (see Messages tab).", type: .error)
            return
        }

        var args: [String] = ["-prg", prgFile.path]
        if autoRun {
            args.append("-autoload")
        }
        args.append(contentsOf: config.xemuExtraArgs)

        logBuild("Launching xemu: \(prgFile.lastPathComponent)", type: .info)
        logBuild("xemu args: \(args.joined(separator: " "))", type: .plain)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.xemuPath)
        process.arguments = args
        process.currentDirectoryURL = prgFile.deletingLastPathComponent()

        // Surface xemu's stderr in the build log. This is typically where useful
        // diagnostics are emitted (missing ROM, bad SD card image, etc.)
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return }
            DispatchQueue.main.async {
                self?.logBuild("xemu: \(text)", type: .plain)
            }
        }

        process.terminationHandler = { [weak self] proc in
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                if proc.terminationStatus != 0 {
                    self?.logMessage("xemu exited with error (code \(proc.terminationStatus))",
                                     type: .error)
                    self?.logBuild("✗ xemu: exited with error (see Messages tab).", type: .error)
                } else {
                    self?.logBuild("xemu exited normally.", type: .info)
                }
                self?.xemuProcess = nil
            }
        }

        do {
            try process.run()
            xemuProcess = process
            logBuild("xemu running (PID \(process.processIdentifier))", type: .success)
            if autoRun {
                logBuild("✓ Running in xemu!", type: .success)
            } else {
                logBuild("✓ Loaded in xemu. Type RUN to start.", type: .success)
            }
        } catch {
            logMessage("Failed to launch xemu: \(error.localizedDescription)", type: .error)
            logBuild("✗ xemu: failed to launch (see Messages tab).", type: .error)
        }
    }

    /// Terminates any running xemu instance spawned by this pipeline.
    public func stopXemu() {
        if let process = xemuProcess, process.isRunning {
            process.terminate()
            logBuild("xemu terminated.", type: .info)
        }
        xemuProcess = nil
    }

    /// Returns `true` if xemu is currently running.
    public var isXemuRunning: Bool { xemuProcess?.isRunning ?? false }

    // MARK: - Logging

    /// Appends a message to the build output panel.
    public func logBuild(_ message: String, type: MessageType) {
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let wc = appDelegate.mainWindowController else { return }
        wc.bottomPanelController.appendBuildOutput(message, type: type)
    }

    /// Appends a message to the general messages panel.
    public func logMessage(_ message: String, type: MessageType) {
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let wc = appDelegate.mainWindowController else { return }
        wc.bottomPanelController.appendMessage(message, type: type)
    }

    /// Alias for `logBuild`. Kept for API consistency with other pipeline controllers.
    public func logOutput(_ message: String, type: MessageType) {
        logBuild(message, type: type)
    }
}

