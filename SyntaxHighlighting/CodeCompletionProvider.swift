// MARK: - CodeCompletionProvider.swift
//
// Offline, deterministic completion candidates for the source editor.
// BASIC files get the active dialect's keywords, the variables already used
// in the file and, after GOTO / GOSUB / THEN, the file's line numbers.
// Assembly files get 6502 mnemonics, ca65 directives, labels and symbols
// defined in the file, and the C64 ROM symbol names. Everything here is a
// pure function of (source, cursor, file type, dialect, known variables),
// so the editor can call it on every keystroke and the tests can pin the
// behaviour down without a text view.

import Foundation

/// One entry in the completion list.
struct CodeCompletion: Equatable {
    enum Kind: String {
        case keyword, function, variable, lineNumber
        case mnemonic, directive, label, macro, symbol
    }

    /// The text that replaces the partial word when the entry is accepted.
    let text: String
    let kind: Kind
    /// One line shown beside the entry: a syntax summary, a label's
    /// definition, a ROM address. Not every source has one.
    let detail: String?

    init(_ text: String, _ kind: Kind, detail: String? = nil) {
        self.text = text
        self.kind = kind
        self.detail = detail
    }
}

struct CodeCompletionProvider {

    /// A variable already used in the file, as the variable scanner reports
    /// it (name as written, `$` / `%` suffix included).
    struct Variable: Equatable {
        let name: String
        let detail: String?

        init(name: String, detail: String? = nil) {
            self.name = name
            self.detail = detail
        }
    }

    struct Request {
        var source: String
        /// UTF-16 offset of the insertion point.
        var cursor: Int
        var fileType: C64FileType
        var dialect: BasicDialect? = nil
        var variables: [Variable] = []

        init(source: String, cursor: Int, fileType: C64FileType,
             dialect: BasicDialect? = nil, variables: [Variable] = []) {
            self.source = source
            self.cursor = cursor
            self.fileType = fileType
            self.dialect = dialect
            self.variables = variables
        }
    }

    /// Automatic completion fires while typing and is deliberately shy: it
    /// needs a prefix of at least `minimumAutomaticPrefix` characters, never
    /// pops up over a word the user has already typed in full, and stays
    /// quiet in the middle of a word. Manual completion (Control-Space)
    /// shows whatever matches.
    enum Trigger { case automatic, manual }

    struct Result: Equatable {
        /// UTF-16 range of the partial word the completions replace.
        let range: NSRange
        /// Prefix matches first (same case before case-insensitive), then
        /// alphabetical; line numbers are in numeric order.
        let items: [CodeCompletion]
    }

    static let minimumAutomaticPrefix = 2

    /// Keywords that take a line number next. `ELSE` is not BASIC V2 but
    /// several dialects have it, and offering a line number after it in V2
    /// costs nothing because the word has to be typed first.
    static let lineTargetKeywords = ["GOTO", "GOSUB", "THEN", "ELSE"]

    // MARK: - Entry point

    /// The completions for the word ending at `request.cursor`, or `nil`
    /// when nothing should be offered there: inside a string literal, in a
    /// comment, in a number, or (automatic trigger) too early.
    static func complete(_ request: Request, trigger: Trigger = .automatic) -> Result? {
        if request.fileType.usesBasicHighlighting {
            return completeBasic(request, trigger: trigger)
        }
        if request.fileType.usesAssemblyHighlighting {
            return completeAssembly(request, trigger: trigger)
        }
        return nil
    }

    // MARK: - BASIC

