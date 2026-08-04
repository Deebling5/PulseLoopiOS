import Foundation
import Security

/// OAuth token bundle persisted for the connected Strava athlete.
nonisolated struct StravaTokens: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var athleteId: Int
    var athleteName: String
}

/// Abstraction over the Strava token store so services (and tests) can swap the
/// Keychain for an in-memory stub. Nonisolated: Keychain calls are synchronous
/// and thread-safe, and sync services run off the main actor.
nonisolated protocol StravaTokenStoring: Sendable {
    func read() throws -> StravaTokens?
    func save(_ tokens: StravaTokens) throws
    func delete() throws
}

/// Stores the Strava OAuth tokens as a single JSON-encoded generic-password
/// item in the iOS Keychain. Tokens are never written to UserDefaults.
nonisolated struct StravaKeychainTokenStore: StravaTokenStoring {
    private let service: String
    private let account: String

    init(service: String = "com.pulseloop.strava", account: String = "oauth_tokens") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func read() throws -> StravaTokens? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = item as? Data else { return nil }
        return try? Self.decoder.decode(StravaTokens.self, from: data)
    }

    func save(_ tokens: StravaTokens) throws {
        let data: Data
        do {
            data = try Self.encoder.encode(tokens)
        } catch {
            throw KeychainError.dataEncoding
        }

        // Upsert: update if present, otherwise add.
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus == errSecItemNotFound {
            var insert = baseQuery
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
            return
        }
        throw KeychainError.unexpectedStatus(updateStatus)
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // Epoch-seconds dates so the blob stays stable across encoder defaults.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
