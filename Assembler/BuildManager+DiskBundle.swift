//  BuildManager+DiskBundle.swift
//  C64 IDE
//
//  Extends BuildManager with a post-build disk image bundling phase.
//  Resolves manifest files, writes compiled output to D64/D81 images,
//  and reports per-disk results to the build log.

import Foundation

// MARK: - DiskBundleResult

/// Outcome of bundling a single disk image during a build.
struct DiskBundleResult {
    let diskLabel: String
    let diskFilename: String
    let success: Bool
    let fileCount: Int
    let elapsed: TimeInterval
    let error: Error?

    var logLine: String {
        let tag    = success ? "✓" : "✗"
        let timing = success
            ? "(\(String(format: "%.1f", elapsed))s, \(fileCount) file\(fileCount == 1 ? "" : "s"))"
            : ""
        return "\(tag) Bundle: \(diskLabel) (\(diskFilename)) \(timing)"
    }
}

// MARK: - BuildResult extension

// Swift doesn't allow stored-property extensions, so we use a parallel
// container vended through a static dictionary keyed by ObjectIdentifier.
private var diskResultsStore: [ObjectIdentifier: [DiskBundleResult]] = [:]

private enum Keys {
    static var project:     UInt8 = 1
    static var projectRoot: UInt8 = 2
}

extension BuildResult {

    /// Per-disk bundle outcomes from the bundle phase, if one ran.
    /// Empty when there is no disk config or the compile phase failed.
    var diskBundleResults: [DiskBundleResult] {
        get { diskResultsStore[ObjectIdentifier(self as AnyObject)] ?? [] }
        set { diskResultsStore[ObjectIdentifier(self as AnyObject)] = newValue }
    }

    /// Summary line appended to the build log after all disk phases.
    var diskBundleSummary: String? {
        let results = diskBundleResults
        guard !results.isEmpty else { return nil }
        let failed  = results.filter { !$0.success }
        let ok      = results.filter {  $0.success }
        if failed.isEmpty {
            return "Build completed. All \(ok.count) disk\(ok.count == 1 ? "" : "s") up to date."
        } else {
            let okNames = ok.map { $0.diskLabel }.joined(separator: ", ")
            let summary = "Build completed with \(failed.count) bundle error\(failed.count == 1 ? "" : "s")."
            return okNames.isEmpty ? summary : summary + " \(okNames) up to date."
        }
    }
}

// MARK: - BuildManager disk bundle phase

extension BuildManager {

    // MARK: - Project context

    /// The currently open project. Set by MainWindowController when a project opens or closes.
    /// `nil` in loose-file mode — disk bundling is skipped.
    var project: C64Project? {
        get { _project }
        set { _project = newValue }
    }

    /// Root directory of the project file. Set alongside `project`.
    var projectRoot: URL? {
        get { _projectRoot }
        set { _projectRoot = newValue }
    }

    // Backing storage via associated objects (avoids stored-property restrictions on class extensions).
    private var _project: C64Project? {
        get { objc_getAssociatedObject(self, &Keys.project) as? C64Project }
        set { objc_setAssociatedObject(self, &Keys.project, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private var _projectRoot: URL? {
        get { objc_getAssociatedObject(self, &Keys.projectRoot) as? URL }
        set { objc_setAssociatedObject(self, &Keys.projectRoot, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    // MARK: - Bundle phase entry point

    /// Runs the disk bundle phase after a successful compile.
    ///
    /// Resolves each disk's manifest, writes files via `DiskImageService.performBatch`,
    /// and emits phased log output matching the spec format:
    ///
    /// ```
    /// ▸ Bundle: Boot Disk (game.d81) ........................ ✓ (0.1s, 15 files)
    /// ▸ Bundle: Data Disk (data.d81) ........................ ✗
    ///     └─ Collision: ...
    /// ```
    ///
    /// - Parameters:
    ///   - outputPRG:  The compiled `.prg` file from the link step.
    ///   - buildDir:   The build output directory (where disk images are written).
    /// - Returns: Array of per-disk results. Empty if there is no disk config.
    func bundleDisks(outputPRG: URL, buildDir: URL) -> [DiskBundleResult] {
        guard let proj = project,
              let root = projectRoot,
              let diskConfig = proj.diskConfig else {
            return []
        }

        emitOutput("", .plain)
        emitOutput("── Disk Bundle ─────────────────────────", .info)

        let resolver = ManifestResolver()
        var results: [DiskBundleResult] = []

        for disk in diskConfig.disks {
            let diskStart = Date()
            let imageURL = root.appendingPathComponent(disk.filename)

            emitOutput("▸ Bundle: \(disk.label) (\(disk.filename))", .plain)

            do {
                // Ensure the image exists — create blank if absent.
                if !FileManager.default.fileExists(atPath: imageURL.path) {
                    try DiskImageService.shared.createImage(
                        at:       imageURL,
                        diskName: disk.cbmDiskName,
                        diskID:   disk.cbmDiskID
                    )
                    emitOutput("  Created new \(disk.format == .d81 ? "D81" : "D64") image: \(disk.filename)", .info)
                }

                // Build the injected PRG entry if this disk is the build target.
                var buildOutputEntry: ResolvedFile? = nil
                if let diskOutput = proj.buildOptions.diskOutput,
                   diskOutput.targetDiskID == disk.id {
                    buildOutputEntry = ResolvedFile(
                        sourceURL: outputPRG,
                        cbmName:   try DiskImageService.shared.validatedCBMName(diskOutput.outputCBMName),
                        fileType:  0x82
                    )
                }

                // Resolve the manifest.
                let files = try resolver.resolve(
                    disk:        disk,
                    projectRoot: root,
                    buildOutput: buildOutputEntry
                )

                // Write all files in a single batch (one load, one save).
                try DiskImageService.shared.performBatch(on: imageURL) { ctx in
                    for file in files {
                        let data = try Data(contentsOf: file.sourceURL)
                        try ctx.addFile(named: file.cbmName, type: file.fileType, data: data)
                    }
                }

                let elapsed = Date().timeIntervalSince(diskStart)
                let result  = DiskBundleResult(
                    diskLabel:    disk.label,
                    diskFilename: disk.filename,
                    success:      true,
                    fileCount:    files.count,
                    elapsed:      elapsed,
                    error:        nil
                )
                results.append(result)
                emitOutput("  \(result.logLine)", .success)

            } catch {
                let elapsed = Date().timeIntervalSince(diskStart)
                let result  = DiskBundleResult(
                    diskLabel:    disk.label,
                    diskFilename: disk.filename,
                    success:      false,
                    fileCount:    0,
                    elapsed:      elapsed,
                    error:        error
                )
                results.append(result)
                emitOutput("  ✗ Bundle: \(disk.label) (\(disk.filename))", .error)
                emitOutput("    └─ \(error.localizedDescription)", .error)
            }
        }

        // Summary line — always present so the user knows overall disk state.
        emitOutput("", .plain)
        let failed = results.filter { !$0.success }.count
        if failed == 0 {
            let total = results.count
            emitOutput("All \(total) disk\(total == 1 ? "" : "s") bundled successfully.", .success)
        } else {
            let ok = results.filter { $0.success }.map { $0.diskLabel }
            let base = "Bundle completed with \(failed) error\(failed == 1 ? "" : "s")."
            if ok.isEmpty {
                emitOutput(base, .error)
            } else {
                emitOutput("\(base) Up to date: \(ok.joined(separator: ", ")).", .info)
            }
        }

        return results
    }
}

