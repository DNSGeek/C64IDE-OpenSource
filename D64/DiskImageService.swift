import Foundation

// ═══════════════════════════════════════════════════════════
// MARK: - DiskImageService
// ═══════════════════════════════════════════════════════════

/// Centralized service for all D64/D81 read and write operations.
///
/// Design principles:
/// - **Singleton**: Shared across the application; never instantiated directly.
/// - **Stateless**: All public methods load the image, perform work, and write back.
///   No in-memory state is retained between calls.
/// - **Serialized**: All operations route through a single `DispatchQueue` to prevent
///   concurrent writes to the same image file.
/// - **Throwing**: Returns typed `DiskImageError` values instead of booleans.
/// - **ASCII Boundary**: Callers pass plain ASCII filenames. PETSCII encoding and
///   uppercasing are handled internally.
///
/// ### Missing-Image Recovery
/// Throws `.imageNotFound(URL)` when a target file is absent. The UI layer
/// (`DiskImageUICoordinator`) handles recovery; this service remains AppKit-free.
///
/// ### Batch Operations
/// `performBatch` loads the image once, executes mutations in-memory, and flushes
/// to disk on success. Ideal for build pipelines that modify multiple files.
final class DiskImageService {

    // MARK: - Singleton

    static let shared = DiskImageService()
    private init() {}

    // MARK: - Serialization Queue

    /// Serializes all public operations. Provides the same thread-safety guarantee
    /// as an actor without requiring `async/await` in the synchronous AppKit codebase.
    private let queue = DispatchQueue(label: "com.c64ide.DiskImageService", qos: .userInitiated)

    // MARK: - Public API

    // ── Create ──────────────────────────────────────────────

    /// Creates a new, blank, formatted disk image and writes it to `url`.
    ///
    /// - Parameters:
    ///   - url:      Destination path.
    ///   - format:   Explicit disk format. Pass this whenever the caller's UI
    ///               lets the user choose a format, so a stale path extension
    ///               can never silently override the user's choice. When nil,
    ///               the format is derived from the URL's extension.
    ///   - diskName: CBM disk name (ASCII, max 16 chars). Silently truncated.
    ///   - diskID:   CBM disk ID (ASCII, max 2 chars). Silently truncated.
    /// - Throws: `.unsupportedFormat` if `format` is nil and the extension is
    ///           not recognised, or if an explicit `format` contradicts a
    ///           recognised extension (a mismatched file would confuse every
    ///           tool that trusts the extension, including this service).
    func createImage(at url: URL, format explicitFormat: DiskFormat? = nil,
                     diskName: String = "NEW DISK", diskID: String = "C6") throws {
        try queue.sync {
            let fmt: DiskFormat
            if let explicitFormat {
                // If the extension is recognised, it must agree with the
                // explicit format - otherwise loadImage() would later open
                // this file as the wrong type.
                if let extFormat = try? format(for: url), extFormat != explicitFormat {
                    throw DiskImageError.unsupportedFormat
                }
                fmt = explicitFormat
            } else {
                fmt = try format(for: url)
            }
            let image = makeBlankImage(format: fmt, diskName: diskName, diskID: diskID)
            try image.save(to: url)
        }
    }

    // ── Read ────────────────────────────────────────────────

    /// Returns all directory entries for the disk image at `url`.
    func directory(at url: URL) throws -> [CBMDirectoryEntry] {
        try queue.sync {
            let image = try loadImage(at: url)
            return image.readDirectory()
        }
    }

    /// Returns summary metadata for the disk image at `url`.
    func info(at url: URL) throws -> DiskInfo {
        try queue.sync {
            let image = try loadImage(at: url)
            return DiskInfo(
                diskName:   image.diskName,
                diskID:     image.diskID,
                dosType:    image.dosType,
                freeBlocks: image.freeBlocks,
                format:     try format(for: url)
            )
        }
    }

