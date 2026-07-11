//  UpdateChecker.swift
//  C64 IDE
//
//  Handles automatic and manual application updates. Fetches a JSON appcast,
//  compares versions, downloads the update package, verifies its integrity
//  AND its code signature, and performs a rollback-safe in-place replacement.
//
//  Security model:
//   - The appcast and download must be served over https from
//     *.gopherbroke.software (defense against appcast tampering pointing
//     the download elsewhere).
//   - The sha256 field is MANDATORY. A missing hash aborts the update
//     (fail closed). The hash protects against corrupt/partial downloads.
//   - The extracted bundle's code signature is verified in-process
//     (deep + strict), and its Team ID must match the running app's Team ID
//     when the running app has one. This is the real authenticity check:
//     even a fully attacker-controlled appcast can then at worst serve an
//     old signed build of this app, not arbitrary code.
//   - com.apple.quarantine is stripped only AFTER those checks pass.
//   - The installer script never deletes the old bundle until the new one
//     is safely in place; on any failure it rolls back and relaunches the
//     original. The user is never left without an app.
//
//  Known limitation: a same-user process could tamper with the extracted
//  bundle between in-process verification and the post-quit copy. Same-user
//  malware can already replace the app directly, so this adds no new
//  exposure; the temp directory is per-user (0700) regardless.

import Cocoa
import CryptoKit
import Security

// MARK: - Appcast Entry

