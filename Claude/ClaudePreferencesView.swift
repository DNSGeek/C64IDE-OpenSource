import SwiftUI
import AppKit

// MARK: - View Model

final class ClaudePreferencesViewModel: ObservableObject {
    @Published var apiKey: String = ""
    @Published var baseURLText: String
    @Published var customBaseURL: String
    @Published var selectedModelID: String
    @Published var thinkingEnabled: Bool
    @Published var maxTokensText: String
    @Published var errorMessage: String? = nil

    @Published var models: [ClaudeModelOption]
    @Published var modelsFetchedAt: Date?
    @Published var isRefreshingModels = false

    /// Changing the provider swaps in that provider's own key, model,
    /// override URL, and model list — none of it leaks across providers.
    @Published var selectedProvider: ClaudeAPIProvider {
        didSet {
            guard oldValue != selectedProvider else { return }
            loadSettings(for: selectedProvider)
        }
    }

    init() {
        let provider = ClaudeAPIService.shared.apiProvider
        selectedProvider = provider

        baseURLText     = ClaudeAPIService.shared.baseURLString
        thinkingEnabled = ClaudeAPIService.shared.thinkingEnabled
        maxTokensText   = String(ClaudeAPIService.shared.maxTokens)

        apiKey          = ClaudeAPIService.shared.loadAPIKey(for: provider) ?? ""
        customBaseURL   = ClaudeAPIService.shared.customBaseURL(for: provider)
        selectedModelID = ClaudeAPIService.shared.modelID(for: provider)
        models          = ClaudeModelCatalog.shared.models(for: provider)
        modelsFetchedAt = ClaudeModelCatalog.shared.fetchedAt(for: provider)

        // Opportunistic background refresh if the cached list is stale.
        Task { [weak self] in
            await self?.opportunisticRefresh(for: provider)
        }
    }

    /// Re-populates every provider-scoped field when the picker changes, so
    /// the form always reflects the newly selected provider's own saved
    /// settings instead of showing the previous provider's values.
    private func loadSettings(for provider: ClaudeAPIProvider) {
        apiKey          = ClaudeAPIService.shared.loadAPIKey(for: provider) ?? ""
        customBaseURL   = ClaudeAPIService.shared.customBaseURL(for: provider)
        selectedModelID = ClaudeAPIService.shared.modelID(for: provider)
        models          = ClaudeModelCatalog.shared.models(for: provider)
        modelsFetchedAt = ClaudeModelCatalog.shared.fetchedAt(for: provider)
        errorMessage    = nil

        Task { [weak self] in
            await self?.opportunisticRefresh(for: provider)
        }
    }

    private func opportunisticRefresh(for provider: ClaudeAPIProvider) async {
        // Custom has no default URL to fall back to; don't probe one.
        if provider == .custom,
           ClaudeAPIService.shared.customBaseURL(for: provider).isEmpty {
            return
        }
        let key = ClaudeAPIService.shared.loadAPIKey(for: provider)
        await ClaudeModelCatalog.shared.refreshIfStale(
            provider: provider,
            apiKey: key,
            baseURL: ClaudeAPIService.shared.effectiveBaseURL(for: provider)
        )
        await MainActor.run {
            self.syncFromCatalog(for: provider)
        }
    }

