//  BuildManager.swift
//  C64 IDE
//
//  Manages the ca65 → ld65 build pipeline, process execution, debug info parsing,
//  and post-build notifications. Coordinates with EmulatorCoordinator for launch.

import Foundation
import AppKit

// MARK: - Notifications

extension Notification.Name {
    /// Posted on the main queue after a successful build that produced a linker `.map` file.
    /// The notification's `object` is the `BuildManager` whose `lastMapFile`, `lastLinkerConfigPath`,
    /// and `lastSourceFile` are now populated.
    static let buildDidProduceMemoryMap = Notification.Name("C64IDE.buildDidProduceMemoryMap")

    /// Posted on the main queue when the active debuggable emulator target changes.
    /// Observers should read `EmulatorCoordinator.shared.debuggable` for the new state.
    static let debuggerTargetDidChange = Notification.Name("C64IDE.debuggerTargetDidChange")
}

// MARK: - Build Result

/// Represents the outcome of a build pipeline execution.
struct BuildResult {
    let success: Bool
    let outputFile: URL?
    let diagnostics: [BuildDiagnostic]
    let assembleTime: TimeInterval
    let linkTime: TimeInterval

    var totalTime: TimeInterval { assembleTime + linkTime }

    var errorCount: Int { diagnostics.filter { $0.severity == .error }.count }
    var warningCount: Int { diagnostics.filter { $0.severity == .warning }.count }

    var summaryString: String {
        if success {
            let warnings = warningCount > 0 ? " (\(warningCount) warning\(warningCount == 1 ? "" : "s"))" : ""
            return "Build succeeded in \(String(format: "%.2f", totalTime))s\(warnings)"
        } else {
            return "Build failed: \(errorCount) error\(errorCount == 1 ? "" : "s"), \(warningCount) warning\(warningCount == 1 ? "" : "s")"
        }
    }
}

// MARK: - Build Type

/// Specifies the build output format and memory layout strategy.
enum BuildType {
    case assemblyPrg       // .asm → .o → .prg (with BASIC stub)
    case assemblyRaw       // .asm → .o → .prg (no stub, SYS to load address)
    case assemblyUpperRAM  // .asm → .o → .prg (at $C000)
    // Future:
    // case basicTokenize  // .bas → tokenized .prg
    // case cCompile       // .c → .s → .o → .prg
}

// MARK: - Build Manager

/// Manages the build process: ca65 assembly → ld65 linking → .prg output.
class BuildManager {

    let config: BuildConfiguration

    /// Callback for build output messages (sent to bottom panel).
    var onOutput: ((String, MessageType) -> Void)?

    /// Callback when build completes.
    var onBuildComplete: ((BuildResult) -> Void)?

    /// Thread-safe wrapper that dispatches output to the main queue.
    func emitOutput(_ msg: String, _ type: MessageType) {
        DispatchQueue.main.async { [weak self] in self?.onOutput?(msg, type) }
    }

    /// Thread-safe wrapper that dispatches completion to the main queue.
    func emitComplete(_ result: BuildResult) {
        DispatchQueue.main.async { [weak self] in self?.onBuildComplete?(result) }
    }

    /// Emits a shell-style command echo for logging and reproducibility.
    private func emitCommand(_ executable: String, arguments: [String]) {
        let quotedArgs = arguments.map { arg -> String in
            arg.contains(" ") ? "'\(arg)'" : arg
        }
        let line = ([executable] + quotedArgs).joined(separator: " ")
        emitOutput("$ \(line)", .command)
    }

    /// Currently running build process (used for cancellation).
    var currentProcess: Process?

    init(config: BuildConfiguration) {
        self.config = config
    }

    // MARK: - Build Pipeline