    private static func completeBasic(_ request: Request, trigger: Trigger) -> Result? {
        let text = request.source as NSString
        let cursor = min(max(0, request.cursor), text.length)
        let lineStart = text.lineRange(for: NSRange(location: cursor, length: 0)).location

        if trigger == .automatic, cursor < text.length,
           isBasicIdentifierChar(text.character(at: cursor)) {
            return nil   // typing in the middle of a word
        }

        // The partial word: letters, digits, $ % # (PRINT#, A$, X%). A run
        // of leading digits is a number, not part of the word, so "10PR"
        // completes PR and "1TO" completes TO.
        var wordStart = cursor
        while wordStart > lineStart, isBasicIdentifierChar(text.character(at: wordStart - 1)) { wordStart -= 1 }

        var candidates = basicKeywordCandidates(dialect: request.dialect)
        let keywordNames = candidates.map(\.text)
        for v in request.variables {
            candidates.append(CodeCompletion(v.name, .variable, detail: v.detail))
        }

        // BASIC lets keywords run into what follows ("THEN100", "PRINTSC"),
        // so when the word as typed matches nothing, peel the longest
        // keyword off its front and try the rest, the way the ROM
        // tokenizer would read it.
        while true {
            var start = wordStart
            while start < cursor, isDigit(text.character(at: start)) { start += 1 }
            let allDigits = start == cursor
            if allDigits { start = wordStart }
            let range = NSRange(location: start, length: cursor - start)
            let word = text.substring(with: range)
            let isNumber = allDigits && !word.isEmpty

            // Strings, REM and DATA swallow everything after them.
            let before = text.substring(with: NSRange(location: lineStart, length: start - lineStart))
            let scan = maskStrings(before, quotes: ["\""])
            guard !scan.open else { return nil }
            let code = scan.masked.uppercased()
            if containsKeyword("REM", in: code) { return nil }
            if let data = lastKeyword("DATA", in: code),
               !code[data...].contains(":") { return nil }

            // After GOTO / GOSUB / THEN / GO TO, offer the file's line numbers.
            if allDigits, followsLineTargetKeyword(code) {
                guard !word.isEmpty || trigger == .manual else { return nil }
                return lineNumberCompletions(in: request.source, prefix: word, range: range, trigger: trigger)
            }
            if isNumber { return nil }
            if trigger == .automatic, word.count < minimumAutomaticPrefix { return nil }

            let lower = word.lowercased()
            if candidates.contains(where: { $0.text.lowercased().hasPrefix(lower) }) {
                guard let items = rank(candidates, word: word, trigger: trigger) else { return nil }
                return Result(range: range, items: items)
            }
            let upper = word.uppercased()
            guard let keyword = keywordNames
                .filter({ upper.hasPrefix($0) && $0.count < upper.count })
                .max(by: { $0.count < $1.count }) else { return nil }
            wordStart = start + (keyword as NSString).length
        }
    }

    /// BASIC V2 keywords, functions, operators and system variables, then
    /// the dialect's keywords on top (a dialect redefinition wins, as in the
    /// reference panel). Emitted in uppercase.
    static func basicKeywordCandidates(dialect: BasicDialect?) -> [CodeCompletion] {
        var byName: [String: CodeCompletion] = [:]
        var order: [String] = []

        func add(_ name: String, _ kind: CodeCompletion.Kind, _ detail: String?) {
            if byName[name] == nil { order.append(name) }
            byName[name] = CodeCompletion(name, kind, detail: detail)
        }

        // GO exists only so "GO TO" tokenizes; nobody completes to it, and
        // listing it would make "GO" an exact match that hides GOTO/GOSUB.
        for kw in C64BasicSyntax.keywords where kw != "GO" {
            add(kw, .keyword, C64BasicSyntax.commandReference[kw]?.syntax)
        }
        for fn in C64BasicSyntax.functions {
            add(fn, .function, C64BasicSyntax.commandReference[fn]?.syntax)
        }
        for op in C64BasicSyntax.operators {
            add(op, .keyword, C64BasicSyntax.commandReference[op]?.syntax)
        }
        for sv in C64BasicSyntax.systemVariables {
            add(sv, .variable, C64BasicSyntax.commandReference[sv]?.description)
        }
        if let dialect {
            for kw in dialect.keywords {
                let name = kw.keyword.uppercased()
                guard !name.isEmpty else { continue }
                let kind: CodeCompletion.Kind
                switch kw.type?.lowercased() {
                case "function", "math", "string": kind = .function
                default: kind = .keyword
                }
                add(name, kind, kw.syntax ?? kw.description)
            }
        }
        return order.compactMap { byName[$0] }
    }

