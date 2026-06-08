//  AppTheme.swift
//  C64 IDE
//
//  Centralized color palette and theme management. All views should read colors
//  from `AppTheme.current` rather than using hardcoded NSColor literals.
//
//  To react to theme changes, observe `.appThemeDidChange` on `NotificationCenter.default`
//  and call `needsDisplay = true` (or re-apply attributed-string colors).

import AppKit

// MARK: - Notification

extension Notification.Name {
    static let appThemeDidChange = Notification.Name("appThemeDidChange")
}

// MARK: - AppTheme

/// Centralised colour palette for C64 IDE.
/// Provides dark and light modes with consistent syntax highlighting, panel styling,
/// and editor theming.
final class AppTheme {

    // MARK: - Singleton / active theme

    /// The currently active theme. Defaults to dark unless the user has previously selected light.
    static var current: AppTheme = {
        let saved = UserDefaults.standard.string(forKey: "colorTheme")
        return (saved == "light") ? .light : .dark
    }()

    static let dark  = AppTheme(style: .dark)
    static let light = AppTheme(style: .light)

    enum Style: String {
        case dark, light
    }

    let style: Style
    var isDark: Bool { style == .dark }

    private init(style: Style) {
        self.style = style
    }

    // MARK: - Toggle

    /// Switches between dark and light themes and persists the choice.
    static func toggle() {
        current = (current.style == .dark) ? .light : .dark
        UserDefaults.standard.set(current.style.rawValue, forKey: "colorTheme")
        // Post on main queue after current run loop cycle to avoid triggering
        // reloadData/needsDisplay inside an active layout pass.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .appThemeDidChange, object: nil)
        }
    }

    // MARK: - Editor core
    var editorBackground: NSColor {
        isDark
            ? NSColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1)
            : NSColor(red: 0.97, green: 0.96, blue: 0.92, alpha: 1)   // warm paper
    }

    var defaultText: NSColor {
        isDark
            ? NSColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 1)
            : NSColor(red: 0.12, green: 0.12, blue: 0.15, alpha: 1)
    }

    var selectionBackground: NSColor {
        isDark
            ? NSColor(red: 0.20, green: 0.30, blue: 0.50, alpha: 1)
            : NSColor(red: 0.70, green: 0.83, blue: 1.00, alpha: 1)
    }

    var selectionForeground: NSColor {
        isDark ? .white : NSColor(red: 0.05, green: 0.05, blue: 0.10, alpha: 1)
    }

    var insertionPoint: NSColor {
        isDark
            ? NSColor(red: 0.40, green: 0.85, blue: 1.00, alpha: 1)
            : NSColor(red: 0.10, green: 0.45, blue: 0.85, alpha: 1)
    }

    // MARK: - Gutter
    var gutterBackground: NSColor {
        isDark
            ? NSColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1)
            : NSColor(red: 0.91, green: 0.90, blue: 0.86, alpha: 1)
    }

    var gutterBorder: NSColor {
        isDark
            ? NSColor(red: 0.20, green: 0.20, blue: 0.22, alpha: 1)
            : NSColor(red: 0.75, green: 0.73, blue: 0.68, alpha: 1)
    }

    var gutterLineNumber: NSColor {
        isDark
            ? NSColor(red: 0.45, green: 0.45, blue: 0.45, alpha: 1)
            : NSColor(red: 0.55, green: 0.52, blue: 0.48, alpha: 1)
    }

    var gutterCurrentLine: NSColor {
        isDark
            ? NSColor(red: 0.80, green: 0.80, blue: 0.40, alpha: 1)
            : NSColor(red: 0.55, green: 0.45, blue: 0.10, alpha: 1)
    }

    // MARK: - Panel backgrounds
    var panelBackground: NSColor {
        isDark
            ? NSColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1)
            : NSColor(red: 0.93, green: 0.92, blue: 0.88, alpha: 1)
    }

    var panelDetailBackground: NSColor {
        isDark
            ? NSColor(red: 0.08, green: 0.08, blue: 0.11, alpha: 1)
            : NSColor(red: 0.96, green: 0.95, blue: 0.91, alpha: 1)
    }

    var panelText: NSColor {
        isDark
            ? NSColor(red: 0.75, green: 0.75, blue: 0.75, alpha: 1)
            : NSColor(red: 0.20, green: 0.18, blue: 0.15, alpha: 1)
    }

    var statusLabel: NSColor {
        isDark
            ? NSColor(red: 0.55, green: 0.55, blue: 0.60, alpha: 1)
            : NSColor(red: 0.45, green: 0.43, blue: 0.40, alpha: 1)
    }

    // MARK: - Build / message log colours (severity)
    var logPlain: NSColor {
        isDark
            ? NSColor(red: 0.75, green: 0.75, blue: 0.75, alpha: 1)
            : NSColor(red: 0.25, green: 0.23, blue: 0.20, alpha: 1)
    }

    var logInfo: NSColor {
        isDark
            ? NSColor(red: 0.40, green: 0.85, blue: 1.00, alpha: 1)
            : NSColor(red: 0.05, green: 0.45, blue: 0.80, alpha: 1)
    }

    var logWarning: NSColor {
        isDark
            ? NSColor(red: 1.00, green: 0.75, blue: 0.20, alpha: 1)
            : NSColor(red: 0.70, green: 0.40, blue: 0.00, alpha: 1)
    }

    var logError: NSColor {
        isDark
            ? NSColor(red: 1.00, green: 0.45, blue: 0.40, alpha: 1)
            : NSColor(red: 0.80, green: 0.10, blue: 0.05, alpha: 1)
    }

    var logSuccess: NSColor {
        isDark
            ? NSColor(red: 0.40, green: 0.90, blue: 0.40, alpha: 1)
            : NSColor(red: 0.00, green: 0.50, blue: 0.00, alpha: 1)
    }

    var logCommand: NSColor {
        isDark
            ? NSColor(red: 0.90, green: 0.75, blue: 0.40, alpha: 1)   // amber
            : NSColor(red: 0.60, green: 0.40, blue: 0.05, alpha: 1)
    }

    // MARK: - Syntax: BASIC
    var syntaxKeyword: NSColor {
        isDark
            ? NSColor(red: 0.40, green: 0.85, blue: 1.00, alpha: 1)   // cyan
            : NSColor(red: 0.05, green: 0.40, blue: 0.80, alpha: 1)
    }

    var syntaxFunction: NSColor {
        isDark
            ? NSColor(red: 0.60, green: 1.00, blue: 0.60, alpha: 1)   // light green
            : NSColor(red: 0.05, green: 0.50, blue: 0.05, alpha: 1)
    }

    var syntaxOperator: NSColor {
        isDark
            ? NSColor(red: 1.00, green: 0.80, blue: 0.40, alpha: 1)   // warm amber
            : NSColor(red: 0.65, green: 0.38, blue: 0.00, alpha: 1)
    }

    var syntaxNumber: NSColor {
        isDark
            ? NSColor(red: 0.80, green: 0.60, blue: 1.00, alpha: 1)   // soft purple
            : NSColor(red: 0.45, green: 0.10, blue: 0.75, alpha: 1)
    }

    var syntaxString: NSColor {
        isDark
            ? NSColor(red: 1.00, green: 0.60, blue: 0.60, alpha: 1)   // salmon
            : NSColor(red: 0.75, green: 0.10, blue: 0.10, alpha: 1)
    }

    var syntaxComment: NSColor {
        isDark
            ? NSColor(red: 0.50, green: 0.50, blue: 0.50, alpha: 1)
            : NSColor(red: 0.50, green: 0.48, blue: 0.44, alpha: 1)
    }

    var syntaxLineNumber: NSColor {   // BASIC line numbers (the 10, 20, 30 kind)
        isDark
            ? NSColor(red: 0.90, green: 0.90, blue: 0.40, alpha: 1)   // yellow
            : NSColor(red: 0.55, green: 0.48, blue: 0.00, alpha: 1)
    }

    var syntaxVariable: NSColor {
        isDark
            ? NSColor(red: 0.90, green: 0.90, blue: 0.90, alpha: 1)
            : NSColor(red: 0.15, green: 0.15, blue: 0.18, alpha: 1)
    }

    var syntaxSystemVariable: NSColor {
        isDark
            ? NSColor(red: 1.00, green: 0.50, blue: 0.80, alpha: 1)   // pink
            : NSColor(red: 0.75, green: 0.05, blue: 0.55, alpha: 1)
    }

    var syntaxPoke: NSColor {
        isDark
            ? NSColor(red: 1.00, green: 0.70, blue: 0.20, alpha: 1)   // orange
            : NSColor(red: 0.70, green: 0.30, blue: 0.00, alpha: 1)
    }

    var syntaxSID: NSColor {
        isDark
            ? NSColor(red: 0.20, green: 0.80, blue: 0.80, alpha: 1)   // teal
            : NSColor(red: 0.00, green: 0.50, blue: 0.55, alpha: 1)
    }

    var syntaxVIC: NSColor {
        isDark
            ? NSColor(red: 0.40, green: 0.70, blue: 1.00, alpha: 1)   // blue
            : NSColor(red: 0.05, green: 0.35, blue: 0.75, alpha: 1)
    }

    var syntaxSeparator: NSColor {
        isDark
            ? NSColor(red: 0.70, green: 0.70, blue: 0.70, alpha: 1)
            : NSColor(red: 0.40, green: 0.38, blue: 0.35, alpha: 1)
    }

    var syntaxPlain: NSColor { defaultText }

    // MARK: - Syntax: Assembly (reuses several BASIC colours)
    var asmOpcode: NSColor    { syntaxKeyword }
    var asmDirective: NSColor { syntaxPoke }
    var asmVIC: NSColor       { syntaxVIC }
    var asmSID: NSColor       { syntaxSID }
    var asmRegister: NSColor  { syntaxSystemVariable }
    var asmNumber: NSColor    { syntaxNumber }
    var asmLabel: NSColor     { syntaxFunction }
    var asmComment: NSColor   { syntaxComment }
    var asmString: NSColor    { syntaxString }
    var asmMacro: NSColor     { syntaxLineNumber }
    var asmSeparator: NSColor { syntaxSeparator }
    var asmPlain: NSColor     { defaultText }

    // MARK: - Reference panel accent colours
    var refAccentBasic: NSColor { syntaxKeyword }   // cyan / blue
    var refAccentAsm: NSColor   { syntaxFunction }  // green
    var refCategory: NSColor    { syntaxLineNumber } // yellow / amber
    var refCommand: NSColor     { syntaxFunction }
    var refDescription: NSColor { syntaxComment }

    // MARK: - Selection highlight in editors (sprite, char, char ROM)
    var editorSelectionHighlight: NSColor {
        isDark
            ? NSColor(red: 0.40, green: 0.85, blue: 1.00, alpha: 1)  // cyan
            : NSColor(red: 0.05, green: 0.40, blue: 0.80, alpha: 1)
    }

    var editorSelectionBg: NSColor {
        isDark
            ? NSColor(red: 0.40, green: 0.85, blue: 1.00, alpha: 0.35)
            : NSColor(red: 0.05, green: 0.40, blue: 0.80, alpha: 0.25)
    }

    var editorHoverBg: NSColor {
        isDark
            ? NSColor(red: 0.40, green: 0.85, blue: 1.00, alpha: 0.20)
            : NSColor(red: 0.05, green: 0.40, blue: 0.80, alpha: 0.15)
    }

    // MARK: - NSAppearance for system controls
    var nsAppearance: NSAppearance? {
        NSAppearance(named: isDark ? .darkAqua : .aqua)
    }
}

