import Foundation

// ═══════════════════════════════════════════════════════════
// MARK: - C64 Timing Constants
// ═══════════════════════════════════════════════════════════

/// PAL/NTSC timing constants for raster-cycle calculations.
/// Used by both the Disassembler and the Debugger.
public struct C64Timing {
    /// Number of raster cycles per line.
    public let cyclesPerLine: Int
    /// Number of raster lines per frame.
    public let linesPerFrame: Int
    /// CPU cycles available on a bad line (VIC-II DMA steals the remaining cycles).
    public let badLineCycles: Int

    /// Total CPU cycles per frame.
    public var cyclesPerFrame: Int { cyclesPerLine * linesPerFrame }

    /// PAL timing configuration (63 cycles/line, 312 lines/frame, 23 bad-line CPU cycles).
    public static let pal = C64Timing(cyclesPerLine: 63, linesPerFrame: 312, badLineCycles: 23)

    /// NTSC timing configuration (65 cycles/line, 263 lines/frame, 25 bad-line CPU cycles).
    public static let ntsc = C64Timing(cyclesPerLine: 65, linesPerFrame: 263, badLineCycles: 25)

    /// Returns the timing configuration matching the active build configuration's video standard.
    static func from(config: BuildConfiguration) -> C64Timing {
        config.viceVideoStandard == "ntsc" ? .ntsc : .pal
    }

    /// Converts a cycle count to a fractional raster line value (2 decimal places).
    public func rasterLines(for cycles: Int) -> String {
        String(format: "%.2f", Double(cycles) / Double(cyclesPerLine))
    }

    /// Human-readable name of the timing standard ("PAL" or "NTSC").
    public var name: String { cyclesPerLine == 63 ? "PAL" : "NTSC" }
}