    /// True when `code` (the line before the partial word, strings masked,
    /// uppercased) ends with GOTO, GOSUB, THEN, ELSE or GO TO, optionally
    /// followed by earlier targets of an ON … GOTO list ("GOTO 10,20,").
    private static func followsLineTargetKeyword(_ code: String) -> Bool {
        var s = Substring(code)
        while let last = s.last, last == " " || last == "\t" || last == "," || last.isNumber {
            s = s.dropLast()
        }
        for kw in lineTargetKeywords where s.hasSuffix(kw) {
            let head = s.dropLast(kw.count)
            if head.last?.isLetter != true { return true }
        }
        // GO TO with any amount of space between the two words.
        if s.hasSuffix("TO") {
            var head = s.dropLast(2)
            while head.last == " " || head.last == "\t" { head = head.dropLast() }
            if head.hasSuffix("GO"), head.dropLast(2).last?.isLetter != true { return true }
        }
        return false
    }

    private static func lineNumberCompletions(in source: String, prefix: String,
                                              range: NSRange, trigger: Trigger) -> Result? {
        var seen = Set<Int>()
        var lines: [(number: Int, body: String)] = []
        source.enumerateLines { line, _ in
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            let digits = trimmed.prefix { $0.isNumber }
            guard !digits.isEmpty, let n = Int(digits), seen.insert(n).inserted else { return }
            let body = trimmed.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
            lines.append((n, body))
        }
        var exact = false
        var items: [CodeCompletion] = []
        for line in lines.sorted(by: { $0.number < $1.number }) {
            let s = String(line.number)
            guard s.hasPrefix(prefix) else { continue }
            if s == prefix { exact = true; continue }
            items.append(CodeCompletion(s, .lineNumber, detail: truncate(line.body, 48)))
        }
        if exact && trigger == .automatic { return nil }
        guard !items.isEmpty else { return nil }
        return Result(range: range, items: items)
    }

    // MARK: - Assembly

    /// ca65 pseudo functions and variables that appear inside operands.
    static let operandFunctions: [String] = [
        ".LOBYTE", ".HIBYTE", ".BANKBYTE", ".LOWORD", ".HIWORD",
        ".SIZEOF", ".STRLEN", ".STRAT", ".STRING", ".CONCAT", ".SPRINTF",
        ".DEFINED", ".REFERENCED", ".BLANK", ".CONST", ".MATCH", ".XMATCH",
        ".TCOUNT", ".LEFT", ".RIGHT", ".MID", ".IDENT", ".MAX", ".MIN",
        ".ASIZE", ".ISIZE", ".PARAMCOUNT", ".CPU", ".TIME", ".VERSION",
    ]

