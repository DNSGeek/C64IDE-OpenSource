import Foundation

// ═══════════════════════════════════════════════════════════
// MARK: - RunOptions
// ═══════════════════════════════════════════════════════════

/// All parameters required to launch a run target.
///
/// Assembled by `MainWindowController.performBuildAndRun` and passed to
/// `EmulatorCoordinator.run(target:options:)`.
///
/// `@unchecked Sendable`: All stored properties are immutable (`let`). The only
/// reference-typed member (`DebugInfoParser` inside `DebugOptions`) is effectively
/// immutable after parsing. Instances are transferred once from a background
/// caller to the main actor and are never shared concurrently.
struct RunOptions: @unchecked Sendable {

    /// The compiled PRG file to load into the emulator.
    let prgURL: URL

    /// Disk mount plan, or `nil` for direct PRG inject mode.
    let diskPlan: DiskMountPlan?

    /// Whether to automatically execute `RUN` after loading the PRG.
    let autoRun: Bool

    /// Debug session options. `nil` indicates a plain run without a debugger.
    let debugOptions: DebugOptions?

    // ── Convenience init for plain runs ────────────────────

    init(prgURL: URL,
         diskPlan: DiskMountPlan? = nil,
         autoRun: Bool = true,
         debugOptions: DebugOptions? = nil) {
        self.prgURL        = prgURL
        self.diskPlan      = diskPlan
        self.autoRun       = autoRun
        self.debugOptions  = debugOptions
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - DebugOptions
// ═══════════════════════════════════════════════════════════

/// Parameters for a source-level debug session.
///
/// Only relevant when the active run target conforms to `DebuggableTarget`.
struct DebugOptions {

    /// Address at which to break before the program starts executing.
    /// Typically the PRG load address (`$0810` for ASM, `$0801` for BASIC).
    let entryPoint: UInt16

    /// Additional breakpoints defined in the editor gutter.
    let breakpoints: [UInt16]

    /// Parsed `.dbg` file for source-level debugging (PC → line mapping).
    /// `nil` if debug info was not generated or parsing failed.
    let debugInfo: DebugInfoParser?

    init(entryPoint: UInt16,
         breakpoints: [UInt16] = [],
         debugInfo: DebugInfoParser? = nil) {
        self.entryPoint  = entryPoint
        self.breakpoints = breakpoints
        self.debugInfo   = debugInfo
    }
}

