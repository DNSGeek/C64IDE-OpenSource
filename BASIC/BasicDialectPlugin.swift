// MARK: - BasicDialectPlugin.swift
//
// Defines the data model, loader, and manager for Commodore BASIC dialect plugins.
// Plugins are JSON files with the `.c64basic` extension that extend tokenization,
// syntax highlighting, and reference documentation for extended BASIC variants.

import Foundation
import os

// MARK: - Dialect Data Model

/// Represents a BASIC dialect plugin configuration.
/// Loaded from `.c64basic` JSON files. Defines keywords, token encodings,
/// load addresses, activation routines, and documentation metadata.
struct BasicDialect: Codable {
    let name: String
    let version: String?
    let author: String?
    let description: String?
    let url: String?
    
    /// When false, omits the BASIC SYS stub in assembly templates.
    /// Defaults to true. Set to false for systems like MEGA65 that run BASIC natively.
    let requiresSYSStub: Bool?

    /// Starting byte value for single-byte extension tokens.
    let tokenBase: Int?

    /// Declared prefix bytes for two-byte token sequences.
    let tokenPrefixes: [TokenPrefix]?

    /// Whether this dialect replaces or extends standard BASIC V2 tokens.
    let extendsBasicV2: Bool?

    /// Override for the program load address (default $0801 for C64).
    let loadAddress: Int?

    /// SYS address to activate the dialect extension (e.g., SYS 2368 for VisionBASIC).
    let activationSYS: Int?

    /// All keywords defined by this dialect.
    let keywords: [BasicDialectKeyword]

    /// Assembler mnemonics for dialects with inline assembly support.
    let assemblerMnemonics: [String]?

    /// Composite keywords parsed as token pairs (e.g., LONGPEEK = LONG + PEEK).
    let compositeKeywords: [CompositeKeyword]?

    /// Shortcut abbreviations expanded at load/paste time.
    let shortcuts: [BasicShortcutExpander.Shortcut]?

    // ── Computed Helpers ──────────────────────────────────

    var prefixBytes: Set<UInt8> {
        guard let prefixes = tokenPrefixes else { return [] }
        return Set(prefixes.map { UInt8($0.byte & 0xFF) })
    }

    var singleByteKeywordsByToken: [UInt8: BasicDialectKeyword] {
        var map: [UInt8: BasicDialectKeyword] = [:]
        for kw in keywords where kw.resolvedPrefixes.isEmpty {
            if let token = kw.token {
                map[UInt8(token & 0xFF)] = kw
            }
        }
        return map
    }

    var prefixedKeywordsByToken: [String: BasicDialectKeyword] {
        var map: [String: BasicDialectKeyword] = [:]
        for kw in keywords {
            let pfx = kw.resolvedPrefixes
            guard !pfx.isEmpty, let token = kw.token else { continue }
            let key = BasicDialect.prefixTokenKey(prefixes: pfx, token: UInt8(token & 0xFF))
            map[key] = kw
        }
        return map
    }

    var keywordsByName: [String: BasicDialectKeyword] {
        var map: [String: BasicDialectKeyword] = [:]
        for kw in keywords {
            map[kw.keyword.uppercased()] = kw
        }
        return map
    }

    var allKeywordNames: [String] {
        keywords.map { $0.keyword.uppercased() }
    }

    static func prefixTokenKey(prefixes: [UInt8], token: UInt8) -> String {
        let pfxStr = prefixes.map { String(format: "%02X", $0) }.joined(separator: " ")
        return "\(pfxStr):\(String(format: "%02X", token))"
    }
}

/// Declares a prefix byte used for two-byte token encoding.
struct TokenPrefix: Codable {
    let byte: Int
    let description: String?
}

/// Defines a single keyword within a dialect.
struct BasicDialectKeyword: Codable {
    let keyword: String
    let prefix: Int?
    let prefixes: [Int]?
    let token: Int?
    let type: String?
    let category: String?
    let syntax: String?
    let description: String?
    let parameters: [ParameterDef]?
    let example: String?
    let notes: String?
    let documented: Bool?

