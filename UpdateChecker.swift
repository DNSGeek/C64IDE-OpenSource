//  UpdateChecker.swift
//  C64 IDE
//
//  Handles automatic and manual application updates. Fetches a JSON appcast,
//  compares versions, downloads the update package, verifies its integrity,
//  and performs a safe in-place application replacement.

import Cocoa
import CryptoKit

// MARK: - Appcast Entry

/// Represents a single release entry from the appcast JSON feed.
/// Expected JSON structure:
/// {
///   "version": "1.0.7",
///   "releaseNotes": "Bug fixes and new features",
///   "downloadURL": "https://...",
///   "sha256": "abc123..."
/// }
/// The `sha256` field is optional but strongly recommended for integrity verification.
private struct AppcastEntry: Decodable {
    let version: String
    let releaseNotes: String?
    let downloadURL: String
    let sha256: String?
}

// MARK: - Update Checker

/// Manages application update checks, downloads, and installations.
class UpdateChecker {

    static let shared = UpdateChecker()

    /// URL hosting the appcast JSON feed.
    private let appcastURL = URL(string: "https://files.gopherbroke.software/appcast.json")!

    /// Minimum interval between silent background checks (24 hours).
    private let checkInterval: TimeInterval = 86_400

    private var isChecking = false
    private var progressPanel: UpdateProgressPanel?

    // MARK: - Public API

    /// Initiates an update check.
    /// - Parameter silently: If `true`, runs in the background and only shows UI if an update is available.
    ///   If `false`, shows a "You're up to date" alert if no update is found.
    func checkForUpdates(silently: Bool) {
        guard !isChecking else { return }

        if silently {
            if let last = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date,
               Date().timeIntervalSince(last) < checkInterval { return }
        }

        isChecking = true

        // Bypass URLCache to ensure we always fetch the latest appcast.
        var request = URLRequest(url: appcastURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            defer { self?.isChecking = false }

            UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")

            guard let data, error == nil,
                  let entry = try? JSONDecoder().decode(AppcastEntry.self, from: data) else {
                if !silently {
                    DispatchQueue.main.async { self?.showError("Could not reach the update server. Please try again later.") }
                }
                return
            }

            let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            let newer   = Self.isNewer(entry.version, than: current)

            DispatchQueue.main.async {
                if newer {
                    self?.presentUpdateAlert(entry: entry, currentVersion: current)
                } else if !silently {
                    let a = NSAlert()
                    a.messageText = "You're up to date!"
                    a.informativeText = "C64 IDE \(current) is the latest version."
                    a.alertStyle = .informational
                    a.addButton(withTitle: "OK")
                    a.runModal()
                }
            }
        }.resume()
    }

    // MARK: - Present Alert

    /// Presents a modal alert prompting the user to download the new version.
    private func presentUpdateAlert(entry: AppcastEntry, currentVersion: String) {
        let a = NSAlert()
        a.messageText = "C64 IDE \(entry.version) is available"
        var info = entry.releaseNotes ?? "A new version is ready to install."
        info += "\n\nYou have version \(currentVersion)."
        a.informativeText = info
        a.alertStyle = .informational
        a.addButton(withTitle: "Download & Install")
        a.addButton(withTitle: "Later")

        if a.runModal() == .alertFirstButtonReturn {
            downloadAndInstall(entry: entry)
        }
    }

    // MARK: - Download

    /// Downloads the update package, verifies its checksum, and prepares for installation.
    private func downloadAndInstall(entry: AppcastEntry) {
        guard let downloadURL = URL(string: entry.downloadURL) else {
            showError("The update URL is invalid.")
            return
        }

        let panel = UpdateProgressPanel()
        self.progressPanel = panel
        panel.show()

        let task = URLSession.shared.downloadTask(with: downloadURL) { [weak self] tempURL, _, error in
            DispatchQueue.main.async { self?.progressPanel?.close(); self?.progressPanel = nil }

            guard let tempURL, error == nil else {
                DispatchQueue.main.async {
                    self?.showError("Download failed: \(error?.localizedDescription ?? "Unknown error")")
                }
                return
            }

            let stableZip = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("C64IDE_update.zip")
            try? FileManager.default.removeItem(at: stableZip)
            guard (try? FileManager.default.moveItem(at: tempURL, to: stableZip)) != nil else {
                DispatchQueue.main.async { self?.showError("Could not save the downloaded update.") }
                return
            }

            // Verify integrity before proceeding
            if let expected = entry.sha256 {
                guard let data = try? Data(contentsOf: stableZip),
                      Self.sha256Hex(data) == expected else {
                    DispatchQueue.main.async {
                        self?.showError("The downloaded update failed its integrity check and will not be installed.")
                    }
                    try? FileManager.default.removeItem(at: stableZip)
                    return
                }
            }

            DispatchQueue.main.async { self?.installUpdate(from: stableZip) }
        }

        let obs = task.progress.observe(\.fractionCompleted) { [weak panel] prog, _ in
            DispatchQueue.main.async { panel?.setFraction(prog.fractionCompleted) }
        }
        objc_setAssociatedObject(task, &UpdateChecker.obsKey, obs, .OBJC_ASSOCIATION_RETAIN)
        task.resume()
    }

