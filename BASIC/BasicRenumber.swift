import Cocoa

// MARK: - BasicLine

/// Represents a single line of BASIC source code with its metadata.
public struct BasicLine {
    /// The line number (e.g., 10, 20).
    public let lineNumber: Int
    /// The content of the line (everything after the line number).
    public let content: String
    /// The original raw text of the line.
    public let rawText: String
    /// The range of this line in the original source text.
    public let range: NSRange
}

// MARK: - Renumber Engine

/// Provides functionality to renumber BASIC lines and update their references.
public class BasicRenumber {

    /// Keywords in C64 BASIC that are typically followed by a line number target.
    /// Note: This list is heuristic. `THEN` can be followed by a statement, not just a number.
    private static let lineRefKeywords = ["GOTO", "GOSUB", "THEN", "RUN", "RESTORE", "LIST"]

    // MARK: - Parse Lines

    /// Parses raw source text into an array of `BasicLine` structs.
    ///
    /// - Parameter source: The full BASIC source code string.
    /// - Returns: An array of parsed lines, preserving their original order.
    public static func parseLines(_ source: String) -> [BasicLine] {
        var lines: [BasicLine] = []
        _ = source as NSString
        var searchStart = 0

        for rawLine in source.components(separatedBy: "\n") {
            let lineRange = NSRange(location: searchStart, length: (rawLine as NSString).length)
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if !trimmed.isEmpty {
                // Extract line number
                var numStr = ""
                var idx = trimmed.startIndex
                while idx < trimmed.endIndex && trimmed[idx].isNumber {
                    numStr.append(trimmed[idx])
                    idx = trimmed.index(after: idx)
                }

                if let lineNum = Int(numStr) {
                    // Skip whitespace after number
                    while idx < trimmed.endIndex && trimmed[idx] == " " {
                        idx = trimmed.index(after: idx)
                    }
                    let content = String(trimmed[idx...])
                    lines.append(BasicLine(lineNumber: lineNum, content: content, rawText: rawLine, range: lineRange))
                }
            }

            searchStart += (rawLine as NSString).length + 1  // +1 for newline
        }

        return lines
    }

    // MARK: - Full Renumber

    /// Renumbers all lines in the source code.
    ///
    /// - Parameters:
    ///   - source: The full BASIC source code.
    ///   - startLine: The starting line number for the renumbering sequence.
    ///   - step: The increment between line numbers.
    /// - Returns: A `RenumberResult` containing the new source and any errors.
    public static func renumberAll(source: String, startLine: Int = 10, step: Int = 10) -> RenumberResult {
        let lines = parseLines(source)
        guard !lines.isEmpty else { return RenumberResult(newSource: source, changeCount: 0, errors: []) }

        // Build old→new line number mapping
        var mapping: [Int: Int] = [:]
        var newNum = startLine
        for line in lines {
            mapping[line.lineNumber] = newNum
            newNum += step
        }

        return applyRenumber(source: source, lines: lines, mapping: mapping)
    }

    // MARK: - Selection Renumber

    /// Renumbers only the lines that overlap with a specific text selection.
    ///
    /// - Parameters:
    ///   - source: The full BASIC source code.
    ///   - selectedRange: The range of text selected by the user.
    ///   - startLine: The starting line number for the renumbering sequence.
    ///   - step: The increment between line numbers.
    /// - Returns: A `RenumberResult` containing the new source and any errors.
    public static func renumberSelection(
        source: String,
        selectedRange: NSRange,
        startLine: Int = 10,
        step: Int = 10
    ) -> RenumberResult {
        let allLines = parseLines(source)
        guard !allLines.isEmpty else { return RenumberResult(newSource: source, changeCount: 0, errors: []) }

        // Find lines that overlap the selection
        var selectedIndices: [Int] = []
        for (i, line) in allLines.enumerated() {
            if NSIntersectionRange(line.range, selectedRange).length > 0 {
                selectedIndices.append(i)
            }
        }

        guard !selectedIndices.isEmpty else {
            return RenumberResult(newSource: source, changeCount: 0, errors: ["No BASIC lines in selection"])
        }

        let firstIdx = selectedIndices.first!
        let lastIdx = selectedIndices.last!

        // Boundary check: what line numbers are before and after the selection?
        let lowerBound = firstIdx > 0 ? allLines[firstIdx - 1].lineNumber : 0
        let upperBound = lastIdx < allLines.count - 1 ? allLines[lastIdx + 1].lineNumber : 64000

        // Check if the new numbering fits
        let needed = selectedIndices.count
        let lastNewNum = startLine + (needed - 1) * step

        var errors: [String] = []
        if startLine <= lowerBound {
            errors.append("Start line \(startLine) must be greater than preceding line \(lowerBound)")
        }
        if lastNewNum >= upperBound {
            errors.append("Last renumbered line \(lastNewNum) would overlap with following line \(upperBound)")
        }

        if !errors.isEmpty {
            return RenumberResult(newSource: source, changeCount: 0, errors: errors)
        }

        // Build mapping for selected lines only
        var mapping: [Int: Int] = [:]
        var newNum = startLine
        for i in selectedIndices {
            mapping[allLines[i].lineNumber] = newNum
            newNum += step
        }

        return applyRenumber(source: source, lines: allLines, mapping: mapping)
    }

