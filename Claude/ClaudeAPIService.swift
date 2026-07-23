import Foundation
import Security

// MARK: - Usage

struct ClaudeUsage {
    let inputTokens: Int
    let outputTokens: Int
}

enum ClaudeAPIProvider: String, CaseIterable, Codable, Hashable {
    case anthropic = "Anthropic"
    case openai = "OpenAI"
    case gemini = "Gemini"
    case custom = "Custom"

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic Claude"
        case .openai: return "OpenAI GPT"
        case .gemini: return "Google Gemini"
        case .custom: return "Custom API"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .anthropic: return "https://api.anthropic.com"
        case .openai: return "https://api.openai.com"
        case .gemini: return "https://generativelanguage.googleapis.com"
        case .custom: return ""
        }
    }

    var apiKeyHeader: String {
        switch self {
        case .anthropic: return "x-api-key"
        case .openai: return "Authorization"
        case .gemini: return "x-goog-api-key"
        case .custom: return "Authorization"
        }
    }

    var apiKeyPrefix: String {
        switch self {
        case .anthropic: return ""
        case .openai: return "Bearer "
        case .gemini: return ""
        case .custom: return "Bearer "
        }
    }
}

// MARK: - Chat Message

struct ClaudeChatMessage: Codable {
    let role: String   // "user" or "assistant"
    let content: String
}

// MARK: - API Errors

enum ClaudeAPIError: Error, LocalizedError {
    case noAPIKey
    case invalidResponse
    case rateLimited
    case apiError(String)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "No API key configured for the selected provider. Please add one in Preferences."
        case .invalidResponse:
            return "Received an unexpected response from the API."
        case .rateLimited:
            return "Rate limited by the API. Please wait a moment and try again."
        case .apiError(let msg):
            return "API error: \(msg)"
        case .networkError(let err):
            return "Network error: \(err.localizedDescription)"
        }
    }
}

// MARK: - Claude API Service

// Handles all communication with Claude and the other supported LLM
// providers. API keys are stored securely in the macOS Keychain, one entry
// per provider (see keychainAccountName(for:)) so switching providers never
// overwrites another provider's saved key.
final class ClaudeAPIService {

    // MARK: - Constants

    static let shared = ClaudeAPIService()

    private let keychainService = "com.c64ide.claude"
    /// Keychain account for the Anthropic key. Unchanged from the
    /// single-provider era so existing users' stored key is preserved;
    /// other providers get their own accounts (see keychainAccountName(for:)).
    private let anthropicKeychainAccount = "anthropic-api-key"

    /// Default API host. Used when no override is configured, and as the
    /// fallback if a stored override turns out to be malformed.
    static let defaultBaseURLString = "https://api.anthropic.com"

    private init() {}

    // MARK: - API Provider Settings

    private enum DefaultsKey {
        static let model           = "ClaudeModel"
        static let thinkingEnabled = "ClaudeThinkingEnabled"
        static let maxTokens       = "ClaudeMaxTokens"
        static let baseURL         = "ClaudeAPIBaseURL"
        static let provider        = "ClaudeAPIProvider"
        static let customBaseURL   = "ClaudeCustomBaseURL"
    }

