import Foundation

// MARK: - IDE Context Protocol
//
// ClaudeIDEContext captures a snapshot of the current IDE state to send
// to Claude as part of each request. It is designed to be extended over
// time without requiring changes to the API service or chat UI:
//
//   Phase 2 (current): file name, file type, selected text, build errors
//   Phase 3 (future):  debugger state, registers, memory map, breakpoints
//
// To add new context, extend the struct and update systemPromptFragment().

struct ClaudeIDEContext {

    // MARK: - Phase 2: Editor Context

    /// File name of the currently active document, e.g. "main.asm"
    let activeFileName: String?

    /// The file type of the active document
    let activeFileType: C64FileType?

    /// The full content of the active document (may be nil if no file is open)
    let activeFileContent: String?

    /// Currently selected text in the editor, if any
    let selectedText: String?

    /// Current build errors and warnings from the last build
    let buildErrors: [String]

    /// Active BASIC dialect name (e.g. "BASIC 7", "MEGA65 BASIC 65", "Simons' BASIC").
    /// nil means standard Commodore BASIC V2.
    let basicDialect: String?

    // MARK: - Phase 3: Debugger Context (future)
    // Uncomment and populate when debugger integration is added:
    //
    // let programCounter: UInt16?
    // let registers: C64Registers?
    // let memoryMap: C64MemoryMap?
    // let breakpoints: [UInt16]
    // let isDebugging: Bool

    // MARK: - Init

    init(
        activeFileName: String? = nil,
        activeFileType: C64FileType? = nil,
        activeFileContent: String? = nil,
        selectedText: String? = nil,
        buildErrors: [String] = [],
        basicDialect: String? = nil
    ) {
        self.activeFileName  = activeFileName
        self.activeFileType  = activeFileType
        self.activeFileContent = activeFileContent
        self.selectedText    = selectedText
        self.buildErrors     = buildErrors
        self.basicDialect    = basicDialect
    }

    /// An empty context — used when no document is open.
    static let empty = ClaudeIDEContext()

    // MARK: - System Prompt Fragment

    /// Generates the context block appended to the system prompt.
    /// Returns nil if there is nothing meaningful to report.
    /// Content is safely truncated to prevent exceeding token limits while
    /// preserving the structure needed for AI context awareness.
    func systemPromptFragment() -> String? {
        var lines: [String] = []

        let dialectLabel = basicDialect ?? "Commodore BASIC V2"
        lines.append("Active BASIC dialect: \(dialectLabel)")

        if let name = activeFileName, let type = activeFileType {
            lines.append("Active file: \(name) (\(type.displayName))")
        }

        if let selected = selectedText, !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let trimmed = selected.trimmingCharacters(in: .whitespacesAndNewlines)
            let preview = trimmed.count > 2000 ? String(trimmed.prefix(2000)) + "\n[... truncated ...]" : trimmed
            lines.append("Selected text:\n```\n\(preview)\n```")
        } else if let content = activeFileContent, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Only include file content if nothing is selected
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            let preview = trimmed.count > 4000 ? String(trimmed.prefix(4000)) + "\n[... truncated ...]" : trimmed
            lines.append("Active file content:\n```\n\(preview)\n```")
        }

        if !buildErrors.isEmpty {
            lines.append("Recent build errors/warnings:\n" + buildErrors.map { "  • \($0)" }.joined(separator: "\n"))
        }

        return lines.isEmpty ? nil : lines.joined(separator: "\n\n")
    }
}

// MARK: - Context Provider Protocol
//
// MainWindowController adopts this so ClaudeTabController can request
// a fresh context snapshot on each send without holding a strong reference
// to the window, preventing retain cycles.

protocol ClaudeIDEContextProvider: AnyObject {
    func currentIDEContext() -> ClaudeIDEContext
}