    // MARK: - Apply Renumber

    /// Applies a line number mapping to the source, updating all references.
    private static func applyRenumber(source: String, lines: [BasicLine], mapping: [Int: Int]) -> RenumberResult {
        var changeCount = 0
        var newLines: [String] = []

        for line in lines {
            let newNum = mapping[line.lineNumber] ?? line.lineNumber

            // Update line references in the content
            let updatedContent = updateLineReferences(in: line.content, mapping: mapping)

            if newNum != line.lineNumber || updatedContent != line.content {
                changeCount += 1
            }

            newLines.append("\(newNum) \(updatedContent)")
        }

        let newSource = newLines.joined(separator: "\n")
        return RenumberResult(newSource: newSource, changeCount: changeCount, errors: [])
    }

    /// Updates line number references in a line's content based on the mapping.
    ///
    /// This method uses a heuristic approach: it scans for keywords known to be
    /// followed by line numbers (e.g., `GOTO`, `THEN`) and replaces any integer
    /// found immediately after them.
    ///
    /// **Limitations:**
    /// - Does not protect line numbers inside string literals (e.g., `PRINT "10"`).
    /// - `THEN` handling assumes a number immediately following it is a line target.
    private static func updateLineReferences(in content: String, mapping: [Int: Int]) -> String {
        var replacements: [(startIndex: Int, length: Int, replacement: String)] = []
        let upper = content.uppercased()

        // Find each keyword that references line numbers
        for keyword in lineRefKeywords {
            var searchFrom = upper.startIndex

            while let range = upper[searchFrom...].range(of: keyword) {
                var afterKeyword = range.upperBound

                // Skip whitespace after keyword
                while afterKeyword < upper.endIndex && upper[afterKeyword] == " " {
                    afterKeyword = upper.index(after: afterKeyword)
                }

                // Read the line number(s) — could be comma-separated (ON...GOTO)
                let numbersStart = afterKeyword
                var pos = afterKeyword
                var newNumbers: [String] = []
                var foundNumber = false

                while pos < upper.endIndex {
                    // Read a number
                    var numStart = pos
                    // Skip spaces
                    while numStart < upper.endIndex && upper[numStart] == " " {
                        numStart = upper.index(after: numStart)
                    }

                    var numEnd = numStart
                    while numEnd < upper.endIndex && upper[numEnd].isNumber {
                        numEnd = upper.index(after: numEnd)
                    }

                    if numEnd > numStart {
                        let numStr = String(upper[numStart..<numEnd])
                        if let oldNum = Int(numStr), let newNum = mapping[oldNum] {
                            newNumbers.append(String(newNum))
                            foundNumber = true
                        } else {
                            newNumbers.append(String(content[numStart..<numEnd]))
                            foundNumber = true
                        }

                        pos = numEnd
                        // Skip spaces and check for comma (ON...GOTO list)
                        while pos < upper.endIndex && upper[pos] == " " {
                            pos = upper.index(after: pos)
                        }
                        if pos < upper.endIndex && upper[pos] == "," {
                            pos = upper.index(after: pos)
                            continue
                        }
                    }
                    break
                }

                if foundNumber {
                    let numbersEnd = pos
                    let contentOffset = content.distance(from: content.startIndex, to: numbersStart)
                    let contentLength = content.distance(from: numbersStart, to: numbersEnd)
                    
                    // Store replacement info (using indices in original content)
                    replacements.append((startIndex: contentOffset, length: contentLength, replacement: newNumbers.joined(separator: ",")))
                }

                // Move search past this match
                searchFrom = range.upperBound
                if searchFrom >= upper.endIndex { break }
            }
        }

        // Apply replacements in reverse order to preserve indices
        var result = content
        for replacement in replacements.reversed() {
            let lowerBound = result.index(result.startIndex, offsetBy: replacement.startIndex)
            let upperBound = result.index(result.startIndex, offsetBy: replacement.startIndex + replacement.length)
            let range = lowerBound..<upperBound
            result.replaceSubrange(range, with: replacement.replacement)
        }

        return result
    }