    /// The model name as typed, trimmed.
    var trimmedModelID: String {
        selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when the typed model name matches an entry in the fetched list,
    /// so its capabilities (thinking, token limit) are actually known.
    var isListedModel: Bool {
        models.contains { $0.id == trimmedModelID }
    }

    /// Catalog entry for the model currently typed/selected, or a neutral
    /// stand-in when it isn't in the list.
    var selectedModel: ClaudeModelOption {
        models.first { $0.id == trimmedModelID }
            ?? ClaudeAPIService.unlistedModelOption(id: trimmedModelID)
    }

    /// Valid max-token range for the currently selected model.
    var maxTokensRange: ClosedRange<Int> {
        ClaudeAPIService.maxTokensRange(for: selectedModel)
    }

    /// Force-refresh the model list for the provider currently being
    /// edited (Refresh button). Uses the in-progress apiKey/URL fields —
    /// not yet-saved settings — so the user can test before hitting Save.
    @MainActor
    func refreshModels() async {
        let provider = selectedProvider
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty || !provider.requiresAPIKey else {
            errorMessage = "Enter an API key before refreshing the model list."
            return
        }
        if provider == .custom,
           customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errorMessage = "Enter the Custom API URL before refreshing the model list."
            return
        }

        let urlString: String
        switch provider {
        case .anthropic:
            let trimmed = baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
            urlString = trimmed.isEmpty ? ClaudeAPIService.defaultBaseURLString : trimmed
        case .openai, .gemini, .custom:
            let trimmed = customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            urlString = trimmed.isEmpty ? provider.defaultBaseURL : trimmed
        }
        guard let baseURL = URL(string: urlString) else {
            errorMessage = "That API URL doesn't look valid."
            return
        }

        isRefreshingModels = true
        defer { isRefreshingModels = false }
        do {
            try await ClaudeModelCatalog.shared.forceRefresh(
                provider: provider,
                apiKey: trimmedKey,
                baseURL: baseURL,
                keepingSelected: trimmedModelID
            )
            errorMessage = nil
        } catch {
            errorMessage = "Model list refresh failed: \(error.localizedDescription)"
        }
        syncFromCatalog(for: provider)
    }

    private func syncFromCatalog(for provider: ClaudeAPIProvider) {
        guard provider == selectedProvider else { return } // user switched providers meanwhile
        models          = ClaudeModelCatalog.shared.models(for: provider)
        modelsFetchedAt = ClaudeModelCatalog.shared.fetchedAt(for: provider)
        // The model name is free text: a refresh never replaces what the
        // user typed, even if the new list doesn't contain it. Only fill
        // in a default when the field is empty.
        if trimmedModelID.isEmpty {
            selectedModelID = ClaudeAPIService.shared.modelID(for: provider)
        }
    }

    /// Validates and persists all settings for the currently selected
    /// provider. Returns true on success; on failure sets errorMessage and
    /// returns false.
    func save() -> Bool {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty || !selectedProvider.requiresAPIKey else {
            errorMessage = "API key cannot be empty."
            return false
        }

        let modelID = trimmedModelID
        guard !modelID.isEmpty else {
            errorMessage = "Enter a model name, or pick one from the list."
            return false
        }

        let trimmedAnthropicURL = baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCustomURL = customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)

        switch selectedProvider {
        case .anthropic:
            guard ClaudeAPIService.isValidBaseURLString(trimmedAnthropicURL, for: selectedProvider) else {
                errorMessage = "API URL must be a valid http:// or https:// address."
                return false
            }
        case .openai, .gemini, .custom:
            guard ClaudeAPIService.isValidBaseURLString(trimmedCustomURL, for: selectedProvider) else {
                errorMessage = selectedProvider == .custom
                    ? "Custom API URL is required and must be a valid http:// or https:// address."
                    : "Override API URL must be a valid http:// or https:// address, or left blank to use the default."
                return false
            }
        }

        let range = maxTokensRange
        guard let tokens = Int(maxTokensText.trimmingCharacters(in: .whitespaces)),
              range.contains(tokens) else {
            errorMessage = "Max tokens must be a whole number between \(range.lowerBound) and \(range.upperBound) for \(selectedModel.displayName)."
            return false
        }

        if trimmedKey.isEmpty {
            // Only reachable for Custom: no key means no key, so drop any
            // previously stored one rather than keep sending it.
            ClaudeAPIService.shared.deleteAPIKey(for: selectedProvider)
        } else {
            do {
                try ClaudeAPIService.shared.saveAPIKey(trimmedKey, for: selectedProvider)
            } catch {
                errorMessage = "Failed to save: \(error.localizedDescription)"
                return false
            }
        }

