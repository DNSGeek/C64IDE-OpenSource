import Foundation
import Security

// MARK: - U64 Response Models

/// Represents the JSON response from the `v1/info` endpoint.
struct U64InfoResponse: Codable {
    let product: String?
    let firmwareVersion: String?
    let fpgaVersion: String?
    let coreVersion: String?
    let hostname: String?
    let uniqueId: String?
    let errors: [String]

    enum CodingKeys: String, CodingKey {
        case product
        case firmwareVersion = "firmware_version"
        case fpgaVersion     = "fpga_version"
        case coreVersion     = "core_version"
        case hostname
        case uniqueId        = "unique_id"
        case errors
    }
}

/// Represents a standard JSON response containing an `errors` array.
struct U64Response: Codable {
    let errors: [String]
}

// MARK: - Errors

/// Errors specific to Ultimate 64 communication and configuration.
enum U64Error: LocalizedError {
    case notConfigured
    case invalidURL
    case httpError(Int)
    case unauthorized
    case deviceErrors([String])
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "U64 host is not configured. Check Settings."
        case .invalidURL:
            return "Invalid U64 host URL."
        case .httpError(let code):
            return "HTTP error \(code) from U64."
        case .unauthorized:
            return "Wrong network password. Check U64 settings."
        case .deviceErrors(let errs):
            return "U64 error: \(errs.joined(separator: ", "))"
        case .networkError(let err):
            return "Network error: \(err.localizedDescription)"
        }
    }
}

// MARK: - Keychain helpers

/// Securely stores and retrieves the U64 network password in the macOS Keychain.
private enum Keychain {
    static let service = "com.dnsgeek.c64ide.u64"
    static let account = "networkPassword"

    /// Saves a password to the Keychain, updating an existing item or creating a new one.
    static func save(_ password: String) {
        let data = Data(password.utf8)
        let lookup: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update: [String: Any] = [
            kSecValueData as String:     data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        let status = SecItemUpdate(lookup as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = lookup
            add[kSecValueData as String]     = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    /// Retrieves the stored password from the Keychain.
    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Deletes the stored password from the Keychain.
    static func delete() {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - U64Client

/// Communicates with the Ultimate 64 REST API (firmware 3.11+).
/// Hostname and optional password are persisted via UserDefaults and the Keychain.
@MainActor
final class U64Client: ObservableObject {

    // MARK: Singleton
    static let shared = U64Client()

    // MARK: Published state
    @Published var host: String {
        didSet { UserDefaults.standard.set(host, forKey: "u64Host") }
    }
    @Published var isConnected = false
    @Published var lastInfo: U64InfoResponse?

    // MARK: Private
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest  = 5
        config.timeoutIntervalForResource = 15      // PRG uploads can be a bit chunky
        config.waitsForConnectivity       = false   // fail fast when U64 is offline
        return URLSession(configuration: config)
    }()

    private init() {
        self.host = UserDefaults.standard.string(forKey: "u64Host") ?? ""
    }

    // MARK: Password (Keychain-backed)

    var password: String {
        get { Keychain.load() ?? "" }
        set {
            if newValue.isEmpty { Keychain.delete() }
            else { Keychain.save(newValue) }
        }
    }

    // MARK: - Public API

    /// Verifies connectivity to the U64 and populates `lastInfo`.
    @discardableResult
    func testConnection() async throws -> U64InfoResponse {
        let info: U64InfoResponse = try await get("v1/info")
        lastInfo    = info
        isConnected = true
        return info
    }

    /// POSTs a PRG file to the U64 — resets, DMA loads, and runs the program.
    func runPRG(_ data: Data) async throws {
        try await postBinary(data, route: "v1/runners:run_prg")
    }

    /// POSTs a PRG file to the U64 — resets and DMA loads, but does NOT run.
    func loadPRG(_ data: Data) async throws {
        try await postBinary(data, route: "v1/runners:load_prg")
    }

    /// POSTs a CRT file to the U64 — resets with the cartridge active.
    func runCRT(_ data: Data) async throws {
        try await postBinary(data, route: "v1/runners:run_crt")
    }

    /// POSTs a SID file for playback.
    func playSID(_ data: Data, songNumber: Int? = nil) async throws {
        var route = "v1/runners:sidplay"
        if let nr = songNumber { route += "?songnr=\(nr)" }
        try await postBinary(data, route: route)
    }

    /// Sends a reset command to the C64.
    func reset() async throws {
        try await put("v1/machine:reset")
    }

    /// Pauses the C64 CPU via DMA.
    func pause() async throws {
        try await put("v1/machine:pause")
    }

    /// Resumes the C64 CPU.
    func resume() async throws {
        try await put("v1/machine:resume")
    }

    /// Reads bytes from C64 memory via DMA.
    /// - Parameters:
    ///   - address: Start address (e.g. 0xC000)
    ///   - length:  Number of bytes (default 256)
    func readMemory(address: UInt16, length: Int = 256) async throws -> Data {
        let route = "v1/machine:readmem?address=\(String(format: "%04X", address))&length=\(length)"
        return try await getBinary(route)
    }

    /// Writes up to 128 bytes to C64 memory via DMA.
    /// Note: The U64 API uses PUT for memory writes.
    func writeMemory(address: UInt16, bytes: [UInt8]) async throws {
        guard !bytes.isEmpty, bytes.count <= 128 else {
            throw U64Error.deviceErrors(["writeMemory: 1–128 bytes required"])
        }
        let hex   = bytes.map { String(format: "%02X", $0) }.joined()
        let route = "v1/machine:writemem?address=\(String(format: "%04X", address))&data=\(hex)"
        try await put(route)
    }

    /// Mounts a disk image already on the U64 filesystem.
    /// Note: The U64 API uses PUT for mount operations.
    func mountDisk(drive: String, path: String, mode: String = "readwrite") async throws {
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw U64Error.invalidURL
        }
        try await put("v1/drives/\(drive):mount?image=\(encoded)&mode=\(mode)")
    }

    /// POSTs a disk image (.d64 etc.) directly to a drive.
    func mountDiskImage(_ data: Data, drive: String, type diskType: String = "d64", mode: String = "readwrite") async throws {
        try await postBinary(data, route: "v1/drives/\(drive):mount?type=\(diskType)&mode=\(mode)")
    }

    // MARK: - Private Networking

    /// Constructs a valid base URL from the configured host string.
    private func baseURL() throws -> URL {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw U64Error.notConfigured }
        let raw = trimmed.hasPrefix("http") ? trimmed : "http://\(trimmed)"
        guard let url = URL(string: raw) else { throw U64Error.invalidURL }
        return url
    }

    /// Constructs a URLRequest for the given route and HTTP method.
    private func request(_ route: String, method: String) throws -> URLRequest {
        let url  = try baseURL().appendingPathComponent(route)
        var req  = URLRequest(url: url)
        req.httpMethod = method
        let pwd  = password
        if !pwd.isEmpty { req.setValue(pwd, forHTTPHeaderField: "X-Password") }
        return req
    }

    /// Validates HTTP response status codes and throws appropriate errors.
    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200...299: break
        case 403:       throw U64Error.unauthorized
        default:        throw U64Error.httpError(http.statusCode)
        }
    }

