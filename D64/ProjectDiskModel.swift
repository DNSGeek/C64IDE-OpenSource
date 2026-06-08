import Foundation

// ═══════════════════════════════════════════════════════════
// MARK: - ProjectDiskConfig
// ═══════════════════════════════════════════════════════════

/// Declares the disk image(s) a project produces.
///
/// Added as an optional field on `C64Project` so that existing project files
/// load unchanged. A missing key decodes as `nil`, preserving the PRG-only
/// workflow for legacy projects.
///
/// Supports multi-disk projects from inception: the list may contain one entry
/// (common case) or many (flip sides, data disks, demo parts). The
/// `primaryDiskID` points to the disk mounted on drive 8 and booted first.
struct ProjectDiskConfig: Codable {

    /// Ordered list of disks this project produces.
    var disks: [ProjectDisk]

    /// UUID of the disk mounted on drive 8 and booted first.
    /// Must match one entry in `disks`. Defaults to the first disk's ID.
    var primaryDiskID: UUID

    // MARK: - Init

    init(disks: [ProjectDisk]) {
        precondition(!disks.isEmpty, "ProjectDiskConfig requires at least one disk")
        self.disks = disks
        self.primaryDiskID = disks[0].id
    }

    // MARK: - Helpers

    /// Returns the disk designated as the primary boot disk.
    var primaryDisk: ProjectDisk? {
        disks.first { $0.id == primaryDiskID }
    }

