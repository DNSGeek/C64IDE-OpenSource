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
///   AppDelegate observes            → opens Map Editor, feeds charset
///

extension Notification.Name {
    /// Posted by `CharEditorViewController` whenever the charset data changes.
    /// `userInfo` keys: `"charsetData"` (Data, 2048 bytes), `"fgColor"` (Int), `"bgColor"` (Int)
    static let charsetDidChange = Notification.Name("com.c64ide.charsetDidChange")

    /// Posted when the user explicitly wants to send the current charset
    /// to the Map Editor (e.g. via a "Send to Map Editor" button).
    /// `userInfo` keys: same as `charsetDidChange`
    static let charsetSendToMapEditor = Notification.Name("com.c64ide.charsetSendToMapEditor")
}

// MARK: - CharSetData Extension (Notification Helper)

extension CharSetData {
    /// Posts a `.charsetDidChange` notification with the current charset state.
    func postDidChange() {
        let data = Data(toBytes())
        NotificationCenter.default.post(
            name: .charsetDidChange,
            object: nil,
            userInfo: [
                "charsetData": data,
                "fgColor": fgColor,
                "bgColor": bgColor
            ]
        )
    }

    /// Posts a `.charsetSendToMapEditor` notification with the current charset.
    func postSendToMapEditor() {
        let data = Data(toBytes())
        NotificationCenter.default.post(
            name: .charsetSendToMapEditor,
            object: nil,
            userInfo: [
                "charsetData": data,
                "fgColor": fgColor,
                "bgColor": bgColor
            ]
        )
    }
}

