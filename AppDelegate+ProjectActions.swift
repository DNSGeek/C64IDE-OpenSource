//  AppDelegate+ProjectActions.swift
//  C64 IDE
//
//  Project management, session persistence, and recent files handling.

import Cocoa

extension AppDelegate {

    // MARK: - Project Notifications

    /// Updates the main window when a project is opened.
    @MainActor @objc func handleProjectDidOpen(_ notification: Notification) {
        guard let wc = mainWindowController else { return }
        let pm = ProjectManager.shared
        guard let project = pm.activeProject, let root = pm.projectRoot else { return }

        wc.window?.title = "\(project.name) — C64 IDE"
        wc.closeAllTabs()

        var restoredCount = 0
        for relativePath in project.session.openFiles {
            let url = ProjectSession.absoluteURL(for: relativePath, root: root)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            wc.loadDocument(from: url)
            restoredCount += 1
        }

        if restoredCount > 0 {
            let idx = project.session.selectedTab
            if let tabView = wc.editorTabView, idx >= 0, idx < tabView.numberOfTabViewItems {
                tabView.selectTabViewItem(at: idx)
            }
        }

        for (relativePath, lines) in project.session.breakpoints {
            let url = ProjectSession.absoluteURL(for: relativePath, root: root)
            wc.restoreBreakpoints(lines, forFileURL: url)
        }

        pm.applyBuildOptions(to: wc.buildConfig)
        rebuildRecentProjectsMenu()
        wc.refreshGitStatus()
        wc.buildManager.project     = ProjectManager.shared.activeProject
        wc.buildManager.projectRoot = ProjectManager.shared.projectRoot
        wc.refreshDiskHint()

        // Persist last open project for auto-reopen on next launch
        if let url = ProjectManager.shared.projectURL {
            UserDefaults.standard.set(url.path, forKey: "lastProjectURL")
        }
    }

    /// Cleans up UI state when a project is closed.
    @MainActor @objc func handleProjectDidClose(_ notification: Notification) {
        mainWindowController?.window?.title = "C64 IDE"
        mainWindowController?.clearGitStatus()
        rebuildRecentProjectsMenu()
        mainWindowController?.buildManager.project     = nil
        mainWindowController?.buildManager.projectRoot = nil
        mainWindowController?.refreshDiskHint()
        UserDefaults.standard.removeObject(forKey: "lastProjectURL")
    }

    /// Updates the window title to show unsaved changes indicator.
    @MainActor @objc func handleProjectDirtyChanged(_ notification: Notification) {
        updateWindowTitleDirtyIndicator()
    }

    @MainActor private func updateWindowTitleDirtyIndicator() {
        guard let wc = mainWindowController,
              let project = ProjectManager.shared.activeProject else { return }
        let dot = ProjectManager.shared.isDirty ? " •" : ""
        wc.window?.title = "\(project.name)\(dot) — C64 IDE"
    }

    /// Opens the map editor when triggered by a charset notification.
    @objc func handleCharsetSendToMapEditor(_ notification: Notification) {
        openMapEditor(nil)
    }
}

// MARK: - Project Actions

extension AppDelegate {

    /// Prompts the user to create a new project directory.
    @MainActor @objc func newProject(_ sender: Any?) {
        let nameAlert = NSAlert()
        nameAlert.messageText = "New Project"
        nameAlert.informativeText = "Enter a name for your new project."
        nameAlert.addButton(withTitle: "Create")
        nameAlert.addButton(withTitle: "Cancel")

        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        nameField.placeholderString = "MyGame"
        nameAlert.accessoryView = nameField
        nameAlert.window.initialFirstResponder = nameField

        guard nameAlert.runModal() == .alertFirstButtonReturn else { return }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.title = "Choose Project Location"
        panel.message = "Choose a folder for \"\(name)\""
        panel.prompt = "Create"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let location = panel.url else { return }
        let projectDir = location.appendingPathComponent(name)
        ProjectManager.shared.createProject(name: name, at: projectDir)
    }