    /// Returns a disk by its stable UUID.
    func disk(withID id: UUID) -> ProjectDisk? {
        disks.first { $0.id == id }
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - ProjectDisk
// ═══════════════════════════════════════════════════════════

/// Represents a single disk image within a project configuration.
///
/// Identity is the `id` UUID, which survives filename or label changes,
/// ensuring cross-references (primary disk, build output target) remain valid.
struct ProjectDisk: Codable, Identifiable {

    // MARK: - Identity

    /// Stable identity. Never changes after creation.
    var id: UUID

    /// Human-readable label shown in the UI ("Boot Disk", "Data Disk", "Side B").
    var label: String

    // MARK: - On-disk File

    /// Filename of the disk image, relative to the project root.
    /// Typically located in the `build/` folder (e.g., "build/game.d81").
    var filename: String

    /// D64 or D81 format.
    var format: DiskFormat

    // MARK: - CBM Metadata

    /// CBM disk name written into the image header. Max 16 chars, ASCII.
    var cbmDiskName: String

    /// CBM disk ID written into the image header. Max 2 chars, ASCII.
    var cbmDiskID: String

    /// Drive number this disk is mounted on in the emulator (8–11).
    var driveNumber: Int

    // MARK: - Manifest

    /// Folders whose contents are automatically discovered and bundled.
    /// Paths are relative to the project root (e.g., "assets/sprites").
    var assetFolders: [String]

    /// Explicit file entries that override or supplement auto-discovered files.
    var explicitFiles: [DiskManifestEntry]

    /// Glob patterns for files to exclude from auto-discovery.
    /// Applied after folder expansion, before explicit entries.
    var excludes: [String]

    /// CBM name of the file that should be first on disk (for LOAD"*",8,1).
    /// `nil` means "first PRG added naturally" — matches C64 default behavior.
    var bootProgramName: String?

    /// Whether the emulator may write to this image at runtime.
    /// The Layer 1 reload-on-access invariant handles staleness from writes.
    var allowWrites: Bool

    // MARK: - Init

    init(
        label: String,
        filename: String,
        format: DiskFormat = .d81,
        cbmDiskName: String = "DISK",
        cbmDiskID: String = "C6",
        driveNumber: Int = 8,
        assetFolders: [String] = [],
        explicitFiles: [DiskManifestEntry] = [],
        excludes: [String] = [],
        bootProgramName: String? = nil,
        allowWrites: Bool = true
    ) {
        self.id             = UUID()
        self.label          = label
        self.filename       = filename
        self.format         = format
        self.cbmDiskName    = cbmDiskName
        self.cbmDiskID      = cbmDiskID
        self.driveNumber    = driveNumber
        self.assetFolders   = assetFolders
        self.explicitFiles  = explicitFiles
        self.excludes       = excludes
        self.bootProgramName = bootProgramName
        self.allowWrites    = allowWrites
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - DiskManifestEntry
// ═══════════════════════════════════════════════════════════

/// Represents an explicit file entry in a disk's manifest.
///
/// Used to override an auto-discovered entry (same `sourcePath`, different
/// `cbmName`) or to add a file from outside the declared asset folders.
struct DiskManifestEntry: Codable {

    /// Source file path, relative to the project root.
    var sourcePath: String

    /// CBM filename to use on disk. ASCII, max 16 chars.
    /// Auto-discovery naming rules apply if this is nil.
    var cbmName: String?

    /// CBM file type byte. Defaults to `0x82` (closed PRG).
    /// Use `0x81` for SEQ, `0x83` for USR.
    var fileType: UInt8

    init(sourcePath: String, cbmName: String? = nil, fileType: UInt8 = 0x82) {
        self.sourcePath = sourcePath
        self.cbmName    = cbmName
        self.fileType   = fileType
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - ProjectBuildDiskOutput
// ═══════════════════════════════════════════════════════════

/// Describes how the compiled main PRG is bundled onto a disk.
///
/// Stored inside `ProjectBuildOptions` as an optional field so existing
/// projects that don't use the disk pipeline are unaffected.
struct ProjectBuildDiskOutput: Codable {

    /// UUID of the `ProjectDisk` the compiled PRG should be written to.
    var targetDiskID: UUID

    /// CBM name to give the compiled PRG on disk. ASCII, max 16 chars.
    /// Defaults to the source filename uppercased and truncated.
    var outputCBMName: String

    init(targetDiskID: UUID, outputCBMName: String) {
        self.targetDiskID  = targetDiskID
        self.outputCBMName = outputCBMName
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - C64Project Extension & Integration Notes
// ═══════════════════════════════════════════════════════════

extension C64Project {

    // MARK: - Integration Notes

    // The following fields should be added to `C64Project` and `ProjectBuildOptions`
    // respectively to complete the disk pipeline integration. They are kept separate
    // here for review purposes but must be merged into their respective structs
    // before shipping.

    // C64Project.swift:
    //   var diskConfig: ProjectDiskConfig? = nil

    // ProjectBuildOptions.swift:
    //   var diskOutput: ProjectBuildDiskOutput? = nil
}

// ═══════════════════════════════════════════════════════════
// MARK: - ManifestResolver
// ═══════════════════════════════════════════════════════════

/// Resolves a `ProjectDisk` manifest into a flat, ordered list of files ready
/// for writing to a disk image.
///
/// This is a pure function wrapped in a struct with no I/O or side effects,
/// making it safe for unit testing. The build pipeline calls it once per disk
/// before opening a `DiskImageService.performBatch`.
///
/// Resolution steps:
/// 1. Walk `assetFolders`, generating one entry per file (skipping excluded patterns).
/// 2. Apply `explicitFiles` — override auto-discovered entries sharing a source path,
///    or add new entries from elsewhere.
/// 3. Inject `buildOutput` as an implicit entry on this disk (if provided).
/// 4. Detect CBM-name collisions and throw `.namingCollision`.
/// 5. Sort so that `bootProgramName` (if set) appears first.
struct ManifestResolver {

    // MARK: - Public API

    /// Resolves `disk`'s manifest into an ordered list of files to write.
    ///
    /// - Parameters:
    ///   - disk:        The `ProjectDisk` to resolve.
    ///   - projectRoot: The root URL of the project (used to resolve relative paths).
    ///   - buildOutput: Optional compiled PRG to inject (path + CBM name).
    ///                  Pass `nil` for disks that don't receive the build output.
    ///   - fileSystem:  Abstraction over filesystem enumeration. Defaults to `RealFileSystemEnumerator`.
    /// - Returns: Ordered `[ResolvedFile]` ready for `DiskImageService.performBatch`.
    /// - Throws: `DiskImageError.namingCollision` if two entries would land on
    ///           disk with the same CBM name.
    func resolve(
        disk: ProjectDisk,
        projectRoot: URL,
        buildOutput: ResolvedFile? = nil,
        fileSystem: FileSystemEnumerator = RealFileSystemEnumerator()
    ) throws -> [ResolvedFile] {

        // ── Step 1: Auto-discovery ───────────────────────────

        var resolved: [String: ResolvedFile] = [:]   // keyed by sourcePath

        for folder in disk.assetFolders {
            let folderURL = projectRoot.appendingPathComponent(folder)
            let files = fileSystem.filesInDirectory(folderURL)

            for fileURL in files {
                let sourcePath = Self.relativePath(for: fileURL, root: projectRoot)
                guard !isExcluded(sourcePath, patterns: disk.excludes) else { continue }

                let cbmName = try autoCBMName(for: fileURL)
                let entry = ResolvedFile(
                    sourceURL: fileURL,
                    cbmName:   cbmName,
                    fileType:  0x82
                )
                resolved[sourcePath] = entry
            }
        }

        // ── Step 2: Explicit overrides / additions ───────────

        for explicit in disk.explicitFiles {
            let sourceURL = projectRoot.appendingPathComponent(explicit.sourcePath)
            let cbmName: String

            if let override = explicit.cbmName {
                // Caller supplied a name — validate it.
                cbmName = try DiskImageService.shared.validatedCBMName(override)
            } else {
                // No override name — use auto-discovery rules.
                cbmName = try autoCBMName(for: sourceURL)
            }

            let entry = ResolvedFile(
                sourceURL: sourceURL,
                cbmName:   cbmName,
                fileType:  explicit.fileType
            )
            resolved[explicit.sourcePath] = entry
        }

        // ── Step 3: Build output injection ──────────────────

        var files = Array(resolved.values)
        if let output = buildOutput {
            // Remove any auto-discovered or explicit entry that has the same
            // CBM name as the build output (the build output wins).
            files.removeAll { $0.cbmName == output.cbmName }
            files.append(output)
        }

        // ── Step 4: Collision detection ──────────────────────

        var seen: [String: URL] = [:]
        for file in files {
            if let existing = seen[file.cbmName] {
                // Two different source files map to the same CBM name.
                if existing != file.sourceURL {
                    throw DiskImageError.namingCollision(file.cbmName)
                }
            }
            seen[file.cbmName] = file.sourceURL
        }

        // ── Step 5: Boot program first ───────────────────────

        if let boot = disk.bootProgramName?.uppercased(),
           let bootIdx = files.firstIndex(where: { $0.cbmName == boot }) {
            let bootFile = files.remove(at: bootIdx)
            files.insert(bootFile, at: 0)
        }
        return files
    }

    // MARK: - Private Helpers

    /// Derives a CBM filename from a host filesystem URL.
    ///
    /// Rules: strip extension → uppercase → truncate to 16 chars →
    /// replace non-PETSCII-printable characters with `.`.
    /// Throws `.invalidPETSCII` only if the result is empty after substitution
    /// (unlikely for real filesystem paths, but guarded for correctness).
    private func autoCBMName(for url: URL) throws -> String {
        let stem = url.deletingPathExtension().lastPathComponent

        // Uppercase first — lowercased ASCII maps 1:1 to PETSCII upper-case.
        var upper = stem.uppercased()

        // Truncate to 16 characters.
        if upper.count > 16 {
            upper = String(upper.prefix(16))
        }

        // Replace characters outside printable PETSCII (0x20–0x7E, excl. " and :).
        let allowed = CharacterSet(charactersIn: Unicode.Scalar(0x20)!...Unicode.Scalar(0x7E)!)
            .subtracting(CharacterSet(charactersIn: "\":"))

        upper = upper.unicodeScalars.map { allowed.contains($0) ? String($0) : "." }.joined()

        guard !upper.isEmpty else {
            throw DiskImageError.invalidPETSCII(url.lastPathComponent)
        }

        return upper
    }

    /// Returns true if `path` matches any of the glob patterns in `patterns`.
    ///
    /// Supports `*` (any characters except `/`) and `**` (any characters including `/`).
    /// Does not support full POSIX glob features (e.g., character classes, ranges).
    private func isExcluded(_ path: String, patterns: [String]) -> Bool {
        patterns.contains { glob($0, matches: path) }
    }

    /// Minimal glob-to-regex converter.
    private func glob(_ pattern: String, matches path: String) -> Bool {
        // Convert glob to a regex: escape `.`, replace `**` then `*`.
        var regex = NSRegularExpression.escapedPattern(for: pattern)
        regex = regex.replacingOccurrences(of: "\\*\\*", with: ".*")
        regex = regex.replacingOccurrences(of: "\\*",    with: "[^/]*")
        regex = "^" + regex + "$"
        return (try? NSRegularExpression(pattern: regex))
            .map { $0.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil }
            ?? false
    }

    /// Makes a path relative to `root`, or returns the absolute path if outside.
    private static func relativePath(for url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        if filePath.hasPrefix(rootPath + "/") {
            return String(filePath.dropFirst(rootPath.count + 1))
        }
        return filePath
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - ResolvedFile
// ═══════════════════════════════════════════════════════════

/// A single file that has been resolved and is ready to write to a disk image.
struct ResolvedFile {
    /// Absolute URL of the source file on the host filesystem.
    let sourceURL: URL
    /// CBM filename to use on disk (already uppercased and validated).
    let cbmName: String
    /// CBM file type byte (e.g., 0x82 = closed PRG).
    let fileType: UInt8
}

// ═══════════════════════════════════════════════════════════
// MARK: - FileSystemEnumerator Protocol
// ═══════════════════════════════════════════════════════════

/// Abstracts filesystem enumeration so `ManifestResolver` can be tested
/// without touching a real disk.
protocol FileSystemEnumerator {
    /// Returns all regular files directly or recursively under `directory`.
    /// Returns an empty array if the directory does not exist.
    func filesInDirectory(_ directory: URL) -> [URL]
}

/// Production implementation — wraps `FileManager`.
struct RealFileSystemEnumerator: FileSystemEnumerator {
    func filesInDirectory(_ directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        return enumerator.compactMap { item -> URL? in
            guard let url = item as? URL,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true
            else { return nil }
            return url
        }
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - ProjectDiskConfig Validation
// ═══════════════════════════════════════════════════════════

extension ProjectDiskConfig {

    /// Errors surfaced at project-settings save time (not at build time).
    enum ValidationError: Error, LocalizedError {
        case noPrimaryDisk(UUID)
        case duplicateDriveNumber(Int)
        case overlappingAssetFolders(String, String, String)   // folder, disk A label, disk B label
        case invalidDriveNumber(Int, diskLabel: String)

        var errorDescription: String? {
            switch self {
            case .noPrimaryDisk(let id):
                return "Primary disk ID \(id) does not match any disk in this project"
            case .duplicateDriveNumber(let n):
                return "Two disks are assigned to drive \(n) — each disk must use a different drive number"
            case .overlappingAssetFolders(let folder, let a, let b):
                return "Asset folder \"\(folder)\" is claimed by both \"\(a)\" and \"\(b)\" — each folder must belong to exactly one disk"
            case .invalidDriveNumber(let n, let label):
                return "Drive number \(n) on \"\(label)\" is out of range — must be 8–11"
            }
        }
    }

    /// Validates the configuration and returns all detected errors.
    ///
    /// Call on project-settings save to collect all errors so the UI can
    /// display them at once rather than one at a time.
    func validate() -> [ValidationError] {
        var errors: [ValidationError] = []

        // Primary disk must exist.
        if !disks.contains(where: { $0.id == primaryDiskID }) {
            errors.append(.noPrimaryDisk(primaryDiskID))
        }

        // Drive numbers must be unique and in range.
        var seenDrives: [Int: String] = [:]
        for disk in disks {
            if disk.driveNumber < 8 || disk.driveNumber > 11 {
                errors.append(.invalidDriveNumber(disk.driveNumber, diskLabel: disk.label))
            } else if let existing = seenDrives[disk.driveNumber] {
                _ = existing   // Used in error generation
                errors.append(.duplicateDriveNumber(disk.driveNumber))
            } else {
                seenDrives[disk.driveNumber] = disk.label
            }
        }

        // Asset folders must not overlap across disks.
        var seenFolders: [String: String] = [:]   // folder → disk label
        for disk in disks {
            for folder in disk.assetFolders {
                let normalised = folder.hasSuffix("/") ? folder : folder + "/"
                if let owner = seenFolders[normalised] {
                    errors.append(.overlappingAssetFolders(folder, owner, disk.label))
                } else {
                    seenFolders[normalised] = disk.label
                }
            }
        }

        return errors
    }
}