    // MARK: - Auto-Number

    /// Calculates the next logical line number after a given line.
    ///
    /// - Parameters:
    ///   - currentLine: The line number of the current line.
    ///   - nextLine: The line number of the next line in the source (optional).
    ///   - defaultStep: The default step to use if `nextLine` is not provided or too close.
    /// - Returns: The suggested next line number, or `nil` if no space exists.
    public static func nextLineNumber(after currentLine: Int, beforeLine nextLine: Int?, defaultStep: Int = 10) -> Int? {
        let proposed = currentLine + defaultStep

        if let next = nextLine {
            if proposed < next {
                return proposed
            }
            // Try to fit between current and next
            let gap = next - currentLine
            if gap > 1 {
                return currentLine + gap / 2
            }
            return nil  // No room
        }

        return proposed
    }

    // MARK: - Auto-Arrange

    /// Describes what (if anything) should happen to a just-committed line
    /// to keep the source in line-number order.
    public enum AutoArrangeAction: Equatable {
        /// Line is unique and already in sorted position.
        case none
        /// Line is out of order. `targetOffset` is the character offset (in
        /// the source as passed in) at which the line, trailing newline
        /// included, should be re-inserted. Always a line boundary, except
        /// the append-after-last-line case, where it may point one past a
        /// final line that has no trailing newline. Callers must clamp to
        /// the text length and re-adjust after deleting the original line.
        case move(targetOffset: Int)
        /// Another line already has this number. `existingLineStart` is that
        /// line's `range.location`.
        case duplicate(existingLineStart: Int)
    }

    /// Classifies the numbered line starting at `lineStart`.
    ///
    /// Assumes the rest of the file is sorted, which holds when this runs on
    /// every line commit: only the just-committed line can be out of place.
    /// For a globally unsorted file the move target is a best-effort
    /// heuristic (the first line with a greater number); a full Renumber
    /// remains the real fix in that situation.
    ///
    /// - Parameters:
    ///   - source: The full BASIC source text.
    ///   - lineStart: Character offset of the start of the committed line.
    /// - Returns: The action to take, or `nil` if no numbered line starts at
    ///   `lineStart` (blank and unnumbered lines are never arranged).
    public static func autoArrangeAction(source: String, lineStart: Int) -> AutoArrangeAction? {
        let lines = parseLines(source)
        guard let idx = lines.firstIndex(where: { $0.range.location == lineStart }) else {
            return nil
        }
        let line = lines[idx]

        // Duplicate beats out-of-order: the collision has to be resolved
        // before a "sorted position" even means anything.
        if let dup = lines.first(where: {
            $0.lineNumber == line.lineNumber && $0.range.location != lineStart
        }) {
            return .duplicate(existingLineStart: dup.range.location)
        }

        let prevOK = idx == 0 || lines[idx - 1].lineNumber < line.lineNumber
        let nextOK = idx == lines.count - 1 || lines[idx + 1].lineNumber > line.lineNumber
        // Qualified: the return type is Optional, so a bare `.none` would
        // infer as Optional.none (nil), not the enum case we mean.
        if prevOK && nextOK { return AutoArrangeAction.none }

        // Insert before the first line carrying a greater number...
        if let target = lines.first(where: {
            $0.lineNumber > line.lineNumber && $0.range.location != lineStart
        }) {
            return .move(targetOffset: target.range.location)
        }

        // ...or after the last other line when every other number is smaller.
        guard let last = lines.last(where: { $0.range.location != lineStart }) else {
            return AutoArrangeAction.none  // Only line in the file: trivially in order.
        }
        // +1 steps past that line's trailing newline; the caller clamps when
        // the file ends without one.
        return .move(targetOffset: NSMaxRange(last.range) + 1)
    }

    /// Gets the line number at a given character position in the source.
    ///
    /// - Parameters:
    ///   - position: The character index in the source string.
    ///   - source: The full source string.
    /// - Returns: A tuple containing the line number and a boolean indicating if the position is at the end of the line.
    public static func lineNumberAt(position: Int, in source: String) -> (lineNumber: Int, isEndOfLine: Bool)? {
        let lines = parseLines(source)
        for line in lines {
            let lineEnd = line.range.location + line.range.length
            if position >= line.range.location && position <= lineEnd {
                return (line.lineNumber, position >= lineEnd - 1)
            }
        }
        return nil
    }
}

