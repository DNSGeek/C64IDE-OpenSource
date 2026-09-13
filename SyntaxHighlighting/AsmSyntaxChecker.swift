// MARK: - AsmSyntaxChecker.swift
//
// Live syntax checking for ca65 assembly source. This is deliberately a
// line-level checker, not an assembler: it does not resolve symbols, expand
// macros or evaluate expressions, so it only reports what can be known from
// one line plus a cheap scan of the file (which CPU is selected, which
// macros are defined here, whether other files are included).
//
// What it catches:
//   - words in the instruction column that are neither a 6502 mnemonic, a
//     ca65 directive nor a macro defined in this file (silenced when the
//     file includes others, since the macro may live there)
//   - undocumented opcodes without `.setcpu "6502X"`, and 65C02/65816/4510
//     mnemonics on a plain 6502
//   - addressing modes the mnemonic does not have (STA #1, LDX ($10),Y,
//     JSR ($1000), INC A ...), including zero-page-only modes given a
//     16-bit literal address (STX $D000,Y)
//   - immediate literals over 255 and addresses over $FFFF
//   - unknown directives, unterminated strings, malformed $/% numbers and
//     unbalanced parentheses
//
// Mode checks are skipped entirely once the file selects a CPU other than
// the 6502/6502X, because the 65C02, 65816 and 4510 add modes this table
// does not model.

import Foundation

struct AsmSyntaxChecker {

    enum CPU {
        case mos6502
        case mos6502X
        /// 65C02, 65816, 4510/45GS02... anything whose extra modes and
        /// mnemonics are not modelled here.
        case other
    }

    /// The operand shape, ignoring the zero-page/absolute distinction
    /// (which needs symbol values to decide).
    enum ModeFamily: Hashable {
        case implied, accumulator, immediate
        case direct        // addr  (zero page, absolute, or a branch target)
        case directX       // addr,X
        case directY       // addr,Y
        case indirect      // (addr)
        case indirectX     // (addr,X)
        case indirectY     // (addr),Y

        var label: String {
            switch self {
            case .implied:     return "implied"
            case .accumulator: return "accumulator (A)"
            case .immediate:   return "immediate (#)"
            case .direct:      return "addr"
            case .directX:     return "addr,X"
            case .directY:     return "addr,Y"
            case .indirect:    return "(addr)"
            case .indirectX:   return "(addr,X)"
            case .indirectY:   return "(addr),Y"
            }
        }

        init(_ mode: AddressingMode) {
            switch mode {
            case .implied:                 self = .implied
            case .accumulator:             self = .accumulator
            case .immediate:               self = .immediate
            case .zeroPage, .absolute, .relative: self = .direct
            case .zeroPageX, .absoluteX:   self = .directX
            case .zeroPageY, .absoluteY:   self = .directY
            case .indirect:                self = .indirect
            case .indirectX:               self = .indirectX
            case .indirectY:               self = .indirectY
            }
        }
    }

    /// What the pre-pass learned about the file as a whole.
    struct FileContext {
        var cpu: CPU = .mos6502
        var macros = Set<String>()
        var hasIncludes = false
        var labelsWithoutColons = false
        /// `.feature dollar_is_pc`: a bare '$' is the program counter.
        var dollarIsPC = false
        /// Lines inside .enum/.struct/.union blocks, whose members look like
        /// unknown instructions to a line-level scan.
        var skipLines = Set<Int>()
    }

    // MARK: - Tables

    /// Mnemonics of the CPUs ca65 supports beyond the NMOS 6502. Only used
    /// to word the error when one shows up while the 6502 is selected.
    static let extendedMnemonics: Set<String> = {
        var s: Set<String> = [
            // 65C02
            "BRA", "PHX", "PHY", "PLX", "PLY", "STZ", "TRB", "TSB", "STP", "WAI",
            // 65816
            "BRL", "COP", "JML", "JSL", "MVN", "MVP", "PEA", "PEI", "PER", "PHB",
            "PHD", "PHK", "PLB", "PLD", "REP", "RTL", "SEP", "TCD", "TCS", "TDC",
            "TSC", "TXY", "TYX", "WDM", "XBA", "XCE",
            // 4510 / 45GS02
            "ASR", "ASW", "BSR", "CLE", "CPZ", "DEW", "DEZ", "EOM", "INW", "INZ",
            "LDZ", "MAP", "NEG", "PHW", "PHZ", "PLZ", "ROW", "TAB", "TAZ", "TBA",
            "TSY", "TYS", "TZA",
        ]
        for n in 0...7 {
            s.insert("BBR\(n)"); s.insert("BBS\(n)")
            s.insert("RMB\(n)"); s.insert("SMB\(n)")
        }
        return s
    }()

