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
    /// The model has no thinking capability.
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

/// Fetches the model list from GET /v1/models, derives thinking support and
/// output limits from each model's capabilities tree, and caches the result
/// on disk with a TTL. Falls back to a hardcoded seed list until the first
/// successful fetch (fresh install, no API key yet, or network failure).
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

    /// Model IDs whose thinking is adaptive and unconditionally on. The
    /// capabilities tree reports whether adaptive thinking is *supported*,
    /// but not whether it can be turned *off*, so this overlay is maintained
    /// by hand. Worst case if it goes stale: the thinking toggle becomes a
    /// placebo on a new always-on model, but every request we send is still
    /// valid (we never send {"type": "disabled"}).
    static let alwaysOnThinkingIDs: Set<String> = [
        "claude-fable-5",
        "claude-mythos-5",
        "claude-sonnet-5",
    ]

    /// Fallback list used until the first successful fetch.
    static let seed: [ClaudeModelOption] = [
        ClaudeModelOption(id: "claude-fable-5",    displayName: "Claude Fable 5",    thinking: .alwaysOn,     maxOutputTokens: 128000, createdAt: nil),
        ClaudeModelOption(id: "claude-opus-4-8",   displayName: "Claude Opus 4.8",   thinking: .adaptive,     maxOutputTokens: 128000, createdAt: nil),
        ClaudeModelOption(id: "claude-sonnet-5",   displayName: "Claude Sonnet 5",   thinking: .alwaysOn,     maxOutputTokens: 128000, createdAt: nil),
        ClaudeModelOption(id: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6", thinking: .adaptive,     maxOutputTokens: 128000, createdAt: nil),
        ClaudeModelOption(id: "claude-haiku-4-5",  displayName: "Claude Haiku 4.5",  thinking: .manualBudget, maxOutputTokens: 64000,  createdAt: nil),
    ]

    // MARK: - State

    private let lock = NSLock()
    private var _models: [ClaudeModelOption]
    private var _fetchedAt: Date?

    /// Current best model list: cached fetch if available, else the seed.
    var models: [ClaudeModelOption] {
        lock.lock(); defer { lock.unlock() }
        return _models
    }

    /// When the list was last fetched from the API. nil means the seed
    /// list is in effect.
    var fetchedAt: Date? {
        lock.lock(); defer { lock.unlock() }
        return _fetchedAt
    }

    /// The catalog entry for a model ID, if present.
    func option(for id: String) -> ClaudeModelOption? {
        models.first { $0.id == id }
    }

    private init() {
        if let cached = Self.loadCache() {
            _models    = cached.models
            _fetchedAt = cached.fetchedAt
        } else {
            _models    = Self.seed
            _fetchedAt = nil
        }
    }

    // MARK: - Refresh

    /// Refreshes if the cache is stale. Silently no-ops when the cache is
    /// fresh, when no API key is stored (the endpoint requires one), or on
    /// failure (the last-known-good list stays in place).
    func refreshIfStale() async {
        if let fetched = fetchedAt, Date().timeIntervalSince(fetched) < Self.cacheTTL {
            return
        }
        guard ClaudeAPIService.shared.hasAPIKey else { return }
        try? await forceRefresh()
    }

    /// Fetches unconditionally (wired to the Refresh button in Preferences).
    /// Throws on failure; the previous list is kept.
    func forceRefresh() async throws {
        let fetched = try await fetchAll()
        let trimmed = Self.trim(fetched, keepingSelected: ClaudeAPIService.shared.model)
        guard !trimmed.isEmpty else { throw ClaudeAPIError.invalidResponse }

        let now = Date()
        lock.lock()
        _models    = trimmed
        _fetchedAt = now
        lock.unlock()

        Self.saveCache(CachedCatalog(fetchedAt: now, models: trimmed))
    }

    // MARK: - Fetching

    private func fetchAll() async throws -> [ClaudeModelOption] {
        guard let apiKey = ClaudeAPIService.shared.loadAPIKey() else {
            throw ClaudeAPIError.noAPIKey
        }

        var options: [ClaudeModelOption] = []
        var afterID: String? = nil

        // Paginate, with a safety cap. Nobody needs 500 models in a picker.
        for _ in 0..<5 {
            var components = URLComponents(string: "https://api.anthropic.com/v1/models")!
            var items = [URLQueryItem(name: "limit", value: "100")]
            if let afterID {
                items.append(URLQueryItem(name: "after_id", value: afterID))
            }
            components.queryItems = items

            var request = URLRequest(url: components.url!)
            request.setValue(apiKey,      forHTTPHeaderField: "x-api-key")
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

            options.append(contentsOf: list.compactMap(Self.parseModel))

            let hasMore = json["has_more"] as? Bool ?? false
            afterID = json["last_id"] as? String
            if !hasMore || afterID == nil { break }
        }

        return options
    }

    // MARK: - Parsing

    private static let isoPlain: ISO8601DateFormatter = ISO8601DateFormatter()
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func parseModel(_ dict: [String: Any]) -> ClaudeModelOption? {
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
            thinking: thinkingSupport(id: id, capabilities: dict["capabilities"] as? [String: Any]),
            maxOutputTokens: maxOutput,
            createdAt: createdAt
        )
    }

    /// Derives thinking support from the capabilities tree, with the
    /// alwaysOnThinkingIDs overlay taking precedence.
    private static func thinkingSupport(id: String, capabilities: [String: Any]?) -> ClaudeThinkingSupport {
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

    // MARK: - Trimming

    /// Sorts newest first, deduplicates dated snapshots that share a display
    /// name (keeping the newest), and caps the list. The user's currently
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

    private struct CachedCatalog: Codable {
        let fetchedAt: Date
        let models: [ClaudeModelOption]
    }

    private static var cacheURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "C64IDE",
                                              isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("claude-models.json")
    }

    private static func loadCache() -> CachedCatalog? {
        guard let url = cacheURL, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CachedCatalog.self, from: data)
    }

    private static func saveCache(_ cache: CachedCatalog) {
        guard let url = cacheURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(cache) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