    private static func completeAssembly(_ request: Request, trigger: Trigger) -> Result? {
        let text = request.source as NSString
        let cursor = min(max(0, request.cursor), text.length)
        let lineStart = text.lineRange(for: NSRange(location: cursor, length: 0)).location

        // The partial word: letters, digits, '_', plus a leading '.' for
        // directives or '@' for cheap local labels.
        var start = cursor
        while start > lineStart, isAsmIdentifierChar(text.character(at: start - 1)) { start -= 1 }
        if start > lineStart {
            let c = text.character(at: start - 1)
            if c == 0x2E || c == 0x40 { start -= 1 }   // '.' '@'
        }
        let range = NSRange(location: start, length: cursor - start)
        let word = text.substring(with: range)

        // $D020, %1010 and plain numbers are literals, not words.
        if start > lineStart {
            let c = text.character(at: start - 1)
            if c == 0x24 || c == 0x25 { return nil }
        }
        let bare = word.drop { $0 == "." || $0 == "@" }
        if bare.first?.isNumber == true { return nil }
        if trigger == .automatic, cursor < text.length,
           isAsmIdentifierChar(text.character(at: cursor)) {
            return nil
        }
        if trigger == .automatic, word.count < minimumAutomaticPrefix { return nil }

        let before = text.substring(with: NSRange(location: lineStart, length: start - lineStart))
        let scan = maskStrings(before, quotes: ["\"", "'"])
        guard !scan.open, !scan.masked.contains(";") else { return nil }

        let definitions = scanAssemblyDefinitions(request.source)
        let code = scan.masked.trimmingCharacters(in: .whitespaces)
        var instructionPosition = code.isEmpty || (code.hasSuffix(":") && !code.hasSuffix(":="))
        if !instructionPosition, definitions.labelsWithoutColons, isIdentifier(code),
           !isMnemonic(code.uppercased()), !definitions.macros.contains(code.uppercased()) {
            instructionPosition = true   // "loop lda #0" with labels_without_colons
        }

        // Match the case of what the user typed for table entries; labels
        // keep the case they were defined with.
        let lowercase = bare.isEmpty ? true : bare.allSatisfy { !$0.isUppercase }
        func cased(_ s: String) -> String { lowercase ? s.lowercased() : s.uppercased() }

        var candidates: [CodeCompletion] = []
        if word.hasPrefix(".") {
            let directives = instructionPosition ? Array(C64AssemblySyntax.directives) : operandFunctions
            for d in directives {
                candidates.append(CodeCompletion(cased(d), .directive,
                                                 detail: instructionPosition ? "ca65 directive" : "ca65 function"))
            }
        } else if instructionPosition {
            for m in C64AssemblySyntax.officialOpcodes.union(C64AssemblySyntax.illegalOpcodes) {
                let ref = C64AssemblySyntax.opcodeReference[m]
                var detail = ref?.fullName
                if ref?.isIllegal == true || C64AssemblySyntax.illegalOpcodes.contains(m),
                   detail?.contains("undocumented") != true {
                    detail = (detail.map { $0 + " " } ?? "") + "(undocumented)"
                }
                candidates.append(CodeCompletion(cased(m), .mnemonic, detail: detail))
            }
            for m in definitions.macroNames {
                candidates.append(CodeCompletion(m, .macro, detail: "macro"))
            }
        } else {
            var taken = Set<String>()
            for s in definitions.symbols {
                taken.insert(s.text.uppercased())
                candidates.append(s)
            }
            for sym in romSymbols where !taken.contains(sym.name.uppercased()) {
                candidates.append(CodeCompletion(cased(sym.name), .symbol, detail: sym.detail))
            }
        }
        guard let items = rank(candidates, word: word, trigger: trigger) else { return nil }
        return Result(range: range, items: items)
    }

    /// What an assembly file defines: labels (`name:`, `@name:`, `.proc`,
    /// column-one names under `.feature labels_without_colons`), assigned
    /// symbols (`name = expr`), imports, and macro names.
    struct AssemblyDefinitions {
        var symbols: [CodeCompletion] = []
        var macroNames: [String] = []
        /// Uppercased macro names, for case-insensitive lookups.
        var macros: Set<String> = []
        var labelsWithoutColons = false
    }

