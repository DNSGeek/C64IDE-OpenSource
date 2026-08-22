import Foundation

// MARK: - Charset Notification Bridge

/// Provides NotificationCenter-based communication between the Character Set Editor
/// and the Map Editor to keep them synchronized without direct coupling.
///
/// Flow:
///   CharEditor edits chars → posts `.charsetDidChange`
///   MapEditor observes    → updates its tile picker + grid
///
///   CharEditor "Send to Map Editor" → posts `.charsetSendToMapEditor`
///   AppDelegate observes            → opens Map Editor, then hands the
///                                     payload to it directly (an editor
///                                     created while the notification is
///                                     being delivered would never receive it)
///

extension Notification.Name {
    /// Posted by `CharEditorViewController` whenever the charset data changes.
    /// See `CharsetPayload` for the `userInfo` contents.
    static let charsetDidChange = Notification.Name("com.c64ide.charsetDidChange")

    /// Posted when the user explicitly wants to send the current charset
    /// to the Map Editor (e.g. via a "Send to Map Editor" button).
    /// `userInfo` keys: same as `charsetDidChange`
    static let charsetSendToMapEditor = Notification.Name("com.c64ide.charsetSendToMapEditor")
}

// MARK: - Charset Payload

/// The charset state carried by both charset notifications.
///
/// Passing this as a struct rather than reading raw `userInfo` keys at each
/// call site means the Map Editor can also be fed directly — which the app
/// delegate must do, because an observer registered while a notification is
/// being delivered does not receive that notification.
public struct CharsetPayload {
    /// Exactly 2048 bytes: 256 characters × 8 bytes.
    public let charset: Data
    public let fgColor: Int
    public let bgColor: Int
    public let isMultiColor: Bool
    public let multiColor1: Int
    public let multiColor2: Int

    private enum Key {
        static let charset = "charsetData"
        static let fg = "fgColor"
        static let bg = "bgColor"
        static let multi = "isMultiColor"
        static let mc1 = "multiColor1"
        static let mc2 = "multiColor2"
    }

    public var userInfo: [String: Any] {
        [
            Key.charset: charset,
            Key.fg: fgColor,
            Key.bg: bgColor,
            Key.multi: isMultiColor,
            Key.mc1: multiColor1,
            Key.mc2: multiColor2,
        ]
    }

    /// Reconstructs a payload from a notification, rejecting anything that
    /// does not carry a full character set.
    public init?(notification: Notification) {
        guard let info = notification.userInfo,
              let raw = info[Key.charset] as? Data,
              raw.count >= CharSetData.byteCount else { return nil }
        // Re-base into a fresh Data: a slice with a nonzero startIndex would
        // make integer subscripting downstream read out of bounds.
        charset = Data(raw.prefix(CharSetData.byteCount))
        fgColor = (info[Key.fg] as? Int) ?? 14
        bgColor = (info[Key.bg] as? Int) ?? 6
        isMultiColor = (info[Key.multi] as? Bool) ?? false
        multiColor1 = (info[Key.mc1] as? Int) ?? 1
        multiColor2 = (info[Key.mc2] as? Int) ?? 11
    }

    public init(charset: Data, fgColor: Int, bgColor: Int,
                isMultiColor: Bool, multiColor1: Int, multiColor2: Int) {
        self.charset = charset
        self.fgColor = fgColor
        self.bgColor = bgColor
        self.isMultiColor = isMultiColor
        self.multiColor1 = multiColor1
        self.multiColor2 = multiColor2
    }
}

// MARK: - CharSetData Extension (Notification Helper)

extension CharSetData {

    /// Snapshot of the current charset state, ready to post or hand over.
    var payload: CharsetPayload {
        CharsetPayload(charset: Data(toBytes()),
                       fgColor: fgColor,
                       bgColor: bgColor,
                       isMultiColor: isMultiColor,
                       multiColor1: multiColor1,
                       multiColor2: multiColor2)
    }

    /// Posts a `.charsetDidChange` notification with the current charset state.
    func postDidChange() {
        NotificationCenter.default.post(
            name: .charsetDidChange, object: nil, userInfo: payload.userInfo)
    }

    /// Posts a `.charsetSendToMapEditor` notification with the current charset.
    func postSendToMapEditor() {
        NotificationCenter.default.post(
            name: .charsetSendToMapEditor, object: nil, userInfo: payload.userInfo)
    }
}
