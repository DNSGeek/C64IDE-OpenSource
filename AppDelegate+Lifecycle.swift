//  AppDelegate+Lifecycle.swift
//  C64 IDE
//
//  Application lifecycle, session restoration, and window management.

import Cocoa

extension AppDelegate {

    // MARK: - App Lifecycle

    /// Handles opening files or projects via URL schemes or Finder drag-and-drop.
    @objc @MainActor func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.pathExtension == C64Project.fileExtension {
                if mainWindowController != nil {
                    ProjectManager.shared.openProject(at: url)
                } else {
                    pendingURLsToOpen.append(url)
                }
            } else {
                if mainWindowController != nil {
                    mainWindowController?.loadDocument(from: url)
                } else {
                    pendingURLsToOpen.append(url)
                }
            }
        }
    }

    /// Restores the last active project from user defaults.
    @MainActor private func restoreLastProject() {
        // A project opened at launch (Finder double-click, URL scheme) takes
        // precedence over auto-reopen. Without this guard, restoring the last
        // project would close all the tabs the just-opened project restored.
        guard !ProjectManager.shared.isProjectOpen else { return }
        guard let path = UserDefaults.standard.string(forKey: "lastProjectURL") else { return }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            UserDefaults.standard.removeObject(forKey: "lastProjectURL")
            return
        }
        ProjectManager.shared.openProject(at: url)
    }

    /// Called when the app finishes launching. Sets up menus, themes, and restores state.
    @MainActor func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = AppTheme.current.nsAppearance
        BasicDialectManager.shared.loadDefaultPlugins()
        setupMainMenu()
        openNewWindow()
        restoreSession()
        openPendingURLs()

        BasicDialectManager.shared.onDialectChanged = { [weak self] in
            C64BasicSyntax.invalidateKeywordMatcher()
            self?.mainWindowController?.allEditors.forEach { $0.rehighlightAll() }
        }

        // Silent background update check (rate-limited to once per day)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            UpdateChecker.shared.checkForUpdates(silently: true)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCharsetSendToMapEditor(_:)),
            name: .charsetSendToMapEditor,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleProjectDidOpen(_:)),
            name: .projectDidOpen,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleProjectDidClose(_:)),
            name: .projectDidClose,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleProjectDirtyChanged(_:)),
            name: .projectDirtyStateChanged,
            object: nil
        )
        restoreLastProject()
    }

    /// Called before the app terminates. Persists session state and prompts for unsaved changes.
    @MainActor func applicationWillTerminate(_ notification: Notification) {
        guard let wc = mainWindowController else { return }
        let openFileURLs = wc.allEditors.compactMap { $0.document.fileURL }
        let openFiles = openFileURLs.map { $0.path }
        let selectedIdx: Int = {
            if let tv = wc.editorTabView, let sel = tv.selectedTabViewItem {
                return tv.indexOfTabViewItem(sel)
            }
            return 0
        }()

        if ProjectManager.shared.isProjectOpen {
            // uniquingKeysWith merges duplicates: if the same file is open in two
            // tabs, uniqueKeysWithValues would trap at runtime.
            let breakpoints = Dictionary(
                wc.allEditors.compactMap { editor -> (URL, [Int])? in
                    guard let url = editor.document.fileURL else { return nil }
                    let lines = Array(editor.breakpointLines).sorted()
                    return lines.isEmpty ? nil : (url, lines)
                },
                uniquingKeysWith: { Array(Set($0 + $1)).sorted() }
            )
            ProjectManager.shared.captureSession(
                openFilePaths: openFileURLs,
                selectedTab: selectedIdx,
                breakpoints: breakpoints
            )
        } else {
            UserDefaults.standard.set(openFiles, forKey: "openTabs")
            UserDefaults.standard.set(selectedIdx, forKey: "selectedTab")
        }
    }

    /// Enables secure restorable state for macOS session management.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    /// Closes the app when the last window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    /// Handles graceful termination, prompting to save unsaved files if needed.
    @MainActor func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !ProjectManager.shared.promptSaveIfNeededOnQuit() {
            return .terminateCancel
        }

        if let wc = mainWindowController {
            for editor in wc.allEditors {
                if editor.document.isModified {
                    let alert = NSAlert()
                    alert.messageText = "Do you want to save changes to \"\(editor.document.displayTitle)\"?"
                    alert.informativeText = "Your changes will be lost if you don't save them."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Save")
                    alert.addButton(withTitle: "Don't Save")
                    alert.addButton(withTitle: "Cancel")

                    switch alert.runModal() {
                    case .alertFirstButtonReturn:
                        editor.saveDocument()
                    case .alertSecondButtonReturn:
                        break
                    default:
                        return .terminateCancel
                    }
                }
            }
        }

        if let diskVC = diskBrowserController?.window?.contentViewController as? D64BrowserViewController {
            if !diskVC.promptToSaveIfNeeded() { return .terminateCancel }
        }

        if let mapWC = mapEditorController {
            if !mapWC.promptToSaveIfNeeded() { return .terminateCancel }
        }

        return .terminateNow
    }

    // MARK: - Window / Session Helpers

    /// Creates and displays the main application window.
    func openNewWindow() {
        let wc = MainWindowController()
        wc.window?.makeKeyAndOrderFront(nil)
        mainWindowController = wc
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Restores previously open files and tab state from user defaults.
    func restoreSession() {
        guard let openFiles = UserDefaults.standard.stringArray(forKey: "openTabs"),
              !openFiles.isEmpty,
              let wc = mainWindowController else { return }

        var restoredCount = 0
        for path in openFiles {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { continue }
            wc.loadDocument(from: url)
            restoredCount += 1
        }

        if restoredCount > 0 {
            let selectedIndex = UserDefaults.standard.integer(forKey: "selectedTab")
            if let tabView = wc.editorTabView,
               selectedIndex >= 0, selectedIndex < tabView.numberOfTabViewItems {
                tabView.selectTabViewItem(at: selectedIndex)
            }
        }
    }

    /// Opens files that were queued before the main window was initialized.
    @MainActor func openPendingURLs() {
        let pending = pendingURLsToOpen
        pendingURLsToOpen = []
        for url in pending {
            if url.pathExtension == C64Project.fileExtension {
                ProjectManager.shared.openProject(at: url)
            } else {
                mainWindowController?.loadDocument(from: url)
            }
        }
    }
}

