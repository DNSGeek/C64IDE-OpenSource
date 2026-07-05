import SwiftUI

// MARK: - View Model

final class ClaudePreferencesViewModel: ObservableObject {
    @Published var apiKey: String = ""
    @Published var errorMessage: String? = nil

    init() {
        apiKey = ClaudeAPIService.shared.loadAPIKey() ?? ""
    }

    func save() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "API key cannot be empty."
            return
        }
        do {
            try ClaudeAPIService.shared.saveAPIKey(trimmed)
            errorMessage = nil
        } catch {
            errorMessage = "Failed to save: \(error.localizedDescription)"
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            Text("Claude AI Settings")
                .font(.headline)

            Text("Enter your Anthropic API key. It will be stored securely in the macOS Keychain.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                SecureField("sk-ant-...", text: $viewModel.apiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
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
                    viewModel.save()
                    // save() sets errorMessage on failure (e.g. empty key) and
                    // clears it on success. Only dismiss once the key is stored.
                    if viewModel.errorMessage == nil {
                        onDismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