    /// Opens an existing `.c64proj` file.
    @MainActor @objc func openProjectDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "Open Project"
        panel.allowedContentTypes = [.init(filenameExtension: C64Project.fileExtension)!]
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        ProjectManager.shared.openProject(at: url)
    }

    /// Opens a project from the recent projects list.
    @MainActor @objc func openRecentProject(_ sender: NSMenuItem) {
        let url = URL(fileURLWithPath: sender.representedObject as! String)
        ProjectManager.shared.openProject(at: url)
    }

    /// Saves the current project state and captures the active session.
    @MainActor @objc func saveProject(_ sender: Any?) {
        guard ProjectManager.shared.isProjectOpen else { return }
        if let wc = mainWindowController {
            let openFileURLs = wc.allEditors.compactMap { $0.document.fileURL }
            let selectedIdx: Int = {
                if let tv = wc.editorTabView, let sel = tv.selectedTabViewItem {
                    return tv.indexOfTabViewItem(sel)
                }
                return 0
            }()
            let breakpoints = Dictionary(
                uniqueKeysWithValues: wc.allEditors.compactMap { editor -> (URL, [Int])? in
                    guard let url = editor.document.fileURL else { return nil }
                    let lines = Array(editor.breakpointLines).sorted()
                    return lines.isEmpty ? nil : (url, lines)
                }
            )
            ProjectManager.shared.captureSession(
                openFilePaths: openFileURLs,
                selectedTab: selectedIdx,
                breakpoints: breakpoints
            )
        }
        do {
            try ProjectManager.shared.saveProject()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not save project"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.runModal()
        }
    }

    /// Closes the active project with unsaved change prompts.
    @MainActor @objc func closeProject(_ sender: Any?) {
        let pm = ProjectManager.shared
        guard pm.isProjectOpen else { return }
        if pm.isDirty {
            switch pm.promptSave(projectName: pm.activeProject?.name ?? "project") {
            case .save:
                guard (try? pm.saveProject()) != nil else { return }
            case .discard:
                break
            case .cancel:
                return
            }
        }
        pm.closeProject()
        restoreSession()
    }

    /// Saves the current document and marks the project as modified if open.
    @MainActor @objc func saveCurrentDocument(_ sender: Any?) {
        mainWindowController?.saveDocument(sender)
        if ProjectManager.shared.isProjectOpen {
            ProjectManager.shared.updateProject { _ in }
        }
    }

    // MARK: - Recent Projects Menu

    /// Rebuilds the recent projects submenu with current entries.
    @MainActor func rebuildRecentProjectsMenu() {
        guard let fileMenu = NSApp.mainMenu?.item(withTitle: "File")?.submenu,
              let recentItem = fileMenu.items.first(where: { $0.tag == 9001 }),
              let recentMenu = recentItem.submenu else { return }

        recentMenu.removeAllItems()
        let recents = ProjectManager.shared.recentProjects

        if recents.isEmpty {
            let empty = NSMenuItem(title: "No Recent Projects", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentMenu.addItem(empty)
        } else {
            for url in recents {
                let item = NSMenuItem(
                    title: url.deletingPathExtension().lastPathComponent,
                    action: #selector(openRecentProject(_:)),
                    keyEquivalent: ""
                )
                item.representedObject = url.path
                item.toolTip = url.path
                recentMenu.addItem(item)
            }
            recentMenu.addItem(.separator())
            recentMenu.addItem(NSMenuItem(
                title: "Clear Recent Projects",
                action: #selector(clearRecentProjects(_:)),
                keyEquivalent: ""
            ))
        }
    }

    /// Clears the recent projects list from user defaults.
    @MainActor @objc func clearRecentProjects(_ sender: Any?) {
        ProjectManager.shared.clearRecentProjects()
        rebuildRecentProjectsMenu()
    }
}

