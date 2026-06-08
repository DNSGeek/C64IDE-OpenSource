import Foundation

/// Represents the type of C64 source file being edited.
public enum C64FileType: String, CaseIterable {
    case basic = "bas"
    case assembly = "asm"
    case assemblyS = "s"
    case text = "txt"

    /// Human-readable display name for the file type.
    public var displayName: String {
        switch self {
        case .basic: return "C64 BASIC"
        case .assembly, .assemblyS: return "6502 Assembly"
        case .text: return "Text"
        }
    }

    /// Returns `true` if the file type should use BASIC syntax highlighting.
    public var usesBasicHighlighting: Bool { self == .basic }

    /// Returns `true` if the file type should use 6502 assembly syntax highlighting.
    public var usesAssemblyHighlighting: Bool { self == .assembly || self == .assemblyS }

    /// Resolves a file extension to its corresponding `C64FileType`.
    public static func from(extension ext: String) -> C64FileType {
        C64FileType(rawValue: ext.lowercased()) ?? .text
    }
}

/// Represents a document open in the IDE.
public class C64Document {
    public var fileURL: URL?
    public var fileType: C64FileType
    public var content: String
    public var isModified: Bool = false
    public var customTitle: String?

    /// Computes the display title for the document. Falls back to the filename or a generic untitled name.
    public var displayTitle: String {
        if let custom = customTitle { return custom }
        if let url = fileURL {
            return url.lastPathComponent
        }
        return "Untitled.\(fileType.rawValue)"
    }

    /// Creates a new document with the specified type and initial content.
    public init(fileType: C64FileType = .basic, content: String = "") {
        self.fileType = fileType
        self.content = content
    }

    /// Loads a document from disk. Applies BASIC shortcut expansion for `.bas` files.
    public init(url: URL) throws {
        self.fileURL = url
        self.fileType = C64FileType.from(extension: url.pathExtension)

        // Read raw file contents.
        let raw = try String(contentsOf: url, encoding: .utf8)

        // For BASIC files, expand shortcut abbreviations (e.g. ? → PRINT)
        // so downstream components — highlighter, lexer, tokenizer, parser,
        // type analyser, renumber — only ever see canonical keywords. The
        // active dialect is passed so dialect-specific shortcuts (if any)
        // apply on top of the universal table.
        // Non-BASIC files (assembly, plain text) are stored verbatim.
        if self.fileType.usesBasicHighlighting {
            self.content = BasicShortcutExpander.expand(
                raw,
                dialect: BasicDialectManager.shared.activeDialect
            )
        } else {
            self.content = raw
        }
    }

    /// Saves the current document content to its backing file URL.
    public func save() throws {
        guard let url = fileURL else {
            throw C64DocumentError.noFileURL
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
        isModified = false
    }

    /// Saves the current document content to a new URL, updating the file reference.
    public func save(to url: URL) throws {
        self.fileURL = url
        self.fileType = C64FileType.from(extension: url.pathExtension)
        try save()
    }

    /// Re-reads the document's content from its backing file URL.
    /// Applies BASIC shortcut expansion for `.bas` files, exactly as the designated URL initialiser does.
    /// Clears `isModified` on success.
    public func reload() throws {
        guard let url = fileURL else {
            throw C64DocumentError.noFileURL
        }
        let raw = try String(contentsOf: url, encoding: .utf8)
        if fileType.usesBasicHighlighting {
            content = BasicShortcutExpander.expand(
                raw,
                dialect: BasicDialectManager.shared.activeDialect
            )
        } else {
            content = raw
        }
        isModified = false
    }
}

/// Errors that can occur during C64Document operations.
public enum C64DocumentError: Error, LocalizedError {
    case noFileURL

    public var errorDescription: String? {
        switch self {
        case .noFileURL: return "No file URL set. Use Save As first."
        }
    }
}