    var resolvedPrefixes: [UInt8] {
        if let prefixes = prefixes, !prefixes.isEmpty {
            return prefixes.map { UInt8($0 & 0xFF) }
        }
        if let prefix = prefix {
            return [UInt8(prefix & 0xFF)]
        }
        return []
    }

    var isPrefixed: Bool { !resolvedPrefixes.isEmpty }

    var highlightColor: KeywordColorType {
        switch type?.lowercased() {
        case "command", "procedure":    return .command
        case "function", "math":        return .function
        case "string":                  return .function
        case "conditional":             return .conditional
        case "loop":                    return .loop
        case "operator":                return .operator_
        case "io":                      return .io
        case "graphics":                return .graphics
        case "sound":                   return .sound
        case "system":                  return .system
        default:                        return .command
        }
    }
}

/// Defines a parameter for a dialect keyword.
struct ParameterDef: Codable {
    let name: String
    let type: String?
    let range: String?
    let description: String?
    let optional: Bool?
}

/// Represents a composite keyword formed by concatenating multiple tokens.
struct CompositeKeyword: Codable {
    let keyword: String
    let tokens: [String]
    let description: String?
}

/// Syntax highlighting category for keywords.
enum KeywordColorType {
    case command, function, conditional, loop, operator_, io, graphics, sound, system
}

// MARK: - Token Encoding

/// The byte sequence emitted when a keyword is matched during tokenization.
enum TokenEncoding {
    case v2(UInt8)
    case extensionSingle(UInt8)
    case extensionPrefixed(prefixes: [UInt8], token: UInt8)
}

/// A unified keyword-to-token mapping entry.
/// Sorted longest-first to enable correct greedy matching across V2 and dialect tokens.
struct UnifiedKeywordEntry {
    let keyword: String
    let encoding: TokenEncoding
}

// MARK: - Plugin Manager

/// Manages loading, activation, and lookup of BASIC dialect plugins.
/// Provides the unified keyword table consumed by the tokenizer (and
/// syntax highlighting / reference panel lookups). The compiler's
/// BasicLexer deliberately does NOT consume this table: it uses the
/// fixed BasicKeywordMatcher.basicV2Keywords set so that compilation
/// is independent of whichever dialect plugin is active.
class BasicDialectManager {

    static let shared = BasicDialectManager()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.c64ide", category: "BasicDialectManager")

    private(set) var availableDialects: [BasicDialect] = []
    private(set) var activeDialect: BasicDialect?
    private(set) var allKeywordNames: Set<String> = []
    private(set) var activePrefixBytes: Set<UInt8> = []
    private(set) var singleByteTokenMap: [UInt8: BasicDialectKeyword] = [:]
    private(set) var prefixedTokenMap: [String: BasicDialectKeyword] = [:]
    private(set) var extensionKeywordMap: [String: (prefixes: [UInt8], token: UInt8)] = [:]
    private(set) var unifiedKeywordTable: [UnifiedKeywordEntry] = []
    private(set) var unifiedKeywordStrings: [String] = []
    private(set) var keywordsWithLongerSibling: Set<String> = []

    /// Keywords that require a letter-boundary guard per C64 ROM tokenization
    /// rules: keywords with a LONGER sibling sharing the prefix and continuing
    /// with a letter (e.g. a dialect's PRINTUSING over PRINT). Precomputed in
    /// rebuildKeywordSet. This used to be a computed property that rebuilt the
    /// whole set with an O(keywords^2) filter on every access — and the
    /// tokenizer read it inside its inner match loop.
    private(set) var keywordsWithLongerLetterSibling: Set<String> = []

    var onDialectChanged: (() -> Void)?

    private init() {
        rebuildKeywordSet()
    }

    // MARK: - Loading