        ClaudeAPIService.shared.apiProvider = selectedProvider
        if selectedProvider == .anthropic {
            ClaudeAPIService.shared.baseURLString = trimmedAnthropicURL
        } else {
            ClaudeAPIService.shared.setCustomBaseURL(trimmedCustomURL, for: selectedProvider)
        }
        ClaudeAPIService.shared.setModelID(modelID, for: selectedProvider)
        ClaudeAPIService.shared.thinkingEnabled = thinkingEnabled
        ClaudeAPIService.shared.maxTokens = tokens

        errorMessage = nil
        return true
    }

    func delete() {
        ClaudeAPIService.shared.deleteAPIKey(for: selectedProvider)
        apiKey = ""
        errorMessage = nil
    }
}

// MARK: - View

struct ClaudePreferencesView: View {
    @ObservedObject var viewModel: ClaudePreferencesViewModel
    var onDismiss: () -> Void

    private var thinkingIsToggleable: Bool {
        guard viewModel.selectedProvider == .anthropic else { return false }
        switch viewModel.selectedModel.thinking {
        case .adaptive, .manualBudget: return true
        case .alwaysOn, .unsupported:  return false
        }
    }

    private var thinkingNote: String? {
        guard viewModel.selectedProvider == .anthropic else {
            return "Extended thinking is only wired up for Anthropic models right now."
        }
        if !viewModel.isListedModel {
            return "Extended thinking is off for models that aren't in the fetched list, since their capabilities are unknown."
        }
        switch viewModel.selectedModel.thinking {
        case .alwaysOn:
            return "This model manages thinking automatically; it cannot be turned off."
        case .unsupported:
            return "This model does not support extended thinking."
        case .adaptive, .manualBudget:
            return nil
        }
    }