    /// Reads and returns the raw bytes of a file from the disk image.
    ///
    /// - Parameters:
    ///   - name: ASCII filename. Case-insensitive; matched after uppercasing.
    /// - Throws: `.imageNotFound`, `.fileNotFound`
    func readFile(named name: String, from url: URL) throws -> Data {
        try queue.sync {
            let image = try loadImage(at: url)
            let cbmName = try validatedCBMName(name)
            guard let entry = image.readDirectory().first(where: { $0.name == cbmName }) else {
                throw DiskImageError.fileNotFound
            }
            return image.extractPRG(entry)
        }
    }

    // ── Write ───────────────────────────────────────────────

    /// Adds or overwrites a file on the disk image.
    ///
    /// Matches C64 DOS behavior: if a file with the same CBM name exists, it is
    /// silently overwritten.
    ///
    /// - Parameters:
    ///   - name:     ASCII filename, max 16 characters.
    ///   - fileType: CBM file type byte. Defaults to `0x82` (closed PRG).
    ///   - data:     Raw file bytes. PRG files should include the 2-byte load address.
    ///   - url:      Target disk image.
    /// - Throws: `.imageNotFound`, `.filenameTooLong`, `.invalidPETSCII`, `.diskFull`
    func addFile(named name: String, type fileType: UInt8 = 0x82, data: Data, to url: URL) throws {
        try queue.sync {
            let image = try loadImage(at: url)
            let cbmName = try validatedCBMName(name)
            guard image.writeFile(name: cbmName, type: fileType, data: Array(data)) else {
                throw DiskImageError.diskFull
            }
            try image.save()
        }
    }

    /// Deletes a file from the disk image.
    ///
    /// - Throws: `.imageNotFound`, `.fileNotFound`
    func deleteFile(named name: String, from url: URL) throws {
        try queue.sync {
            let image = try loadImage(at: url)
            let cbmName = try validatedCBMName(name)
            guard let entry = image.readDirectory().first(where: { $0.name == cbmName }) else {
                throw DiskImageError.fileNotFound
            }
            image.deleteFile(entry)
            try image.save()
        }
    }

    /// Renames a file on the disk image.
    ///
    /// - Parameters:
    ///   - oldName: Current ASCII filename.
    ///   - newName: New ASCII filename, max 16 characters.
    /// - Throws: `.imageNotFound`, `.fileNotFound`, `.filenameTooLong`,
    ///           `.invalidPETSCII`, `.namingCollision`
    func renameFile(named oldName: String, to newName: String, on url: URL) throws {
        try queue.sync {
            let image = try loadImage(at: url)
            let cbmOld = try validatedCBMName(oldName)
            let cbmNew = try validatedCBMName(newName)

            let dir = image.readDirectory()
            if dir.contains(where: { $0.name == cbmNew }) {
                throw DiskImageError.namingCollision(cbmNew)
            }

            guard let entry = dir.first(where: { $0.name == cbmOld }) else {
                throw DiskImageError.fileNotFound
            }
            guard image.renameFile(entry, to: cbmNew) else {
                // Failsafe for edge-case collisions not caught by the directory scan
                throw DiskImageError.namingCollision(cbmNew)
            }
            try image.save()
        }
    }

    // ── Batch ───────────────────────────────────────────────

    /// Executes multiple mutations on a single disk image with one load and one save.
    ///
    /// The image is loaded before `body` executes and saved afterward if modified.
    /// If `body` throws, the image is **not** saved, preserving the on-disk state.
    ///
    /// - Parameters:
    ///   - url:  Target disk image.
    ///   - body: Closure receiving a `BatchContext`. Must not escape the context.
    func performBatch(on url: URL, body: (BatchContext) throws -> Void) throws {
        try queue.sync {
            let image = try loadImage(at: url)
            let ctx = BatchContext(image: image)
            try body(ctx)
            if image.isModified {
                try image.save()
            }
        }
    }

    // MARK: - BatchContext

