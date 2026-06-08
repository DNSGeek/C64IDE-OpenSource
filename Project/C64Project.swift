import Foundation

// MARK: - C64Project

/// In-memory representation of a `.c64proj` file.
/// Encodes/decodes directly to JSON. All fields are optional or include sensible defaults
/// to ensure backward compatibility with older project files.
struct C64Project: Codable {

    // MARK: - Metadata

    /// Display name of the project (not necessarily the filename)
    var name: String

    /// File format version. Increment when making breaking schema changes.
    var version: Int = 1

    /// Main source file to build, relative to the project root.
    /// `nil` falls back to the active editor file (legacy behavior).
    var mainFile: String?

    /// Active BASIC dialect plugin name, or `nil` for standard BASIC V2.
    var dialect: String?

    // MARK: - Project-scoped build settings

    /// Build options specific to this project. Machine-wide tool paths remain in `BuildConfiguration`.
    var buildOptions: ProjectBuildOptions

    /// Disk configuration for the project.
    var diskConfig: ProjectDiskConfig? = nil

    // MARK: - Session state

    /// Editor session state restored when the project is opened.
    var session: ProjectSession

    // MARK: - Init

    init(name: String, mainFile: String? = nil) {
        self.name = name
        self.mainFile = mainFile
        self.buildOptions = ProjectBuildOptions()
        self.session = ProjectSession()
    }
}

// MARK: - ProjectBuildOptions

/// Project-specific build settings — settings that can differ between projects
/// on the same machine. Machine-wide paths and preferences live in `BuildConfiguration`.
struct ProjectBuildOptions: Codable {

    /// Output directory, relative to the project root
    var outputDirectory: String = "build"

    /// Whether to generate a `.dbg` debug info file
    var generateDebugInfo: Bool = true

    /// Whether to generate a `.lst` assembly listing file
    var generateListing: Bool = false

    /// Strip whitespace when tokenizing BASIC (reduces binary size)
    var basicStripWhitespace: Bool = false

    /// Additional `ca65` include paths (relative or absolute)
    var includePaths: [String] = []

    /// `ca65` preprocessor defines
    var defines: [String: String] = [:]

    /// Target platform for `ca65`
    var targetPlatform: String = "c64"

    /// Custom linker config path (`nil` uses the built-in default)
    var customLinkerConfig: String? = nil

    /// Automatically run in VICE after a successful build
    var viceAutoRun: Bool = true

    /// Extra VICE command-line arguments
    var viceExtraArgs: [String] = []

    /// C64 model for VICE emulation (empty string = default)
    var viceC64Model: String = ""

    /// SID model for VICE: 0 = 6581, 1 = 8580, 2 = 8580+Digiboost
    var viceSIDModel: Int = 0

    /// PAL or NTSC video standard
    var viceVideoStandard: String = "pal"

    /// VICE ROM image overrides (empty strings = use VICE defaults)
    var viceKernalROM: String = ""
    var viceBasicROM: String = ""
    var viceChargenROM: String = ""

    /// Disk output configuration
    var diskOutput: ProjectBuildDiskOutput? = nil
    
    /// Per-project C64 emulator override. `nil` = use global preference.
    var preferredC64Emulator: RunTarget? = nil
}

// MARK: - ProjectSession

/// Editor session state — restored when the project is opened.
/// Stored in the project file so it survives across machines (e.g., git clones).
struct ProjectSession: Codable {

    /// Open file paths, relative to the project root
    var openFiles: [String] = []

    /// Index of the active tab
    var selectedTab: Int = 0

    /// Breakpoints keyed by relative file path, values are 1-based line numbers
    var breakpoints: [String: [Int]] = [:]

    // MARK: - Helpers

    /// Resolves a relative session path against a project root URL.
    static func absoluteURL(for relativePath: String, root: URL) -> URL {
        if relativePath.hasPrefix("/") {
            return URL(fileURLWithPath: relativePath)   // Already absolute (legacy)
        }
        return root.appendingPathComponent(relativePath)
    }

    /// Converts a file URL to a path relative to the project root.
    /// Falls back to an absolute path if the file resides outside the project root.
    static func relativePath(for url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        let normalizedRoot = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        
        if filePath.hasPrefix(normalizedRoot) {
            return String(filePath.dropFirst(normalizedRoot.count))
        }
        return filePath   // Outside project root — store absolute
    }
}

// MARK: - Persistence

extension C64Project {

    static let fileExtension = "c64proj"

    /// Loads a project from a `.c64proj` file URL.
    static func load(from url: URL) throws -> C64Project {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(C64Project.self, from: data)
    }

    /// Saves this project to a `.c64proj` file URL atomically.
    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }
}