    private static var obsKey = 0

    // MARK: - Install

    /// Performs a safe in-place application replacement after quitting the current process.
    private func installUpdate(from zipPath: URL) {
        let a = NSAlert()
        a.messageText = "Ready to Install"
        a.informativeText = "C64 IDE will quit and relaunch with the update installed."
        a.alertStyle = .informational
        a.addButton(withTitle: "Install & Relaunch")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }

        guard let appPath = Bundle.main.bundleURL.path as String? else { return }
        let appName = (appPath as NSString).lastPathComponent
        let appsDir = (appPath as NSString).deletingLastPathComponent
        let extractDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("C64IDE_update_extracted")
        let pid = ProcessInfo.processInfo.processIdentifier

        // Escape paths for safe shell execution
        func esc(_ s: String) -> String {
            return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }

        let eAppPath = esc(appPath)
        let eAppName = esc(appName)
        let eAppsDir = esc(appsDir)
        let eExtractDir = esc(extractDir.path)
        let eZipPath = esc(zipPath.path)

        // Shell script handles graceful shutdown, extraction, replacement, and relaunch.
        // Design rationale:
        //  • Waits for the current process PID to exit before touching the bundle.
        //  • Uses `ditto` to preserve code signatures, extended attributes, and resource forks.
        //  • Strips `com.apple.quarantine` to prevent Gatekeeper warnings on the new bundle.
        //  • Escapes all paths to prevent shell injection.
        let script = """
        #!/bin/bash
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done

        rm -rf \(eExtractDir)
        unzip -o -q \(eZipPath) -d \(eExtractDir)

        NEW_APP=$(find \(eExtractDir) -maxdepth 2 -name "*.app" -type d | head -1)

        if [ -d "$NEW_APP" ]; then
            xattr -dr com.apple.quarantine "$NEW_APP" 2>/dev/null
            rm -rf \(eAppPath)
            ditto "$NEW_APP" \(eAppsDir)/\(eAppName)
            open \(eAppPath)
        fi

        rm -rf \(eExtractDir) \(eZipPath)
        """

        let scriptPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("c64ide_install.sh")
        do {
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        } catch {
            showError("Could not write the installer script: \(error.localizedDescription)")
            return
        }

        let proc = Process()
        proc.launchPath = "/bin/bash"
        proc.arguments = [scriptPath]
        try? proc.run()
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    /// Displays an error alert to the user.
    private func showError(_ message: String) {
        let a = NSAlert()
        a.messageText = "Update Error"
        a.informativeText = message
        a.alertStyle = .warning
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    /// Compares two version strings numerically.
    /// Parses dotted components (e.g., "1.3.10") and compares them left-to-right.
    /// Missing components are treated as 0. Non-numeric suffixes are ignored.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let c = versionComponents(candidate)
        let u = versionComponents(current)
        let len = max(c.count, u.count)
        for i in 0..<len {
            let ci = i < c.count ? c[i] : 0
            let ui = i < u.count ? u[i] : 0
            if ci != ui { return ci > ui }
        }
        return false
    }

    /// Splits a version string into an array of integer components.
    private static func versionComponents(_ s: String) -> [Int] {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
         .split(separator: ".")
         .map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    /// Computes the lowercase hex SHA-256 hash of the given data.
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Download Progress Panel

/// Lightweight panel that displays download progress for application updates.
private class UpdateProgressPanel {

    private let window: NSPanel

    init() {
        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.title = "Downloading Update…"
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.center()

        let bar = NSProgressIndicator(frame: NSRect(x: 20, y: 24, width: 280, height: 20))
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 1
        bar.isIndeterminate = false
        bar.doubleValue = 0
        window.contentView?.addSubview(bar)

        let label = NSTextField(labelWithString: "Downloading…")
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 20, y: 50, width: 280, height: 16)
        window.contentView?.addSubview(label)
    }

    func show() { window.makeKeyAndOrderFront(nil) }
    func close() { window.close() }

    func setFraction(_ fraction: Double) {
        guard let bar = window.contentView?.subviews.compactMap({ $0 as? NSProgressIndicator }).first else { return }
        bar.doubleValue = fraction
    }
}

