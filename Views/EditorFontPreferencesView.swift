import Cocoa
import SwiftUI

// MARK: - Editor Font Preferences View

/// SwiftUI view for the "Editor Font" section in Preferences.
/// Can be shown standalone or composed into a tabbed preferences window.
struct EditorFontPreferencesView: View {
    @ObservedObject var viewModel: EditorFontPreferencesViewModel
    var onDismiss: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var accentColor: Color { colorScheme == .dark ? .cyan : Color(red: 0.05, green: 0.40, blue: 0.80) }
    private var dimText:     Color { colorScheme == .dark ? .gray : Color(white: 0.45) }
    private var previewFg:   Color { colorScheme == .dark ? Color(white: 0.85) : Color(white: 0.12) }
    private var previewBg:   Color { colorScheme == .dark ? Color(red: 0.08, green: 0.08, blue: 0.12) : Color(NSColor.windowBackgroundColor) }
    private var panelBg:     Color { colorScheme == .dark ? Color(red: 0.10, green: 0.10, blue: 0.13) : Color(NSColor.windowBackgroundColor) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            sectionHeader("Editor Font")

            Text("Changes apply to the source code editor only — tool windows and tab labels are not affected.")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(dimText.opacity(0.7))

            // ── Font Family ──────────────────────────────
            HStack {
                Text("Font Family:")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(dimText)
                    .frame(width: 120, alignment: .trailing)
                Picker("", selection: $viewModel.selectedFontName) {
                    ForEach(viewModel.availableFonts, id: \.self) { fontName in
                        Text(fontName)
                            .tag(fontName)
                    }
                }
                .labelsHidden()
                .frame(width: 260)
            }

            // ── Font Size ────────────────────────────────
            HStack {
                Text("Font Size:")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(dimText)
                    .frame(width: 120, alignment: .trailing)

                HStack(spacing: 8) {
                    Button(action: { viewModel.decreaseSize() }) {
                        Image(systemName: "minus")
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.bordered)

                    Text("\(Int(viewModel.fontSize)) pt")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(previewFg)
                        .frame(width: 50, alignment: .center)

                    Button(action: { viewModel.increaseSize() }) {
                        Image(systemName: "plus")
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.bordered)

                    Slider(value: $viewModel.fontSize, in: 9...36, step: 1.0)
                        .frame(width: 140)
                }
            }

            Divider().padding(.vertical, 4)

            // ── Preview ──────────────────────────────────
            sectionHeader("Preview")

            Text(viewModel.previewText)
                .font(Font(viewModel.previewNSFont))
                .foregroundColor(previewFg)
                .padding(12)
                .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
                .background(previewBg)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )

            Divider().padding(.vertical, 4)

            // ── Buttons ──────────────────────────────────
            HStack {
                Button("Reset to Defaults") {
                    viewModel.resetToDefaults()
                }
                .font(.system(.body, design: .monospaced))

                Spacer()

                Button("Cancel") {
                    onDismiss()
                }
                .font(.system(.body, design: .monospaced))
                .keyboardShortcut(.cancelAction)

                Button("Apply") {
                    viewModel.apply()
                    onDismiss()
                }
                .font(.system(.body, design: .monospaced))
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
        }
        .padding(20)
        .frame(width: 540, height: 400)
        .background(panelBg)
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 15, weight: .bold, design: .monospaced))
            .foregroundColor(accentColor)
    }
}

// MARK: - View Model

class EditorFontPreferencesViewModel: ObservableObject {
    @Published var selectedFontName: String
    @Published var fontSize: CGFloat

    /// Cached list of monospaced font families on this system.
    let availableFonts: [String]

    let previewText = """
    10 PRINT "HELLO, WORLD!"
    LDA #$01     ; 6502 assembly
    STA $D020    ; border color
    .scope Main  ; ca65 macro
    """

    init() {
        let mgr = EditorFontManager.shared
        self.selectedFontName = mgr.fontName
        self.fontSize = mgr.fontSize
        self.availableFonts = EditorFontManager.availableMonospacedFonts

        // If the current font isn't in the list (e.g. uninstalled),
        // add it so the picker still shows the right selection.
        if !availableFonts.contains(mgr.fontName) {
            // We already captured it above — the picker will just show
            // the raw name; user can switch to something installed.
        }
    }

    /// The NSFont for the live preview area.
    var previewNSFont: NSFont {
        NSFont(name: selectedFontName, size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    func increaseSize() {
        fontSize = min(fontSize + 1, 36)
    }

    func decreaseSize() {
        fontSize = max(fontSize - 1, 9)
    }

    func resetToDefaults() {
        selectedFontName = "SFMono-Regular"
        fontSize = 13
    }

    /// Commit the chosen font to EditorFontManager (which persists
    /// to UserDefaults and posts the change notification).
    func apply() {
        let mgr = EditorFontManager.shared
        mgr.fontName = selectedFontName
        mgr.fontSize = fontSize
    }
}

