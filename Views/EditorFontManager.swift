import Cocoa

/// Manages the editor font (name + size), persists to `UserDefaults`,
/// and posts notifications when the font changes so all open editors
/// can update in lockstep.
///
/// This controls ONLY the source-code editor font. Tool windows
/// (sprite editor, SID editor, etc.) and the tab bar keep their own
/// independent fonts.
class EditorFontManager {

    static let shared = EditorFontManager()

    /// Posted on the default `NotificationCenter` whenever the editor font changes.
    /// `object` is the `EditorFontManager` instance. No `userInfo`.
    static let fontDidChangeNotification = Notification.Name("EditorFontDidChange")

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let fontName = "EditorFontName"
        static let fontSize = "EditorFontSize"
    }

    // MARK: - Defaults

    /// The font we ship with if the user hasn't chosen anything yet.
    private static let defaultFontName = "SFMono-Regular"
    private static let defaultFontSize: CGFloat = 13
    private static let minimumFontSize: CGFloat = 9
    private static let maximumFontSize: CGFloat = 36

    // MARK: - Stored Properties

    /// The user's chosen font family name, or our built-in default.
    var fontName: String {
        get { UserDefaults.standard.string(forKey: Keys.fontName) ?? Self.defaultFontName }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.fontName)
            postChange()
        }
    }

    /// The user's chosen font size, clamped to a sensible range.
    var fontSize: CGFloat {
        get {
            let stored = CGFloat(UserDefaults.standard.float(forKey: Keys.fontSize))
            return stored > 0 ? stored.clamped(to: Self.minimumFontSize...Self.maximumFontSize) : Self.defaultFontSize
        }
        set {
            let clamped = newValue.clamped(to: Self.minimumFontSize...Self.maximumFontSize)
            UserDefaults.standard.set(Float(clamped), forKey: Keys.fontSize)
            postChange()
        }
    }

    // MARK: - Derived Fonts

    /// The current monospaced editor font at the user's chosen size.
    var codeFont: NSFont {
        if let font = NSFont(name: fontName, size: fontSize) {
            return font
        }
        // Fallback chain: SF Mono → system monospace
        if let sfMono = NSFont(name: "SF Mono", size: fontSize) {
            return sfMono
        }
        return NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    /// Bold variant for syntax-highlighted keywords / opcodes.
    var codeFontBold: NSFont {
        let base = codeFont
        return NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
    }

    /// Default text attributes for the editor (font + foreground color).
    var defaultAttributes: [NSAttributedString.Key: Any] {
        [
            .font: codeFont,
            .foregroundColor: AppTheme.current.defaultText,
        ]
    }

    /// A proportionally-sized font for the line-number gutter.
    /// Slightly smaller than the editor font so it stays unobtrusive.
    var gutterFont: NSFont {
        let gutterSize = max(fontSize - 3, Self.minimumFontSize)
        return NSFont.monospacedSystemFont(ofSize: gutterSize, weight: .regular)
    }

    // MARK: - Actions

    /// Bump the editor font size up by 1 point (⌘+).
    func increaseFontSize() {
        fontSize = min(fontSize + 1, Self.maximumFontSize)
    }

    /// Bump the editor font size down by 1 point (⌘−).
    func decreaseFontSize() {
        fontSize = max(fontSize - 1, Self.minimumFontSize)
    }

    /// Reset to defaults.
    func resetToDefaults() {
        UserDefaults.standard.removeObject(forKey: Keys.fontName)
        UserDefaults.standard.removeObject(forKey: Keys.fontSize)
        postChange()
    }

    // MARK: - Font Discovery

    /// Returns a list of monospaced (or mostly-monospaced) font family names
    /// available on this system, sorted alphabetically.
    static var availableMonospacedFonts: [String] {
        NSFontManager.shared.availableFontFamilies.filter { family in
            guard let font = NSFont(name: family, size: 13) else { return false }
            let descriptor = font.fontDescriptor
            // Accept anything the system considers monospaced or that has
            // "Mono" in the name (catches C64 Pro Mono, etc.)
            if descriptor.symbolicTraits.contains(.monoSpace) { return true }
            if family.localizedCaseInsensitiveContains("mono") { return true }
            if family.localizedCaseInsensitiveContains("courier") { return true }
            if family.localizedCaseInsensitiveContains("console") { return true }
            return false
        }.sorted()
    }

    // MARK: - Private

    private func postChange() {
        NotificationCenter.default.post(name: Self.fontDidChangeNotification, object: self)
    }

    private init() {}
}

// MARK: - Comparable Clamping Helper

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

