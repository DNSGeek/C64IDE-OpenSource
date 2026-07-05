import SwiftUI

// MARK: - View Model

final class ClaudePreferencesViewModel: ObservableObject {
    @Published var apiKey: String = ""
    @Published var selectedModelID: String
    @Published var thinkingEnabled: Bool
    @Published var maxTokensText: String
    @Published var errorMessage: String? = nil

    @Published var models: [ClaudeModelOption]
    @Published var modelsFetchedAt: Date?
    @Published var isRefreshingModels = false

    init() {
        apiKey          = ClaudeAPIService.shared.loadAPIKey() ?? ""
        selectedModelID = ClaudeAPIService.shared.model
        thinkingEnabled = ClaudeAPIService.shared.thinkingEnabled
        maxTokensText   = String(ClaudeAPIService.shared.maxTokens)
        models          = ClaudeModelCatalog.shared.models
        modelsFetchedAt = ClaudeModelCatalog.shared.fetchedAt

        // Opportunistic background refresh if the cached list is stale.
        // The picker shows the cached/seed list immediately and quietly
        // updates when the fetch lands.
        Task { [weak self] in
            await ClaudeModelCatalog.shared.refreshIfStale()
            guard let self else { return }
            await MainActor.run { self.syncFromCatalog() }
        }
    }

    /// Catalog entry for the currently selected model.
    var selectedModel: ClaudeModelOption {
        models.first { $0.id == selectedModelID } ?? ClaudeModelCatalog.seed[0]
    }

    /// Valid max-token range for the currently selected model.
    var maxTokensRange: ClosedRange<Int> {
        ClaudeAPIService.maxTokensRange(for: selectedModel)
    }

    /// Force-refresh the model list (Refresh button).
    @MainActor
    func refreshModels() async {
        isRefreshingModels = true
        defer { isRefreshingModels = false }
        do {
            try await ClaudeModelCatalog.shared.forceRefresh()
            errorMessage = nil
        } catch {
            errorMessage = "Model list refresh failed: \(error.localizedDescription)"
        }
        syncFromCatalog()
    }

    private func syncFromCatalog() {
        models          = ClaudeModelCatalog.shared.models
        modelsFetchedAt = ClaudeModelCatalog.shared.fetchedAt
        // If a refresh removed the selected model, fall back to the
        // service's resolution (default, or newest available).
        if !models.contains(where: { $0.id == selectedModelID }) {
            selectedModelID = ClaudeAPIService.shared.model
        }
    }

    /// Validates and persists all settings.
    /// Returns true on success; on failure sets errorMessage and returns false.
    func save() -> Bool {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            errorMessage = "API key cannot be empty."
            return false
        }

        let range = maxTokensRange
        guard let tokens = Int(maxTokensText.trimmingCharacters(in: .whitespaces)),
              range.contains(tokens) else {
            errorMessage = "Max tokens must be a whole number between \(range.lowerBound) and \(range.upperBound) for \(selectedModel.displayName)."
            return false
        }

        do {
            try ClaudeAPIService.shared.saveAPIKey(trimmedKey)
        } catch {
            errorMessage = "Failed to save: \(error.localizedDescription)"
            return false
        }

        ClaudeAPIService.shared.model           = selectedModelID
        ClaudeAPIService.shared.thinkingEnabled = thinkingEnabled
        ClaudeAPIService.shared.maxTokens       = tokens

        errorMessage = nil
        return true
    }

    func delete() {
        ClaudeAPIService.shared.deleteAPIKey()
        apiKey = ""
        errorMessage = nil
    }
}

// MARK: - View

struct ClaudePreferencesView: View {
    @ObservedObject var viewModel: ClaudePreferencesViewModel
    var onDismiss: () -> Void

    private var thinkingNote: String? {
        switch viewModel.selectedModel.thinking {
        case .alwaysOn:
            return "This model manages thinking automatically; it cannot be turned off."
        case .unsupported:
            return "This model does not support extended thinking."
        case .adaptive, .manualBudget:
            return nil
        }
    }

    private var thinkingIsToggleable: Bool {
        switch viewModel.selectedModel.thinking {
        case .adaptive, .manualBudget: return true
        case .alwaysOn, .unsupported:  return false
        }
    }

    private var modelListCaption: String {
        if let fetched = viewModel.modelsFetchedAt {
            return "Model list fetched \(fetched.formatted(date: .abbreviated, time: .shortened))."
        }
        return "Built-in model list. Save an API key, then Refresh to fetch the current list."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            Text("Claude AI Settings")
                .font(.headline)

            Text("Enter your Anthropic API key. It will be stored securely in the macOS Keychain.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("sk-ant-...", text: $viewModel.apiKey)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            Divider()

            // Model selection + refresh
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Picker("Model:", selection: $viewModel.selectedModelID) {
                        ForEach(viewModel.models) { option in
                            Text(option.displayName).tag(option.id)
                        }
                    }
                    .pickerStyle(.menu)

                    if viewModel.isRefreshingModels {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("Refresh") {
                            Task { await viewModel.refreshModels() }
                        }
                        .controlSize(.small)
                        .help("Fetch the current model list from the Anthropic API")
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
