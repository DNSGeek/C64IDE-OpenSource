//  ExternalTool.swift
//  C64 IDE
//
//  Shared plumbing for locating and running external command-line tools
//  (etherload, emulators, assemblers). Hand-rolled `Process` blocks kept
//  reintroducing the same three defects — undrained pipes, `waitUntilExit()`
//  on a process that never launched, and no timeout — so the safe version
//  lives here once.

import Foundation

// ═══════════════════════════════════════════════════════════
// MARK: - ToolResult
// ═══════════════════════════════════════════════════════════

/// The outcome of running an external command-line tool.
struct ToolResult: Sendable {

    /// Exit status when the tool exited normally, or the signal number that
    /// killed it. Read together with `exitedNormally` — a process terminated
    /// by SIGTERM reports 15 here, which is not an error exit.
    let exitCode: Int32

    /// True when the tool exited under its own control rather than being
    /// killed by a signal.
    let exitedNormally: Bool

    let stdout: String
    let stderr: String

    /// True only for a clean, zero-status exit.
    var succeeded: Bool { exitedNormally && exitCode == 0 }

    /// The most useful thing to show a user about a failure: whatever the tool
    /// said, falling back to how it died.
    var diagnostic: String {
        let said = stderr.isEmpty ? stdout : stderr
        let how  = exitedNormally ? "exit code \(exitCode)" : "killed by signal \(exitCode)"
        return said.isEmpty ? how : "\(said) (\(how))"
    }