    static func scanAssemblyDefinitions(_ source: String) -> AssemblyDefinitions {
        var defs = AssemblyDefinitions()
        var seen = Set<String>()

        func addSymbol(_ name: String, _ kind: CodeCompletion.Kind, _ detail: String?) {
            guard !name.isEmpty, seen.insert(name).inserted else { return }
            defs.symbols.append(CodeCompletion(name, kind, detail: detail))
        }

        var codeLines: [(code: NSString, columnOne: Bool)] = []
        source.enumerateLines { line, _ in
            var masked = maskStrings(line, quotes: ["\"", "'"]).masked
            if let semi = masked.firstIndex(of: ";") { masked = String(masked[..<semi]) }
            let columnOne = masked.first.map { $0 != " " && $0 != "\t" } ?? false
            codeLines.append((masked as NSString, columnOne))
            if masked.lowercased().contains(".feature"),
               masked.lowercased().contains("labels_without_colons") {
                defs.labelsWithoutColons = true
            }
        }

        for (code, columnOne) in codeLines {
            var pos = skipSpaces(code, from: 0)
            // Labels: "name:" / "@name:" (any number of them), ':' alone.
            while pos < code.length {
                if code.character(at: pos) == 0x3A {
                    pos = skipSpaces(code, from: pos + 1)
                    continue
                }
                let r = identifierRange(code, at: pos)
                guard r.length > 0 else { break }
                let name = code.substring(with: r)
                guard !name.hasPrefix("."), !isMnemonic(name.uppercased()) else { break }
                let after = skipSpaces(code, from: NSMaxRange(r))
                guard after < code.length, code.character(at: after) == 0x3A,
                      !(after + 1 < code.length && code.character(at: after + 1) == 0x3D) else { break }
                addSymbol(name, .label, "label")
                pos = skipSpaces(code, from: after + 1)
            }
            guard pos < code.length else { continue }
            let r = identifierRange(code, at: pos)
            guard r.length > 0 else { continue }
            let word = code.substring(with: r)
            let upper = word.uppercased()
            let operandStart = skipSpaces(code, from: NSMaxRange(r))
            let operand = code.substring(from: operandStart).trimmingCharacters(in: .whitespaces)

            if upper.hasPrefix(".") {
                let first = operand.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," || $0 == "(" }).first.map(String.init) ?? ""
                switch upper {
                case ".PROC":
                    addSymbol(first, .label, "proc")
                case ".MACRO", ".MAC", ".DEFINE":
                    if !first.isEmpty, defs.macros.insert(first.uppercased()).inserted {
                        defs.macroNames.append(first)
                    }
                case ".IMPORT", ".IMPORTZP", ".GLOBAL", ".GLOBALZP":
                    for part in operand.split(separator: ",") {
                        let name = part.trimmingCharacters(in: .whitespaces)
                            .split(separator: ":").first.map(String.init) ?? ""
                        addSymbol(name, .symbol, upper.hasPrefix(".IMPORT") ? "imported" : "global")
                    }
                default:
                    break
                }
                continue
            }

            // name = expr, name := expr, name .set expr
            if operand.hasPrefix("=") && !operand.hasPrefix("==") {
                addSymbol(word, .symbol, "= " + truncate(operand.dropFirst().trimmingCharacters(in: .whitespaces), 32))
                continue
            }
            if operand.hasPrefix(":=") {
                addSymbol(word, .symbol, "= " + truncate(operand.dropFirst(2).trimmingCharacters(in: .whitespaces), 32))
                continue
            }
            if operand.lowercased().hasPrefix(".set ") {
                addSymbol(word, .symbol, "= " + truncate(operand.dropFirst(5).trimmingCharacters(in: .whitespaces), 32))
                continue
            }

            // Column-one word that is neither instruction, directive nor
            // macro: a label when the file enables labels_without_colons.
            if defs.labelsWithoutColons, columnOne, pos == 0,
               !isMnemonic(upper), !defs.macros.contains(upper) {
                addSymbol(word, .label, "label")
            }
        }
        return defs
    }

    /// KERNAL, BASIC ROM, VIC, SID and CIA names with their address and a
    /// short description, deduplicated by name.
    static let romSymbols: [(name: String, detail: String)] = {
        var seen = Set<String>()
        var out: [(String, String)] = []
        for sym in C64ROMSymbols.allSymbols where seen.insert(sym.name).inserted {
            let desc = sym.description.split(separator: ".").first.map(String.init) ?? sym.description
            out.append((sym.name, String(format: "$%04X  ", sym.address) + truncate(desc, 56)))
        }
        return out
    }()

    // MARK: - Ranking

    /// Keeps the candidates the word is a prefix of, drops exact matches
    /// (nothing to complete), and orders same-case prefix matches before
    /// case-insensitive ones, alphabetically within each group. Returns
    /// `nil` when nothing is left, or when an automatic trigger lands on a
    /// word the user has already typed in full.
    static func rank(_ candidates: [CodeCompletion], word: String, trigger: Trigger) -> [CodeCompletion]? {
        let lower = word.lowercased()
        var seen = Set<String>()
        var exact = false
        var matched: [(item: CodeCompletion, sameCase: Bool)] = []
        for c in candidates {
            let cl = c.text.lowercased()
            guard cl.hasPrefix(lower) else { continue }
            if cl == lower { exact = true; continue }
            guard seen.insert(c.text).inserted else { continue }
            matched.append((c, c.text.hasPrefix(word)))
        }
        if exact && trigger == .automatic { return nil }
        guard !matched.isEmpty else { return nil }
        return matched.sorted { a, b in
            if a.sameCase != b.sameCase { return a.sameCase }
            let la = a.item.text.lowercased(), lb = b.item.text.lowercased()
            if la != lb { return la < lb }
            return a.item.text < b.item.text
        }.map(\.item)
    }

    // MARK: - Scanning helpers

    /// Blanks the inside of string literals (quotes included) so keyword
    /// searches ignore them, and reports whether a literal is still open at
    /// the end. Each quote character opens and closes its own kind.
    static func maskStrings(_ s: String, quotes: Set<Character>) -> (masked: String, open: Bool) {
        var out = ""
        out.reserveCapacity(s.count)
        var open: Character? = nil
        for ch in s {
            if let q = open {
                out.append(" ")
                if ch == q { open = nil }
            } else if quotes.contains(ch) {
                out.append(" ")
                open = ch
            } else {
                out.append(ch)
            }
        }
        return (out, open != nil)
    }

    /// True when `keyword` occurs in `code` with no letter in front of it
    /// (so REM matches in "10 REM" and "A=1:REM" but not in "TREMOR").
    private static func containsKeyword(_ keyword: String, in code: String) -> Bool {
        lastKeyword(keyword, in: code) != nil
    }

    private static func lastKeyword(_ keyword: String, in code: String) -> String.Index? {
        var searchEnd = code.endIndex
        while let r = code.range(of: keyword, options: .backwards, range: code.startIndex..<searchEnd) {
            if r.lowerBound == code.startIndex || !code[code.index(before: r.lowerBound)].isLetter {
                return r.lowerBound
            }
            searchEnd = r.lowerBound
        }
        return nil
    }

    private static func truncate(_ s: String, _ limit: Int) -> String {
        s.count <= limit ? s : String(s.prefix(limit - 1)) + "…"
    }

    private static func isDigit(_ c: unichar) -> Bool { c >= 0x30 && c <= 0x39 }

    private static func isLetter(_ c: unichar) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
    }