    // Selected API provider. Defaults to Anthropic.
    var apiProvider: ClaudeAPIProvider {
        get {
            if let providerString = UserDefaults.standard.string(forKey: DefaultsKey.provider),
               let provider = ClaudeAPIProvider(rawValue: providerString) {
                return provider
            }
            return .anthropic
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: DefaultsKey.provider)
        }
    }

    // MARK: - Per-Provider Base URL Override

    private static func customBaseURLDefaultsKey(for provider: ClaudeAPIProvider) -> String {
        switch provider {
        case .anthropic: return "ClaudeCustomBaseURL_Anthropic" // unused (Anthropic uses baseURLString below)
        case .openai:    return "ClaudeCustomBaseURL_OpenAI"
        case .gemini:    return "ClaudeCustomBaseURL_Gemini"
        case .custom:    return DefaultsKey.customBaseURL // unchanged key, preserves existing Custom-provider users
        }
    }

    /// Override base URL for a specific provider. Empty means "use the
    /// provider's default" (or, for .custom, "not configured yet").
    func customBaseURL(for provider: ClaudeAPIProvider) -> String {
        let stored = UserDefaults.standard.string(forKey: Self.customBaseURLDefaultsKey(for: provider))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let stored, !stored.isEmpty else { return "" }
        return stored
    }

    func setCustomBaseURL(_ value: String, for provider: ClaudeAPIProvider) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = Self.customBaseURLDefaultsKey(for: provider)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(trimmed, forKey: key)
        }
    }

    /// Convenience for the currently selected provider.
    var customBaseURL: String {
        get { customBaseURL(for: apiProvider) }
        set { setCustomBaseURL(newValue, for: apiProvider) }
    }

    /// Effective base URL for a specific provider: Anthropic keeps using the
    /// original single-URL override (baseURLString) it always had; every
    /// other provider falls back to its own default unless a per-provider
    /// override has been set.
    func effectiveBaseURLString(for provider: ClaudeAPIProvider) -> String {
        switch provider {
        case .anthropic:
            return baseURLString
        case .openai, .gemini, .custom:
            let custom = customBaseURL(for: provider)
            return custom.isEmpty ? provider.defaultBaseURL : custom
        }
    }

    func effectiveBaseURL(for provider: ClaudeAPIProvider) -> URL {
        URL(string: effectiveBaseURLString(for: provider)) ?? URL(string: Self.defaultBaseURLString)!
    }

    /// Convenience for the currently selected provider.
    var effectiveBaseURLString: String { effectiveBaseURLString(for: apiProvider) }
    var effectiveBaseURL: URL { effectiveBaseURL(for: apiProvider) }

    // MARK: - Send Message

    // Send a message to the selected provider and return the assistant's
    // reply.
    // - Parameters:
    //   - history: Full conversation history (user + assistant turns)
    //   - context: Current IDE context snapshot
    // - Returns: The assistant's reply string and token usage
    func sendMessage(
        history: [ClaudeChatMessage],
        context: ClaudeIDEContext
    ) async throws -> (text: String, usage: ClaudeUsage) {

        guard let apiKey = loadAPIKey() else {
            throw ClaudeAPIError.noAPIKey
        }

        let systemPrompt = buildSystemPrompt(context: context)

        switch apiProvider {
        case .anthropic:
            return try await sendAnthropicMessage(
                history: history,
                systemPrompt: systemPrompt,
                apiKey: apiKey
            )
        case .openai:
            return try await sendOpenAIMessage(
                history: history,
                systemPrompt: systemPrompt,
                apiKey: apiKey
            )
        case .gemini:
            return try await sendGeminiMessage(
                history: history,
                systemPrompt: systemPrompt,
                apiKey: apiKey
            )
        case .custom:
            return try await sendCustomMessage(
                history: history,
                systemPrompt: systemPrompt,
                apiKey: apiKey
            )
        }
    }

    // MARK: - Provider-Specific Message Methods

    private func sendAnthropicMessage(
        history: [ClaudeChatMessage],
        systemPrompt: String,
        apiKey: String
    ) async throws -> (text: String, usage: ClaudeUsage) {

        let messagesPayload = history.map { ["role": $0.role, "content": $0.content] }

        let option = modelOption
        let requestMaxTokens = min(maxTokens, Self.maxTokensRange(for: option).upperBound)

        var body: [String: Any] = [
            "model":      option.id,
            "max_tokens": requestMaxTokens,
            "system":     systemPrompt,
            "messages":   messagesPayload,
        ]

        // Thinking configuration
        switch (thinkingEnabled, option.thinking) {
        case (true, .adaptive), (true, .alwaysOn):
            body["thinking"] = ["type": "adaptive"]
        case (true, .manualBudget):
            if requestMaxTokens > 1024 {
                let budget = max(1024, min(requestMaxTokens - 1, requestMaxTokens / 2))
                body["thinking"] = ["type": "enabled", "budget_tokens": budget]
            }
        case (true, .unsupported), (false, _):
            break
        }

        let bodyData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: messagesEndpoint)
        request.httpMethod = "POST"
        request.httpBody   = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(ClaudeAPIProvider.anthropic.apiKeyPrefix + apiKey,
                          forHTTPHeaderField: ClaudeAPIProvider.anthropic.apiKeyHeader)
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 300

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ClaudeAPIError.networkError(error)
        }

        return try handleAnthropicResponse(data, response)
    }

    private func sendOpenAIMessage(
        history: [ClaudeChatMessage],
        systemPrompt: String,
        apiKey: String
    ) async throws -> (text: String, usage: ClaudeUsage) {

        var messages: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        for msg in history {
            let role = msg.role == "user" ? "user" : "assistant"
            messages.append(["role": role, "content": msg.content])
        }

        let bodyData = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": messages,
            // max_tokens is deprecated on Chat Completions in favor of
            // max_completion_tokens (required on reasoning models, accepted
            // on the rest).
            "max_completion_tokens": maxTokens
        ])

        var request = URLRequest(url: openAIEndpoint)
        request.httpMethod = "POST"
        request.httpBody   = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiProvider.apiKeyPrefix + apiKey, forHTTPHeaderField: apiProvider.apiKeyHeader)
        request.timeoutInterval = 300

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ClaudeAPIError.networkError(error)
        }

        return try handleOpenAIResponse(data, response)
    }

    private func sendGeminiMessage(
        history: [ClaudeChatMessage],
        systemPrompt: String,
        apiKey: String
    ) async throws -> (text: String, usage: ClaudeUsage) {

        var contents: [[String: Any]] = []
        for msg in history {
            let role = msg.role == "user" ? "user" : "model"
            contents.append(["role": role, "parts": [["text": msg.content]]])
        }

        // The system prompt goes in systemInstruction, not as a leading
        // "user" turn — Gemini requires contents to strictly alternate
        // user/model, and a fake leading user turn breaks that whenever the
        // first real history entry is also a user turn.
        let bodyData = try JSONSerialization.data(withJSONObject: [
            "contents": contents,
            "systemInstruction": ["parts": [["text": systemPrompt]]],
            "generationConfig": ["maxOutputTokens": maxTokens]
        ])

        var request = URLRequest(url: geminiEndpoint)
        request.httpMethod = "POST"
        request.httpBody   = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiProvider.apiKeyPrefix + apiKey, forHTTPHeaderField: apiProvider.apiKeyHeader)
        request.timeoutInterval = 300

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ClaudeAPIError.networkError(error)
        }

        return try handleGeminiResponse(data, response)
    }

    private func sendCustomMessage(
        history: [ClaudeChatMessage],
        systemPrompt: String,
        apiKey: String
    ) async throws -> (text: String, usage: ClaudeUsage) {

        // handleGenericResponse assumes an OpenAI-compatible chat completions
        // response shape (choices[0].message.content), so the request body
        // needs to match that shape too: a "system" role message inside
        // "messages", not a top-level "system" key that a generic server
        // would just ignore.
        var messages: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        messages.append(contentsOf: history.map { ["role": $0.role, "content": $0.content] })

        let bodyData = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": messages,
            "max_completion_tokens": maxTokens
        ])

        var request = URLRequest(url: effectiveBaseURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.httpBody   = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiProvider.apiKeyPrefix + apiKey, forHTTPHeaderField: apiProvider.apiKeyHeader)
        request.timeoutInterval = 300

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ClaudeAPIError.networkError(error)
        }

        return try handleGenericResponse(data, response)
    }

    // MARK: - Response Handling Methods

    private func handleAnthropicResponse(_ data: Data, _ response: URLResponse) throws -> (text: String, usage: ClaudeUsage) {
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200: break
            case 429: throw ClaudeAPIError.rateLimited
            default:
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let error = json["error"] as? [String: Any],
                   let message = error["message"] as? String {
                    throw ClaudeAPIError.apiError(message)
                }
                throw ClaudeAPIError.apiError("HTTP \(http.statusCode)")
            }
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let text = content.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String else {
            throw ClaudeAPIError.invalidResponse
        }

        let usageDict = json["usage"] as? [String: Any]
        let usage = ClaudeUsage(
            inputTokens:  usageDict?["input_tokens"]  as? Int ?? usageDict?["prompt_tokens"]  as? Int ?? 0,
            outputTokens: usageDict?["output_tokens"] as? Int ?? usageDict?["completion_tokens"] as? Int ?? 0
        )

        return (text: text, usage: usage)
    }

    private func handleOpenAIResponse(_ data: Data, _ response: URLResponse) throws -> (text: String, usage: ClaudeUsage) {
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200: break
            case 429: throw ClaudeAPIError.rateLimited
            default:
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let error = json["error"] as? [String: Any],
                   let message = error["message"] as? String {
                    throw ClaudeAPIError.apiError(message)
                }
                throw ClaudeAPIError.apiError("HTTP \(http.statusCode)")
            }
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw ClaudeAPIError.invalidResponse
        }

        let usageDict = json["usage"] as? [String: Any]
        let usage = ClaudeUsage(
            inputTokens:  usageDict?["prompt_tokens"] as? Int ?? 0,
            outputTokens: usageDict?["completion_tokens"] as? Int ?? 0
        )

        return (text: content, usage: usage)
    }

    private func handleGeminiResponse(_ data: Data, _ response: URLResponse) throws -> (text: String, usage: ClaudeUsage) {
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200: break
            case 429: throw ClaudeAPIError.rateLimited
            default:
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let error = json["error"] as? [String: Any],
                   let message = error["message"] as? String {
                    throw ClaudeAPIError.apiError(message)
                }
                throw ClaudeAPIError.apiError("HTTP \(http.statusCode)")
            }
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let firstPart = parts.first,
              let text = firstPart["text"] as? String else {
            throw ClaudeAPIError.invalidResponse
        }

        let usageMeta = json["usageMetadata"] as? [String: Any]
        let usage = ClaudeUsage(
            inputTokens:  usageMeta?["promptTokenCount"] as? Int ?? 0,
            outputTokens: usageMeta?["candidatesTokenCount"] as? Int ?? 0
        )

        return (text: text, usage: usage)
    }

    private func handleGenericResponse(_ data: Data, _ response: URLResponse) throws -> (text: String, usage: ClaudeUsage) {
        // Generic response handling - assume OpenAI-style structure
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200: break
            case 429: throw ClaudeAPIError.rateLimited
            default:
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let error = json["error"] as? [String: Any],
                   let message = error["message"] as? String {
                    throw ClaudeAPIError.apiError(message)
                }
                throw ClaudeAPIError.apiError("HTTP \(http.statusCode)")
            }
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw ClaudeAPIError.invalidResponse
        }

        let usageDict = json["usage"] as? [String: Any]
        let usage = ClaudeUsage(
            inputTokens:  usageDict?["prompt_tokens"] as? Int ?? 0,
            outputTokens: usageDict?["completion_tokens"] as? Int ?? 0
        )
        return (text: content, usage: usage)
    }

    // MARK: - API Endpoint Properties

    private var openAIEndpoint: URL {
        effectiveBaseURL.appendingPathComponent("v1/chat/completions")
    }

    private var geminiEndpoint: URL {
        effectiveBaseURL.appendingPathComponent("v1beta/models/\(model):generateContent")
    }

    // MARK: - Utility Methods

    /// Validate a base URL for a specific provider. Empty is valid for any
    /// provider that has its own default to fall back to; Custom has no
    /// default, so an empty (or malformed) URL is rejected for it.
    static func isValidBaseURLString(_ string: String, for provider: ClaudeAPIProvider) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return provider != .custom }

        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            return false
        }
        return true
    }

    /// Back-compat convenience for callers that don't have a provider in
    /// hand; validates against Anthropic's rules (empty allowed).
    static func isValidBaseURLString(_ string: String) -> Bool {
        isValidBaseURLString(string, for: .anthropic)
    }

    // MARK: - Model Catalog Accessors

    /// Models offered in Preferences for a given provider. Sourced from
    /// ClaudeModelCatalog, which fetches each provider's own model-list
    /// endpoint with a 7-day disk cache and falls back to a per-provider
    /// seed list until the first successful fetch.
    static func availableModels(for provider: ClaudeAPIProvider) -> [ClaudeModelOption] {
        ClaudeModelCatalog.shared.models(for: provider)
    }

    /// Convenience for the currently selected provider.
    static var availableModels: [ClaudeModelOption] { availableModels(for: .anthropic) }

    static let defaultMaxTokens = 4096

    /// Best-known default model per provider. Anthropic's is a real,
    /// currently-offered model. The OpenAI/Gemini defaults are last-known
    /// IDs kept only as a pre-Refresh fallback — provider lineups move fast,
    /// so treat these as placeholders, not a source of truth.
    static func defaultModelID(for provider: ClaudeAPIProvider) -> String? {
        switch provider {
        case .anthropic: return "claude-sonnet-5"
        case .openai:    return "gpt-4o"
        case .gemini:    return "gemini-1.5-pro"
        case .custom:    return nil
        }
    }

    /// Absolute bounds for max output tokens, independent of model. The
    /// ceiling is deliberately below what current models accept (128k)
    /// because this client does not stream, and very large non-streamed
    /// responses risk request timeouts.
    static let absoluteMaxTokensRange = 256...ClaudeModelCatalog.absoluteMaxOutputTokens

    /// Valid max-token range for a specific model: the absolute range
    /// further capped by the model's own output limit.
    static func maxTokensRange(for option: ClaudeModelOption) -> ClosedRange<Int> {
        let lower = absoluteMaxTokensRange.lowerBound
        let upper = min(option.maxOutputTokens, absoluteMaxTokensRange.upperBound)
        return lower...max(lower, upper)
    }

    // MARK: - Settings (UserDefaults)

    private static func modelDefaultsKey(for provider: ClaudeAPIProvider) -> String {
        switch provider {
        case .anthropic: return DefaultsKey.model // unchanged key, preserves existing users' selection
        case .openai:    return "ClaudeModel_OpenAI"
        case .gemini:    return "ClaudeModel_Gemini"
        case .custom:    return "ClaudeModel_Custom"
        }
    }

    /// Selected model ID for a specific provider. Falls back to that
    /// provider's default (or its newest fetched model) if the stored value
    /// isn't in its catalog, e.g. after a model is retired.
    func modelID(for provider: ClaudeAPIProvider) -> String {
        let available = Self.availableModels(for: provider)
        let storedRaw = UserDefaults.standard.string(forKey: Self.modelDefaultsKey(for: provider))

        if let stored = storedRaw, available.contains(where: { $0.id == stored }) {
            return stored
        }
        if available.isEmpty, let stored = storedRaw, !stored.isEmpty {
            // Nothing fetched yet to validate against (e.g. Custom before
            // the first successful Refresh) — trust the last saved value.
            return stored
        }
        if let fallback = Self.defaultModelID(for: provider),
           available.contains(where: { $0.id == fallback }) {
            return fallback
        }
        return available.first?.id ?? Self.defaultModelID(for: provider) ?? ""
    }

    func setModelID(_ id: String, for provider: ClaudeAPIProvider) {
        UserDefaults.standard.set(id, forKey: Self.modelDefaultsKey(for: provider))
    }

    /// Convenience: the model ID for the currently selected provider.
    var model: String {
        get { modelID(for: apiProvider) }
        set { setModelID(newValue, for: apiProvider) }
    }

    /// The catalog entry for a provider's selected model.
    func modelOption(for provider: ClaudeAPIProvider) -> ClaudeModelOption {
        let id = modelID(for: provider)
        if let option = ClaudeModelCatalog.shared.option(for: id, provider: provider) {
            return option
        }
        if let first = Self.availableModels(for: provider).first {
            return first
        }
        // No catalog entry yet (e.g. Custom before the first Refresh) —
        // synthesize a placeholder instead of borrowing another provider's
        // model.
        return ClaudeModelOption(
            id: id.isEmpty ? "unknown" : id,
            displayName: id.isEmpty ? "No model selected" : id,
            thinking: .unsupported,
            maxOutputTokens: ClaudeModelCatalog.absoluteMaxOutputTokens,
            createdAt: nil
        )
    }

    /// Convenience for the currently selected provider.
    var modelOption: ClaudeModelOption { modelOption(for: apiProvider) }

    /// Whether extended thinking is requested. Defaults to true. Only
    /// wired up for Anthropic requests today — the other providers ignore
    /// it (see ClaudePreferencesView, which disables the toggle for them).
    /// Models with ClaudeThinkingSupport.alwaysOn think regardless of this
    /// setting.
    var thinkingEnabled: Bool {
        get { UserDefaults.standard.object(forKey: DefaultsKey.thinkingEnabled) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: DefaultsKey.thinkingEnabled) }
    }

    /// Max output tokens per response, shared across providers (a response-
    /// length preference rather than a provider-specific setting). Thinking
    /// tokens (when enabled, Anthropic only) count against this budget too.
    /// The stored value is clamped to the absolute range; any per-model cap
    /// is applied at request time, so switching models never silently
    /// rewrites the stored preference.
    var maxTokens: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: DefaultsKey.maxTokens)
            return Self.absoluteMaxTokensRange.contains(stored) ? stored : Self.defaultMaxTokens
        }
        set {
            let clamped = min(max(newValue, Self.absoluteMaxTokensRange.lowerBound),
                              Self.absoluteMaxTokensRange.upperBound)
            UserDefaults.standard.set(clamped, forKey: DefaultsKey.maxTokens)
        }
    }

    /// API host for Anthropic, as entered by the user. Defaults to
    /// Anthropic's endpoint; can be overridden to point at a locally-hosted
    /// server that speaks the same Messages API shape (e.g. a local proxy
    /// or self-hosted model server). Storing an empty string, or the
    /// default itself, clears the override rather than persisting a
    /// redundant value. Other providers use customBaseURL(for:) instead.
    var baseURLString: String {
        get {
            let stored = UserDefaults.standard.string(forKey: DefaultsKey.baseURL)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let stored, !stored.isEmpty else { return Self.defaultBaseURLString }
            return stored
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == Self.defaultBaseURLString {
                UserDefaults.standard.removeObject(forKey: DefaultsKey.baseURL)
            } else {
                UserDefaults.standard.set(trimmed, forKey: DefaultsKey.baseURL)
            }
        }
    }

    /// Parsed Anthropic base URL, falling back to the default if the stored
    /// string is somehow malformed (shouldn't happen given
    /// isValidBaseURLString, but this keeps requests from force-unwrapping
    /// a bad value).
    var baseURL: URL {
        URL(string: baseURLString) ?? URL(string: Self.defaultBaseURLString)!
    }

    /// POST endpoint for chat completions, derived from the effective base
    /// URL for the current provider.
    var messagesEndpoint: URL {
        effectiveBaseURL.appendingPathComponent("v1/messages")
    }

    // MARK: - Keychain

    private func keychainAccountName(for provider: ClaudeAPIProvider) -> String {
        switch provider {
        case .anthropic: return anthropicKeychainAccount // unchanged, preserves existing stored key
        case .openai:    return "openai-api-key"
        case .gemini:    return "gemini-api-key"
        case .custom:    return "custom-api-key"
        }
    }

    /// Save an API key to the Keychain for a specific provider.
    /// Uses SecItemUpdate first, falling back to SecItemAdd if the item doesn't exist yet.
    func saveAPIKey(_ key: String, for provider: ClaudeAPIProvider) throws {
        let data = Data(key.utf8)
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccountName(for: provider),
        ]
        let update: [CFString: Any] = [
            kSecValueData:      data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked,
        ]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData] = data
            addQuery[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus))
            }
        } else if status != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    /// Convenience: saves under the currently selected provider.
    func saveAPIKey(_ key: String) throws { try saveAPIKey(key, for: apiProvider) }

    /// Retrieve the API key for a specific provider. Returns nil if not set.
    func loadAPIKey(for provider: ClaudeAPIProvider) -> String? {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      keychainService,
            kSecAttrAccount:      keychainAccountName(for: provider),
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }
        return key
    }

    /// Convenience: loads for the currently selected provider.
    func loadAPIKey() -> String? { loadAPIKey(for: apiProvider) }

    func hasAPIKey(for provider: ClaudeAPIProvider) -> Bool { loadAPIKey(for: provider) != nil }

    /// Convenience: whether the currently selected provider has a key.
    var hasAPIKey: Bool { hasAPIKey(for: apiProvider) }

    /// Delete the stored API key for a specific provider.
    func deleteAPIKey(for provider: ClaudeAPIProvider) {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccountName(for: provider),
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Convenience: deletes for the currently selected provider.
    func deleteAPIKey() { deleteAPIKey(for: apiProvider) }

    // MARK: - System Prompt

    private func buildSystemPrompt(context: ClaudeIDEContext) -> String {
        var prompt = """
        You are an expert Commodore development assistant integrated into C64 IDE,
        a macOS IDE for Commodore 64 and MEGA65 development. Keep responses concise
        and practical — prefer short, correct code examples over lengthy prose.

        # Domain knowledge

        Hardware and platforms:
        - 6502/6510 (C64) and 45GS02 (MEGA65, 6502-superset) CPUs and addressing modes
        - 6502 is little-endian: low byte first in .word data and address pairs
        - C64 memory map: zero page ($00–$FF), stack ($0100–$01FF),
          screen RAM ($0400–$07E7), sprite pointers ($07FA–$07FF for default bank),
          BASIC ROM ($A000–$BFFF), I/O ($D000–$DFFF), color RAM ($D800–$DBE7),
          KERNAL ROM ($E000–$FFFF)
        - VIC-II ($D000–$D02E): sprites, raster, color, scrolling, display modes
        - SID ($D400–$D41C): three voices, ADSR, waveforms, filters
        - CIA1 ($DC00) and CIA2 ($DD00): keyboard, joystick, timers, serial, VIC bank select
        - MEGA65: enhanced VIC-IV, BASIC 65, additional memory, xemu/xmega65 emulation,
          etherload for deployment. Do not assume stock 6502/VIC-II behavior when the
          active project targets MEGA65.

        Toolchain:
        - ca65 assembler: .segment, .byte, .word, .res, .proc, .scope, .macro, .import,
          .export, .include, etc.
        - ld65 linker configuration files (.cfg) and segment layout
        - ca65 .dbg files drive VICE source-level debugging in this IDE
        - Standard formats: PRG, D64, D81, T64, TAP

        BASIC dialects:
        The IDE supports multiple BASIC dialects via plugins, including Commodore
        BASIC V2, BASIC 7 (C128), MEGA65 BASIC 65, Simons' BASIC, CommanderX16 BASIC,
        and VisionBASIC. The rules in the next section are defaults for stock
        Commodore BASIC V2. The active dialect is provided in the IDE context block
        below ("Active BASIC dialect: ...") and is authoritative — when generating
        or analysing BASIC code, follow that dialect's keywords, statement syntax,
        and reserved names rather than assuming V2. If a feature does not exist in
        the active dialect, say so instead of inventing it.

        Common patterns: raster IRQs, sprite multiplexing, double buffering,
        music drivers, KERNAL disk I/O, PETSCII vs screen-code conversion.

        BASIC 7 is supported as a dialect for C128 deployment, but the IDE does
        not currently target C128 assembly — suggest C64 or MEGA65 assembly only.

        # BASIC V2 conventions

        - There is no integer division. Division always returns a float.
        - Only the first two characters of a variable name are significant to the
          parser, but every character is stored verbatim in the program and costs
          bytes at runtime (MONEY = 5 bytes, MO = 2). Prefer two-character names
          in real code; use longer descriptive names only when illustrating a
          concept or when readability clearly outweighs the size cost.
        - A variable name is invalid if its first two characters spell a BASIC
          keyword (TO, OR, IF, ON, GO, FN, etc.) — this also breaks longer names
          that start with those two letters (e.g. TONY parses as TO NY).
        - ST, TI, and TI$ are reserved system variables: readable but not assignable
          by user code (TI$ accepts assignment to set the jiffy clock).
        - The first character of a variable name must be a letter; the second may be
          a letter or digit. Suffix $ for strings, % for integer-typed variables.
        - Do not use LET — it is never required.
        - Write BASIC keywords and variables in uppercase.
        - BASIC lines have a maximum of 80 characters including the line number.
          Prefer to keep them under 40 for readability on a 40-column screen.
        - Use whitespace freely for readability. The IDE strips non-essential
          whitespace when tokenizing to PRG, so it costs nothing at runtime.
        - String literals on screen go through PETSCII, not ASCII. When emitting raw
          .byte data for screen output, remember it is screen codes, not PETSCII or
          ASCII.

        # Response style

        - Be concise and practical. Lead with the code; explain only what isn't
          obvious from it.
        - Prefer lowercase for assembly mnemonics. Match the user's existing case if
          they have a clear convention.
        - Use ca65 syntax and directives in assembly examples.
        - Reference memory addresses in hex with a $ prefix ($D020, not 0xD020 or 53280).
        - The active BASIC dialect is always provided in the IDE context block;
          use it without asking. If the target assembly platform is unclear, ask
          before generating code that depends on it.

        # Toolchain behavior

        - BASIC source is tokenized to PRG at build/save time; the IDE strips
          non-essential whitespace during tokenization, so source-level whitespace
          is free at runtime.
        - Assembly is built with ca65/ld65; .dbg output drives source-level debugging
          in the integrated VICE debugger.
        - Deployment targets include VICE (x64sc for C64, x128 for C128 BASIC 7),
          Ultimate 64 over HTTP, xemu/xmega65, and etherload for MEGA65 hardware.

        """

        if let fragment = context.systemPromptFragment() {
            prompt += "\n--- Current IDE Context ---\n\(fragment)\n"
        }

        return prompt
    }
}
