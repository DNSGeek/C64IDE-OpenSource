import Foundation

// MARK: - Thinking Support

/// How a model exposes extended thinking on the Messages API.
/// This varies by model generation, so it is tracked per model.
enum ClaudeThinkingSupport: String, Codable {
    /// Send {"type": "adaptive"} to enable; omit the field to disable.
    case adaptive
    /// Thinking is adaptive and always on. It cannot be turned off;
    /// {"type": "disabled"} returns a 400 on these models.
    case alwaysOn
    /// Pre-adaptive model: send {"type": "enabled", "budget_tokens": N}
    /// to enable; omit the field to disable.
    case manualBudget
    /// The model has no thinking capability (or the catalog has no way to
    /// tell — e.g. models discovered through a provider whose list endpoint
    /// doesn't report reasoning support).
    case unsupported
}

// MARK: - Model Option

struct ClaudeModelOption: Identifiable, Hashable, Codable {
    /// API model ID, e.g. "claude-sonnet-5"
    let id: String
    let displayName: String
    let thinking: ClaudeThinkingSupport
    /// Maximum output tokens the model accepts (thinking + text combined).
    let maxOutputTokens: Int
    /// Release date, used for newest-first sorting. nil for seed entries.
    let createdAt: Date?
}

// MARK: - Model Catalog

/// Fetches each provider's own model-list endpoint, derives thinking support
/// and output limits where that provider's response shape reports them, and
/// caches the result on disk (per provider) with a TTL. Falls back to a
/// hardcoded seed list per provider until that provider's first successful
/// fetch (fresh install, no API key yet, or network failure).
///
/// Thread safety: state is guarded by a lock because the API service reads
/// the catalog from background tasks while the UI reads it from the main
/// thread. Fetches happen off-main via async URLSession.
final class ClaudeModelCatalog {

    static let shared = ClaudeModelCatalog()

    // MARK: - Tunables

    /// Refresh the cached list when it is older than this (checked on
    /// access, not on a timer; see refreshIfStale()).
    static let cacheTTL: TimeInterval = 7 * 24 * 60 * 60

    /// Newest-first cap so the picker doesn't become a museum tour.
    static let maxPickerEntries = 10

    /// Hard ceiling on max output tokens regardless of what a model
    /// supports: this client does not stream, and very large non-streamed
    /// responses risk request timeouts.
    static let absoluteMaxOutputTokens = 32000

    /// Anthropic model IDs whose thinking is adaptive and unconditionally
    /// on. The capabilities tree reports whether adaptive thinking is
    /// *supported*, but not whether it can be turned *off*, so this overlay
    /// is maintained by hand. Worst case if it goes stale: the thinking
    /// toggle becomes a placebo on a new always-on model, but every request
    /// we send is still valid (we never send {"type": "disabled"}).
    static let alwaysOnThinkingIDs: Set<String> = [
        "claude-fable-5",
        "claude-mythos-5",
        "claude-sonnet-5",
    ]

    /// Fallback list per provider, used until that provider's first
    /// successful fetch. Anthropic's is a real, currently-offered lineup.
    /// The OpenAI/Gemini/Custom seeds are best-effort placeholders only —
    /// model naming on those platforms moves fast and this file has no way
    /// to stay current on its own. Add an API key and hit Refresh to
    /// replace them with that provider's actual current list.
    static func seed(for provider: ClaudeAPIProvider) -> [ClaudeModelOption] {
        switch provider {
        case .anthropic:
            return [
                ClaudeModelOption(id: "claude-fable-5",    displayName: "Claude Fable 5",    thinking: .alwaysOn,     maxOutputTokens: 128000, createdAt: nil),
                ClaudeModelOption(id: "claude-opus-4-8",   displayName: "Claude Opus 4.8",   thinking: .adaptive,     maxOutputTokens: 128000, createdAt: nil),
                ClaudeModelOption(id: "claude-sonnet-5",   displayName: "Claude Sonnet 5",   thinking: .alwaysOn,     maxOutputTokens: 128000, createdAt: nil),
                ClaudeModelOption(id: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6", thinking: .adaptive,     maxOutputTokens: 128000, createdAt: nil),
                ClaudeModelOption(id: "claude-haiku-4-5",  displayName: "Claude Haiku 4.5",  thinking: .manualBudget, maxOutputTokens: 64000,  createdAt: nil),
            ]
        case .openai:
            return [
                ClaudeModelOption(id: "gpt-4o",      displayName: "GPT-4o (placeholder — Refresh for current list)",      thinking: .unsupported, maxOutputTokens: 16384, createdAt: nil),
                ClaudeModelOption(id: "gpt-4o-mini", displayName: "GPT-4o mini (placeholder — Refresh for current list)", thinking: .unsupported, maxOutputTokens: 16384, createdAt: nil),
            ]
        case .gemini:
            return [
                ClaudeModelOption(id: "gemini-1.5-pro",   displayName: "Gemini 1.5 Pro (placeholder — Refresh for current list)",   thinking: .unsupported, maxOutputTokens: 8192, createdAt: nil),
                ClaudeModelOption(id: "gemini-1.5-flash", displayName: "Gemini 1.5 Flash (placeholder — Refresh for current list)", thinking: .unsupported, maxOutputTokens: 8192, createdAt: nil),
            ]
        case .custom:
            // No sensible guess for an arbitrary custom endpoint — empty
            // until the user enters a key/URL and hits Refresh.
            return []
        }
    }

    // MARK: - State

    private struct ProviderState {
        var models: [ClaudeModelOption]
        var fetchedAt: Date?
    }

    private let lock = NSLock()
    private var state: [ClaudeAPIProvider: ProviderState]

    /// Current best model list for a provider: cached fetch if available,
    /// else that provider's seed.
    func models(for provider: ClaudeAPIProvider) -> [ClaudeModelOption] {
        lock.lock(); defer { lock.unlock() }
        return state[provider]?.models ?? Self.seed(for: provider)
    }

    /// When a provider's list was last fetched from its API. nil means the
    /// seed list is in effect for that provider.
    func fetchedAt(for provider: ClaudeAPIProvider) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return state[provider]?.fetchedAt
    }

