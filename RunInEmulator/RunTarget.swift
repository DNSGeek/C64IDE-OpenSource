import Foundation

// ═══════════════════════════════════════════════════════════
// MARK: - RunTarget
// ═══════════════════════════════════════════════════════════

/// Every target the IDE can send a built PRG to.
enum RunTarget: String, Codable, CaseIterable {

    // ── Emulators (local process) ──────────────────────────
    case vc64       // VirtualC64 — embedded, C64 only
    case viceX64sc  // VICE x64sc — C64, fallback / user preference
    case viceX128   // VICE x128  — C128, BASIC 7, BASIC 3.5
    case viceXpet    // VICE PET   - BASIC 4
    case xemu       // xmega65    — MEGA65, BASIC 65

    // ── Hardware (network delivery) ────────────────────────
    case u64        // Ultimate 64 via REST API
    case mega65     // MEGA65 via etherload


    // ─────────────────────────────────────────────────────────
    // MARK: Classification
    // ─────────────────────────────────────────────────────────

    var isEmulator: Bool {
        switch self {
        case .vc64, .viceX64sc, .viceX128, .viceXpet, .xemu: return true
        case .u64, .mega65:                        return false
        }
    }

    var isHardware: Bool { !isEmulator }

    /// True if the target supports the IDE's source-level debugger.
    /// xemu lacks a monitor protocol; hardware targets lack a local process.
    var isDebuggable: Bool {
        switch self {
        case .vc64, .viceX64sc, .viceX128, .viceXpet: return true
        default:                            return false
        }
    }

    /// True if the target manages a local OS process.
    var isProcessBased: Bool {
        switch self {
        case .vc64, .viceX64sc, .viceX128, .viceXpet, .xemu: return true
        case .u64, .mega65:                        return false
        }
    }


    // ─────────────────────────────────────────────────────────
    // MARK: Display
    // ─────────────────────────────────────────────────────────

    var displayName: String {
        switch self {
        case .vc64:      return "VirtualC64"
        case .viceX64sc: return "VICE x64sc"
        case .viceX128:  return "VICE x128"
        case .viceXpet:   return "VICE PET"
        case .xemu:      return "xemu (xmega65)"
        case .u64:       return "Ultimate 64"
        case .mega65:    return "MEGA65"
        }
    }

    /// SF Symbol name for toolbar and menu items.
    var systemImage: String {
        switch self {
        case .vc64, .viceX64sc, .viceX128, .viceXpet, .xemu: return "play.fill"
        case .u64, .mega65:                        return "play.rectangle.fill"
        }
    }


    // ─────────────────────────────────────────────────────────
    // MARK: Routing
    // ─────────────────────────────────────────────────────────

    /// Determines the appropriate run target based on the BASIC dialect's load
    /// address and user preferences.
    ///
    /// - Parameters:
    ///   - loadAddress: The dialect's `loadAddress`, or `nil` for assembly.
    ///   - c64Preference: The user's preferred C64 emulator. Defaults to `.vc64`.
    ///   - projectOverride: Per-project override. Takes absolute precedence.
    static func preferred(
        forLoadAddress loadAddress: Int?,
        c64Preference: RunTarget = .vc64,
        projectOverride: RunTarget? = nil
    ) -> RunTarget {
        // Project override wins unconditionally.
        if let override = projectOverride { return override }

        switch loadAddress {
        case Int(BasicTokenizer.mega65StartAddress):
            return .xemu
        case Int(BasicTokenizer.c128StartAddress):
            return .viceX128
        case Int(BasicTokenizer.petStartAddress):
            return .viceXpet
        default:
            // C64 and assembly targets use the user's preference.
            return c64Preference
        }
    }

    /// Convenience: resolve the preferred target from the currently active dialect.
    static func forActiveDialect(
        c64Preference: RunTarget = .vc64,
        projectOverride: RunTarget? = nil
    ) -> RunTarget {
        let loadAddress = BasicDialectManager.shared.activeDialect?.loadAddress
        return preferred(
            forLoadAddress: loadAddress,
            c64Preference: c64Preference,
            projectOverride: projectOverride
        )
    }


    // ─────────────────────────────────────────────────────────
    // MARK: C64-target cases
    // ─────────────────────────────────────────────────────────

    /// All targets that can run standard C64 software.
    /// Used to populate the preference picker in settings.
    static var c64Targets: [RunTarget] { [.vc64, .viceX64sc] }
}