    private static func isBasicIdentifierChar(_ c: unichar) -> Bool {
        isLetter(c) || isDigit(c) || c == 0x24 || c == 0x25 || c == 0x23   // $ % #
    }

    private static func isAsmIdentifierChar(_ c: unichar) -> Bool {
        isLetter(c) || isDigit(c) || c == 0x5F   // _
    }

    private static func isIdentifier(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first else { return false }
        let f = unichar(truncatingIfNeeded: first.value)
        guard isLetter(f) || f == 0x5F || f == 0x40 else { return false }
        return s.unicodeScalars.dropFirst().allSatisfy { isAsmIdentifierChar(unichar(truncatingIfNeeded: $0.value)) }
    }

    private static func isMnemonic(_ upper: String) -> Bool {
        C64AssemblySyntax.officialOpcodes.contains(upper)
            || C64AssemblySyntax.illegalOpcodes.contains(upper)
            || C64AssemblySyntax.mnemonicAliases[upper] != nil
    }

    private static func skipSpaces(_ s: NSString, from pos: Int) -> Int {
        var i = pos
        while i < s.length, s.character(at: i) == 0x20 || s.character(at: i) == 0x09 { i += 1 }
        return i
    }

    /// Range of an identifier (letters, digits, '_', a leading '.' or '@')
    /// starting at `pos`.
    private static func identifierRange(_ s: NSString, at pos: Int) -> NSRange {
        guard pos < s.length else { return NSRange(location: pos, length: 0) }
        let first = s.character(at: pos)
        guard isLetter(first) || first == 0x5F || first == 0x2E || first == 0x40 else {
            return NSRange(location: pos, length: 0)
        }
        var i = pos + 1
        while i < s.length, isAsmIdentifierChar(s.character(at: i)) { i += 1 }
        return NSRange(location: pos, length: i - pos)
    }
}

// MARK: - Variable scanner bridge

extension CodeCompletionProvider.Variable {
    /// Describes a scanned variable the way the reference panel does: its
    /// BASIC type for scalars, the dimensions for arrays, FN for functions.
    init(_ info: BasicVariableInfo) {
        let detail: String
        switch info.kind {
        case .scalar:
            detail = info.typeDescription
        case .array:
            detail = "array" + (info.dims.map { " (\($0))" } ?? "")
        case .function:
            detail = "user function"
        }
        self.init(name: info.name, detail: detail)
    }
}