    /// Initiates an asynchronous build of a source file.
    /// - Parameters:
    ///   - sourceFile: Path to the source file to build.
    ///   - type: Build output format and memory layout.
    ///   - runTarget: If known, the target the user will launch after the build.
    ///     Passed to `validatePaths` for target-aware validation. `nil` validates toolchain only.
    func build(sourceFile: URL, type: BuildType = .assemblyPrg, runTarget: RunTarget? = nil) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            self._buildSync(sourceFile: sourceFile, type: type, runTarget: runTarget)
        }
    }

    /// Synchronous build pipeline execution. Runs on a background queue.
    private func _buildSync(sourceFile: URL, type: BuildType, runTarget: RunTarget? = nil) {
        // Validate paths first. Target-aware: we don't error on a missing emulator
        // binary if we're about to launch a different one.
        let errors = config.validatePaths(for: runTarget)
        if !errors.isEmpty {
            for error in errors {
                emitOutput("✗ \(error)", .error)
            }
            emitOutput("Configure tool paths in Preferences.", .warning)
            let result = BuildResult(success: false, outputFile: nil,
                diagnostics: errors.map { BuildDiagnostic(severity: .error, file: nil, line: nil, column: nil, message: $0, rawLine: $0) },
                assembleTime: 0, linkTime: 0)
            emitComplete(result)
            return
        }

        // Set up build directory
        let sourceDir = sourceFile.deletingLastPathComponent()
        let buildDir = sourceDir.appendingPathComponent(config.outputDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)

        let baseName = sourceFile.deletingPathExtension().lastPathComponent
        let objectFile = buildDir.appendingPathComponent("\(baseName).o")
        let outputFile = buildDir.appendingPathComponent("\(baseName).prg")

        emitOutput("═══════════════════════════════════════", .info)
        emitOutput("Building: \(sourceFile.lastPathComponent)", .info)
        emitOutput("═══════════════════════════════════════", .info)

        // Step 1: Assemble
        let assembleStart = Date()
        emitOutput("Assembling with ca65...", .plain)

        var ca65Args = [
            "-t", config.targetPlatform,
            "-o", objectFile.path,
        ]

        if config.generateDebugInfo { ca65Args.append("-g") }
        if config.generateListing {
            let listingFile = buildDir.appendingPathComponent("\(baseName).lst")
            ca65Args.append(contentsOf: ["-l", listingFile.path])
        }

        for includePath in config.includePaths {
            ca65Args.append(contentsOf: ["-I", includePath])
        }

        for (key, value) in config.defines {
            ca65Args.append(contentsOf: ["-D", "\(key)=\(value)"])
        }

        ca65Args.append(sourceFile.path)

        emitCommand(config.ca65Path, arguments: ca65Args)
        let (ca65Exit, ca65Stdout, ca65Stderr) = runProcess(config.ca65Path, arguments: ca65Args, workingDirectory: sourceDir)
        let assembleTime = Date().timeIntervalSince(assembleStart)

        var allDiagnostics: [BuildDiagnostic] = []

        if !ca65Stdout.isEmpty { emitOutput(ca65Stdout, .plain) }
        if !ca65Stderr.isEmpty {
            let diags = BuildErrorParser.parseCa65Output(ca65Stderr)
            allDiagnostics.append(contentsOf: diags)
            for diag in diags {
                emitOutput(diag.displayString, diag.severity == .error ? .error : .warning)
            }
            if diags.isEmpty { emitOutput(ca65Stderr, .plain) }
        }

        if ca65Exit != 0 {
            emitOutput("✗ Assembly failed (exit code \(ca65Exit))", .error)
            emitComplete(BuildResult(success: false, outputFile: nil, diagnostics: allDiagnostics,
                assembleTime: assembleTime, linkTime: 0))
            return
        }

        emitOutput("✓ Assembly OK (\(String(format: "%.2f", assembleTime))s)", .success)

        // Step 2: Link
        let linkStart = Date()
        emitOutput("Linking with ld65...", .plain)

        let linkerConfig: String
        switch type {
        case .assemblyPrg:      linkerConfig = LinkerConfigs.c64Prg
        case .assemblyRaw:      linkerConfig = LinkerConfigs.c64Raw
        case .assemblyUpperRAM: linkerConfig = LinkerConfigs.c64UpperRAM
        }

        let configPath: String
        let localCfg = sourceDir.appendingPathComponent("C64.cfg")
        if let customConfig = config.customLinkerConfig {
            configPath = customConfig
        } else if FileManager.default.fileExists(atPath: localCfg.path) {
            configPath = localCfg.path
            emitOutput("Using project linker config: C64.cfg", .info)
        } else {
            guard let configURL = LinkerConfigs.writeTemporaryConfig(linkerConfig, named: "c64_\(type)") else {
                emitOutput("✗ Failed to write linker config", .error)
                emitComplete(BuildResult(success: false, outputFile: nil, diagnostics: allDiagnostics,
                    assembleTime: assembleTime, linkTime: 0))
                return
            }
            configPath = configURL.path
        }

        let mapFile = buildDir.appendingPathComponent("\(baseName).map")
        var ld65Args = [
            "-C", configPath,
            "-o", outputFile.path,
            "--mapfile", mapFile.path,
            objectFile.path,
        ]

        if config.generateDebugInfo {
            let dbgFile = buildDir.appendingPathComponent("\(baseName).dbg")
            ld65Args.append(contentsOf: ["--dbgfile", dbgFile.path])
        }

        emitCommand(config.ld65Path, arguments: ld65Args)
        let (ld65Exit, ld65Stdout, ld65Stderr) = runProcess(config.ld65Path, arguments: ld65Args, workingDirectory: sourceDir)
        let linkTime = Date().timeIntervalSince(linkStart)

        if !ld65Stdout.isEmpty { emitOutput(ld65Stdout, .plain) }
        if !ld65Stderr.isEmpty {
            let diags = BuildErrorParser.parseLd65Output(ld65Stderr)
            allDiagnostics.append(contentsOf: diags)
            for diag in diags {
                emitOutput(diag.displayString, diag.severity == .error ? .error : .warning)
            }
            if diags.isEmpty { emitOutput(ld65Stderr, .plain) }
        }

        if ld65Exit != 0 {
            let combined = ld65Stdout + ld65Stderr
            if combined.contains("overflows memory area") {
                emitOutput("✗ Program is too large to fit in C64 memory.", .error)
                emitOutput("  The compiled output exceeds the available ~38KB.", .error)
                emitOutput("  Tip: Large BASIC programs with heavy PETSCII strings", .info)
                emitOutput("  are better run as interpreted BASIC (⌘R) than compiled.", .info)
            } else {
                emitOutput("✗ Linking failed (exit code \(ld65Exit))", .error)
            }
            emitComplete(BuildResult(success: false, outputFile: nil, diagnostics: allDiagnostics,
                assembleTime: assembleTime, linkTime: linkTime))
            return
        }

        if let attrs = try? FileManager.default.attributesOfItem(atPath: outputFile.path),
           let size = attrs[.size] as? Int {
            emitOutput("✓ Link OK → \(outputFile.lastPathComponent) (\(size) bytes, \(String(format: "%.2f", linkTime))s)", .success)
        } else {
            emitOutput("✓ Link OK (\(String(format: "%.2f", linkTime))s)", .success)
        }

        emitOutput("Build succeeded in \(String(format: "%.2f", assembleTime + linkTime))s", .success)

        // Post-build tasks on main queue
        DispatchQueue.main.async { @MainActor [self] in
            if let appDelegate = NSApp.delegate as? AppDelegate,
               let w = appDelegate.mainWindowController?.window {
                bundleDisksWithRecovery(outputPRG: outputFile, buildDir: outputFile.deletingLastPathComponent(), parentWindow: w)
            } else {
                _ = bundleDisks(outputPRG: outputFile, buildDir: outputFile.deletingLastPathComponent())
            }
        }

        // Parse debug info if available
        if config.generateDebugInfo {
            let dbgFile = buildDir.appendingPathComponent("\(baseName).dbg")
            if let debugInfo = DebugInfoParser.parse(contentsOf: dbgFile) {
                lastDebugInfo = debugInfo
                emitOutput("Debug info: \(debugInfo.summary)", .info)
            }
        }

        // Parse memory map artifacts for the Memory Map window
        lastMapFile = FileManager.default.fileExists(atPath: mapFile.path) ? mapFile : nil
        lastLinkerConfigPath = URL(fileURLWithPath: configPath)
        lastSourceFile = sourceFile
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .buildDidProduceMemoryMap, object: self)
        }

        emitComplete(BuildResult(success: true, outputFile: outputFile, diagnostics: allDiagnostics,
            assembleTime: assembleTime, linkTime: linkTime))
    }

    // MARK: - State & Cancellation

    /// Breakpoints set from the editor (hex addresses).
    var editorBreakpoints: [UInt16] = []

    /// Last parsed debug info from .dbg file.
    private(set) var lastDebugInfo: DebugInfoParser?

    /// Last `.map` file emitted by ld65. Picked up by the Memory Map window.
    private(set) var lastMapFile: URL?

    /// Linker config (.cfg) used by the most recent build. Used to render the planned memory layout.
    private(set) var lastLinkerConfigPath: URL?

    /// Source file the most recent build was for. Used for the Memory Map window title.
    private(set) var lastSourceFile: URL?

    /// Cancels the currently running build process.
    func cancelBuild() {
        currentProcess?.terminate()
        currentProcess = nil
        onOutput?("Build cancelled.", .warning)
    }
    
    /// Builds a source file and immediately runs it via EmulatorCoordinator.
    func buildAndRun(sourceFile: URL,
                     type: BuildType = .assemblyPrg,
                     target: RunTarget,
                     debugOptions: DebugOptions? = nil) {
        let originalCallback = onBuildComplete
        onBuildComplete = { [weak self] result in
            self?.onBuildComplete = originalCallback
            originalCallback?(result)
            guard result.success, let outputFile = result.outputFile else { return }

            let plan = MainActor.assumeIsolated { self?.resolveDiskPlan(for: outputFile) }
            let options = RunOptions(
                prgURL:       outputFile,
                diskPlan:     plan,
                autoRun:      self?.config.viceAutoRun ?? true,
                debugOptions: debugOptions
            )
            do {
                try EmulatorCoordinator.shared.run(target: target, options: options, config: self?.config)
            } catch {
                self?.emitOutput("✗ Launch failed: \(error.localizedDescription)", .error)
            }
        }
        build(sourceFile: sourceFile, type: type, runTarget: target)
    }

    @MainActor private func resolveDiskPlan(for prgFile: URL) -> DiskMountPlan? {
        guard let proj = ProjectManager.shared.activeProject,
              let root = ProjectManager.shared.projectRoot,
              let diskConfig = proj.diskConfig,
              let plan = EmulatorMountAdapter.plan(for: diskConfig, projectRoot: root),
              plan.hasMounts else { return nil }
        return plan
    }

    // MARK: - Process Execution

    /// Runs an external process synchronously and captures stdout/stderr.
    /// Uses concurrent pipe draining to prevent deadlocks when child processes
    /// fill one pipe buffer while the parent blocks on the other.
    private func runProcess(_ executable: String, arguments: [String], workingDirectory: URL) -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        currentProcess = process

        do {
            try process.run()
        } catch {
            return (-1, "", "Failed to run \(executable): \(error.localizedDescription)")
        }

        var stdoutData = Data()
        var stderrData = Data()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global().async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        group.enter()
        DispatchQueue.global().async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        group.wait()
        process.waitUntilExit()

        currentProcess = nil

        let stdout = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return (process.terminationStatus, stdout, stderr)
    }
}

