import AppKit

// ═══════════════════════════════════════════════════════════
// MARK: - BottomPanelController + disk hint
// ═══════════════════════════════════════════════════════════

/// Adds a thin disk-status hint strip to the bottom of the build tab.
///
/// The strip shows one of three states:
///
/// - **Will bundle** — "Will bundle as: MYGAME on Boot Disk (Drive 8)"
///   when the active file is covered by the project's disk manifest.
/// - **Not bundled** — "Not bundled — add to a disk in Project Settings"
///   when a project is open but the file has no disk association.
/// - **Hidden** — when no project is open (loose-file mode).
///
/// `updateDiskHint(for:)` is called by `MainWindowController` whenever
/// the active editor tab changes. It runs the manifest check synchronously
/// (pure in-memory, no I/O) so there's no perceptible delay.
extension BottomPanelController {

    // MARK: - Hint label access

    /// Lazy-created hint label. Inserted as a sibling of `buildScrollView`
    /// the first time it's needed, so the existing build tab layout is
    /// untouched until a project with a disk config is opened.
    var diskHintLabel: NSTextField {
        if let existing = view.viewWithTag(Self.diskHintTag) as? NSTextField {
            return existing
        }
        return installDiskHintLabel()
    }

    private static let diskHintTag = 0xD15C  // "DISC" — unique tag for lookup

    // MARK: - Public API

    /// Update the disk hint for the given source file URL.
    ///
    /// Pass `nil` to hide the hint (e.g. on project close or unsaved scratch files).
    func updateDiskHint(for fileURL: URL?) {
        guard let fileURL else {
            hideDiskHint()
            return
        }

        let pm = ProjectManager.shared
        guard pm.isProjectOpen,
              let project = pm.activeProject,
              let root = pm.projectRoot,
              let diskConfig = project.diskConfig else {
            hideDiskHint()
            return
        }

        // Check whether the file falls inside any asset folder on any disk.
        if let (disk, cbmName) = resolvedEntry(for: fileURL, root: root, config: diskConfig) {
            showDiskHint(
                "Will bundle as: \(cbmName)  on  \(disk.label) (Drive \(disk.driveNumber))",
                style: .bundled
            )
        } else if project.buildOptions.diskOutput != nil,
                  let targetID = project.buildOptions.diskOutput?.targetDiskID,
                  let targetDisk = diskConfig.disk(withID: targetID) {
            // File isn't in an asset folder — check if it might be the main source
            // (heuristic: file is in the project root or a direct child folder).
            let rel = fileURL.path.hasPrefix(root.path + "/")
                ? String(fileURL.path.dropFirst(root.path.count + 1))
                : nil
            let depth = rel?.components(separatedBy: "/").count ?? 99

            if depth <= 2 {
                let cbmName = project.buildOptions.diskOutput?.outputCBMName ?? "?"
                showDiskHint(
                    "Main source — compiles as: \(cbmName)  on  \(targetDisk.label) (Drive \(targetDisk.driveNumber))",
                    style: .bundled
                )
            } else {
                showDiskHint("Not bundled — add this file to a disk in Project Settings", style: .notBundled)
            }
        } else {
            showDiskHint("Not bundled — add this file to a disk in Project Settings", style: .notBundled)
        }
    }

    // MARK: - Manifest check (pure, no I/O)

    /// Returns `(disk, cbmName)` if `fileURL` would actually be bundled by
    /// any disk's manifest, or nil if it would not.
    ///
    /// Runs the real `ManifestResolver` against a filesystem stub containing
    /// only this one file, so the hint honors exactly the same rules as the
    /// build: exclude globs, explicit-file renames, and the auto-naming
    /// substitution rules. The old folder-prefix heuristic showed
    /// "Will bundle" for excluded files and could display a CBM name that
    /// differed from what the build actually writes.
    private func resolvedEntry(
        for fileURL: URL,
        root: URL,
        config: ProjectDiskConfig
    ) -> (ProjectDisk, String)? {
        let fileStd    = fileURL.standardizedFileURL
        let resolver   = ManifestResolver()
        let enumerator = SingleFileEnumerator(file: fileStd)

        for disk in config.disks {
            // Resolution can throw (e.g. a naming collision among explicit
            // entries). For hint purposes, treat that as "not resolvable"
            // and move on - the build itself will surface the real error.
            guard let files = try? resolver.resolve(
                disk: disk,
                projectRoot: root,
                buildOutput: nil,
                fileSystem: enumerator
            ) else { continue }

            if let match = files.first(where: {
                $0.sourceURL.standardizedFileURL.path == fileStd.path
            }) {
                return (disk, match.cbmName)
            }
        }
        return nil
    }

    // MARK: - Show / hide

    enum DiskHintStyle { case bundled, notBundled }