    private var modelListCaption: String {
        if let fetched = viewModel.modelsFetchedAt {
            return "Model list fetched \(fetched.formatted(date: .abbreviated, time: .shortened))."
        }
        if viewModel.models.isEmpty {
            return viewModel.selectedProvider.requiresAPIKey
                ? "No models yet for \(viewModel.selectedProvider.displayName). Type a model name, or add an API key and Refresh."
                : "No models yet. Type a model name, or set the API URL and Refresh."
        }
        return "Built-in placeholder list for \(viewModel.selectedProvider.displayName). Save an API key, then Refresh to fetch the current list."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            Text("AI Settings")
                .font(.headline)

            // API Provider Selection
            Picker("API Provider:", selection: $viewModel.selectedProvider) {
                ForEach(ClaudeAPIProvider.allCases, id: \.rawValue) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.menu)

            Text(viewModel.selectedProvider.requiresAPIKey
                 ? "Enter your API key for \(viewModel.selectedProvider.displayName). It's stored securely in the macOS Keychain, separately for each provider."
                 : "API key is optional for a custom endpoint; leave it blank if your server doesn't use one. If set, it's stored securely in the macOS Keychain.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField(viewModel.selectedProvider.requiresAPIKey ? "API Key" : "API Key (optional)",
                        text: $viewModel.apiKey)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            // Base URL — Anthropic keeps its own override field (unchanged
            // behavior); every other provider shares one override field,
            // required for Custom and optional for the rest.
            VStack(alignment: .leading, spacing: 4) {
                if viewModel.selectedProvider == .anthropic {
                    HStack(spacing: 8) {
                        TextField(ClaudeAPIService.defaultBaseURLString, text: $viewModel.baseURLText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .autocorrectionDisabled()

                        if viewModel.baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
                            != ClaudeAPIService.defaultBaseURLString {
                            Button("Reset") {
                                viewModel.baseURLText = ClaudeAPIService.defaultBaseURLString
                            }
                            .controlSize(.small)
                            .help("Restore the default API URL")
                        }
                    }
                    Text("API URL. Change this to point at a locally-hosted server that speaks the same API.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    TextField(
                        viewModel.selectedProvider == .custom ? "Required, e.g. http://localhost:11434 or https://your-server" : "Optional override",
                        text: $viewModel.customBaseURL
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()

                    Text(viewModel.selectedProvider == .custom
                         ? "Base URL for your custom, OpenAI-compatible API endpoint. Plain http:// is allowed for self-hosted servers, but it sends your prompts and API key unencrypted; use https:// for anything outside your own network."
                         : "Optional. Point this at a compatible proxy instead of \(viewModel.selectedProvider.defaultBaseURL). Leave blank to use the default.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            // Model selection + refresh
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    // Editable: type any model name, or pick from the
                    // fetched list with the arrow. The list holds model IDs
                    // because that's what gets sent to the API.
                    Text("Model:")
                    ModelNameComboBox(
                        text: $viewModel.selectedModelID,
                        items: viewModel.models.map(\.id)
                    )
                    .frame(minWidth: 240)

                    if viewModel.isRefreshingModels {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("Refresh") {
                            Task { await viewModel.refreshModels() }
                        }
                        .controlSize(.small)
                        .help("Fetch the current model list for \(viewModel.selectedProvider.displayName)")
                    }
                }
                if !viewModel.trimmedModelID.isEmpty {
                    Text(viewModel.isListedModel
                         ? viewModel.selectedModel.displayName
                         : "Not in the fetched list; it will be sent as typed.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text(modelListCaption)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Extended thinking
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Enable extended thinking", isOn: $viewModel.thinkingEnabled)
                    .disabled(!thinkingIsToggleable)
                if let note = thinkingNote {
                    Text(note)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Max output tokens
            HStack(spacing: 8) {
                Text("Max output tokens:")
                TextField("", text: $viewModel.maxTokensText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 80)
                Text("(\(viewModel.maxTokensRange.lowerBound) - \(viewModel.maxTokensRange.upperBound))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Remove Key", role: .destructive) {
                    viewModel.delete()
                }
                .disabled(viewModel.apiKey.isEmpty)

                Spacer()

                Button("Cancel") {
                    onDismiss()
                }

                Button("Save") {
                    // save() validates the key and max tokens, persists
                    // everything, and reports success. Only dismiss then.
                    if viewModel.save() {
                        onDismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.selectedProvider.requiresAPIKey
                          && viewModel.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

// MARK: - Model Name Combo Box

/// Editable model-name field with a dropdown of known models: an NSComboBox,
/// since SwiftUI has no combo box on macOS 13. Typing updates `text`
/// directly; choosing a list entry replaces `text` with that entry.
private struct ModelNameComboBox: NSViewRepresentable {
    @Binding var text: String
    var items: [String]

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSComboBox {
        let box = NSComboBox()
        box.usesDataSource = false
        box.completes = true                // inline autocomplete from the list
        box.numberOfVisibleItems = 15
        box.isButtonBordered = true
        box.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        box.placeholderString = "Model name"
        box.delegate = context.coordinator
        box.addItems(withObjectValues: items)
        context.coordinator.items = items
        box.stringValue = text
        return box
    }

    func updateNSView(_ box: NSComboBox, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.items != items {
            box.removeAllItems()
            box.addItems(withObjectValues: items)
            context.coordinator.items = items
        }
        // Only push external changes (provider switch, list pick, default
        // fill-in). While typing, the delegate keeps both sides equal, so
        // this never fires mid-edit and never moves the cursor.
        if box.stringValue != text {
            box.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSComboBoxDelegate {
        var parent: ModelNameComboBox
        var items: [String] = []

        init(_ parent: ModelNameComboBox) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox else { return }
            parent.text = box.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox else { return }
            parent.text = box.stringValue
        }

        // Fires before the field's stringValue changes, so read the picked
        // item directly instead of box.stringValue.
        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let box = notification.object as? NSComboBox else { return }
            let index = box.indexOfSelectedItem
            guard index >= 0, index < box.numberOfItems,
                  let picked = box.itemObjectValue(at: index) as? String else { return }
            parent.text = picked
        }
    }
}
