import Foundation
import Metal

// ═══════════════════════════════════════════════════════════
// MARK: - RegisterState
// ═══════════════════════════════════════════════════════════

/// Snapshot of the 6502/8502 CPU registers.
///
/// Shared across all debuggable targets to provide a consistent view of CPU state.
struct RegisterState {
    var pc:    UInt16 = 0
    var a:     UInt8  = 0
    var x:     UInt8  = 0
    var y:     UInt8  = 0
    var sp:    UInt8  = 0
    var flags: UInt8  = 0   // NV-BDIZC

    var negative:  Bool { flags & 0x80 != 0 }
    var overflow:  Bool { flags & 0x40 != 0 }
    var brk:       Bool { flags & 0x10 != 0 }
    var decimal:   Bool { flags & 0x08 != 0 }
    var interrupt: Bool { flags & 0x04 != 0 }
    var zero:      Bool { flags & 0x02 != 0 }
    var carry:     Bool { flags & 0x01 != 0 }

    var flagsString: String {
        let bits: [(Bool, Character)] = [
            (negative, "N"), (overflow, "V"), (true,      "-"),
            (brk,      "B"), (decimal,  "D"), (interrupt, "I"),
            (zero,     "Z"), (carry,    "C"),
        ]
        return String(bits.map { $0.0 ? $0.1 : "-" })
    }

    /// Parses register state from a VICE monitor `r` command output line.
    ///
    /// Expected format: `.;0810 00 00 00 f7 2f 37 00100100 000 000    4538170`
    /// Index 7 contains the 8-character binary flags string.
    ///
    /// - Parameter line: Raw output line from the VICE monitor.
    /// - Returns: A populated `RegisterState`, or `nil` if the format is invalid.
    static func parse(_ line: String) -> RegisterState? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(".;") else { return nil }

        let parts = trimmed.dropFirst(2)
                     .split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 8 else { return nil }

        var s = RegisterState()
        s.pc    = UInt16(parts[0], radix: 16) ?? 0
        s.a     = UInt8 (parts[1], radix: 16) ?? 0
        s.x     = UInt8 (parts[2], radix: 16) ?? 0
        s.y     = UInt8 (parts[3], radix: 16) ?? 0
        s.sp    = UInt8 (parts[4], radix: 16) ?? 0

        let flagStr = String(parts[7])
        if flagStr.count == 8 {
            var f: UInt8 = 0
            for (i, ch) in flagStr.enumerated() where ch == "1" {
                f |= (0x80 >> i)
            }
            s.flags = f
        }
        return s
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - RunTargetProtocol
// ═══════════════════════════════════════════════════════════

/// Base capability for any target that can receive and execute a built PRG.
///
/// All concrete targets (emulators and hardware) conform to this protocol.
/// Avoid holding bare `RunTargetProtocol` references; prefer the more specific
/// `EmulatorTarget` or `HardwareTarget` protocols when emulator/hardware 
/// capabilities are needed.
protocol RunTargetProtocol: AnyObject {

    /// Identifies the concrete target type.
    var runTarget: RunTarget { get }

    /// Indicates whether the target is actively running.
    var isRunning: Bool { get }

    /// Starts the target with the provided configuration.
    ///
    /// May throw if required binaries are missing, network is unreachable, etc.
    /// Called internally by `EmulatorCoordinator`; do not invoke directly.
    func run(options: RunOptions) throws

    /// Stops the target. Safe to call even when already stopped.
    /// Called by `EmulatorCoordinator` before launching a new target.
    func stop()

    /// Routes log output to the IDE's build panel.
    /// Must be called on the main thread by the target implementation.
    @MainActor var onLog: ((String, MessageType) -> Void)? { get set }

    /// Called on the main thread when the target begins execution.
    @MainActor var onDidStart: (() -> Void)? { get set }

    /// Called on the main thread when the target terminates
    /// (process exit, network disconnect, etc.).
    @MainActor var onDidStop: (() -> Void)? { get set }
}

// ═══════════════════════════════════════════════════════════
// MARK: - EmulatorTarget
// ═══════════════════════════════════════════════════════════

/// Refines `RunTargetProtocol` with capabilities specific to local-process emulators.
///
/// Implemented by VICE (x64sc, x128), xemu, and VirtualC64.
/// Hardware targets (U64, MEGA65) do not conform to this protocol.
protocol EmulatorTarget: RunTargetProtocol {

