import SwiftUI

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

    /// Catalog entry for the currently selected model.
    var selectedModel: ClaudeModelOption {
        models.first { $0.id == selectedModelID } ?? ClaudeAPIService.shared.modelOption(for: selectedProvider)
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
        guard !trimmedKey.isEmpty else {
            errorMessage = "Enter an API key before refreshing the model list."
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
                keepingSelected: selectedModelID
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
        // If a refresh removed the selected model, fall back to the
        // service's resolution (default, or newest available).
        if !models.isEmpty, !models.contains(where: { $0.id == selectedModelID }) {
            selectedModelID = ClaudeAPIService.shared.modelID(for: provider)
        }
    }

    /// Validates and persists all settings for the currently selected
    /// provider. Returns true on success; on failure sets errorMessage and
    /// returns false.
    func save() -> Bool {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            errorMessage = "API key cannot be empty."
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

        do {
            try ClaudeAPIService.shared.saveAPIKey(trimmedKey, for: selectedProvider)
        } catch {
            errorMessage = "Failed to save: \(error.localizedDescription)"
            return false
        }

        ClaudeAPIService.shared.apiProvider = selectedProvider
        if selectedProvider == .anthropic {
            ClaudeAPIService.shared.baseURLString = trimmedAnthropicURL
        } else {
            ClaudeAPIService.shared.setCustomBaseURL(trimmedCustomURL, for: selectedProvider)
        }
        ClaudeAPIService.shared.setModelID(selectedModelID, for: selectedProvider)
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
            return "No models yet for \(viewModel.selectedProvider.displayName). Add an API key, then Refresh."
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

            Text("Enter your API key for \(viewModel.selectedProvider.displayName). It's stored securely in the macOS Keychain, separately for each provider.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("API Key", text: $viewModel.apiKey)
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
                        viewModel.selectedProvider == .custom ? "Required, e.g. https://your-server/v1" : "Optional override",
                        text: $viewModel.customBaseURL
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()

                    Text(viewModel.selectedProvider == .custom
                         ? "Base URL for your custom, OpenAI-compatible API endpoint."
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
                    if viewModel.models.isEmpty {
                        Text("No models available yet.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Picker("Model:", selection: $viewModel.selectedModelID) {
                            ForEach(viewModel.models) { option in
                                Text(option.displayName).tag(option.id)
                            }
                        }
                        .pickerStyle(.menu)
                    }

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
                .disabled(viewModel.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
