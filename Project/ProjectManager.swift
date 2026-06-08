import Foundation
import AppKit

// MARK: - Notifications

extension Notification.Name {
    /// Posted on the main thread after a project opens successfully.
    /// `object` = `ProjectManager`, `userInfo["projectURL"]` = URL
    static let projectDidOpen  = Notification.Name("C64IDE.projectDidOpen")

    /// Posted on the main thread after a project closes.
    /// `object` = `ProjectManager`
    static let projectDidClose = Notification.Name("C64IDE.projectDidClose")

    /// Posted whenever the project's dirty state changes.
    /// `object` = `ProjectManager`
    static let projectDirtyStateChanged = Notification.Name("C64IDE.projectDirtyStateChanged")
}

// MARK: - ProjectManager

@MainActor
final class ProjectManager {

    // MARK: - Singleton

    static let shared = ProjectManager()
    private init() {
        loadRecentProjects()
    }

    // MARK: - State

    /// The currently open project, or `nil` in loose-file mode.
    private(set) var activeProject: C64Project?

    /// URL of the `.c64proj` file on disk.
    private(set) var projectURL: URL?

    /// Root directory of the project (parent of the `.c64proj` file).
    var projectRoot: URL? { projectURL?.deletingLastPathComponent() }

    /// True when the project has changes not yet written to disk.
    private(set) var isDirty: Bool = false {
        didSet {
            guard isDirty != oldValue else { return }
            NotificationCenter.default.post(name: .projectDirtyStateChanged, object: self)
        }
    }

    /// Whether a project is currently open.
    var isProjectOpen: Bool { activeProject != nil }

    // MARK: - Recent Projects

    private let recentProjectsKey = "recentProjects"
    private let maxRecentProjects = 10

    /// Most-recently-used project URLs (most recent first).
    private(set) var recentProjects: [URL] = []