// MARK: - Renumber Result

/// The result of a renumbering operation.
public struct RenumberResult {
    /// The new source code with renumbered lines.
    public let newSource: String
    /// The number of lines that were modified.
    public let changeCount: Int
    /// Any errors that occurred during the operation.
    public let errors: [String]

    /// Returns true if the operation was successful and made changes.
    public var success: Bool { errors.isEmpty && changeCount > 0 }
}

// MARK: - Renumber Dialog

/// A macOS UI helper to display the renumbering dialog.
///
/// Note: This class is tightly coupled to `NSTextView` and `NSAlert`.
/// For a library, it is recommended to extract the logic into a separate
/// service or use a more generic configuration struct.
public class RenumberDialog {

    /// Shows the renumber dialog and applies the result to the text view.
    ///
    /// - Parameters:
    ///   - textView: The `NSTextView` containing the BASIC code.
    ///   - hasSelection: Whether the user has a text selection.
    ///   - completion: A closure called with the `RenumberResult` (or `nil` if cancelled).
    public static func show(for textView: NSTextView, hasSelection: Bool, completion: @escaping (RenumberResult?) -> Void) {
        let alert = NSAlert()
        alert.messageText = hasSelection ? "Renumber Selected Lines" : "Renumber All Lines"
        alert.informativeText = "Enter the starting line number and step increment.\nAll GOTO, GOSUB, THEN, etc. references will be updated."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Renumber")
        alert.addButton(withTitle: "Cancel")

        // Accessory view with start/step fields using NSStackView for modern layout
        let accessory = NSStackView()
        accessory.orientation = .vertical
        accessory.spacing = 8
        accessory.alignment = .leading
        accessory.translatesAutoresizingMaskIntoConstraints = false

        // Row 1: Start
        let startRow = NSStackView()
        startRow.alignment = .centerY
        startRow.translatesAutoresizingMaskIntoConstraints = false
        
        let startLabel = NSTextField(labelWithString: "Start:")
        startLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        startLabel.translatesAutoresizingMaskIntoConstraints = false
        
        let startField = NSTextField(string: "10")
        startField.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        startField.translatesAutoresizingMaskIntoConstraints = false
        startField.isBezeled = true
        
        startRow.addArrangedSubview(startLabel)
        startRow.addArrangedSubview(startField)

        // Row 2: Step
        let stepRow = NSStackView()
        stepRow.alignment = .centerY
        stepRow.translatesAutoresizingMaskIntoConstraints = false
        
        let stepLabel = NSTextField(labelWithString: "Step:")
        stepLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        stepLabel.translatesAutoresizingMaskIntoConstraints = false
        
        let stepField = NSTextField(string: "10")
        stepField.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        stepField.translatesAutoresizingMaskIntoConstraints = false
        stepField.isBezeled = true
        
        stepRow.addArrangedSubview(stepLabel)
        stepRow.addArrangedSubview(stepField)

        accessory.addArrangedSubview(startRow)
        accessory.addArrangedSubview(stepRow)

        if hasSelection {
            let note = NSTextField(labelWithString: "Only selected lines will be renumbered.")
            note.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
            note.textColor = .secondaryLabelColor
            note.translatesAutoresizingMaskIntoConstraints = false
            accessory.addArrangedSubview(note)
        }

        alert.accessoryView = accessory

        guard let window = textView.window else {
            completion(nil)
            return
        }

        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else {
                completion(nil)
                return
            }

            let start = Int(startField.stringValue) ?? 10
            let step = Int(stepField.stringValue) ?? 10

            guard start > 0, start <= 63999, step > 0 else {
                let errAlert = NSAlert()
                errAlert.messageText = "Invalid Values"
                errAlert.informativeText = "Start must be 1-63999 and step must be positive."
                errAlert.runModal()
                completion(nil)
                return
            }

            let source = textView.string
            let result: RenumberResult

            if hasSelection {
                result = BasicRenumber.renumberSelection(
                    source: source,
                    selectedRange: textView.selectedRange(),
                    startLine: start,
                    step: step
                )
            } else {
                result = BasicRenumber.renumberAll(
                    source: source,
                    startLine: start,
                    step: step
                )
            }

            if !result.errors.isEmpty {
                let errAlert = NSAlert()
                errAlert.messageText = "Cannot Renumber"
                errAlert.informativeText = result.errors.joined(separator: "\n")
                errAlert.alertStyle = .warning
                errAlert.runModal()
                completion(nil)
                return
            }

            completion(result)
        }
    }
}