    /// Checks the response body for U64-specific error arrays and throws if found.
    private func checkErrors(_ data: Data) throws {
        if let result = try? JSONDecoder().decode(U64Response.self, from: data),
           !result.errors.isEmpty {
            throw U64Error.deviceErrors(result.errors)
        }
    }

    // GET → Codable
    private func get<T: Decodable>(_ route: String) async throws -> T {
        do {
            let req          = try request(route, method: "GET")
            let (data, resp) = try await session.data(for: req)
            try validate(resp)
            return try JSONDecoder().decode(T.self, from: data)
        } catch let e as U64Error { throw e }
        catch { throw U64Error.networkError(error) }
    }

    // GET → raw Data (for readmem)
    private func getBinary(_ route: String) async throws -> Data {
        do {
            let req          = try request(route, method: "GET")
            let (data, resp) = try await session.data(for: req)
            try validate(resp)
            return data
        } catch let e as U64Error { throw e }
        catch { throw U64Error.networkError(error) }
    }

    // PUT (no body)
    @discardableResult
    private func put(_ route: String) async throws -> U64Response {
        do {
            let req          = try request(route, method: "PUT")
            let (data, resp) = try await session.data(for: req)
            try validate(resp)
            try checkErrors(data)
            return (try? JSONDecoder().decode(U64Response.self, from: data)) ?? U64Response(errors: [])
        } catch let e as U64Error { throw e }
        catch { throw U64Error.networkError(error) }
    }

    // POST binary attachment
    private func postBinary(_ body: Data, route: String) async throws {
        do {
            var req          = try request(route, method: "POST")
            req.httpBody     = body
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let (data, resp) = try await session.data(for: req)
            try validate(resp)
            try checkErrors(data)
        } catch let e as U64Error { throw e }
        catch { throw U64Error.networkError(error) }
    }
}

