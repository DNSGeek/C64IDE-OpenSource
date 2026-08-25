import Foundation

// MARK: - Errors

/// Errors specific to MEGA65 hardware communication.
enum MEGA65Error: LocalizedError {
    /// etherload path is not configured and could not be auto-detected.
    case notConfigured
    /// etherload binary not found at the specified location.
    case binaryNotFound(String)
    /// Failed to launch the etherload process.
    case launchFailed(Error)
    /// etherload ran but reported failure.
    case etherloadFailed(ToolResult)
    /// etherload was still running when the transfer deadline expired.
    case timedOut(TimeInterval)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "etherload path is not configured. Check MEGA65 Settings."
        case .binaryNotFound(let path):
            return "etherload binary not found at: \(path)"
        case .launchFailed(let err):
            return "Failed to launch etherload: \(err.localizedDescription)"
        case .etherloadFailed(let result):
            return "etherload failed: \(result.diagnostic)"
        case .timedOut(let seconds):
            return "etherload did not respond within \(Int(seconds))s. "
                 + "Check that the MEGA65 is powered on, on the same network, "
                 + "and that the host address in MEGA65 Settings is correct."
        }
    }
}

// MARK: - Transfer options

/// Everything one `etherload` invocation needs, resolved from the build
/// configuration and the active dialect by the caller.
struct MEGA65TransferOptions {

    /// Absolute path to the `etherload` binary. Empty means "auto-detect".
    var toolPath: String = ""

    /// Optional MEGA65 address, passed as `-i <host>`. Empty means etherload's
    /// own default discovery. Required on networks where broadcast discovery
    /// doesn't reach the machine (different subnet, VLAN, Wi-Fi isolation).
    var host: String = ""

    /// `true` → `--m65mode` (native MEGA65 BASIC 65),
    /// `false` → `--c64mode` (C64 compatibility mode).
    var m65Mode: Bool = false

    /// `true` → `--ntsc`, `false` → `--pal`.
    var ntsc: Bool = false

    /// Append `--run` so the MEGA65 starts the program immediately.
    var run: Bool = true

    /// User-supplied flags appended after the generated ones, mirroring
    /// `BuildConfiguration.xemuExtraArgs`. The escape hatch for etherload
    /// builds whose flag spelling differs from the defaults below.
    var extraArgs: [String] = []
}

// MARK: - MEGA65Client

/// Wraps the `etherload` command-line tool for sending PRG files to a MEGA65
/// over the network. The tool is optional — users configure its path in prefs.
///
/// Command form:
///   etherload [-i <host>] [--c64mode|--m65mode] [--pal|--ntsc] [--run] <file.prg>
///
/// Flag spelling varies between etherload builds; `MEGA65TransferOptions.extraArgs`
/// exists so a user whose build differs can adjust without a code change.
///
/// Stateless by design: every setting arrives in `MEGA65TransferOptions` from
/// `BuildConfiguration`, so there is no second copy of the etherload path to
/// drift out of sync with Preferences, and nothing here is actor-bound.
enum MEGA65Client {

    // MARK: Configuration

    /// Wall-clock limit for one transfer.
    ///
    /// etherload has no timeout of its own: aimed at a MEGA65 that is switched
    /// off or unreachable it waits indefinitely, which used to wedge the Run
    /// action with no way to cancel it.
    static let transferTimeout: TimeInterval = 60

    /// Bare binary name, used for auto-detection.
    static let binaryName = "etherload"

    /// Full paths tried before the standard search directories, covering the
    /// MEGA65 tools distribution's own install locations.
    static let extraCandidates = [
        "/Applications/MEGA65/etherload",
        "/Applications/MEGA65.app/Contents/MacOS/etherload",
        "\(NSHomeDirectory())/mega65/etherload",
    ]

    // MARK: - Public API

    /// Locates `etherload` without consulting `$PATH` via `which`.
    ///
    /// A Finder-launched app inherits launchd's minimal PATH, so `which` would
    /// never find the Homebrew or `/usr/local/bin` install that virtually every
    /// user actually has. `ExternalTool.locate` scans real directories instead.
    static func autoDetectPath() -> String? {
        ExternalTool.locate(binaryName, extraCandidates: extraCandidates)
    }

    /// Resolves the tool path to use: the configured one, or auto-detection.
    static func resolvedToolPath(configured: String) -> String? {
        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return autoDetectPath()
    }

    /// Builds the argument vector for a transfer. Separated from `sendPRG` so
    /// the pipeline can log the exact command and so it can be unit-tested
    /// without spawning anything.
    static func arguments(for prgURL: URL, options: MEGA65TransferOptions) -> [String] {
        var args: [String] = []

        let host = options.host.trimmingCharacters(in: .whitespacesAndNewlines)
        if !host.isEmpty { args += ["-i", host] }

        args.append(options.m65Mode ? "--m65mode" : "--c64mode")
        args.append(options.ntsc ? "--ntsc" : "--pal")
        if options.run { args.append("--run") }
        args += options.extraArgs
        args.append(prgURL.path)

        return args
    }

    /// Sends a compiled PRG to a MEGA65 device via `etherload`.
    ///
    /// - Returns: Whatever etherload printed, so the caller can surface its
    ///   progress output in the build log even on success.
    /// - Throws: `MEGA65Error` for every failure mode, including timeout.
    ///   Cancelling the surrounding `Task` terminates etherload.
    @discardableResult
    static func sendPRG(at prgURL: URL, options: MEGA65TransferOptions) async throws -> ToolResult {
        guard let toolPath = resolvedToolPath(configured: options.toolPath) else {
            throw MEGA65Error.notConfigured
        }
        guard FileManager.default.isExecutableFile(atPath: toolPath) else {
            throw MEGA65Error.binaryNotFound(toolPath)
        }

        let result: ToolResult
        do {
            result = try await ExternalTool.run(
                toolPath,
                arguments: arguments(for: prgURL, options: options),
                workingDirectory: prgURL.deletingLastPathComponent(),
                timeout: transferTimeout)
        } catch let error as ToolError {
            switch error {
            case .timedOut:                 throw MEGA65Error.timedOut(transferTimeout)
            case .notExecutable(let path):  throw MEGA65Error.binaryNotFound(path)
            case .launchFailed(_, let err): throw MEGA65Error.launchFailed(err)
            }
        }

        guard result.succeeded else { throw MEGA65Error.etherloadFailed(result) }
        return result
    }
}
