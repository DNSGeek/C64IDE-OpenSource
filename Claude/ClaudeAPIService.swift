import Foundation
import Security

// MARK: - Usage

struct ClaudeUsage {
    let inputTokens: Int
    let outputTokens: Int
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
            return "No API key configured. Please add your Anthropic API key in Preferences."
        case .invalidResponse:
            return "Received an unexpected response from the Claude API."
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

/// Handles all communication with the Anthropic Claude API.
/// API key is stored securely in the macOS Keychain.
final class ClaudeAPIService {

    // MARK: - Constants

    static let shared = ClaudeAPIService()

    private let keychainService = "com.c64ide.claude"
    private let keychainAccount = "anthropic-api-key"
    private let apiEndpoint     = URL(string: "https://api.anthropic.com/v1/messages")!

    private init() {}

    // MARK: - Model Catalog Accessors

    /// Models offered in Preferences. Sourced from ClaudeModelCatalog, which
    /// fetches GET /v1/models with a 7-day disk cache and falls back to a
    /// hardcoded seed list until the first successful fetch.
    static var availableModels: [ClaudeModelOption] { ClaudeModelCatalog.shared.models }

    static let defaultModelID   = "claude-sonnet-5"
    static let defaultMaxTokens = 4096

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

    private enum DefaultsKey {
        static let model           = "ClaudeModel"
        static let thinkingEnabled = "ClaudeThinkingEnabled"
        static let maxTokens       = "ClaudeMaxTokens"
    }

    /// Selected model ID. Falls back to the default (or the newest available
    /// model) if the stored value is no longer in the catalog, e.g. after a
    /// model is retired.
    var model: String {
        get {
            let available = Self.availableModels
            if let stored = UserDefaults.standard.string(forKey: DefaultsKey.model),
               available.contains(where: { $0.id == stored }) {
                return stored
            }
            if available.contains(where: { $0.id == Self.defaultModelID }) {
                return Self.defaultModelID
            }
            return available.first?.id ?? Self.defaultModelID
        }
        set { UserDefaults.standard.set(newValue, forKey: DefaultsKey.model) }
    }

    /// The catalog entry for the selected model.
    var modelOption: ClaudeModelOption {
        ClaudeModelCatalog.shared.option(for: model) ?? ClaudeModelCatalog.seed[0]
    }

    /// Whether extended thinking is requested. Defaults to true.
    /// Models with ClaudeThinkingSupport.alwaysOn think regardless of this setting.
    var thinkingEnabled: Bool {
        get { UserDefaults.standard.object(forKey: DefaultsKey.thinkingEnabled) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: DefaultsKey.thinkingEnabled) }
    }

    /// Max output tokens per response. Thinking tokens (when enabled) count
    /// against this budget too. The stored value is clamped to the absolute
    /// range; the per-model cap is applied at request time in sendMessage,
    /// so switching models never silently rewrites the stored preference.
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

    // MARK: - Keychain

    /// Save the API key to the Keychain.
    /// Uses SecItemUpdate first, falling back to SecItemAdd if the item doesn't exist yet.
    func saveAPIKey(_ key: String) throws {
        let data = Data(key.utf8)
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
        ]
        let update: [CFString: Any] = [
            kSecValueData:      data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked,
        ]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            // Item doesn't exist yet, add it
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

    /// Retrieve the API key from the Keychain. Returns nil if not set.
    func loadAPIKey() -> String? {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      keychainService,
            kSecAttrAccount:      keychainAccount,
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

    /// Returns true if an API key is stored.
    var hasAPIKey: Bool { loadAPIKey() != nil }

    /// Delete the stored API key.
    func deleteAPIKey() {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }

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

    // MARK: - API Call

    /// Send a message to Claude and return the assistant's reply.
    /// - Parameters:
    ///   - history: Full conversation history (user + assistant turns)
    ///   - context: Current IDE context snapshot
    /// - Returns: The assistant's reply string and token usage
    func sendMessage(
        history: [ClaudeChatMessage],
        context: ClaudeIDEContext
    ) async throws -> (text: String, usage: ClaudeUsage) {

        guard let apiKey = loadAPIKey() else {
            throw ClaudeAPIError.noAPIKey
        }

        let systemPrompt = buildSystemPrompt(context: context)

        let messagesPayload = history.map { ["role": $0.role, "content": $0.content] }

        let option = modelOption
        // Apply the model-specific output cap at request time.
        let requestMaxTokens = min(maxTokens, Self.maxTokensRange(for: option).upperBound)

        var body: [String: Any] = [
            "model":      option.id,
            "max_tokens": requestMaxTokens,
            "system":     systemPrompt,
            "messages":   messagesPayload,
        ]

        // Thinking configuration depends on the model generation (see
        // ClaudeThinkingSupport). Thinking blocks share the max_tokens budget
        // and are emitted before the text block (handled when parsing below).
        switch (thinkingEnabled, option.thinking) {
        case (true, .adaptive), (true, .alwaysOn):
            // Adaptive lets the model decide how much to reason per request.
            body["thinking"] = ["type": "adaptive"]
        case (true, .manualBudget):
            // Pre-adaptive models need an explicit budget:
            // budget_tokens must be >= 1024 and < max_tokens.
            if requestMaxTokens > 1024 {
                let budget = max(1024, min(requestMaxTokens - 1, requestMaxTokens / 2))
                body["thinking"] = ["type": "enabled", "budget_tokens": budget]
            }
        case (true, .unsupported), (false, _):
            // Omit the field entirely. This disables thinking on adaptive and
            // manual-budget models. alwaysOn models (Fable 5, Sonnet 5) run
            // adaptive thinking regardless; sending {"type": "disabled"}
            // would be rejected with a 400, so we don't.
            break
        }

        let bodyData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: apiEndpoint)
        request.httpMethod = "POST"
        request.httpBody   = bodyData
        request.setValue("application/json",      forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey,                  forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01",            forHTTPHeaderField: "anthropic-version")
        // Generous timeout: this client doesn't stream, and a large
        // max_tokens with thinking enabled can legitimately take a while.
        request.timeoutInterval = 300

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ClaudeAPIError.networkError(error)
        }

        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200: break
            case 429: throw ClaudeAPIError.rateLimited
            default:
                // Try to extract error message from response body
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let error = json["error"] as? [String: Any],
                   let message = error["message"] as? String {
                    throw ClaudeAPIError.apiError(message)
                }
                throw ClaudeAPIError.apiError("HTTP \(http.statusCode)")
            }
        }

        // The content array may lead with a "thinking" block (adaptive thinking),
        // so pick the first block of type "text" rather than assuming index 0.
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let text = content.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String else {
            throw ClaudeAPIError.invalidResponse
        }

        // Anthropic's usage keys may vary by API version. Fallback to prompt/completion tokens.
        let usageDict = json["usage"] as? [String: Any]
        let usage = ClaudeUsage(
            inputTokens:  usageDict?["input_tokens"]  as? Int ?? usageDict?["prompt_tokens"]  as? Int ?? 0,
            outputTokens: usageDict?["output_tokens"] as? Int ?? usageDict?["completion_tokens"] as? Int ?? 0
        )

        return (text: text, usage: usage)
    }
}

