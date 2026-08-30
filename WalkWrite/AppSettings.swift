import Foundation
import Observation
import Security

struct BackendConfiguration: Sendable {
    let baseURL: URL
    let appToken: String
    let allowsCellular: Bool
}

protocol AppTokenStoring {
    func read(for endpoint: URL) throws -> String?
    func save(_ token: String, for endpoint: URL) throws
    func remove(for endpoint: URL) throws
}

enum SettingsError: LocalizedError {
    case invalidEndpoint
    case invalidToken
    case openAIKeyNotAllowed
    case keychain
    case tokenRequired

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "Enter your backend's HTTPS origin, without a path, query, or credentials."
        case .invalidToken:
            return "APP_TOKEN must contain 32–512 letters, numbers, or URL-safe token characters."
        case .openAIKeyNotAllowed:
            return "OpenAI API keys belong only on the backend. Enter the personal backend APP_TOKEN instead."
        case .keychain:
            return "The backend token could not be accessed in Keychain. Unlock the device and try again."
        case .tokenRequired:
            return "Enter an APP_TOKEN for this backend. Tokens are never reused for a different address."
        }
    }
}

/// Tokens are scoped to the configured origin and are never stored in preferences.
final class KeychainAppTokenStore: AppTokenStoring {
    private let service = "PersonalVoiceNotes.BackendToken"

    private func query(for endpoint: URL) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: endpoint.absoluteString,
            kSecAttrSynchronizable as String: false
        ]
    }

    func read(for endpoint: URL) throws -> String? {
        var query = query(for: endpoint)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            throw SettingsError.keychain
        }
        return token
    }

    func save(_ token: String, for endpoint: URL) throws {
        let query = query(for: endpoint)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw SettingsError.keychain
            }
        } else if updateStatus != errSecSuccess {
            throw SettingsError.keychain
        }
    }

    func remove(for endpoint: URL) throws {
        let status = SecItemDelete(query(for: endpoint) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SettingsError.keychain
        }
    }
}

@MainActor
@Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let tokenStore: any AppTokenStoring

    var automaticSummary: Bool {
        didSet { defaults.set(automaticSummary, forKey: "automaticAISummary") }
    }
    var useCellularForAI: Bool {
        didSet { defaults.set(useCellularForAI, forKey: "useCellularForAI") }
    }
    var whisperLanguage: String {
        didSet { defaults.set(whisperLanguage, forKey: "whisperLanguage") }
    }
    private(set) var backendURLString: String
    private(set) var hasBackendToken = false
    private(set) var configurationError: String?

    init(defaults: UserDefaults = .standard,
         tokenStore: any AppTokenStoring = KeychainAppTokenStore()) {
        self.defaults = defaults
        self.tokenStore = tokenStore
        // Missing preference keys intentionally mean OFF.
        automaticSummary = defaults.bool(forKey: "automaticAISummary")
        useCellularForAI = defaults.bool(forKey: "useCellularForAI")
        whisperLanguage = defaults.string(forKey: "whisperLanguage") ?? "auto"
        backendURLString = defaults.string(forKey: "backendURL") ?? ""
        refreshTokenStatus()
    }

    var isBackendConfigured: Bool {
        (try? Self.validateEndpoint(backendURLString)) != nil && hasBackendToken
    }

    static func validateEndpoint(_ value: String) throws -> URL {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: text),
              parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.port == nil || (1...65535).contains(parts.port!),
              host.lowercased() != "api.openai.com" else {
            throw SettingsError.invalidEndpoint
        }
        parts.scheme = "https"
        parts.host = host.lowercased()
        parts.path = ""
        guard let url = parts.url else { throw SettingsError.invalidEndpoint }
        return url
    }

    static func validateToken(_ token: String) throws {
        guard !token.hasPrefix("sk-") else { throw SettingsError.openAIKeyNotAllowed }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~+/=")
        guard (32...512).contains(token.utf8.count),
              token.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw SettingsError.invalidToken
        }
    }

    func saveBackend(urlString: String, newToken: String) throws {
        let endpoint = try Self.validateEndpoint(urlString)
        let token = newToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.isEmpty {
            guard endpoint.absoluteString == backendURLString,
                  let existing = try tokenStore.read(for: endpoint), !existing.isEmpty else {
                throw SettingsError.tokenRequired
            }
        } else {
            try Self.validateToken(token)
            try tokenStore.save(token, for: endpoint)
        }
        // Update the address only after Keychain succeeds.
        backendURLString = endpoint.absoluteString
        defaults.set(backendURLString, forKey: "backendURL")
        refreshTokenStatus()
    }

    func removeBackend() throws {
        if let endpoint = try? Self.validateEndpoint(backendURLString) {
            try tokenStore.remove(for: endpoint)
        }
        backendURLString = ""
        defaults.removeObject(forKey: "backendURL")
        hasBackendToken = false
        configurationError = nil
    }

    func refreshTokenStatus() {
        hasBackendToken = false
        configurationError = nil
        guard let endpoint = try? Self.validateEndpoint(backendURLString) else { return }
        do {
            if let token = try tokenStore.read(for: endpoint) {
                try Self.validateToken(token)
                hasBackendToken = true
            }
        } catch {
            configurationError = error.localizedDescription
        }
    }

    func backendConfiguration() throws -> BackendConfiguration {
        guard let endpoint = try? Self.validateEndpoint(backendURLString),
              let token = try tokenStore.read(for: endpoint), !token.isEmpty else {
            throw AIServiceError.notConfigured
        }
        try Self.validateToken(token)
        return BackendConfiguration(baseURL: endpoint, appToken: token,
                                    allowsCellular: useCellularForAI)
    }
}