    /// Every ca65 control command that can start a statement. Operand-level
    /// functions (.LOBYTE, .SIZEOF, .DEFINED ...) are not statements and are
    /// not listed; they never appear in this position.
    static let directives: Set<String> = [
        ".A16", ".A8", ".ADDR", ".ALIGN", ".ASCIIZ", ".ASSERT", ".AUTOIMPORT",
        ".BANKBYTES", ".BSS", ".BYT", ".BYTE", ".CASE", ".CHARMAP", ".CODE",
        ".CONDES", ".CONSTRUCTOR", ".DATA", ".DBYT", ".DEBUGINFO", ".DEFINE",
        ".DELMAC", ".DELMACRO", ".DESTRUCTOR", ".DWORD", ".ELSE", ".ELSEIF",
        ".END", ".ENDENUM", ".ENDIF", ".ENDMAC", ".ENDMACRO", ".ENDPROC",
        ".ENDREP", ".ENDREPEAT", ".ENDSCOPE", ".ENDSTRUCT", ".ENDUNION", ".ENUM",
        ".ERROR", ".EXITMAC", ".EXITMACRO", ".EXPORT", ".EXPORTZP", ".FARADDR",
        ".FATAL", ".FEATURE", ".FILEOPT", ".FOPT", ".FORCEIMPORT", ".GLOBAL",
        ".GLOBALZP", ".HIBYTES", ".I16", ".I8", ".IF", ".IFBLANK", ".IFCONST",
        ".IFDEF", ".IFNBLANK", ".IFNCONST", ".IFNDEF", ".IFNREF", ".IFP02",
        ".IFP4510", ".IFP45GS02", ".IFP816", ".IFPC02", ".IFPDTV", ".IFPSC02",
        ".IFREF", ".IMPORT", ".IMPORTZP", ".INCBIN", ".INCLUDE", ".INTERRUPTOR",
        ".LINECONT", ".LIST", ".LISTBYTES", ".LITERAL", ".LOBYTES", ".LOCAL",
        ".LOCALCHAR", ".MAC", ".MACPACK", ".MACRO", ".ORG", ".OUT", ".P02",
        ".P4510", ".P45GS02", ".P816", ".PAGELEN", ".PAGELENGTH", ".PC02",
        ".PDTV", ".POPCPU", ".POPSEG", ".PROC", ".PSC02", ".PUSHCPU", ".PUSHSEG",
        ".REFERTO", ".REFTO", ".RELOC", ".REPEAT", ".RES", ".RODATA", ".SCOPE",
        ".SEGMENT", ".SET", ".SETCPU", ".SMART", ".STRUCT", ".TAG", ".UNDEF",
        ".UNDEFINE", ".UNION", ".WARNING", ".WORD", ".ZEROPAGE",
    ]

    // MARK: - Entry Point

    func check(_ source: String) -> [SyntaxDiagnostic] {
        let lines = source.components(separatedBy: "\n")
        let context = Self.scanFile(lines)
        var diagnostics: [SyntaxDiagnostic] = []
        for (index, line) in lines.enumerated() {
            diagnostics += Self.checkLine(line, index: index, context: context)
        }
        return diagnostics.sorted(by: SyntaxDiagnostic.displayOrder)
    }

    // MARK: - File Pre-pass