    private func loadRecentProjects() {
        let paths = UserDefaults.standard.stringArray(forKey: recentProjectsKey) ?? []
        recentProjects = paths
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func addToRecents(_ url: URL) {
        recentProjects.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        recentProjects.insert(url, at: 0)
        if recentProjects.count > maxRecentProjects {
            recentProjects = Array(recentProjects.prefix(maxRecentProjects))
        }
        UserDefaults.standard.set(recentProjects.map { $0.path }, forKey: recentProjectsKey)
        // Rebuild the Recent Projects submenu
        NotificationCenter.default.post(name: .projectDidOpen, object: self,
                                        userInfo: ["projectURL": url])
    }

    func clearRecentProjects() {
        recentProjects = []
        UserDefaults.standard.removeObject(forKey: recentProjectsKey)
    }

    // MARK: - Open

    /// Opens a `.c64proj` file. Prompts to save the current project first if dirty.
    /// - Returns: `true` if the project was successfully opened.
    @discardableResult
    func openProject(at url: URL) -> Bool {
        guard url.pathExtension == C64Project.fileExtension else { return false }

        // Prompt to save current project if needed
        if isDirty, let current = activeProject {
            let choice = promptSave(projectName: current.name)
            switch choice {
            case .save:
                guard (try? saveProject()) != nil else { return false }
            case .discard:
                break
            case .cancel:
                return false
            }
        }

        do {
            let project = try C64Project.load(from: url)
            activeProject = project
            projectURL = url
            isDirty = false
            addToRecents(url)

            NotificationCenter.default.post(
                name: .projectDidOpen,
                object: self,
                userInfo: ["projectURL": url]
            )
            return true
        } catch {
            showError("Could not open project", detail: error.localizedDescription)
            return false
        }
    }

    // MARK: - Create

    /// Creates a new project at the given directory.
    /// Creates the directory and writes an initial `.c64proj` file.
    @discardableResult
    func createProject(name: String, at directory: URL) -> Bool {
        // Prompt to save current project if needed
        if isDirty, let current = activeProject {
            let choice = promptSave(projectName: current.name)
            switch choice {
            case .save:
                guard (try? saveProject()) != nil else { return false }
            case .discard:
                break
            case .cancel:
                return false
            }
        }

        let projectFile = directory
            .appendingPathComponent(name)
            .appendingPathExtension(C64Project.fileExtension)

        do {
            try FileManager.default.createDirectory(at: directory,
                                                     withIntermediateDirectories: true)
            let project = C64Project(name: name)
            try project.save(to: projectFile)

            activeProject = project
            projectURL = projectFile
            isDirty = false
            addToRecents(projectFile)

            NotificationCenter.default.post(
                name: .projectDidOpen,
                object: self,
                userInfo: ["projectURL": projectFile]
            )
            return true
        } catch {
            showError("Could not create project", detail: error.localizedDescription)
            return false
        }
    }

    // MARK: - Save

    /// Saves the active project to its `.c64proj` file.
    /// - Throws: If there is no active project or the write fails.
    func saveProject() throws {
        guard let project = activeProject, let url = projectURL else {
            throw ProjectError.noActiveProject
        }
        try project.save(to: url)
        isDirty = false
    }

    // MARK: - Close

    /// Closes the active project. Caller is responsible for prompting to save first
    /// (use `promptSaveIfNeeded()` before calling this).
    func closeProject() {
        activeProject = nil
        projectURL = nil
        isDirty = false
        NotificationCenter.default.post(name: .projectDidClose, object: self)
    }

    // MARK: - Mutating the active project

    /// Updates the active project and marks it dirty.
    /// Use this for all mutations so dirty tracking remains consistent.
    func updateProject(_ block: (inout C64Project) -> Void) {
        guard var project = activeProject else { return }
        block(&project)
        activeProject = project
        isDirty = true
    }

    /// Saves the current editor session into the project (open tabs, selected tab, breakpoints).
    /// Call this from `AppDelegate` just before saving or quitting.
    func captureSession(openFilePaths: [URL], selectedTab: Int, breakpoints: [URL: [Int]]) {
        guard let root = projectRoot else { return }
        updateProject { project in
            project.session.openFiles = openFilePaths.map {
                ProjectSession.relativePath(for: $0, root: root)
            }
            project.session.selectedTab = selectedTab
            project.session.breakpoints = Dictionary(
                uniqueKeysWithValues: breakpoints.map { url, lines in
                    (ProjectSession.relativePath(for: url, root: root), lines)
                }
            )
        }
    }

    // MARK: - Applying project config to BuildConfiguration

    /// Copies project-specific build options into a `BuildConfiguration` instance.
    /// The global config already holds the machine-wide tool paths — we only
    /// override the project-scoped fields.
    func applyBuildOptions(to config: BuildConfiguration) {
        guard let options = activeProject?.buildOptions else { return }
        config.outputDirectory       = options.outputDirectory
        config.generateDebugInfo     = options.generateDebugInfo
        config.generateListing       = options.generateListing
        config.basicStripWhitespace  = options.basicStripWhitespace
        config.includePaths          = options.includePaths
        config.defines               = options.defines
        config.targetPlatform        = options.targetPlatform
        config.customLinkerConfig    = options.customLinkerConfig
        config.viceAutoRun           = options.viceAutoRun
        config.viceExtraArgs         = options.viceExtraArgs
        config.viceC64Model          = options.viceC64Model
        config.viceSIDModel          = options.viceSIDModel
        config.viceVideoStandard     = options.viceVideoStandard
        config.viceKernalROM         = options.viceKernalROM
        config.viceBasicROM          = options.viceBasicROM
        config.viceChargenROM        = options.viceChargenROM
    }

    /// Snapshots the current `BuildConfiguration` back into the project's build options.
    /// Call this when the user saves preferences while a project is open.
    func captureBuildOptions(from config: BuildConfiguration) {
        updateProject { project in
            project.buildOptions.outputDirectory      = config.outputDirectory
            project.buildOptions.generateDebugInfo    = config.generateDebugInfo
            project.buildOptions.generateListing      = config.generateListing
            project.buildOptions.basicStripWhitespace = config.basicStripWhitespace
            project.buildOptions.includePaths         = config.includePaths
            project.buildOptions.defines              = config.defines
            project.buildOptions.targetPlatform       = config.targetPlatform
            project.buildOptions.customLinkerConfig   = config.customLinkerConfig
            project.buildOptions.viceAutoRun          = config.viceAutoRun
            project.buildOptions.viceExtraArgs        = config.viceExtraArgs
            project.buildOptions.viceC64Model         = config.viceC64Model
            project.buildOptions.viceSIDModel         = config.viceSIDModel
            project.buildOptions.viceVideoStandard    = config.viceVideoStandard
            project.buildOptions.viceKernalROM        = config.viceKernalROM
            project.buildOptions.viceBasicROM         = config.viceBasicROM
            project.buildOptions.viceChargenROM       = config.viceChargenROM
        }
    }

    // MARK: - Quit support

    enum SaveChoice { case save, discard, cancel }

    /// Shows a "You have unsaved changes" sheet. Returns the user's choice.
    func promptSave(projectName: String) -> SaveChoice {
        let alert = NSAlert()
        alert.messageText = "Save changes to \"\(projectName)\"?"
        alert.informativeText = "Your project changes will be lost if you don't save them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:  return .save
        case .alertSecondButtonReturn: return .discard
        default:                       return .cancel
        }
    }

    /// Called from `applicationShouldTerminate`. Returns `false` if the user cancels.
    func promptSaveIfNeededOnQuit() -> Bool {
        guard isDirty, let project = activeProject else { return true }
        switch promptSave(projectName: project.name) {
        case .save:
            return (try? saveProject()) != nil
        case .discard:
            return true
        case .cancel:
            return false
        }
    }

    // MARK: - Private helpers

    private func showError(_ message: String, detail: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = message
            alert.informativeText = detail
            alert.alertStyle = .critical
            alert.runModal()
        }
    }
}

// MARK: - Errors

enum ProjectError: LocalizedError {
    case noActiveProject
    case invalidFileExtension

    var errorDescription: String? {
        switch self {
        case .noActiveProject:      return "No project is currently open."
        case .invalidFileExtension: return "File must have a .\(C64Project.fileExtension) extension."
        }
    }
}

