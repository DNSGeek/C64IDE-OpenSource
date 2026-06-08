import Foundation
import AppKit

// MARK: - Git Status

enum GitStatus: Equatable {
    case noRepo             // No `.git` folder found
    case clean              // Working tree clean
    case modified           // Staged or unstaged changes
    case untracked          // Untracked files present (and no other changes)
    case unknown            // Git is available but status couldn't be parsed
}

// MARK: - GitManager

/// Lightweight Git integration using `Process`.
/// Follows the same pattern as `BuildManager` — no libgit2 or external dependencies.
/// All async methods callback on the main thread.
@MainActor
final class GitManager {

    // MARK: - Singleton

    static let shared = GitManager()
    private init() {
        let candidates = [
            "/usr/bin/git",
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
        ]
        self.gitPath = candidates.first {
            FileManager.default.isExecutableFile(atPath: $0)
        } ?? "/usr/bin/git"
    }

    // MARK: - Git executable

    /// Path to the `git` binary, resolved at init.
    nonisolated private let gitPath: String

    nonisolated var isGitAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: gitPath)
    }

    // MARK: - Status

    /// Checks the Git status of a directory asynchronously.
    func status(in directory: URL, completion: @escaping (GitStatus) -> Void) {
        guard isGitAvailable else {
            DispatchQueue.main.async { completion(.noRepo) }
            return
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }

            // Walk up from directory to find the repo root.
            // `--show-toplevel` fails fast if there's no `.git` ancestor.
            let (revExit, toplevel, _) = self.run(
                ["rev-parse", "--show-toplevel"],
                in: directory
            )

            if revExit != 0 {
                DispatchQueue.main.async { completion(.noRepo) }
                return
            }

            // Run status from the actual repo root for reliable results
            let repoRoot = URL(fileURLWithPath: toplevel.trimmingCharacters(in: .whitespacesAndNewlines))

            // `--porcelain` gives us a stable machine-readable format
            let (_, stdout, _) = self.run(
                ["status", "--porcelain"],
                in: repoRoot
            )

            let status: GitStatus
            if stdout.isEmpty {
                status = .clean
            } else {
                // Porcelain format: XY filename
                // X = index, Y = worktree. '?' = untracked
                let lines = stdout.components(separatedBy: "\n").filter { !$0.isEmpty }
                let hasModified = lines.contains { line in
                    let xy = line.prefix(2)
                    return xy != "??" // Anything other than untracked counts as modified
                }
                status = hasModified ? .modified : .untracked
            }

            DispatchQueue.main.async { completion(status) }
        }
    }

    // MARK: - Init repo

    /// Runs `git init` in a directory.
    func initRepo(in directory: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let (exit, _, stderr) = self.run(["init"], in: directory)
            DispatchQueue.main.async {
                if exit == 0 {
                    completion(.success(()))
                } else {
                    completion(.failure(GitError.commandFailed("git init: \(stderr)")))
                }
            }
        }
    }

    // MARK: - Stage all & commit

    /// Stages all changes and commits with a message.
    func commitAll(message: String, in directory: URL,
                   completion: @escaping (Result<String, Error>) -> Void) {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completion(.failure(GitError.emptyCommitMessage))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            // Stage everything
            let (addExit, _, addErr) = self.run(["add", "-A"], in: directory)
            guard addExit == 0 else {
                DispatchQueue.main.async {
                    completion(.failure(GitError.commandFailed("git add: \(addErr)")))
                }
                return
            }

            // Commit
            let (commitExit, commitOut, commitErr) = self.run(
                ["commit", "-m", message],
                in: directory
            )

            DispatchQueue.main.async {
                if commitExit == 0 {
                    // Extract the short hash from the commit output if possible
                    let summary = commitOut.components(separatedBy: "\n").first ?? "Committed."
                    completion(.success(summary))
                } else {
                    let detail = commitErr.isEmpty ? commitOut : commitErr
                    completion(.failure(GitError.commandFailed("git commit: \(detail)")))
                }
            }
        }
    }

    // MARK: - Push

    func push(in directory: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let (exit, _, stderr) = self.run(["push"], in: directory)
            DispatchQueue.main.async {
                if exit == 0 {
                    completion(.success(()))
                } else {
                    completion(.failure(GitError.commandFailed("git push: \(stderr)")))
                }
            }
        }
    }

    // MARK: - Pull

    func pull(in directory: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let (exit, _, stderr) = self.run(["pull"], in: directory)
            DispatchQueue.main.async {
                if exit == 0 {
                    completion(.success(()))
                } else {
                    completion(.failure(GitError.commandFailed("git pull: \(stderr)")))
                }
            }
        }
    }

    // MARK: - Remote check

    /// Returns the remote URL string if one is configured, `nil` otherwise.
    func remoteURL(in directory: URL, completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let (exit, stdout, _) = self.run(
                ["remote", "get-url", "origin"],
                in: directory
            )
            DispatchQueue.main.async {
                completion(exit == 0 ? stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil)
            }
        }
    }

    // MARK: - Convenience: current branch name

    func currentBranch(in directory: URL, completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let (exit, stdout, _) = self.run(
                ["rev-parse", "--abbrev-ref", "HEAD"],
                in: directory
            )
            DispatchQueue.main.async {
                completion(exit == 0 ? stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil)
            }
        }
    }

    // MARK: - Process execution (synchronous, call from background queue)

    /// Executes a Git command synchronously on a background thread.
    @discardableResult
    nonisolated private func run(_ arguments: [String], in directory: URL) -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = arguments
        process.currentDirectoryURL = directory

        // Suppress interactive prompts — Git should never block waiting for input
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_ASKPASS"] = "echo"
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError  = stderrPipe

        do {
            try process.run()
        } catch {
            return (-1, "", "Failed to run git: \(error.localizedDescription)")
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stdout = String(data: stdoutData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return (process.terminationStatus, stdout, stderr)
    }
}

// MARK: - Errors

enum GitError: LocalizedError {
    case commandFailed(String)
    case emptyCommitMessage

    var errorDescription: String? {
        switch self {
        case .commandFailed(let detail): return detail
        case .emptyCommitMessage:        return "Commit message cannot be empty."
        }
    }
}

