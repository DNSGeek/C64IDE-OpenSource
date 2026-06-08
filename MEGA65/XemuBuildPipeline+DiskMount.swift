import Foundation
import AppKit

// ═══════════════════════════════════════════════════════════
// MARK: - XemuBuildPipeline + disk mount
// ═══════════════════════════════════════════════════════════

/// Extends `XemuBuildPipeline` with disk-aware launch logic for xemu.
///
/// When the active project has a `ProjectDiskConfig`, `runPRGWithDiskSupport`
/// mounts the project's disk images via `-8`/`-9` etc. and boots with
/// `-autoload`, instead of injecting the PRG with `-prg`. When there is no
/// disk config the original `-prg` behaviour is completely unchanged.
extension XemuBuildPipeline {

    /// Launch xemu with disk images mounted if the active project has a disk
    /// config, otherwise fall back to the existing PRG inject mode.
    ///
    /// - Parameters:
    ///   - prgFile:  The compiled `.prg`. Used as the inject target in
    ///               fallback mode; ignored when disk mode is active.
    ///   - autoRun:  Whether to `-autoload` (RUN) the boot program.
    ///   - config:   The active `BuildConfiguration` (for xemu path and extra args).
    func runPRGWithDiskSupport(at prgFile: URL, autoRun: Bool, config: BuildConfiguration) {
        let pm = ProjectManager.shared

        guard let proj = pm.activeProject,
              let root = pm.projectRoot,
              let diskConfig = proj.diskConfig,
              let plan = EmulatorMountAdapter.plan(for: diskConfig, projectRoot: root),
              plan.hasMounts else {
            // No disk config — use existing inject-mode path unchanged.
            runPRG(at: prgFile, autoRun: autoRun, config: config)
            return
        }

        let mountArgs = EmulatorMountAdapter.xemuArguments(for: plan, autoRun: autoRun)

        logBuild("Mounting disks:", type: .info)
        for disk in plan.disks {
            let boot = disk.driveNumber == plan.primaryDisk?.driveNumber ? " (boot)" : ""
            logBuild("  Drive \(disk.driveNumber): \(disk.label) → \(disk.imageURL.lastPathComponent)\(boot)",
                     type: .info)
        }

        launchXemuWithArguments(mountArgs, prgFile: prgFile, autoRun: autoRun, config: config)
    }

    // MARK: - Internal launch with pre-built argument list

    /// Core xemu launch with pre-built mount arguments.
    ///
    /// Mirrors the structure of the private `launchXemu` method, replacing
    /// the `-prg` inject block with the supplied `mountArgs`. All other
    /// behaviour (stderr capture, termination handler, extra args) is
    /// identical.
    ///
    /// `prgFile` is kept as a parameter so the working directory and log
    /// message remain meaningful in both inject and disk modes.
    func launchXemuWithArguments(_ mountArgs: [String], prgFile: URL, autoRun: Bool, config: BuildConfiguration) {
        stopXemu()

        guard !config.xemuPath.isEmpty,
              FileManager.default.isExecutableFile(atPath: config.xemuPath) else {
            logMessage("xemu not found at: \(config.xemuPath). Set the path in Preferences → Build → Tool Paths.",
                       type: .error)
            logBuild("✗ xemu: binary not found (see Messages tab).", type: .error)
            return
        }

        var args = mountArgs
        args += config.xemuExtraArgs

        logBuild("Launching xemu (disk mode): \(prgFile.lastPathComponent)", type: .info)
        logBuild("xemu args: \(args.joined(separator: " "))", type: .plain)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.xemuPath)
        process.arguments = args
        process.currentDirectoryURL = prgFile.deletingLastPathComponent()

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
                logBuild("✓ Running in xemu (disk mode)!", type: .success)
            } else {
                logBuild("✓ Loaded in xemu (disk mode). Type RUN to start.", type: .success)
            }
        } catch {
            logMessage("Failed to launch xemu: \(error.localizedDescription)", type: .error)
            logBuild("✗ xemu: failed to launch (see Messages tab).", type: .error)
        }
    }
}

