//  BuildConfiguration.swift
//  C64 IDE
//
//  Persistent build configuration. Stores paths to toolchains, emulator binaries,
//  linker options, debug settings, and platform-specific flags.

import Foundation

/// Persistent build configuration for the IDE.
class BuildConfiguration: Codable {

    // MARK: - Toolchain Paths

    /// Path to the ca65 assembler binary.
    var ca65Path: String = "/usr/local/bin/ca65"

    /// Path to the ld65 linker binary.
    var ld65Path: String = "/usr/local/bin/ld65"

    /// Path to the cc65 C compiler (optional, reserved for future use).
    var cc65Path: String = "/usr/local/bin/cc65"

    // MARK: - Emulator Paths

    /// Path to VICE x64sc emulator.
    var vicePath: String = "/Applications/VICE/x64sc.app/Contents/MacOS/x64sc"

    /// Path to VICE x128 emulator (C128). Used when the active dialect targets C128.
    var x128Path: String = "/Applications/VICE/x128.app/Contents/MacOS/x128"

    /// Path to VICE xpet emulator (PET). Used when the active dialect targets PET.
    var xpetPath: String = "/Applications/VICE/xpet.app/Contents/MacOS/xpet"

    /// Path to VICE xvic emulator (VIC-20). Used when the active dialect targets
    /// the VIC-20, e.g. the Super Expander.
    var xvicPath: String = "/Applications/VICE/xvic.app/Contents/MacOS/xvic"

    /// Optional VIC-20 Super Expander cartridge ROM image, passed to xvic as
    /// `-cartse`. Without it the VIC-20 boots with expansion RAM but no Super
    /// Expander keywords, so SE programs load and then fail with ?SYNTAX ERROR.
    var xvicSuperExpanderROM: String = ""

    /// Path to xemu's MEGA65 emulator binary (xmega65).
    var xemuPath: String = "/usr/local/bin/xmega65"

    // MARK: - Build Settings

    /// Default output directory (relative to source file).
    var outputDirectory: String = "build"

    /// Additional ca65 include paths.
    var includePaths: [String] = []

    /// Additional ca65 defines.
    var defines: [String: String] = [:]

    /// Target platform for ca65 (e.g., "c64", "c128", "plus4").
    var targetPlatform: String = "c64"

    /// Custom linker config file path. `nil` uses built-in C64 config.
    var customLinkerConfig: String? = nil

    /// Whether to generate debug info (.dbg).
    var generateDebugInfo: Bool = true

    /// Whether to generate a listing file (.lst).
    var generateListing: Bool = false

    // MARK: - Emulator Settings

    /// VICE launch arguments.
    var viceExtraArgs: [String] = []

    /// Extra xemu (xmega65) launch arguments. Appended after auto-generated flags.
    var xemuExtraArgs: [String] = []

    /// Auto-run program after loading in VICE.
    var viceAutoRun: Bool = true

    /// Strip unnecessary whitespace when tokenizing BASIC.
    var basicStripWhitespace: Bool = false

    /// VICE ROM images (empty strings use VICE defaults).
    var viceKernalROM: String = ""
    var viceBasicROM: String = ""
    var viceChargenROM: String = ""

    /// C64 model for VICE (empty = default).
    var viceC64Model: String = ""

    /// SID model: 0 = 6581, 1 = 8580, 2 = 8580 + digiboost.
    var viceSIDModel: Int = 0

    /// PAL or NTSC video standard.
    var viceVideoStandard: String = "pal"

    /// Preferred emulator for C64 targets.
    var preferredC64Emulator: RunTarget = .vc64

    // MARK: - Decoding

    init() {}