    /// The catalog entry for a model ID under a specific provider, if present.
    func option(for id: String, provider: ClaudeAPIProvider) -> ClaudeModelOption? {
        models(for: provider).first { $0.id == id }
    }

    private init() {
        let cached = Self.loadCache()
        var initial: [ClaudeAPIProvider: ProviderState] = [:]
        for provider in ClaudeAPIProvider.allCases {
            if let entry = cached?[provider.rawValue] {
                initial[provider] = ProviderState(models: entry.models, fetchedAt: entry.fetchedAt)
            } else {
                initial[provider] = ProviderState(models: Self.seed(for: provider), fetchedAt: nil)
            }
        }
        state = initial
    }

    // MARK: - Refresh

    /// Refreshes a provider's list if its cache is stale. Silently no-ops
    /// when the cache is fresh, when no API key is available for that
    /// provider, or on failure (the last-known-good list stays in place).
    func refreshIfStale(provider: ClaudeAPIProvider, apiKey: String?, baseURL: URL) async {
        if let fetched = fetchedAt(for: provider), Date().timeIntervalSince(fetched) < Self.cacheTTL {
            return
        }
        guard let apiKey, !apiKey.isEmpty else { return }
        try? await forceRefresh(
            provider: provider,
            apiKey: apiKey,
            baseURL: baseURL,
            keepingSelected: ClaudeAPIService.shared.modelID(for: provider)
        )
    }

    /// Fetches a provider's list unconditionally (wired to the Refresh
    /// button in Preferences). Throws on failure; the previous list for
    /// that provider is kept. apiKey/baseURL are passed explicitly (rather
    /// than read from persisted settings) so Refresh can test in-progress,
    /// unsaved Preferences edits.
    func forceRefresh(provider: ClaudeAPIProvider, apiKey: String, baseURL: URL, keepingSelected selectedID: String) async throws {
        let fetched = try await fetchAll(provider: provider, apiKey: apiKey, baseURL: baseURL)
        let trimmed = Self.trim(fetched, keepingSelected: selectedID)
        guard !trimmed.isEmpty else { throw ClaudeAPIError.invalidResponse }

        let now = Date()
        store(models: trimmed, fetchedAt: now, provider: provider)
        Self.saveCache(snapshot())
    }

    /// Synchronous so the lock is never held across a suspension point
    /// (NSLock.lock() is unavailable from async contexts).
    private func store(models: [ClaudeModelOption], fetchedAt: Date, provider: ClaudeAPIProvider) {
        lock.lock(); defer { lock.unlock() }
        state[provider] = ProviderState(models: models, fetchedAt: fetchedAt)
    }

    private func snapshot() -> [String: CachedProviderEntry] {
        lock.lock(); defer { lock.unlock() }
        var out: [String: CachedProviderEntry] = [:]
        for (provider, s) in state {
            if let fetchedAt = s.fetchedAt {
                out[provider.rawValue] = CachedProviderEntry(fetchedAt: fetchedAt, models: s.models)
            }
        }
        return out
    }

    // MARK: - Fetching (dispatch)

    private func fetchAll(provider: ClaudeAPIProvider, apiKey: String, baseURL: URL) async throws -> [ClaudeModelOption] {
        switch provider {
        case .anthropic:
            return try await fetchAnthropicModels(apiKey: apiKey, baseURL: baseURL)
        case .openai, .custom:
            return try await fetchOpenAIStyleModels(apiKey: apiKey, baseURL: baseURL, provider: provider)
        case .gemini:
            return try await fetchGeminiModels(apiKey: apiKey, baseURL: baseURL)
        }
    }