    static func scanFile(_ lines: [String]) -> FileContext {
        var ctx = FileContext()
        var blockDepth = 0
        for (index, line) in lines.enumerated() {
            if blockDepth > 0 { ctx.skipLines.insert(index) }
            let code = stripComment(line).code
            let trimmed = code.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(".") else { continue }
            let words = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let first = words.first?.uppercased() else { continue }
            let second = words.count > 1 ? String(words[1]) : ""

            switch first {
            case ".ENUM", ".STRUCT", ".UNION":
                blockDepth += 1
            case ".ENDENUM", ".ENDSTRUCT", ".ENDUNION":
                blockDepth = max(blockDepth - 1, 0)
                ctx.skipLines.remove(index)
            case ".SETCPU":
                let name = second.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).uppercased()
                switch name {
                case "6502":  ctx.cpu = .mos6502
                case "6502X": ctx.cpu = .mos6502X
                default:      ctx.cpu = .other
                }
            case ".P02":
                ctx.cpu = .mos6502
            case ".PC02", ".PSC02", ".P816", ".P4510", ".P45GS02", ".PDTV":
                ctx.cpu = .other
            case ".MACRO", ".MAC", ".DEFINE":
                // ".macro name arg1, arg2" / ".define name(args) body"
                var name = second
                if let paren = name.firstIndex(of: "(") { name = String(name[..<paren]) }
                name = name.trimmingCharacters(in: CharacterSet(charactersIn: ","))
                if !name.isEmpty { ctx.macros.insert(name.uppercased()) }
            case ".INCLUDE", ".MACPACK":
                ctx.hasIncludes = true
            case ".FEATURE":
                let features = trimmed.lowercased()
                if features.contains("labels_without_colons") { ctx.labelsWithoutColons = true }
                if features.contains("dollar_is_pc") { ctx.dollarIsPC = true }
            default:
                break
            }
        }
        return ctx
    }

    // MARK: - Line Check

    static func checkLine(_ line: String, index: Int, context: FileContext) -> [SyntaxDiagnostic] {
        var diags: [SyntaxDiagnostic] = []
        let stripped = stripComment(line)
        if let quote = stripped.unterminatedStringAt {
            diags.append(SyntaxDiagnostic(line: index, column: quote, length: 1,
                                          message: "Unterminated string"))
        }
        let code = stripped.code as NSString
        let pos = skipSpaces(code, from: 0)
        guard pos < code.length else { return diags }

        // Structural checks apply to the whole statement.
        diags += checkNumbersAndParens(code, index: index, context: context)

        guard !context.skipLines.contains(index) else { return diags }
        diags += checkStatement(code, from: pos, index: index, context: context)
        return diags
    }

    /// Checks the statement starting at `start`: optional labels, then a
    /// directive, instruction, macro call or assignment.
    private static func checkStatement(_ code: NSString, from start: Int, index: Int,
                                       context: FileContext) -> [SyntaxDiagnostic] {
        var diags: [SyntaxDiagnostic] = []
        var pos = start

        // Unnamed label ":" and named labels "name:" / "@name:".
        var sawLabel = false
        while pos < code.length {
            if code.character(at: pos) == 0x3A { // ':' alone
                pos = skipSpaces(code, from: pos + 1)
                sawLabel = true
                continue
            }
            let wordRange = identifierRange(code, at: pos)
            guard wordRange.length > 0 else { break }
            // Mnemonics are reserved words in ca65 and can never be labels,
            // so "bne :+" is a branch to an unnamed label, not a label "bne".
            let candidate = code.substring(with: wordRange).uppercased()
            guard canonicalMnemonic(candidate) == nil,
                  !extendedMnemonics.contains(candidate) else { break }
            let after = skipSpaces(code, from: NSMaxRange(wordRange))
            if after < code.length, code.character(at: after) == 0x3A,
               !(after + 1 < code.length && code.character(at: after + 1) == 0x3D) { // ':' but not ':='
                pos = skipSpaces(code, from: after + 1)
                sawLabel = true
                continue
            }
            break
        }
        guard pos < code.length else { return diags }

        let wordRange = identifierRange(code, at: pos)
        guard wordRange.length > 0 else {
            let ch = String(Character(UnicodeScalar(code.character(at: pos)) ?? " "))
            if ch == "*" {
                diags.append(SyntaxDiagnostic(line: index, column: pos, length: 1,
                    message: "ca65 does not use '* =' to set the address; use .org"))
            } else if ch == "!" {
                diags.append(SyntaxDiagnostic(line: index, column: pos, length: 1,
                    message: "'!' pseudo-ops are ACME syntax; ca65 uses .byte, .word, .text..."))
            } else {
                diags.append(SyntaxDiagnostic(line: index, column: pos, length: 1,
                    message: "Unexpected '\(ch)' at the start of a statement"))
            }
            return diags
        }
        let word = code.substring(with: wordRange)
        let upper = word.uppercased()
        let operandStart = skipSpaces(code, from: NSMaxRange(wordRange))
        let operand = code.substring(from: operandStart)
            .trimmingCharacters(in: .whitespaces)

        // Directive
        if upper.hasPrefix(".") {
            if !directives.contains(upper) {
                diags.append(SyntaxDiagnostic(line: index, column: wordRange.location,
                    length: wordRange.length, message: "Unknown directive \(word)"))
            }
            return diags
        }

        // Symbol assignment: name = expr, name := expr, name .set expr
        if operand.hasPrefix("=") || operand.hasPrefix(":=")
            || operand.lowercased().hasPrefix(".set ") {
            return diags
        }

        // Instruction
        if let mnemonic = canonicalMnemonic(upper) {
            let encodings = C64AssemblySyntax.encodings(for: mnemonic)
            let documented = encodings.contains { !$0.isIllegal }
            if !documented && context.cpu == .mos6502 {
                diags.append(SyntaxDiagnostic(line: index, column: wordRange.location,
                    length: wordRange.length,
                    message: "\(upper) is an undocumented opcode; add .setcpu \"6502X\" to assemble it"))
                return diags
            }
            guard context.cpu != .other else { return diags }
            let allowed = Set(encodings
                .filter { context.cpu == .mos6502X || !$0.isIllegal }
                .map { ModeFamily($0.mode) })
            diags += checkOperand(operand, at: operandStart, mnemonic: upper,
                                  allowed: allowed, index: index)
            return diags
        }

        if extendedMnemonics.contains(upper) {
            if context.cpu != .other {
                diags.append(SyntaxDiagnostic(line: index, column: wordRange.location,
                    length: wordRange.length,
                    message: "\(upper) is not a 6502 instruction; select its CPU with .setcpu first"))
            }
            return diags
        }

        // Macro defined in this file
        if context.macros.contains(upper) { return diags }

        // Label without a colon (only legal with the feature enabled)
        if context.labelsWithoutColons && !sawLabel {
            // The rest of the line is the real statement; check it.
            if operandStart < code.length {
                diags += checkStatement(code, from: operandStart, index: index, context: context)
            }
            return diags
        }

        // Unknown word. If the file pulls in other files the word may be a
        // macro defined there, so say nothing.
        guard !context.hasIncludes else { return diags }
        let hint = wordRange.location == 0
            ? " If it is a label, add ':' after it."
            : ""
        diags.append(SyntaxDiagnostic(line: index, column: wordRange.location,
            length: wordRange.length,
            message: "\(word) is not a known instruction or macro.\(hint)"))
        return diags
    }

    // MARK: - Operand / Addressing Mode

    static func checkOperand(_ operand: String, at start: Int, mnemonic: String,
                             allowed: Set<ModeFamily>, index: Int) -> [SyntaxDiagnostic] {
        let length = max((operand as NSString).length, 1)
        func fail(_ message: String) -> [SyntaxDiagnostic] {
            [SyntaxDiagnostic(line: index, column: start, length: length, message: message)]
        }
        func valid(_ family: ModeFamily) -> [SyntaxDiagnostic] {
            guard !allowed.contains(family) else { return [] }
            let modes = allowed.map(\.label).sorted().joined(separator: ", ")
            return fail("\(mnemonic) has no \(family.label) form; valid: \(modes)")
        }

        if operand.isEmpty {
            if allowed.contains(.implied) || allowed.contains(.accumulator) { return [] }
            return fail("\(mnemonic) needs an operand")
        }
        if operand.uppercased() == "A" {
            return valid(.accumulator)
        }
        if operand.hasPrefix("#") {
            var diags = valid(.immediate)
            let value = String(operand.dropFirst()).trimmingCharacters(in: .whitespaces)
            if let n = literalValue(value), n > 255 {
                diags += fail("Immediate value \(value) does not fit in a byte (0-255)")
            }
            return diags
        }
        if operand.hasPrefix("("), let close = matchingParen(operand, open: operand.startIndex) {
            let inner = String(operand[operand.index(after: operand.startIndex)..<close])
            let rest = String(operand[operand.index(after: close)...])
                .replacingOccurrences(of: " ", with: "").uppercased()
            if rest.isEmpty {
                let (base, reg) = splitIndex(inner)
                switch reg {
                case "X":
                    return valid(.indirectX) + zeroPageOnly(base, mnemonic: mnemonic, mode: "(addr,X)", index: index, start: start, length: length)
                case "Y":
                    return fail("(addr,Y) is not a 6502 addressing mode; did you mean (addr),Y?")
                case nil:
                    return valid(.indirect)
                default:
                    return fail("Unexpected ',\(reg!)' inside the parentheses")
                }
            }
            if rest == ",Y" {
                return valid(.indirectY) + zeroPageOnly(inner, mnemonic: mnemonic, mode: "(addr),Y", index: index, start: start, length: length)
            }
            if rest == ",X" {
                return fail("(addr),X is not a 6502 addressing mode; did you mean (addr,X)?")
            }
            // "(expr) + 1" style: the parenthesis was part of an expression.
        }

        let (base, reg) = splitIndex(operand)
        switch reg {
        case nil:
            var diags = valid(.direct)
            if let n = literalValue(base), n > 0xFFFF {
                diags += fail("Address \(base) is beyond $FFFF")
            }
            return diags
        case "X":
            return valid(.directX) + rangeForIndexed(base, family: .directX, mnemonic: mnemonic, allowed: allowed, index: index, start: start, length: length)
        case "Y":
            return valid(.directY) + rangeForIndexed(base, family: .directY, mnemonic: mnemonic, allowed: allowed, index: index, start: start, length: length)
        case "Z", "S", "SP":
            return fail("',\(reg!)' indexing is not available on the 6502; select the CPU with .setcpu")
        default:
            return fail("Expected ,X or ,Y after the address")
        }
    }

    /// STX addr,Y and STY addr,X (and the undocumented SAX/LAX zp,Y) exist
    /// only in zero page; a literal above 255 cannot assemble.
    private static func rangeForIndexed(_ base: String, family: ModeFamily, mnemonic: String,
                                        allowed: Set<ModeFamily>, index: Int,
                                        start: Int, length: Int) -> [SyntaxDiagnostic] {
        guard allowed.contains(family), let n = literalValue(base) else { return [] }
        if n > 0xFFFF {
            return [SyntaxDiagnostic(line: index, column: start, length: length,
                                     message: "Address \(base) is beyond $FFFF")]
        }
        let hasAbsolute = C64AssemblySyntax.encodings(for: mnemonic).contains {
            ($0.mode == .absoluteX && family == .directX) || ($0.mode == .absoluteY && family == .directY)
        }
        if n > 255 && !hasAbsolute {
            return [SyntaxDiagnostic(line: index, column: start, length: length,
                message: "\(mnemonic) \(family.label) only exists for zero-page addresses (0-255)")]
        }
        return []
    }

    private static func zeroPageOnly(_ base: String, mnemonic: String, mode: String, index: Int,
                                     start: Int, length: Int) -> [SyntaxDiagnostic] {
        guard let n = literalValue(base), n > 255 else { return [] }
        return [SyntaxDiagnostic(line: index, column: start, length: length,
            message: "\(mnemonic) \(mode) needs a zero-page address (0-255)")]
    }

    /// Splits "expr,X" into ("expr", "X") at the last top-level comma.
    private static func splitIndex(_ text: String) -> (String, String?) {
        var depth = 0
        var inString: Character? = nil
        var lastComma: String.Index? = nil
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if let q = inString {
                if ch == q { inString = nil }
            } else if ch == "\"" || ch == "'" {
                inString = ch
            } else if ch == "(" || ch == "[" {
                depth += 1
            } else if ch == ")" || ch == "]" {
                depth -= 1
            } else if ch == "," && depth == 0 {
                lastComma = i
            }
            i = text.index(after: i)
        }
        guard let comma = lastComma else {
            return (text.trimmingCharacters(in: .whitespaces), nil)
        }
        let base = String(text[..<comma]).trimmingCharacters(in: .whitespaces)
        let reg = String(text[text.index(after: comma)...])
            .trimmingCharacters(in: .whitespaces).uppercased()
        return (base, reg)
    }

    private static func matchingParen(_ text: String, open: String.Index) -> String.Index? {
        var depth = 0
        var inString: Character? = nil
        var i = open
        while i < text.endIndex {
            let ch = text[i]
            if let q = inString {
                if ch == q { inString = nil }
            } else if ch == "\"" || ch == "'" {
                inString = ch
            } else if ch == "(" {
                depth += 1
            } else if ch == ")" {
                depth -= 1
                if depth == 0 { return i }
            }
            i = text.index(after: i)
        }
        return nil
    }

    /// The value of a lone numeric literal ($FF, %1010, 255, 'A'); nil for
    /// anything involving symbols or operators.
    static func literalValue(_ text: String) -> Int? {
        let s = text.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("$") { return Int(s.dropFirst(), radix: 16) }
        if s.hasPrefix("%") { return Int(s.dropFirst(), radix: 2) }
        if s.hasPrefix("'"), s.count == 3, s.hasSuffix("'") {
            return Int(s[s.index(after: s.startIndex)].asciiValue ?? 0)
        }
        if s.allSatisfy({ $0.isNumber }) { return Int(s) }
        return nil
    }

    // MARK: - Mnemonics

    /// The reference's spelling for `upper`, or nil if it is not a 6502
    /// mnemonic (documented or undocumented).
    static func canonicalMnemonic(_ upper: String) -> String? {
        if C64AssemblySyntax.officialOpcodes.contains(upper) { return upper }
        if C64AssemblySyntax.illegalOpcodes.contains(upper) { return upper }
        if let alias = C64AssemblySyntax.mnemonicAliases[upper] { return alias }
        if !C64AssemblySyntax.encodings(for: upper).isEmpty { return upper }
        return nil
    }

    // MARK: - Structural Checks

    /// Malformed $/% numbers and unbalanced brackets, outside strings.
    static func checkNumbersAndParens(_ code: NSString, index: Int,
                                      context: FileContext) -> [SyntaxDiagnostic] {
        var diags: [SyntaxDiagnostic] = []
        var depth = 0
        var i = 0
        let n = code.length
        while i < n {
            let c = code.character(at: i)
            if c == 0x22 || c == 0x27 { // " or '
                var j = i + 1
                while j < n && code.character(at: j) != c { j += 1 }
                i = min(j + 1, n)
                continue
            }
            if c == 0x24 || c == 0x25 { // $ or %
                var j = i + 1
                while j < n, isAlnum(code.character(at: j)) { j += 1 }
                let digits = code.substring(with: NSRange(location: i + 1, length: j - i - 1))
                var ok = c == 0x24
                    ? (!digits.isEmpty && Int(digits, radix: 16) != nil)
                    : (!digits.isEmpty && Int(digits, radix: 2) != nil)
                if c == 0x24 && digits.isEmpty && context.dollarIsPC { ok = true }
                if !ok {
                    diags.append(SyntaxDiagnostic(line: index, column: i, length: max(j - i, 1),
                        message: c == 0x24 ? "Malformed hex number" : "Malformed binary number"))
                }
                i = max(j, i + 1)
                continue
            }
            if c == 0x28 || c == 0x5B { depth += 1 }           // ( [
            if c == 0x29 || c == 0x5D {                        // ) ]
                depth -= 1
                if depth < 0 {
                    diags.append(SyntaxDiagnostic(line: index, column: i, length: 1,
                                                  message: "Unmatched closing parenthesis"))
                    depth = 0
                }
            }
            i += 1
        }
        if depth > 0 {
            diags.append(SyntaxDiagnostic(line: index, column: 0, length: n,
                                          message: "Missing closing parenthesis"))
        }
        return diags
    }

    // MARK: - Lexical Helpers

    /// The line up to its ';' comment, and where an unterminated string
    /// starts if the line has one.
    static func stripComment(_ line: String) -> (code: String, unterminatedStringAt: Int?) {
        let ns = line as NSString
        var inString: unichar = 0
        var stringStart = 0
        var i = 0
        while i < ns.length {
            let c = ns.character(at: i)
            if inString != 0 {
                if c == inString { inString = 0 }
            } else if c == 0x22 || c == 0x27 {
                inString = c
                stringStart = i
            } else if c == 0x3B {
                return (ns.substring(to: i), nil)
            }
            i += 1
        }
        // A lone apostrophe in text is common ("don't" is usually inside a
        // comment, which is already gone); only flag double quotes.
        return (line, inString == 0x22 ? stringStart : nil)
    }

    private static func skipSpaces(_ s: NSString, from: Int) -> Int {
        var i = from
        while i < s.length, s.character(at: i) == 0x20 || s.character(at: i) == 0x09 { i += 1 }
        return i
    }

    /// Range of an identifier (letters, digits, '_', a leading '.' for
    /// directives or '@' for cheap labels) starting at `pos`.
    private static func identifierRange(_ s: NSString, at pos: Int) -> NSRange {
        guard pos < s.length else { return NSRange(location: pos, length: 0) }
        let first = s.character(at: pos)
        guard isAlpha(first) || first == 0x5F || first == 0x2E || first == 0x40 else {
            return NSRange(location: pos, length: 0)
        }
        var i = pos + 1
        while i < s.length, isAlnum(s.character(at: i)) || s.character(at: i) == 0x5F { i += 1 }
        return NSRange(location: pos, length: i - pos)
    }

    private static func isAlpha(_ c: unichar) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
    }

    private static func isAlnum(_ c: unichar) -> Bool {
        isAlpha(c) || (c >= 0x30 && c <= 0x39)
    }
}