    /// Decodes tolerantly: every key is optional and falls back to its default.
    ///
    /// The synthesized `init(from:)` throws `keyNotFound` for any property
    /// missing from the JSON, and `load()` turns a throw into "start from
    /// defaults" — so adding a single new setting would have silently discarded
    /// every path the user had configured. Decoding key by key keeps old
    /// configuration files loadable as the schema grows, and a field whose type
    /// changed falls back to its default instead of taking the file down.
    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }

        ca65Path  = value(.ca65Path,  ca65Path)
        ld65Path  = value(.ld65Path,  ld65Path)
        cc65Path  = value(.cc65Path,  cc65Path)

        vicePath  = value(.vicePath,  vicePath)
        x128Path  = value(.x128Path,  x128Path)
        xpetPath  = value(.xpetPath,  xpetPath)
        xvicPath  = value(.xvicPath,  xvicPath)
        xemuPath  = value(.xemuPath,  xemuPath)
        xvicSuperExpanderROM = value(.xvicSuperExpanderROM, xvicSuperExpanderROM)

        outputDirectory   = value(.outputDirectory, outputDirectory)
        includePaths      = value(.includePaths, includePaths)
        defines           = value(.defines, defines)
        targetPlatform    = value(.targetPlatform, targetPlatform)
        customLinkerConfig = (try? c.decodeIfPresent(String.self, forKey: .customLinkerConfig)) ?? nil
        generateDebugInfo = value(.generateDebugInfo, generateDebugInfo)
        generateListing   = value(.generateListing, generateListing)

        viceExtraArgs        = value(.viceExtraArgs, viceExtraArgs)
        xemuExtraArgs        = value(.xemuExtraArgs, xemuExtraArgs)
        viceAutoRun          = value(.viceAutoRun, viceAutoRun)
        basicStripWhitespace = value(.basicStripWhitespace, basicStripWhitespace)
        viceKernalROM        = value(.viceKernalROM, viceKernalROM)
        viceBasicROM         = value(.viceBasicROM, viceBasicROM)
        viceChargenROM       = value(.viceChargenROM, viceChargenROM)
        viceC64Model         = value(.viceC64Model, viceC64Model)
        viceSIDModel         = value(.viceSIDModel, viceSIDModel)
        viceVideoStandard    = value(.viceVideoStandard, viceVideoStandard)
        preferredC64Emulator = value(.preferredC64Emulator, preferredC64Emulator)
    }

    // MARK: - Persistence

    private static let configFileName = "c64ide_build.json"

    private static var configURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("C64IDE", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(configFileName)
    }

    /// Loads configuration from disk. Returns defaults if the file is missing or invalid.
    static func load() -> BuildConfiguration {
        let url = configURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(BuildConfiguration.self, from: data) else {
            return BuildConfiguration()
        }
        return config
    }

    /// Saves the current configuration to disk atomically.
    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.configURL, options: .atomic)
    }

    // MARK: - Validation

    /// Validates required tool paths for a specific run target.
    /// - Parameter target: The emulator target the user intends to launch.
    ///   Only that target's binary is validated. Pass `nil` to validate only the toolchain.
    /// - Returns: An array of error messages for missing or non-executable files.
    func validatePaths(for target: RunTarget? = nil) -> [String] {
        var errors: [String] = []

        // Toolchain — always required for assembly builds.
        if !FileManager.default.isExecutableFile(atPath: ca65Path) {
            errors.append("ca65 not found at: \(ca65Path)")
        }
        if !FileManager.default.isExecutableFile(atPath: ld65Path) {
            errors.append("ld65 not found at: \(ld65Path)")
        }

        // Emulator binary — only validate the one we're actually going to launch.
        // Target-aware validation prevents spurious "emulator not found" errors
        // when the user runs a target that doesn't require that emulator.
        switch target {
        case .viceX64sc:
            if !FileManager.default.isExecutableFile(atPath: vicePath) {
                let alternatives = [
                    "/Applications/VICE/x64sc.app/Contents/MacOS/x64sc",
                    "/opt/homebrew/bin/x64sc",
                    "/usr/local/bin/x64sc",
                ]
                if let found = alternatives.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
                    // Self-heal: adopt the working binary for this session so the
                    // launch that follows validation actually uses it. Previously
                    // we suppressed the error here but kept the stale vicePath,
                    // so validation passed and the launch then failed anyway.
                    // Intentionally not persisted - Preferences and autoDetect()
                    // remain the ways to save a path change.
                    vicePath = found
                } else {
                    errors.append("VICE (x64sc) not found at: \(vicePath)")
                }
            }
        case .viceX128:
            if !x128Path.isEmpty && !FileManager.default.isExecutableFile(atPath: x128Path) {
                errors.append("VICE (x128) not found at: \(x128Path)")
            }
        case .viceXpet:
            if !xpetPath.isEmpty && !FileManager.default.isExecutableFile(atPath: xpetPath) {
                errors.append("VICE (xpet) not found at: \(xpetPath)")
            }
        case .viceXvic:
            if !xvicPath.isEmpty && !FileManager.default.isExecutableFile(atPath: xvicPath) {
                errors.append("VICE (xvic) not found at: \(xvicPath)")
            }
        case .xemu:
            if !xemuPath.isEmpty && !FileManager.default.isExecutableFile(atPath: xemuPath) {
                errors.append("xemu (xmega65) not found at: \(xemuPath)")
            }
        case .vc64, .u64, .mega65, .none:
            break
        }

        return errors
    }

    /// Auto-detects tool paths from common locations and Homebrew installations.
    func autoDetect() {
        let ca65Candidates = [
            "/opt/homebrew/bin/ca65",
            "/usr/local/bin/ca65",
            "\(NSHomeDirectory())/.local/bin/ca65",
        ]
        for path in ca65Candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                ca65Path = path
                let ld65 = (path as NSString).deletingLastPathComponent + "/ld65"
                if FileManager.default.isExecutableFile(atPath: ld65) {
                    ld65Path = ld65
                }
                break
            }
        }

        let viceCandidates = [
            "/Applications/VICE/x64sc.app/Contents/MacOS/x64sc",
            "/opt/homebrew/bin/x64sc",
            "/usr/local/bin/x64sc",
        ]
        for path in viceCandidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                vicePath = path
                break
            }
        }

        let x128Candidates = [
            "/Applications/VICE/x128.app/Contents/MacOS/x128",
            "/opt/homebrew/bin/x128",
            "/usr/local/bin/x128",
        ]
        for path in x128Candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                x128Path = path
                break
            }
        }

        let xpetCandidates = [
            "/Applications/VICE/xpet.app/Contents/MacOS/xpet",
            "/opt/homebrew/bin/xpet",
            "/usr/local/bin/xpet",
        ]
        for path in xpetCandidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                xpetPath = path
                break
            }
        }

        let xvicCandidates = [
            "/Applications/VICE/xvic.app/Contents/MacOS/xvic",
            "/opt/homebrew/bin/xvic",
            "/usr/local/bin/xvic",
        ]
        for path in xvicCandidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                xvicPath = path
                break
            }
        }
        // xemu — handles DEB package renaming and Homebrew/manual builds.
        let xemuCandidates = [
            "/opt/homebrew/bin/xmega65",
            "/usr/local/bin/xmega65",
            "/opt/homebrew/bin/xemu-xmega65",
            "/usr/local/bin/xemu-xmega65",
            "/Applications/Xemu.app/Contents/MacOS/xmega65",
        ]
        for path in xemuCandidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                xemuPath = path
                break
            }
        }
    }
}