    // MARK: - Fetching (Anthropic)

    private func fetchAnthropicModels(apiKey: String, baseURL: URL) async throws -> [ClaudeModelOption] {
        var options: [ClaudeModelOption] = []
        var afterID: String? = nil

        // Paginate, with a safety cap. Nobody needs 500 models in a picker.
        for _ in 0..<5 {
            var components = URLComponents(url: baseURL.appendingPathComponent("v1/models"),
                                            resolvingAgainstBaseURL: false)!
            var items = [URLQueryItem(name: "limit", value: "100")]
            if let afterID {
                items.append(URLQueryItem(name: "after_id", value: afterID))
            }
            components.queryItems = items

            var request = URLRequest(url: components.url!)
            request.setValue(ClaudeAPIProvider.anthropic.apiKeyPrefix + apiKey,
                              forHTTPHeaderField: ClaudeAPIProvider.anthropic.apiKeyHeader)
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.timeoutInterval = 30

            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                throw ClaudeAPIError.networkError(error)
            }

            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw ClaudeAPIError.apiError("HTTP \(http.statusCode) from /v1/models")
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = json["data"] as? [[String: Any]] else {
                throw ClaudeAPIError.invalidResponse
            }

            options.append(contentsOf: list.compactMap(Self.parseAnthropicModel))

            let hasMore = json["has_more"] as? Bool ?? false
            afterID = json["last_id"] as? String
            if !hasMore || afterID == nil { break }
        }