    // ── Run control ────────────────────────────────────────
    func pause()
    func resume()
    func reset()

    // ── Memory inspection ──────────────────────────────────
    func readMemory(from start: UInt16, to end: UInt16) -> Data
    func writeByte(_ value: UInt8, to address: UInt16)

    // ── Disassembly ────────────────────────────────────────
    /// Returns `count` disassembly lines starting at `address`.
    /// Format matches VICE monitor style: `"C:0810  A9 00       LDA #$00"`
    func disassemble(count: Int, from address: UInt16) -> [String]

    // ── Video ──────────────────────────────────────────────
    /// Updates a Metal texture with the current video frame.
    /// Returns `nil` if the emulator manages its own window and does not expose a texture surface.
    func updateTexture(device: MTLDevice) -> MTLTexture?
}

/// Default no-op for targets that manage their own native window (e.g., xemu).
extension EmulatorTarget {
    func updateTexture(device: MTLDevice) -> MTLTexture? { nil }
}

// ═══════════════════════════════════════════════════════════
// MARK: - DebuggableTarget
// ═══════════════════════════════════════════════════════════

/// Extends `EmulatorTarget` with source-level debugging capabilities.
///
/// Implemented by VirtualC64 and VICE (x64sc, x128).
/// xemu does not conform to this protocol as it lacks a remote monitor protocol.
///
/// `DebuggerViewController` holds `(any DebuggableTarget)?` to abstract away
/// the underlying emulator implementation.
protocol DebuggableTarget: EmulatorTarget {

    // ── CPU state ──────────────────────────────────────────
    /// Current register state. Valid while paused; returns cached state while running.
    var registers: RegisterState { get }

    // ── Execution control ──────────────────────────────────
    func stepInto()
    func stepOver()
    func stepCycle()
    func finishLine()

    // ── Breakpoints ────────────────────────────────────────
    func setBreakpoint(at address: UInt16)
    func deleteBreakpoint(at address: UInt16)
    func deleteAllBreakpoints()
    func hasBreakpoint(at address: UInt16) -> Bool

    // ── Watchpoints ────────────────────────────────────────
    func setWatchpoint(at address: UInt16)
    func deleteWatchpoint(at address: UInt16)
    func hasWatchpoint(at address: UInt16) -> Bool

    // ── Callbacks ──────────────────────────────────────────
    /// Called on the main thread when the CPU hits a breakpoint or watchpoint.
    /// The `UInt16` parameter is the PC at the time of the break.
    @MainActor var onBreakpoint: ((UInt16) -> Void)? { get set }

    /// Called on the main thread when the CPU halts on an illegal opcode (JAM/KIL).
    /// The `UInt16` is the address of the offending instruction.
    /// Targets that cannot detect a jam (e.g., VICE lacks a direct monitor event)
    /// simply never invoke this. Distinct from `onBreakpoint` because a jam is fatal
    /// and requires a reset to recover.
    @MainActor var onJam: ((UInt16) -> Void)? { get set }

    /// Called on the main thread when execution pauses for any reason
    /// (breakpoint, step complete, manual pause).
    @MainActor var onPause: ((RegisterState) -> Void)? { get set }
}

/// Default no-op watchpoint implementations.
/// Callers that do not need watchpoint support inherit these stubs automatically.
extension DebuggableTarget {
    func setWatchpoint(at address: UInt16)    { }
    func deleteWatchpoint(at address: UInt16) { }
    func hasWatchpoint(at address: UInt16) -> Bool { false }
}

// ═══════════════════════════════════════════════════════════
// MARK: - HardwareTarget
// ═══════════════════════════════════════════════════════════

/// Protocol for physical hardware targets that receive a PRG over the network.
///
/// Implemented by U64 (REST API) and MEGA65 (etherload).
/// Hardware targets have no local process, no CPU inspection, and no debugger.
/// `isRunning` remains `false` from the IDE's perspective once delivery completes.
protocol HardwareTarget: RunTargetProtocol {

    /// Called on the main thread when the PRG has been successfully delivered.
    @MainActor var onDelivered: (() -> Void)? { get set }
}

/// Hardware targets are never "running" from the IDE's perspective.
/// Once the PRG is sent, execution is handed off to the physical device.
extension HardwareTarget {
    var isRunning: Bool { false }
    func stop() { }
}