    /// Scoped handle passed to `performBatch` callers.
    ///
    /// Provides the same mutating operations as `DiskImageService` but operates
    /// on an already-loaded in-memory image, eliminating redundant I/O.
    /// The context is only valid within the `performBatch` closure.
    final class BatchContext {

        private let image: any DiskImage

        fileprivate init(image: any DiskImage) {
            self.image = image
        }

        /// Adds or overwrites a file. See `DiskImageService.addFile` for details.
        func addFile(named name: String, type fileType: UInt8 = 0x82, data: Data) throws {
            let cbmName = try diskServiceValidatedCBMName(name)
            guard image.writeFile(name: cbmName, type: fileType, data: Array(data)) else {
                throw DiskImageError.diskFull
            }
        }

        /// Deletes a file. Throws `.fileNotFound` if the name is absent.
        func deleteFile(named name: String) throws {
            let cbmName = try diskServiceValidatedCBMName(name)
            guard let entry = image.readDirectory().first(where: { $0.name == cbmName }) else {
                throw DiskImageError.fileNotFound
            }
            image.deleteFile(entry)
        }

        /// Returns all directory entries.
        func directory() -> [CBMDirectoryEntry] {
            image.readDirectory()
        }
    }

    // MARK: - Private Helpers

    /// Forwards to the file-scope validation function so `BatchContext` can
    /// validate names without depending on `DiskImageService.shared`.
    func validatedCBMName(_ name: String) throws -> String {
        try diskServiceValidatedCBMName(name)
    }

    // ── Image Loading ────────────────────────────────────────

    /// Loads the image at `url`, throwing `.imageNotFound` if absent.
    private func loadImage(at url: URL) throws -> any DiskImage {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DiskImageError.imageNotFound(url)
        }
        switch try format(for: url) {
        case .d64: return try D64Image(contentsOf: url)
        case .d81: return try D81Image(contentsOf: url)
        }
    }

    /// Creates a blank formatted image of the given format.
    private func makeBlankImage(format: DiskFormat, diskName: String, diskID: String) -> any DiskImage {
        switch format {
        case .d64: return D64Image(diskName: diskName, diskID: diskID)
        case .d81: return D81Image(diskName: diskName, diskID: diskID)
        }
    }

    /// Derives `DiskFormat` from a URL's path extension.
    private func format(for url: URL) throws -> DiskFormat {
        switch url.pathExtension.lowercased() {
        case "d64": return .d64
        case "d81": return .d81
        default:    throw DiskImageError.unsupportedFormat
        }
    }

}

// ═══════════════════════════════════════════════════════════
// MARK: - PETSCII Validation (File-Scope)
// ═══════════════════════════════════════════════════════════

/// Maximum length of a CBM filename on disk.
private let cbmMaxNameLength = 16

/// Validates and normalizes an ASCII filename for C64 disk storage.
///
/// Validation rules (per CBM DOS):
/// - Empty names throw `.fileNotFound`.
/// - Names longer than 16 characters throw `.filenameTooLong`.
/// - Characters outside printable ASCII (0x20–0x7E) or the special DOS
///   delimiters `"` and `:` throw `.invalidPETSCII`.
///
/// Returns an uppercased string. Lowercased ASCII maps 1:1 to PETSCII
/// upper-case codepoints, so no additional encoding is required.
func diskServiceValidatedCBMName(_ name: String) throws -> String {
    guard !name.isEmpty else { throw DiskImageError.fileNotFound }

    let upper = name.uppercased()

    guard upper.count <= cbmMaxNameLength else {
        throw DiskImageError.filenameTooLong(name)
    }

    // Reject characters outside printable ASCII or DOS special delimiters
    let forbidden = CharacterSet(charactersIn: "\":")
    let printableASCII = CharacterSet(charactersIn: Unicode.Scalar(0x20)!...Unicode.Scalar(0x7E)!)
    let allowed = printableASCII.subtracting(forbidden)

    for scalar in upper.unicodeScalars {
        guard allowed.contains(scalar) else {
            throw DiskImageError.invalidPETSCII(name)
        }
    }

    return upper
}

