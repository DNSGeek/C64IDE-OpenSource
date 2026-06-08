import Foundation

// MARK: - Build Diagnostic

/// A single error or warning from the build process
struct BuildDiagnostic {
    enum Severity {
        case error
        case warning
        case info
    }

    let severity: Severity
    let file: String?
    let line: Int?
    let column: Int?
    let message: String
    let rawLine: String  // Original output line

    var displayString: String {
        var parts: [String] = []

        switch severity {
        case .error:   parts.append("ERROR")
        case .warning: parts.append("WARN")
        case .info:    parts.append("INFO")
        }

        if let file = file {
            let filename = (file as NSString).lastPathComponent
            if let line = line {
                parts.append("\(filename):\(line)")
            } else {
                parts.append(filename)
            }
        }

        parts.append(message)

        return parts.joined(separator: ": ")
    }
}

// MARK: - Build Error Parser

/// Parses ca65 and ld65 output into structured diagnostics
struct BuildErrorParser {

    /// Parse ca65 assembler output
    /// Format: "filename(line): Error: message"
    /// Format: "filename(line): Warning: message"
    static func parseCa65Output(_ output: String) -> [BuildDiagnostic] {
        var diagnostics: [BuildDiagnostic] = []

        for rawLine in output.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // ca65 format: "filename(line): Error: message"
            //           or: "filename(line): Warning: message"
            if let diagnostic = parseCa65Line(trimmed) {
                diagnostics.append(diagnostic)
            } else if trimmed.lowercased().contains("error") || trimmed.lowercased().contains("warning") {
                // Catch any unparsed error/warning lines
                let severity: BuildDiagnostic.Severity = trimmed.lowercased().contains("error") ? .error : .warning
                diagnostics.append(BuildDiagnostic(
                    severity: severity, file: nil, line: nil, column: nil,
                    message: trimmed, rawLine: rawLine
                ))
            }
        }

        return diagnostics
    }

    /// Parse ld65 linker output
    /// Format varies: "ld65: Error: ..." or "ld65: Warning: ..."
    static func parseLd65Output(_ output: String) -> [BuildDiagnostic] {
        var diagnostics: [BuildDiagnostic] = []

        for rawLine in output.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            if trimmed.hasPrefix("ld65:") {
                let rest = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                let severity: BuildDiagnostic.Severity
                let message: String

                if rest.hasPrefix("Error:") {
                    severity = .error
                    message = String(rest.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                } else if rest.hasPrefix("Warning:") {
                    severity = .warning
                    message = String(rest.dropFirst(8)).trimmingCharacters(in: .whitespaces)
                } else {
                    severity = .info
                    message = rest
                }

                diagnostics.append(BuildDiagnostic(
                    severity: severity, file: nil, line: nil, column: nil,
                    message: message, rawLine: rawLine
                ))
            }
        }

        return diagnostics
    }

    // MARK: - Private Helpers

    /// Parse a single ca65 output line
    /// Expected format: "path/to/file.s(42): Error: Some message"
    private static func parseCa65Line(_ line: String) -> BuildDiagnostic? {
        // Match: filename(linenum): Severity: message
        // Regex pattern: ^(.+?)\((\d+)\):\s*(Error|Warning):\s*(.+)$

        guard let parenOpen = line.firstIndex(of: "("),
              let parenClose = line[parenOpen...].firstIndex(of: ")") else {
            return nil
        }

        let file = String(line[line.startIndex..<parenOpen])
        let lineNumStr = String(line[line.index(after: parenOpen)..<parenClose])
        guard let lineNum = Int(lineNumStr) else { return nil }

        let afterParen = line[line.index(after: parenClose)...]
        guard afterParen.hasPrefix(":") else { return nil }

        let rest = afterParen.dropFirst().trimmingCharacters(in: .whitespaces)

        let severity: BuildDiagnostic.Severity
        let message: String

        if rest.hasPrefix("Error:") {
            severity = .error
            message = String(rest.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        } else if rest.hasPrefix("Warning:") {
            severity = .warning
            message = String(rest.dropFirst(8)).trimmingCharacters(in: .whitespaces)
        } else {
            severity = .info
            message = rest
        }

        return BuildDiagnostic(
            severity: severity, file: file, line: lineNum, column: nil,
            message: message, rawLine: line
        )
    }
}
