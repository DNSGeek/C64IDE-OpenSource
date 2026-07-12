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
///
/// All colors are stored constants, initialized once per theme instance. Syntax
/// highlighting reads them in a tight loop over every token in a document, so
/// they must not be computed properties that allocate a fresh NSColor per access.
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
    let editorBackground: NSColor
    let defaultText: NSColor
    let selectionBackground: NSColor
    let selectionForeground: NSColor
    let insertionPoint: NSColor

    // MARK: - Gutter
    let gutterBackground: NSColor
    let gutterBorder: NSColor
    let gutterLineNumber: NSColor
    let gutterCurrentLine: NSColor

    // MARK: - Panel backgrounds
    let panelBackground: NSColor
    let panelDetailBackground: NSColor
    let panelText: NSColor
    let statusLabel: NSColor

    // MARK: - Build / message log colours (severity)
    let logPlain: NSColor
    let logInfo: NSColor
    let logWarning: NSColor
    let logError: NSColor
    let logSuccess: NSColor
    let logCommand: NSColor

    // MARK: - Syntax: BASIC
    let syntaxKeyword: NSColor
    let syntaxFunction: NSColor
    let syntaxOperator: NSColor
    let syntaxNumber: NSColor
    let syntaxString: NSColor
    let syntaxComment: NSColor
    let syntaxLineNumber: NSColor   // BASIC line numbers (the 10, 20, 30 kind)
    let syntaxVariable: NSColor
    let syntaxSystemVariable: NSColor
    let syntaxPoke: NSColor
    let syntaxSID: NSColor
    let syntaxVIC: NSColor
    let syntaxSeparator: NSColor
    let syntaxPlain: NSColor

    // MARK: - Syntax: Assembly (reuses several BASIC colours)
    let asmOpcode: NSColor
    let asmDirective: NSColor
    let asmVIC: NSColor
    let asmSID: NSColor
    let asmRegister: NSColor
    let asmNumber: NSColor
    let asmLabel: NSColor
    let asmComment: NSColor
    let asmString: NSColor
    let asmMacro: NSColor
    let asmSeparator: NSColor
    let asmPlain: NSColor

    // MARK: - Reference panel accent colours
    let refAccentBasic: NSColor   // cyan / blue
    let refAccentAsm: NSColor     // green
    let refCategory: NSColor      // yellow / amber
    let refCommand: NSColor
    let refDescription: NSColor

    // MARK: - Selection highlight in editors (sprite, char, char ROM)
    let editorSelectionHighlight: NSColor
    let editorSelectionBg: NSColor
    let editorHoverBg: NSColor

    // MARK: - NSAppearance for system controls
    var nsAppearance: NSAppearance? {
        NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    // MARK: - Init

    private init(style: Style) {
        self.style = style
        let dark = (style == .dark)

        // Editor core
        editorBackground = dark
            ? NSColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1)
            : NSColor(red: 0.97, green: 0.96, blue: 0.92, alpha: 1)   // warm paper
        defaultText = dark
            ? NSColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 1)
            : NSColor(red: 0.12, green: 0.12, blue: 0.15, alpha: 1)
        selectionBackground = dark
            ? NSColor(red: 0.20, green: 0.30, blue: 0.50, alpha: 1)
            : NSColor(red: 0.70, green: 0.83, blue: 1.00, alpha: 1)
        selectionForeground = dark
            ? .white
            : NSColor(red: 0.05, green: 0.05, blue: 0.10, alpha: 1)
        insertionPoint = dark
            ? NSColor(red: 0.40, green: 0.85, blue: 1.00, alpha: 1)
            : NSColor(red: 0.10, green: 0.45, blue: 0.85, alpha: 1)

        // Gutter
        gutterBackground = dark
            ? NSColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1)
            : NSColor(red: 0.91, green: 0.90, blue: 0.86, alpha: 1)
        gutterBorder = dark
            ? NSColor(red: 0.20, green: 0.20, blue: 0.22, alpha: 1)
            : NSColor(red: 0.75, green: 0.73, blue: 0.68, alpha: 1)
        gutterLineNumber = dark
            ? NSColor(red: 0.45, green: 0.45, blue: 0.45, alpha: 1)
            : NSColor(red: 0.55, green: 0.52, blue: 0.48, alpha: 1)
        gutterCurrentLine = dark
            ? NSColor(red: 0.80, green: 0.80, blue: 0.40, alpha: 1)
            : NSColor(red: 0.55, green: 0.45, blue: 0.10, alpha: 1)

        // Panel backgrounds
        panelBackground = dark
            ? NSColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1)
            : NSColor(red: 0.93, green: 0.92, blue: 0.88, alpha: 1)
        panelDetailBackground = dark
            ? NSColor(red: 0.08, green: 0.08, blue: 0.11, alpha: 1)
            : NSColor(red: 0.96, green: 0.95, blue: 0.91, alpha: 1)
        panelText = dark
            ? NSColor(red: 0.75, green: 0.75, blue: 0.75, alpha: 1)
            : NSColor(red: 0.20, green: 0.18, blue: 0.15, alpha: 1)
        statusLabel = dark
            ? NSColor(red: 0.55, green: 0.55, blue: 0.60, alpha: 1)
            : NSColor(red: 0.45, green: 0.43, blue: 0.40, alpha: 1)

        // Build / message log colours (severity)
        logPlain = dark
            ? NSColor(red: 0.75, green: 0.75, blue: 0.75, alpha: 1)
            : NSColor(red: 0.25, green: 0.23, blue: 0.20, alpha: 1)
        logInfo = dark
            ? NSColor(red: 0.40, green: 0.85, blue: 1.00, alpha: 1)
            : NSColor(red: 0.05, green: 0.45, blue: 0.80, alpha: 1)
        logWarning = dark
            ? NSColor(red: 1.00, green: 0.75, blue: 0.20, alpha: 1)
            : NSColor(red: 0.70, green: 0.40, blue: 0.00, alpha: 1)
        logError = dark
            ? NSColor(red: 1.00, green: 0.45, blue: 0.40, alpha: 1)
            : NSColor(red: 0.80, green: 0.10, blue: 0.05, alpha: 1)
        logSuccess = dark
            ? NSColor(red: 0.40, green: 0.90, blue: 0.40, alpha: 1)
            : NSColor(red: 0.00, green: 0.50, blue: 0.00, alpha: 1)
        logCommand = dark
            ? NSColor(red: 0.90, green: 0.75, blue: 0.40, alpha: 1)   // amber
            : NSColor(red: 0.60, green: 0.40, blue: 0.05, alpha: 1)

        // Syntax: BASIC
        syntaxKeyword = dark
            ? NSColor(red: 0.40, green: 0.85, blue: 1.00, alpha: 1)   // cyan
            : NSColor(red: 0.05, green: 0.40, blue: 0.80, alpha: 1)
        syntaxFunction = dark
            ? NSColor(red: 0.60, green: 1.00, blue: 0.60, alpha: 1)   // light green
            : NSColor(red: 0.05, green: 0.50, blue: 0.05, alpha: 1)
        syntaxOperator = dark
            ? NSColor(red: 1.00, green: 0.80, blue: 0.40, alpha: 1)   // warm amber
            : NSColor(red: 0.65, green: 0.38, blue: 0.00, alpha: 1)
        syntaxNumber = dark
            ? NSColor(red: 0.80, green: 0.60, blue: 1.00, alpha: 1)   // soft purple
            : NSColor(red: 0.45, green: 0.10, blue: 0.75, alpha: 1)
        syntaxString = dark
            ? NSColor(red: 1.00, green: 0.60, blue: 0.60, alpha: 1)   // salmon
            : NSColor(red: 0.75, green: 0.10, blue: 0.10, alpha: 1)
        syntaxComment = dark
            ? NSColor(red: 0.50, green: 0.50, blue: 0.50, alpha: 1)
            : NSColor(red: 0.50, green: 0.48, blue: 0.44, alpha: 1)
        syntaxLineNumber = dark
            ? NSColor(red: 0.90, green: 0.90, blue: 0.40, alpha: 1)   // yellow
            : NSColor(red: 0.55, green: 0.48, blue: 0.00, alpha: 1)
        syntaxVariable = dark
            ? NSColor(red: 0.90, green: 0.90, blue: 0.90, alpha: 1)
            : NSColor(red: 0.15, green: 0.15, blue: 0.18, alpha: 1)
        syntaxSystemVariable = dark
            ? NSColor(red: 1.00, green: 0.50, blue: 0.80, alpha: 1)   // pink
            : NSColor(red: 0.75, green: 0.05, blue: 0.55, alpha: 1)
        syntaxPoke = dark
            ? NSColor(red: 1.00, green: 0.70, blue: 0.20, alpha: 1)   // orange
            : NSColor(red: 0.70, green: 0.30, blue: 0.00, alpha: 1)
        syntaxSID = dark
            ? NSColor(red: 0.20, green: 0.80, blue: 0.80, alpha: 1)   // teal
            : NSColor(red: 0.00, green: 0.50, blue: 0.55, alpha: 1)
        syntaxVIC = dark
            ? NSColor(red: 0.40, green: 0.70, blue: 1.00, alpha: 1)   // blue
            : NSColor(red: 0.05, green: 0.35, blue: 0.75, alpha: 1)
        syntaxSeparator = dark
            ? NSColor(red: 0.70, green: 0.70, blue: 0.70, alpha: 1)
            : NSColor(red: 0.40, green: 0.38, blue: 0.35, alpha: 1)
        syntaxPlain = defaultText

        // Syntax: Assembly (reuses several BASIC colours)
        asmOpcode    = syntaxKeyword
        asmDirective = syntaxPoke
        asmVIC       = syntaxVIC
        asmSID       = syntaxSID
        asmRegister  = syntaxSystemVariable
        asmNumber    = syntaxNumber
        asmLabel     = syntaxFunction
        asmComment   = syntaxComment
        asmString    = syntaxString
        asmMacro     = syntaxLineNumber
        asmSeparator = syntaxSeparator
        asmPlain     = defaultText

        // Reference panel accent colours
        refAccentBasic = syntaxKeyword    // cyan / blue
        refAccentAsm   = syntaxFunction   // green
        refCategory    = syntaxLineNumber // yellow / amber
        refCommand     = syntaxFunction
        refDescription = syntaxComment

        // Selection highlight in editors (sprite, char, char ROM)
        editorSelectionHighlight = dark
            ? NSColor(red: 0.40, green: 0.85, blue: 1.00, alpha: 1)   // cyan
            : NSColor(red: 0.05, green: 0.40, blue: 0.80, alpha: 1)
        editorSelectionBg = dark
            ? NSColor(red: 0.40, green: 0.85, blue: 1.00, alpha: 0.35)
            : NSColor(red: 0.05, green: 0.40, blue: 0.80, alpha: 0.25)
        editorHoverBg = dark
            ? NSColor(red: 0.40, green: 0.85, blue: 1.00, alpha: 0.20)
            : NSColor(red: 0.05, green: 0.40, blue: 0.80, alpha: 0.15)
    }
}