    func loadPlugins(from directory: URL) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }

        for url in contents where url.pathExtension == "c64basic" {
            if let dialect = loadPlugin(from: url) {
                registerDialect(dialect, from: url)
            }
        }
    }

    func loadPlugin(from url: URL) -> BasicDialect? {
        guard let data = try? Data(contentsOf: url) else {
            logger.error("Failed to read \(url.lastPathComponent)")
            return nil
        }

        do {
            let dialect = try JSONDecoder().decode(BasicDialect.self, from: data)
            logger.info("Loaded BASIC dialect: \(dialect.name) v\(dialect.version ?? "?") from \(url.lastPathComponent)")

            let names = dialect.keywords.map { $0.keyword.uppercased() }
            let duplicates = Dictionary(grouping: names, by: { $0 })
                .filter { $1.count > 1 }
                .keys.sorted()
            if !duplicates.isEmpty {
                logger.warning("\(url.lastPathComponent) has duplicate keyword names: \(duplicates.joined(separator: ", ")). Only the last definition will be used.")
            }

            return dialect
        } catch {
            logger.error("Failed to parse \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    private func registerDialect(_ dialect: BasicDialect, from url: URL) {
        if let existingIndex = availableDialects.firstIndex(where: { $0.name == dialect.name }) {
            let existing = availableDialects[existingIndex]
            let existingVer = existing.version ?? "0"
            let newVer = dialect.version ?? "0"

            if compareVersions(newVer, existingVer) > 0 {
                logger.info("Upgrading \(dialect.name) from v\(existingVer) to v\(newVer)")
                availableDialects[existingIndex] = dialect
            } else {
                logger.debug("Skipping \(dialect.name) v\(newVer) (already have v\(existingVer))")
            }
        } else {
            availableDialects.append(dialect)
        }
    }

    private func compareVersions(_ a: String, _ b: String) -> Int {
        let aParts = a.split(separator: ".").compactMap { Int($0) }
        let bParts = b.split(separator: ".").compactMap { Int($0) }
        let maxLen = max(aParts.count, bParts.count)

        for i in 0..<maxLen {
            let aVal = i < aParts.count ? aParts[i] : 0
            let bVal = i < bParts.count ? bParts[i] : 0
            if aVal != bVal { return aVal - bVal }
        }
        return 0
    }

    func addDialect(_ dialect: BasicDialect) {
        availableDialects.append(dialect)
        availableDialects.sort { $0.name < $1.name }
    }

    func removeDialect(named name: String) {
        availableDialects.removeAll { $0.name == name }
    }

    // MARK: - Activation

    func setActiveDialect(named name: String?) {
        if let name = name {
            activeDialect = availableDialects.first { $0.name == name }
        } else {
            activeDialect = nil
        }
        rebuildKeywordSet()
        onDialectChanged?()
    }

    func setActiveDialect(_ dialect: BasicDialect?) {
        activeDialect = dialect
        rebuildKeywordSet()
        onDialectChanged?()
    }

    // MARK: - Keyword Lookup

    func isKeyword(_ word: String) -> Bool {
        allKeywordNames.contains(word.uppercased())
    }

    func lookupKeyword(_ word: String) -> BasicDialectKeyword? {
        activeDialect?.keywordsByName[word.uppercased()]
    }

    func lookupSingleByteToken(_ token: UInt8) -> BasicDialectKeyword? {
        singleByteTokenMap[token]
    }

    func lookupPrefixedToken(prefixes: [UInt8], token: UInt8) -> BasicDialectKeyword? {
        let key = BasicDialect.prefixTokenKey(prefixes: prefixes, token: token)
        return prefixedTokenMap[key]
    }

    func lookupPrefixedToken(prefix: UInt8, token: UInt8) -> BasicDialectKeyword? {
        lookupPrefixedToken(prefixes: [prefix], token: token)
    }

    func lookupToken(_ token: Int) -> BasicDialectKeyword? {
        singleByteTokenMap[UInt8(token & 0xFF)]
    }

    func isPrefixByte(_ byte: UInt8) -> Bool {
        activePrefixBytes.contains(byte)
    }

    func keywords(inCategory category: String) -> [BasicDialectKeyword] {
        guard let dialect = activeDialect else { return [] }
        return dialect.keywords.filter { $0.category?.lowercased() == category.lowercased() }
    }

    var categories: [String] {
        guard let dialect = activeDialect else { return [] }
        let cats = Set(dialect.keywords.compactMap { $0.category })
        return cats.sorted()
    }

    // MARK: - Reference Panel Support

    func referenceEntry(for keyword: BasicDialectKeyword) -> String {
        var lines: [String] = []

        let pfx = keyword.resolvedPrefixes
        if !pfx.isEmpty, let token = keyword.token {
            let pfxStr = pfx.map { String(format: "$%02X", $0) }.joined(separator: " ")
            lines.append("\(keyword.keyword)  [token: \(pfxStr) $\(String(format: "%02X", token))]")
        } else if let token = keyword.token {
            lines.append("\(keyword.keyword)  [token: $\(String(format: "%02X", token))]")
        } else {
            lines.append(keyword.keyword)
        }

        if let syntax = keyword.syntax      { lines.append("  Syntax: \(syntax)") }
        if let desc = keyword.description   { lines.append("  \(desc)") }

        if let params = keyword.parameters, !params.isEmpty {
            lines.append("  Parameters:")
            for p in params {
                var paramLine = "    \(p.name)"
                if let type = p.type        { paramLine += " (\(type))" }
                if let range = p.range      { paramLine += " [\(range)]" }
                if let desc = p.description { paramLine += " — \(desc)" }
                if p.optional == true       { paramLine += " (optional)" }
                lines.append(paramLine)
            }
        }

        if let example = keyword.example    { lines.append("  Example: \(example)") }
        if let notes = keyword.notes        { lines.append("  Note: \(notes)") }

        return lines.joined(separator: "\n")
    }

    // MARK: - Tokenizer Support

    var extensionTokensSorted: [(keyword: String, prefixes: [UInt8], token: UInt8)] {
        guard let dialect = activeDialect else { return [] }
        return dialect.keywords
            .compactMap { kw -> (keyword: String, prefixes: [UInt8], token: UInt8)? in
                guard let token = kw.token else { return nil }
                return (keyword: kw.keyword.uppercased(),
                        prefixes: kw.resolvedPrefixes,
                        token: UInt8(token & 0xFF))
            }
            .sorted { $0.keyword.count > $1.keyword.count }
    }

    // MARK: - Private

    private func rebuildKeywordSet() {
        allKeywordNames = Set(standardBasicV2Keywords)
        activePrefixBytes = []
        singleByteTokenMap = [:]
        prefixedTokenMap = [:]
        extensionKeywordMap = [:]

        // 1. Build V2 portion of the unified table
        var entries: [UnifiedKeywordEntry] = BasicTokenizer.tokenTable.map { kw, token in
            UnifiedKeywordEntry(keyword: kw, encoding: .v2(token))
        }

        // 2. Append dialect keywords and populate lookup maps
        if let dialect = activeDialect {
            activePrefixBytes = dialect.prefixBytes

            for kw in dialect.keywords {
                allKeywordNames.insert(kw.keyword.uppercased())

                guard let token = kw.token else { continue }
                let tokenByte = UInt8(token & 0xFF)
                let pfxBytes = kw.resolvedPrefixes

                if !pfxBytes.isEmpty {
                    let key = BasicDialect.prefixTokenKey(prefixes: pfxBytes, token: tokenByte)
                    prefixedTokenMap[key] = kw
                    extensionKeywordMap[kw.keyword.uppercased()] = (prefixes: pfxBytes, token: tokenByte)
                    entries.append(UnifiedKeywordEntry(
                        keyword: kw.keyword.uppercased(),
                        encoding: .extensionPrefixed(prefixes: pfxBytes, token: tokenByte)
                    ))
                } else {
                    singleByteTokenMap[tokenByte] = kw
                    extensionKeywordMap[kw.keyword.uppercased()] = (prefixes: [], token: tokenByte)
                    entries.append(UnifiedKeywordEntry(
                        keyword: kw.keyword.uppercased(),
                        encoding: .extensionSingle(tokenByte)
                    ))
                }
            }
        }

        // 3. Sort longest-first for correct greedy tokenization matching
        entries.sort { $0.keyword.count > $1.keyword.count }

        unifiedKeywordTable   = entries
        unifiedKeywordStrings = entries.map { $0.keyword }

        // 4. Precompute keywords requiring letter-boundary guards per C64 ROM rules
        keywordsWithLongerSibling = Set(
            unifiedKeywordStrings.filter { kw in
                unifiedKeywordStrings.contains(where: {
                    $0.count > kw.count && $0.hasPrefix(kw)
                })
            }
        )

        // Refined variant used by the tokenizer's guard: only siblings that
        // continue with a LETTER matter, because only those can win when a
        // letter follows the short keyword. PRINT# does not put PRINT in
        // this set ('#' is not a letter), so PRINTA still crunches as
        // PRINT + A, exactly like the ROM.
        keywordsWithLongerLetterSibling = Set(
            unifiedKeywordStrings.filter { kw in
                unifiedKeywordStrings.contains(where: { longer in
                    guard longer.count > kw.count && longer.hasPrefix(kw) else { return false }
                    let nextChar = longer[longer.index(longer.startIndex, offsetBy: kw.count)]
                    return nextChar.isLetter
                })
            }
        )
    }

    private let standardBasicV2Keywords: [String] = [
        "END", "FOR", "NEXT", "DATA", "INPUT#", "INPUT", "DIM", "READ", "LET",
        "GOTO", "RUN", "IF", "RESTORE", "GOSUB", "RETURN", "REM", "STOP", "ON",
        "WAIT", "LOAD", "SAVE", "VERIFY", "DEF", "POKE", "PRINT#", "PRINT",
        "CONT", "LIST", "CLR", "CMD", "SYS", "OPEN", "CLOSE", "GET", "NEW",
        "TAB(", "TO", "FN", "SPC(", "THEN", "NOT", "STEP", "+", "-", "*", "/",
        "^", "AND", "OR", ">", "=", "<",
        "SGN", "INT", "ABS", "USR", "FRE", "POS", "SQR", "RND", "LOG",
        "EXP", "COS", "SIN", "TAN", "ATN", "PEEK", "LEN", "STR$",
        "VAL", "ASC", "CHR$", "LEFT$", "RIGHT$", "MID$", "GO",
    ]
}

// MARK: - Plugin Directory

extension BasicDialectManager {

    static var pluginDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("C64IDE/Plugins")
    }

    func loadDefaultPlugins() {
        // ~/Library/Application Support/C64IDE/Plugins/
        let dir = Self.pluginDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        loadPlugins(from: dir)

        // ~/.c64ide/plugins/
        let homePlugins = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".c64ide/plugins")
        if FileManager.default.fileExists(atPath: homePlugins.path) {
            loadPlugins(from: homePlugins)
        }

        // App bundle Resources/Plugins/
        if let bundlePlugins = Bundle.main.url(forResource: "Plugins", withExtension: nil) {
            loadPlugins(from: bundlePlugins)
        }

        // App bundle Resources/ directly
        if let resourcePath = Bundle.main.resourceURL {
            let pluginsDir = resourcePath.appendingPathComponent("Plugins")
            if FileManager.default.fileExists(atPath: pluginsDir.path) {
                loadPlugins(from: pluginsDir)
            }
            loadPlugins(from: resourcePath)
        }

        availableDialects.sort { $0.name < $1.name }

        if !availableDialects.isEmpty {
            logger.info("\(self.availableDialects.count) dialect(s) available: \(self.availableDialects.map { "\($0.name) v\($0.version ?? "?")" }.joined(separator: ", "))")
        }
    }
}