    /// stdout and stderr interleaved for display, oldest stream first.
    var combinedOutput: String {
        [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - ToolError
// ═══════════════════════════════════════════════════════════

/// Failures that stop a tool from producing a result at all.
enum ToolError: LocalizedError {
    /// The path is missing, a directory, or not marked executable.
    case notExecutable(String)
    /// `Process.run()` refused to start the binary.
    case launchFailed(String, Error)
    /// The tool was still running when its time limit expired.
    case timedOut(String, TimeInterval)

    var errorDescription: String? {
        switch self {
        case .notExecutable(let path):
            return "Not an executable file: \(path)"
        case .launchFailed(let name, let err):
            return "Failed to launch \(name): \(err.localizedDescription)"
        case .timedOut(let name, let seconds):
            return "\(name) did not finish within \(Int(seconds))s and was stopped."
        }
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - ExternalTool
// ═══════════════════════════════════════════════════════════

/// Locates and runs external command-line tools.
enum ExternalTool {

    // MARK: - Locating binaries

    /// Directories searched for tools, in preference order.
    ///
    /// Deliberately *not* derived from `which`. A GUI app launched from Finder
    /// or the Dock inherits launchd's minimal `PATH`
    /// (`/usr/bin:/bin:/usr/sbin:/sbin`), so `which` can never see Homebrew or
    /// `/usr/local/bin` — the two places these tools actually install to.
    static var searchDirectories: [String] {
        var directories = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/local/bin",
            "\(NSHomeDirectory())/.local/bin",
            "\(NSHomeDirectory())/bin",
        ]
        // A terminal launch may have a richer PATH than launchd's default, so
        // honour it as an extra source — never as the only one.
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            directories += path.split(separator: ":").map(String.init)
        }
        return directories
    }

    /// Resolves a tool name to an absolute path.
    ///
    /// - Parameters:
    ///   - name: Bare binary name, e.g. `etherload`.
    ///   - extraCandidates: Full paths tried first, for tools that ship inside
    ///     an app bundle or under a non-standard name.
    /// - Returns: The first executable match, or `nil`.
    static func locate(_ name: String, extraCandidates: [String] = []) -> String? {
        let fm = FileManager.default

        for candidate in extraCandidates where fm.isExecutableFile(atPath: candidate) {
            return candidate
        }
        for directory in searchDirectories {
            let full = (directory as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: full) { return full }
        }
        return nil
    }

    // MARK: - Running

    /// Runs a tool to completion and returns everything it wrote.
    ///
    /// Both pipes are drained concurrently while the tool runs. Reading one
    /// stream only after `waitUntilExit()` deadlocks the moment the tool fills
    /// the other pipe's 64 KiB buffer — the child blocks in `write()`, the
    /// parent blocks in `wait()`, and neither ever moves again.
    ///
    /// - Parameters:
    ///   - path: Absolute path to the binary.
    ///   - arguments: Argument vector, excluding argv[0].
    ///   - workingDirectory: Directory to run in, or `nil` to inherit.
    ///   - timeout: Wall-clock limit. The tool is sent SIGTERM when it expires,
    ///     then SIGKILL two seconds later if it ignores that.
    /// - Throws: `ToolError` if the tool could not run or timed out, or
    ///   `CancellationError` if the surrounding `Task` was cancelled. A tool
    ///   that runs and fails returns a `ToolResult` with `succeeded == false`
    ///   rather than throwing, so callers can show what it printed.
    @discardableResult
    static func run(_ path: String,
                    arguments: [String],
                    workingDirectory: URL? = nil,
                    timeout: TimeInterval? = nil) async throws -> ToolResult {

        let name = (path as NSString).lastPathComponent

        // Check before spawning. `Process.waitUntilExit()` raises an
        // uncatchable ObjC exception when called on a process that never
        // launched, so a bad path must never reach the run loop below.
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw ToolError.notExecutable(path)
        }

        let run = ToolRun(name: name, timeout: timeout)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                run.start(path: path,
                          arguments: arguments,
                          workingDirectory: workingDirectory,
                          continuation: continuation)
            }
        } onCancel: {
            run.cancel()
        }
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - ToolRun
// ═══════════════════════════════════════════════════════════

/// One in-flight tool invocation.
///
/// Owns the continuation and guarantees it is resumed exactly once, whichever
/// of completion, timeout, cancellation or launch failure gets there first.
private final class ToolRun: @unchecked Sendable {

    private let name: String
    private let timeout: TimeInterval?

    private let lock = NSLock()
    private var process: Process?
    private var continuation: CheckedContinuation<ToolResult, Error>?
    private var didTimeOut  = false
    private var isCancelled = false

    init(name: String, timeout: TimeInterval?) {
        self.name = name
        self.timeout = timeout
    }

    // MARK: Launch

    func start(path: String,
               arguments: [String],
               workingDirectory: URL?,
               continuation: CheckedContinuation<ToolResult, Error>) {

        lock.lock()
        // Cancellation can land before the task body even runs.
        if isCancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments     = arguments
            if let workingDirectory { process.currentDirectoryURL = workingDirectory }

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError  = errPipe
            // Never let a tool inherit the IDE's stdin: one that decides to
            // prompt would wait on input nobody can supply.
            process.standardInput  = FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                finish(.failure(ToolError.launchFailed(name, error)))
                return
            }

            lock.lock()
            self.process = process
            let cancelledDuringLaunch = isCancelled
            lock.unlock()
            if cancelledDuringLaunch { process.terminate() }

            var timer: DispatchWorkItem?
            if let timeout {
                let item = DispatchWorkItem { [weak self] in self?.expire() }
                timer = item
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
            }

            // Drain both pipes concurrently — see `ExternalTool.run(_:)`.
            var outData = Data()
            var errData = Data()
            let group = DispatchGroup()

            group.enter()
            DispatchQueue.global().async {
                outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }

            group.wait()
            process.waitUntilExit()
            timer?.cancel()

            // Close explicitly instead of waiting for the pipes to deallocate,
            // so a long IDE session can't leak descriptors one launch at a time.
            try? outPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForReading.close()

            let result = ToolResult(exitCode:       process.terminationStatus,
                                    exitedNormally: process.terminationReason == .exit,
                                    stdout:         Self.text(outData),
                                    stderr:         Self.text(errData))

            lock.lock()
            let expired   = didTimeOut
            let cancelled = isCancelled
            lock.unlock()

            if expired {
                finish(.failure(ToolError.timedOut(name, self.timeout ?? 0)))
            } else if cancelled {
                finish(.failure(CancellationError()))
            } else {
                finish(.success(result))
            }
        }
    }

    // MARK: Stopping

    /// Terminates the tool because the surrounding `Task` was cancelled.
    func cancel() {
        lock.lock()
        isCancelled = true
        let running = process
        lock.unlock()
        running?.terminate()
    }

    /// Terminates the tool because its time limit expired.
    private func expire() {
        lock.lock()
        guard !didTimeOut, let running = process, running.isRunning else {
            lock.unlock()
            return
        }
        didTimeOut = true
        lock.unlock()

        running.terminate()
        // Escalate for a tool that ignores SIGTERM, otherwise the drain
        // threads would sit on the pipes indefinitely.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if running.isRunning { kill(running.processIdentifier, SIGKILL) }
        }
    }

    // MARK: Completion

    /// Resumes the continuation, and does nothing on any later call.
    private func finish(_ result: Result<ToolResult, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }

    private static func text(_ data: Data) -> String {
        String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