        return options
    }

    private static let isoPlain: ISO8601DateFormatter = ISO8601DateFormatter()
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func parseAnthropicModel(_ dict: [String: Any]) -> ClaudeModelOption? {
        guard let id = dict["id"] as? String else { return nil }

        let displayName = dict["display_name"] as? String ?? id

        let createdAt = (dict["created_at"] as? String).flatMap {
            isoPlain.date(from: $0) ?? isoFractional.date(from: $0)
        }

        // "max_tokens" is the model's max *output* tokens. Fall back to our
        // ceiling if the field is missing (it costs nothing: the effective
        // cap is min(this, absoluteMaxOutputTokens) anyway).
        let maxOutput = dict["max_tokens"] as? Int ?? absoluteMaxOutputTokens

        return ClaudeModelOption(
            id: id,
            displayName: displayName,
            thinking: anthropicThinkingSupport(id: id, capabilities: dict["capabilities"] as? [String: Any]),
            maxOutputTokens: maxOutput,
            createdAt: createdAt
        )
    }

    /// Derives thinking support from the capabilities tree, with the
    /// alwaysOnThinkingIDs overlay taking precedence.
    private static func anthropicThinkingSupport(id: String, capabilities: [String: Any]?) -> ClaudeThinkingSupport {
        if alwaysOnThinkingIDs.contains(id) { return .alwaysOn }
        // Also match dated snapshots, e.g. "claude-sonnet-5-20260315".
        if alwaysOnThinkingIDs.contains(where: { id.hasPrefix($0 + "-") }) { return .alwaysOn }

        guard let thinking = capabilities?["thinking"] as? [String: Any] else {
            // Capabilities missing from the response: assume the current
            // convention. Adaptive is valid on every model we would offer.
            return .adaptive
        }

        if (thinking["supported"] as? Bool) == false { return .unsupported }

        let types = thinking["types"] as? [String: Any]
        func supported(_ key: String) -> Bool {
            ((types?[key] as? [String: Any])?["supported"] as? Bool) ?? false
        }

        if supported("adaptive") { return .adaptive }
        if supported("enabled")  { return .manualBudget }

        // thinking.supported is true but no type we recognize: don't guess
        // a request shape that might 400.
        return .unsupported
    }

    // MARK: - Fetching (OpenAI-style: OpenAI and Custom)

    private func fetchOpenAIStyleModels(apiKey: String, baseURL: URL, provider: ClaudeAPIProvider) async throws -> [ClaudeModelOption] {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/models"))
        request.setValue(provider.apiKeyPrefix + apiKey, forHTTPHeaderField: provider.apiKeyHeader)
        request.timeoutInterval = 30

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ClaudeAPIError.networkError(error)
        }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ClaudeAPIError.apiError("HTTP \(http.statusCode) from /v1/models")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else {
            throw ClaudeAPIError.invalidResponse
        }

        return list.compactMap(Self.parseOpenAIStyleModel)
    }

    private static func parseOpenAIStyleModel(_ dict: [String: Any]) -> ClaudeModelOption? {
        guard let id = dict["id"] as? String else { return nil }

        let createdAt: Date?
        if let seconds = dict["created"] as? Double {
            createdAt = Date(timeIntervalSince1970: seconds)
        } else if let seconds = dict["created"] as? Int {
            createdAt = Date(timeIntervalSince1970: TimeInterval(seconds))
        } else {
            createdAt = nil
        }

        return ClaudeModelOption(
            id: id,
            displayName: id, // the list endpoint doesn't report a friendly display name
            // The list endpoint doesn't report reasoning/thinking support,
            // so this is left unsupported rather than guessed.
            thinking: .unsupported,
            maxOutputTokens: absoluteMaxOutputTokens,
            createdAt: createdAt
        )
    }

    // MARK: - Fetching (Gemini)

    private func fetchGeminiModels(apiKey: String, baseURL: URL) async throws -> [ClaudeModelOption] {
        var options: [ClaudeModelOption] = []
        var pageToken: String? = nil

        for _ in 0..<5 {
            var components = URLComponents(url: baseURL.appendingPathComponent("v1beta/models"),
                                            resolvingAgainstBaseURL: false)!
            var items = [URLQueryItem(name: "pageSize", value: "100")]
            if let pageToken {
                items.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            components.queryItems = items

            var request = URLRequest(url: components.url!)
            request.setValue(ClaudeAPIProvider.gemini.apiKeyPrefix + apiKey,
                              forHTTPHeaderField: ClaudeAPIProvider.gemini.apiKeyHeader)
            request.timeoutInterval = 30

            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                throw ClaudeAPIError.networkError(error)
            }

            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw ClaudeAPIError.apiError("HTTP \(http.statusCode) from /v1beta/models")
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = json["models"] as? [[String: Any]] else {
                throw ClaudeAPIError.invalidResponse
            }

            options.append(contentsOf: list.compactMap(Self.parseGeminiModel))

            pageToken = json["nextPageToken"] as? String
            if pageToken == nil { break }
        }

        return options
    }

    private static func parseGeminiModel(_ dict: [String: Any]) -> ClaudeModelOption? {
        guard let name = dict["name"] as? String else { return nil }

        // Only offer models that actually support chat-style generation —
        // the list endpoint also returns embedding-only models.
        let methods = dict["supportedGenerationMethods"] as? [String] ?? []
        guard methods.contains("generateContent") else { return nil }

        let id = name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
        let displayName = dict["displayName"] as? String ?? id
        let outputLimit = dict["outputTokenLimit"] as? Int ?? absoluteMaxOutputTokens

        return ClaudeModelOption(
            id: id,
            displayName: displayName,
            // Some Gemini models support a thinking budget, but the list
            // endpoint doesn't say which, so this isn't modeled yet — the
            // "Enable extended thinking" toggle stays Anthropic-only.
            thinking: .unsupported,
            maxOutputTokens: outputLimit,
            createdAt: nil
        )
    }

    // MARK: - Trimming

    /// Sorts newest first, deduplicates dated snapshots that share a display
    /// name (keeping the newest), and caps the list. The caller's currently
    /// selected model is re-appended if the API still offers it but it fell
    /// below the cap, so a refresh never yanks their selection.
    private static func trim(_ fetched: [ClaudeModelOption], keepingSelected selectedID: String) -> [ClaudeModelOption] {
        let sorted = fetched.sorted { a, b in
            switch (a.createdAt, b.createdAt) {
            case let (x?, y?): return x > y
            case (_?, nil):    return true
            case (nil, _?):    return false
            case (nil, nil):   return a.id < b.id
            }
        }

        var seenNames = Set<String>()
        var deduped: [ClaudeModelOption] = []
        for option in sorted where seenNames.insert(option.displayName).inserted {
            deduped.append(option)
        }

        var trimmed = Array(deduped.prefix(maxPickerEntries))

        if !trimmed.contains(where: { $0.id == selectedID }),
           let selected = fetched.first(where: { $0.id == selectedID }) {
            trimmed.append(selected)
        }

        return trimmed
    }

    // MARK: - Disk Cache

    private struct CachedProviderEntry: Codable {
        let fetchedAt: Date
        let models: [ClaudeModelOption]
    }

    private static var cacheURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "C64IDE",
                                              isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // v2: keyed by provider. Bumped from the old single-provider cache
        // file so a stale file from before multi-provider support just
        // fails to decode (falls back to seeds) instead of decoding into
        // the wrong shape.
        return dir.appendingPathComponent("claude-models-v2.json")
    }

    private static func loadCache() -> [String: CachedProviderEntry]? {
        guard let url = cacheURL, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([String: CachedProviderEntry].self, from: data)
    }

    private static func saveCache(_ cache: [String: CachedProviderEntry]) {
        guard let url = cacheURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(cache) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