    /// `FileSystemEnumerator` stub exposing exactly one file, and only when
    /// the queried directory actually contains it. Lets the disk hint reuse
    /// `ManifestResolver` per-file without walking the whole project tree.
    private struct SingleFileEnumerator: FileSystemEnumerator {
        /// Must already be standardized by the caller.
        let file: URL
        func filesInDirectory(_ directory: URL) -> [URL] {
            let dir = directory.standardizedFileURL.path
            return file.path.hasPrefix(dir + "/") ? [file] : []
        }
    }

    private func showDiskHint(_ text: String, style: DiskHintStyle) {
        let label = diskHintLabel
        label.stringValue = style == .bundled
            ? "  \u{1F4BE}  \(text)"   // 💾
            : "  \u{26A0}\u{FE0F}  \(text)"  // ⚠️
        label.backgroundColor = AppTheme.current.panelBackground
        label.textColor = style == .bundled
            ? AppTheme.current.logSuccess
            : AppTheme.current.logWarning
        label.isHidden = false
        adjustBuildScrollViewForHint(visible: true)
    }

    private func hideDiskHint() {
        guard let label = view.viewWithTag(Self.diskHintTag) as? NSTextField else { return }
        label.isHidden = true
        adjustBuildScrollViewForHint(visible: false)
    }

    // MARK: - Layout helpers

    private func installDiskHintLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.tag = Self.diskHintTag
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = true
        label.backgroundColor = AppTheme.current.panelBackground
        label.autoresizingMask = [.width]
        label.isHidden = true

        // Find the build tab's content view to insert into
        guard let buildTabItem = tabView?.tabViewItem(at: 0),
              let tabContentView = buildTabItem.view else {
            // Fallback — insert into main view
            label.frame = NSRect(x: 0, y: 0, width: view.bounds.width, height: Self.hintHeight)
            view.addSubview(label)
            return label
        }

        let w = tabContentView.bounds.width
        label.frame = NSRect(x: 0, y: 0, width: w, height: Self.hintHeight)
        tabContentView.addSubview(label)
        return label
    }

    private static let hintHeight: CGFloat = 22

    /// Shrink or restore the build scroll view to make room for the hint strip.
    private func adjustBuildScrollViewForHint(visible: Bool) {
        guard let buildTabItem = tabView?.tabViewItem(at: 0),
              let tabContentView = buildTabItem.view,
              let scrollView = tabContentView.subviews.first(where: { $0 is NSScrollView }) else {
            return
        }

        var frame = scrollView.frame
        let containerHeight = tabContentView.bounds.height

        if visible {
            // Leave room at the bottom for the hint strip
            frame.origin.y = Self.hintHeight
            frame.size.height = containerHeight - Self.hintHeight
        } else {
            frame.origin.y = 0
            frame.size.height = containerHeight
        }
        scrollView.frame = frame
    }

    // MARK: - tabView access

    /// `tabView` is declared `private` in `BottomPanelController` — access
    /// it via the tag we know it has, or fall back to the first NSTabView
    /// in the subview hierarchy.
    private var tabView: NSTabView? {
        view.subviews.first(where: { $0 is NSTabView }) as? NSTabView
    }

    // MARK: - Theme support

    func applyDiskHintTheme() {
        guard let label = view.viewWithTag(Self.diskHintTag) as? NSTextField else { return }
        label.backgroundColor = AppTheme.current.panelBackground
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - MainWindowController wiring
// ═══════════════════════════════════════════════════════════

/// Wires the disk hint update into the tab-change callback.
///
/// Add the following lines to `MainWindowController.wireEditorCallbacks(_:)`
/// (or wherever the active tab change is observed) so the hint refreshes
/// whenever the user switches editor tabs:
///
/// ```swift
/// // In wireEditorCallbacks or the tab-did-select handler:
/// refreshDiskHint()
/// ```
///
/// And add this method to `MainWindowController`:
///
/// ```swift
/// func refreshDiskHint() {
///     let url = editorViewController?.document.fileURL
///     bottomPanelController.updateDiskHint(for: url)
/// }
/// ```
///
/// Also call `refreshDiskHint()` from:
/// - `handleProjectDidOpen` (in AppDelegate+ProjectActions)
/// - `handleProjectDidClose`
/// - After `ProjectManager.updateProject` returns in `ProjectSettingsViewModel.save()`
///   (post a `.projectDirtyStateChanged` notification — already done).
///
/// That's all the wiring needed. The hint then stays in sync with:
/// - Tab switches
/// - Project open/close
/// - Disk config changes saved from Project Settings
extension MainWindowController {

    /// Refresh the disk hint in the bottom panel for the currently active file.
    @objc func refreshDiskHint() {
        let url = editorViewController?.document.fileURL
        bottomPanelController.updateDiskHint(for: url)
    }

}