/// Represents a single release entry from the appcast JSON feed.
/// Expected JSON structure:
/// {
///   "version": "1.0.7",
///   "releaseNotes": "Bug fixes and new features",
///   "downloadURL": "https://...",
///   "sha256": "abc123..."
/// }
/// `sha256` is decoded as optional so old feeds still parse, but an entry
/// without it is REJECTED at install time (fail closed, never fail open).
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

    /// Downloads are only accepted from this domain (or its subdomains),
    /// over https. Keeps a tampered appcast from redirecting elsewhere.
    private static let trustedHostSuffix = "gopherbroke.software"

    /// Minimum interval between silent background checks (24 hours).
    private let checkInterval: TimeInterval = 86_400

    /// How long the installer script waits for this process to exit before
    /// giving up. NSApp.terminate can be vetoed (unsaved-changes prompts),
    /// and a script waiting forever would install a stale download hours
    /// later, out from under a running session. 1500 ticks x 0.2 s = 5 min.
    private let installWaitTicks = 1500

    private enum DefaultsKey {
        static let lastCheck      = "lastUpdateCheck"
        static let skippedVersion = "skippedUpdateVersion"
    }

    private var isChecking = false
    private var progressPanel: UpdateProgressPanel?
    private var progressObservation: NSKeyValueObservation?
    private var downloadTask: URLSessionDownloadTask?

    // MARK: - Public API

    /// Initiates an update check.
    /// - Parameter silently: If `true`, runs in the background, respects the
    ///   check interval and any user-skipped version, and only shows UI when
    ///   an update is available. If `false`, always checks and reports the
    ///   outcome (including "up to date" and distinct error causes).
    func checkForUpdates(silently: Bool) {
        guard !isChecking else { return }

        if silently {
            if let last = UserDefaults.standard.object(forKey: DefaultsKey.lastCheck) as? Date,
               Date().timeIntervalSince(last) < checkInterval { return }
        }

        isChecking = true

        // Bypass URLCache to ensure we always fetch the latest appcast.
        var request = URLRequest(url: appcastURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            defer { self?.isChecking = false }
            guard let self else { return }

            // Distinct failure causes so the user isn't told "server
            // unreachable" for what is actually a 500 or a malformed feed.
            if let error {
                if !silently {
                    DispatchQueue.main.async {
                        self.showError("Could not reach the update server: \(error.localizedDescription)")
                    }
                }
                return
            }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                if !silently {
                    DispatchQueue.main.async {
                        self.showError("The update server returned an error (HTTP \(http.statusCode)).")
                    }
                }
                return
            }
            guard let data, let entry = try? JSONDecoder().decode(AppcastEntry.self, from: data) else {
                if !silently {
                    DispatchQueue.main.async {
                        self.showError("The update feed could not be read. Please try again later.")
                    }
                }
                return
            }

            // Record the check time only after a SUCCESSFUL fetch+decode;
            // recording it up front meant one flaky launch-time check
            // suppressed retries for a full 24 hours.
            UserDefaults.standard.set(Date(), forKey: DefaultsKey.lastCheck)

            let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            let newer   = Self.isNewer(entry.version, than: current)

            // Respect "Skip This Version" for background checks only;
            // an explicit manual check always shows what's available.
            if silently, newer,
               UserDefaults.standard.string(forKey: DefaultsKey.skippedVersion) == entry.version {
                return
            }

            DispatchQueue.main.async {
                if newer {
                    self.presentUpdateAlert(entry: entry, currentVersion: current)
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
        a.addButton(withTitle: "Skip This Version")

        switch a.runModal() {
        case .alertFirstButtonReturn:
            UserDefaults.standard.removeObject(forKey: DefaultsKey.skippedVersion)
            downloadAndInstall(entry: entry)
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(entry.version, forKey: DefaultsKey.skippedVersion)
        default:
            break  // Later: ask again next cycle
        }
    }

    // MARK: - Install Preflight

    /// Checks whether the running bundle can actually be replaced in place.
    /// Returns a user-facing explanation if it cannot, nil if all clear.
    /// Catching these BEFORE downloading avoids the worst failure mode:
    /// the app quits, the script's rm/mv fails silently, the old version
    /// relaunches, and the user believes they updated.
    private func installPreflightError() -> String? {
        let bundleURL = Bundle.main.bundleURL
        let fm = FileManager.default

        // Gatekeeper app translocation: the app runs from a randomized
        // read-only mount under AppTranslocation; replacing that path would
        // update a temporary copy while the real bundle stays old.
        if bundleURL.path.contains("/AppTranslocation/") {
            return "C64 IDE is running from a temporary Gatekeeper location. "
                 + "Please move C64 IDE to your Applications folder, relaunch it, "
                 + "and check for updates again."
        }

        // Read-only volume (running from a mounted DMG) or a location the
        // current user cannot write (e.g. /Applications owned by another
        // admin account).
        let parentDir = bundleURL.deletingLastPathComponent().path
        if !fm.isWritableFile(atPath: parentDir) || !fm.isWritableFile(atPath: bundleURL.path) {
            return "C64 IDE cannot be replaced at its current location "
                 + "(read-only volume or insufficient permissions). "
                 + "Please move it to your Applications folder and try again."
        }

        return nil
    }

    // MARK: - Download

    /// Validates the download URL, downloads the update package, then hands
    /// off to verification. All heavy work happens off the main thread.
    private func downloadAndInstall(entry: AppcastEntry) {
        // Fail closed: no hash, no update. A feed that omits the hash gives
        // us nothing to verify the download against.
        guard let expectedHash = entry.sha256?.lowercased(),
              !expectedHash.isEmpty else {
            showError("This update is missing its integrity hash and will not be installed. "
                    + "Please report this to the developer.")
            return
        }

        guard let downloadURL = URL(string: entry.downloadURL),
              Self.isTrustedDownloadURL(downloadURL) else {
            showError("The update download location is invalid or untrusted, "
                    + "so the update will not be installed.")
            return
        }

        if let problem = installPreflightError() {
            showError(problem)
            return
        }

        let panel = UpdateProgressPanel()
        progressPanel = panel
        panel.onCancel = { [weak self] in
            self?.downloadTask?.cancel()
        }
        panel.show()

        let task = URLSession.shared.downloadTask(with: downloadURL) { [weak self] tempURL, response, error in
            guard let self else { return }
            DispatchQueue.main.async {
                self.progressObservation?.invalidate()
                self.progressObservation = nil
                self.downloadTask = nil
                self.progressPanel?.close()
                self.progressPanel = nil
            }

            if let urlError = error as? URLError, urlError.code == .cancelled {
                return  // user hit Cancel; not an error
            }
            guard let tempURL, error == nil else {
                DispatchQueue.main.async {
                    self.showError("Download failed: \(error?.localizedDescription ?? "Unknown error")")
                }
                return
            }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                DispatchQueue.main.async {
                    self.showError("The update server returned an error while downloading (HTTP \(http.statusCode)).")
                }
                return
            }

            // Move the download to a stable path before the temp file
            // vanishes at the end of this callback.
            let stableZip = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("C64IDE_update.zip")
            try? FileManager.default.removeItem(at: stableZip)
            guard (try? FileManager.default.moveItem(at: tempURL, to: stableZip)) != nil else {
                DispatchQueue.main.async { self.showError("Could not save the downloaded update.") }
                return
            }

            // Hash check, extraction, and signature verification are slow;
            // run them off the URLSession callback queue.
            DispatchQueue.global(qos: .userInitiated).async {
                self.verifyAndPrepare(zipURL: stableZip, expectedHash: expectedHash)
            }
        }

        downloadTask = task
        progressObservation = task.progress.observe(\.fractionCompleted) { [weak panel] prog, _ in
            DispatchQueue.main.async { panel?.setFraction(prog.fractionCompleted) }
        }
        task.resume()
    }

    // MARK: - Verification

    /// Verifies the download hash, extracts the archive, locates the new
    /// bundle, and verifies its code signature and Team ID. Runs on a
    /// background queue; on success hands the verified bundle to
    /// installUpdate(...) on the main queue.
    private func verifyAndPrepare(zipURL: URL, expectedHash: String) {
        let fm = FileManager.default

        func fail(_ message: String, cleaning extractDir: URL? = nil) {
            try? fm.removeItem(at: zipURL)
            if let extractDir { try? fm.removeItem(at: extractDir) }
            DispatchQueue.main.async { self.showError(message) }
        }

        // 1. Integrity: streamed SHA-256 of the archive.
        guard let actualHash = Self.sha256Hex(ofFileAt: zipURL) else {
            fail("Could not read the downloaded update for verification.")
            return
        }
        guard actualHash == expectedHash else {
            fail("The downloaded update failed its integrity check and will not be installed.")
            return
        }

        // 2. Extract with ditto -x -k: unlike unzip, ditto preserves the
        //    extended attributes, symlinks, and resource forks that code
        //    signatures cover. (Same reason the install copy uses ditto.)
        let extractDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("C64IDE_update_extracted_\(UUID().uuidString)")
        guard Self.extractZip(zipURL, to: extractDir) else {
            fail("The downloaded update could not be unpacked.", cleaning: extractDir)
            return
        }

        // 3. Locate the .app bundle (top level or one directory deep).
        guard let newApp = Self.locateAppBundle(in: extractDir) else {
            fail("The downloaded update does not contain an application bundle.", cleaning: extractDir)
            return
        }

        // 4. Authenticity: deep, strict code-signature verification, and the
        //    Team ID must match ours (when we have one). This is what stops
        //    a tampered appcast + matching hash from installing foreign code.
        guard Self.verifyCodeSignature(ofBundleAt: newApp) else {
            fail("The downloaded update failed code-signature verification and will not be installed.",
                 cleaning: extractDir)
            return
        }
        if let ourTeam = Self.teamIdentifier(forBundleAt: Bundle.main.bundleURL) {
            guard Self.teamIdentifier(forBundleAt: newApp) == ourTeam else {
                fail("The downloaded update was not signed by this application's developer "
                   + "and will not be installed.", cleaning: extractDir)
                return
            }
        }
        // If the running build has no Team ID (ad-hoc/dev build) the team
        // match is skipped, but the signature validity check above still
        // rejects unsigned payloads.

        DispatchQueue.main.async {
            self.installUpdate(newApp: newApp, zipURL: zipURL, extractDir: extractDir)
        }
    }

    // MARK: - Install

    /// Prompts, then arms the installer script and quits. The script swaps
    /// the bundle only after this process exits, with rollback on failure.
    private func installUpdate(newApp: URL, zipURL: URL, extractDir: URL) {
        let fm = FileManager.default

        let a = NSAlert()
        a.messageText = "Ready to Install"
        a.informativeText = "C64 IDE will quit and relaunch with the update installed."
        a.alertStyle = .informational
        a.addButton(withTitle: "Install & Relaunch")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else {
            // Don't leave a verified-but-unused payload sitting in tmp.
            try? fm.removeItem(at: zipURL)
            try? fm.removeItem(at: extractDir)
            return
        }

        let appPath = Bundle.main.bundleURL.path
        let appName = (appPath as NSString).lastPathComponent
        let appsDir = (appPath as NSString).deletingLastPathComponent
        let backupPath = (appsDir as NSString).appendingPathComponent(".\(appName).update-backup")
        let pid = ProcessInfo.processInfo.processIdentifier

        // Escape paths for safe shell execution
        func esc(_ s: String) -> String {
            return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }

        let eAppPath    = esc(appPath)
        let eBackupPath = esc(backupPath)
        let eExtractDir = esc(extractDir.path)
        let eZipPath    = esc(zipURL.path)
        let eNewApp     = esc(newApp.path)

        // Installer script. Design rationale:
        //  - Waits for this PID to exit, WITH A TIMEOUT: NSApp.terminate can
        //    be vetoed by unsaved-changes prompts, and a script waiting
        //    forever would install a stale download out from under a session
        //    the user chose to keep. On timeout it cleans up and installs
        //    nothing.
        //  - The old bundle is moved aside (same volume, atomic mv), never
        //    deleted before the new copy succeeds. ditto failure (disk full,
        //    damaged extraction) rolls the original back.
        //  - Every non-timeout path ends in `open`, so the user always gets
        //    an app back - the old code could quit and simply never relaunch.
        //  - `ditto` preserves code signatures, xattrs, and resource forks.
        //  - Quarantine is stripped only on the bundle whose signature was
        //    verified in-process before this script was armed.
        //  - All paths are single-quote escaped against shell injection.
        let script = """
        #!/bin/bash
        # C64 IDE update installer (generated; self-deletes when done)

        TICKS=0
        while kill -0 \(pid) 2>/dev/null; do
            sleep 0.2
            TICKS=$((TICKS + 1))
            if [ "$TICKS" -ge \(installWaitTicks) ]; then
                # App never exited (quit was cancelled). Do not install a
                # stale update under a running session; clean up and bail.
                rm -rf \(eExtractDir) \(eZipPath)
                rm -f -- "$0"
                exit 0
            fi
        done

        # Move the old bundle aside instead of deleting it, so a failed
        # copy can be rolled back and the user is never left without an app.
        rm -rf \(eBackupPath)
        if ! mv \(eAppPath) \(eBackupPath); then
            # Could not move the old app (permissions changed since
            # preflight?). Leave everything untouched and relaunch it.
            rm -rf \(eExtractDir) \(eZipPath)
            open \(eAppPath)
            rm -f -- "$0"
            exit 1
        fi

        if ditto \(eNewApp) \(eAppPath); then
            # Success: clear quarantine on the verified bundle, drop backup.
            xattr -dr com.apple.quarantine \(eAppPath) 2>/dev/null
            rm -rf \(eBackupPath)
        else
            # Copy failed (disk full?). Roll the original bundle back.
            rm -rf \(eAppPath)
            mv \(eBackupPath) \(eAppPath)
        fi

        open \(eAppPath)
        rm -rf \(eExtractDir) \(eZipPath)
        rm -f -- "$0"
        """

        let scriptPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("c64ide_install.sh")
        do {
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        } catch {
            showError("Could not write the installer script: \(error.localizedDescription)")
            try? fm.removeItem(at: zipURL)
            try? fm.removeItem(at: extractDir)
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [scriptPath]
        do {
            try proc.run()
        } catch {
            // If the installer never launched, do NOT quit: the user would
            // get no update and no explanation.
            showError("Could not start the installer: \(error.localizedDescription)")
            try? fm.removeItem(at: zipURL)
            try? fm.removeItem(at: extractDir)
            return
        }
        NSApp.terminate(nil)
        // If a delegate or unsaved-changes prompt vetoes this terminate, the
        // script's timeout (5 min) disarms the pending install safely.
    }

    // MARK: - Helpers (UI)

    /// Displays an error alert to the user.
    private func showError(_ message: String) {
        let a = NSAlert()
        a.messageText = "Update Error"
        a.informativeText = message
        a.alertStyle = .warning
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    // MARK: - Helpers (trust and verification)

    /// True if the URL is https on the trusted domain (or a subdomain).
    static func isTrustedDownloadURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else { return false }
        return host == trustedHostSuffix || host.hasSuffix("." + trustedHostSuffix)
    }

    /// Deep, strict code-signature verification of a bundle, equivalent to
    /// `codesign --verify --deep --strict`.
    private static func verifyCodeSignature(ofBundleAt url: URL) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures
                                       | kSecCSCheckNestedCode
                                       | kSecCSStrictValidate)
        return SecStaticCodeCheckValidityWithErrors(code, flags, nil, nil) == errSecSuccess
    }

    /// Reads the Team Identifier from a bundle's code signature.
    /// Returns nil for unsigned or ad-hoc-signed bundles.
    private static func teamIdentifier(forBundleAt url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code,
                                            SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Extracts a zip with `ditto -x -k`, which preserves the xattrs,
    /// symlinks, and resource forks that code signatures cover.
    private static func extractZip(_ zip: URL, to dir: URL) -> Bool {
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else {
            return false
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, dir.path]
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Finds the first .app bundle at the top level of `dir`, or one
    /// directory down (archives often wrap the app in a folder).
    private static func locateAppBundle(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard let top = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return nil
        }
        if let app = top.first(where: { $0.pathExtension == "app" }) { return app }
        for sub in top {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: sub.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if let inner = try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil),
               let app = inner.first(where: { $0.pathExtension == "app" }) {
                return app
            }
        }
        return nil
    }

    // MARK: - Helpers (versions and hashing)

    /// Compares two version strings numerically.
    /// Parses dotted components (e.g., "1.3.10") and compares them
    /// left-to-right. Missing components are treated as 0. A non-numeric
    /// prefix like "v" is skipped; non-numeric suffixes are ignored.
    /// Known limitation: pre-release tags don't order ("1.0.8-beta1"
    /// compares equal to "1.0.8") - keep appcast versions plain.
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
    /// "v1.0.7" -> [1, 0, 7]; "1.0.8-beta1" -> [1, 0, 8].
    private static func versionComponents(_ s: String) -> [Int] {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
         .split(separator: ".")
         .map { component -> Int in
             let digits = component
                 .drop(while: { !$0.isNumber })
                 .prefix(while: { $0.isNumber })
             return Int(digits) ?? 0
         }
    }

    /// Computes the lowercase hex SHA-256 of a file, streamed in 1 MB
    /// chunks so large update packages never need to fit in memory.
    static func sha256Hex(ofFileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Computes the lowercase hex SHA-256 of in-memory data.
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Download Progress Panel

/// Lightweight panel that displays download progress for application
/// updates, with a Cancel button that aborts the download.
private class UpdateProgressPanel {

    private let window: NSPanel
    private let bar: NSProgressIndicator

    /// Called when the user clicks Cancel.
    var onCancel: (() -> Void)?

    init() {
        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 104),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.title = "Downloading Update..."
        // A programmatic NSPanel defaults to isReleasedWhenClosed = true;
        // combined with this Swift strong reference, close() would
        // over-release and crash. This must stay false.
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.center()

        bar = NSProgressIndicator(frame: NSRect(x: 20, y: 48, width: 280, height: 20))
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 1
        bar.isIndeterminate = false
        bar.doubleValue = 0
        window.contentView?.addSubview(bar)

        let label = NSTextField(labelWithString: "Downloading...")
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 20, y: 74, width: 280, height: 16)
        window.contentView?.addSubview(label)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked(_:)))
        cancelButton.bezelStyle = .rounded
        cancelButton.frame = NSRect(x: 220, y: 12, width: 80, height: 26)
        window.contentView?.addSubview(cancelButton)
    }

    @objc private func cancelClicked(_ sender: Any?) {
        onCancel?()
    }

    func show() { window.makeKeyAndOrderFront(nil) }
    func close() { window.close() }

    func setFraction(_ fraction: Double) {
        bar.doubleValue = fraction
    }
}
