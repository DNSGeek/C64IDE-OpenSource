import Foundation
import AppKit

// ═══════════════════════════════════════════════════════════
// MARK: - XemuBuildPipeline + disk mount
// ═══════════════════════════════════════════════════════════

/// Extends `XemuBuildPipeline` with disk-aware launch logic for xemu.
///
/// When the active project has a `ProjectDiskConfig`, `runPRGWithDiskSupport`
/// mounts the project's disk images and boots with `-autoload` instead of
/// injecting the PRG with `-prg`. When there is no disk config the original
/// `-prg` behaviour is completely unchanged.
///
/// Only argument selection lives here — spawning, stderr capture and
/// termination handling belong to `XemuBuildPipeline.launch(arguments:…)`.
/// This file used to carry its own copy of all of that, and the copy had
/// already drifted out of sync with the original.
extension XemuBuildPipeline {

    /// Launch xemu with disk images mounted if the active project has a disk
    /// config, otherwise fall back to the existing PRG inject mode.
    ///
    /// - Parameters:
    ///   - prgFile:  The compiled `.prg`. Used as the inject target in
    ///               fallback mode; in disk mode it only sets the working
    ///               directory, since the program is loaded from the image.
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
        guard !mountArgs.isEmpty else {
            logBuild("xemu: no mountable disk resolved — falling back to PRG inject.",
                     type: .warning)
            runPRG(at: prgFile, autoRun: autoRun, config: config)
            return
        }

        // The MEGA65 has one internal 3.5" drive, so exactly one image is
        // mounted. Say which, and name the ones being left behind rather than
        // letting them disappear without explanation.
        if let boot = plan.primaryDisk {
            logBuild("Mounting disk:", type: .info)
            logBuild("  Drive 8: \(boot.label) → \(boot.imageURL.lastPathComponent) (boot)",
                     type: .info)
            if let program = plan.bootProgramName {
                logBuild("  Boot program: \(program)", type: .info)
            }
        }
        let skipped = EmulatorMountAdapter.xemuUnmountedDisks(for: plan)
        if !skipped.isEmpty {
            logBuild("  Not mounted (the MEGA65 has a single drive): "
                   + skipped.map(\.label).joined(separator: ", "),
                     type: .warning)
        }

        launch(arguments: mountArgs,
               prgFile: prgFile,
               autoRun: autoRun,
               config: config,
               diskMode: true)
    }
}
