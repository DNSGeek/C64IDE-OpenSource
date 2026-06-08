import Foundation

// MARK: - Errors

/// Errors specific to MEGA65 hardware communication.
enum MEGA65Error: LocalizedError {
    /// etherload path is not configured.
    case notConfigured
    /// etherload binary not found at the specified location.
    case binaryNotFound(String)
    /// Failed to launch the etherload process.
    case launchFailed(Error)
    /// etherload exited with a non-zero status.
    case etherloadFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "etherload path is not configured. Check MEGA65 Settings."
        case .binaryNotFound(let path):
            return "etherload binary not found at: \(path)"
        case .launchFailed(let err):
            return "Failed to launch etherload: \(err.localizedDescription)"
        case .etherloadFailed(let code, let output):
            let detail = output.isEmpty ? "exit code \(code)" : output
            return "etherload failed: \(detail)"
        }
    }
}

// MARK: - MEGA65Client

/// Wraps the `etherload` command-line tool for sending PRG files to a MEGA65
/// over the network. The tool is optional — users configure its path in prefs.
///
/// Command forms:
///   etherload --c64mode [--pal|--ntsc] [--run] <file.prg>
///   etherload --m65mode [--pal|--ntsc] [--run] <file.prg>
@MainActor
final class MEGA65Client {

    // MARK: Singleton

    static let shared = MEGA65Client()
    private init() {}

    // MARK: UserDefaults keys

    private enum Keys {
        static let etherloadPath = "mega65EtherloadPath"
    }

    // MARK: Persisted settings

    /// Full path to the `etherload` binary, e.g. `/usr/local/bin/etherload`.
    /// Defaults to empty string, triggering automatic PATH resolution.
    var etherloadPath: String {
        get { UserDefaults.standard.string(forKey: Keys.etherloadPath) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Keys.etherloadPath) }
    }

    // MARK: - Public API

    /// Sends a compiled PRG to a MEGA65 device via `etherload`.
    ///
    /// - Parameters:
    ///   - prgURL:    Path to the PRG file on disk.
    ///   - m65Mode:   `true` → `--m65mode` (native MEGA65 BASIC 65),
    ///                `false` → `--c64mode` (C64 compatibility mode).
    ///   - ntsc:      `true` → `--ntsc`, `false` → `--pal`.
    ///   - run:       Append `--run` so the MEGA65 starts the program immediately.
    func sendPRG(at prgURL: URL, m65Mode: Bool, ntsc: Bool, run: Bool) async throws {
        let toolPath = resolvedToolPath()
        guard !toolPath.isEmpty else { throw MEGA65Error.notConfigured }
        guard FileManager.default.isExecutableFile(atPath: toolPath) else {
            throw MEGA65Error.binaryNotFound(toolPath)
        }

        var args: [String] = []
        args.append(m65Mode ? "--m65mode" : "--c64mode")
        args.append(ntsc ? "--ntsc" : "--pal")
        if run { args.append("--run") }
        args.append(prgURL.path)

        try await runTool(toolPath, arguments: args)
    }

    // MARK: - Private

    /// If the stored path is blank, attempts to locate `etherload` on `$PATH`.
    private func resolvedToolPath() -> String {
        let stored = etherloadPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stored.isEmpty { return stored }

        // Attempt to locate via `which etherload`
        if let found = shellWhich("etherload") { return found }
        return ""
    }

    /// Executes `/usr/bin/which` to resolve a command name to a full path.
    private func shellWhich(_ name: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = [name]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError  = Pipe()
        try? proc.run()
        proc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out.isEmpty ? nil : out
    }

    /// Runs a command-line tool asynchronously and captures its exit status.
    private func runTool(_ path: String, arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: path)
                proc.arguments     = arguments

                let outPipe = Pipe()
                let errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError  = errPipe

                do {
                    try proc.run()
                } catch {
                    continuation.resume(throwing: MEGA65Error.launchFailed(error))
                    return
                }

                proc.waitUntilExit()

                let exitCode = Int(proc.terminationStatus)
                if exitCode == 0 {
                    continuation.resume()
                } else {
                    // Collect stderr for a useful error message
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let errStr  = String(data: errData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    continuation.resume(throwing: MEGA65Error.etherloadFailed(exitCode, errStr))
                }
            }
        }
    }
}

