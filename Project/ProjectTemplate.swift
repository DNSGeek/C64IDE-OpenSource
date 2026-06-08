import Foundation

// MARK: - ProjectTemplate

/// Describes a bundled project template.
///
/// Each template lives in `Resources/Templates/<folderName>/` and contains:
///   - A `template.json` metadata file (decoded into `TemplateMetadata`)
///   - A `.c64proj` file
///   - One or more source files
///
/// The template folder is copied verbatim to the user's chosen location,
/// then the `.c64proj` file is renamed and its `name` field updated.
struct ProjectTemplate: Identifiable {

    /// Stable identifier — matches the folder name inside `Resources/Templates/`
    var id: String

    /// Display name shown in the picker (e.g., "Simple Game Starter")
    var name: String

    /// One-line description shown below the name in the picker
    var summary: String

    /// Category for grouping in the picker sidebar
    var category: TemplateCategory

    /// Filename of the `.c64proj` inside the template folder
    var projectFileName: String

    /// URL of the template folder inside the app bundle
    var folderURL: URL

    enum TemplateCategory: String, CaseIterable {
        case basic    = "BASIC"
        case assembly = "Assembly"

        var displayName: String { rawValue }
    }
}

// MARK: - Template metadata (template.json)

/// Codable mirror of `template.json` — only used during bundle loading.
private struct TemplateMetadata: Codable {
    var name: String
    var summary: String
    var category: String
    var projectFileName: String
}

// MARK: - ProjectTemplateLoader

/// Discovers and loads all bundled templates from `Resources/Templates/`.
enum ProjectTemplateLoader {

    /// Returns all valid templates found in the app bundle, sorted by category then name.
    static func loadAll() -> [ProjectTemplate] {
        guard let templatesURL = Bundle.main.url(
            forResource: "Templates", withExtension: nil
        ) else {
            return []
        }

        let fm = FileManager.default
        guard let subfolders = try? fm.contentsOfDirectory(
            at: templatesURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var templates: [ProjectTemplate] = []

        for folder in subfolders {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue
            else { continue }

            let metaURL = folder.appendingPathComponent("template.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let meta = try? JSONDecoder().decode(TemplateMetadata.self, from: data)
            else {
                continue    // Skip folders without valid metadata
            }

            let category = ProjectTemplate.TemplateCategory(rawValue: meta.category)
                        ?? .basic

            templates.append(ProjectTemplate(
                id:              folder.lastPathComponent,
                name:            meta.name,
                summary:         meta.summary,
                category:        category,
                projectFileName: meta.projectFileName,
                folderURL:       folder
            ))
        }

        return templates.sorted {
            if $0.category.rawValue != $1.category.rawValue {
                return $0.category.rawValue < $1.category.rawValue
            }
            return $0.name < $1.name
        }
    }
}

// MARK: - Template installer

/// Copies a template folder to the user's chosen location and patches the project file.
enum ProjectTemplateInstaller {

    enum InstallError: LocalizedError {
        case projectFileNotFound(String)
        case jsonParseFailed
        case writeFailed(Error)

        var errorDescription: String? {
            switch self {
            case .projectFileNotFound(let name):
                return "Could not find \"\(name)\" in the template folder."
            case .jsonParseFailed:
                return "The template project file could not be read."
            case .writeFailed(let e):
                return "Could not write project: \(e.localizedDescription)"
            }
        }
    }

    /// Installs `template` into `destinationURL/<projectName>/`.
    ///
    /// - Parameters:
    ///   - template:        The template to install.
    ///   - projectName:     The name the user typed — becomes the folder name,
    ///                      the `.c64proj` filename, and the `name` field inside it.
    ///   - destinationURL:  Parent folder chosen by the user (e.g., `~/Developer`).
    /// - Returns:           URL of the newly created `.c64proj` file.
    @discardableResult
    static func install(
        template: ProjectTemplate,
        projectName: String,
        into destinationURL: URL
    ) throws -> URL {

        let fm = FileManager.default
        let projectDir = destinationURL.appendingPathComponent(projectName)

        // 1. Copy the entire template folder to the destination
        try fm.copyItem(at: template.folderURL, to: projectDir)

        // 2. Remove `template.json` — it's internal scaffolding, not part of the project
        let metaURL = projectDir.appendingPathComponent("template.json")
        try? fm.removeItem(at: metaURL)

        // 3. Rename the `.c64proj` file to match the new project name
        let oldProjURL = projectDir.appendingPathComponent(template.projectFileName)
        guard fm.fileExists(atPath: oldProjURL.path) else {
            throw InstallError.projectFileNotFound(template.projectFileName)
        }
        let newProjFileName = projectName + ".c64proj"
        let newProjURL = projectDir.appendingPathComponent(newProjFileName)
        try fm.moveItem(at: oldProjURL, to: newProjURL)

        // 4. Patch the `name` field inside the `.c64proj` JSON
        do {
            let data = try Data(contentsOf: newProjURL)
            guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw InstallError.jsonParseFailed }

            json["name"] = projectName as Any

            let patched = try JSONSerialization.data(
                withJSONObject: json,
                options: [.prettyPrinted, .sortedKeys]
            )
            try patched.write(to: newProjURL, options: .atomic)
        } catch let e as InstallError {
            throw e
        } catch {
            throw InstallError.writeFailed(error)
        }

        return newProjURL
    }
}

