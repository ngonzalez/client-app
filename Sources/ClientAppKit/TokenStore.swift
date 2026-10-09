import Foundation
import Security

/// The tokens of a sign-in
public struct Token: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date

    /// Renew a minute early, so a request doesn't start with a token about to expire
    public func isExpired(now: Date = Date()) -> Bool {
        expiresAt.addingTimeInterval(-60) <= now
    }
}

public protocol TokenStore: Sendable {
    func load() throws -> Token?
    func save(_ token: Token) throws
    func delete() throws
}

/// The tokens in the login keychain, one item per backend
public struct KeychainTokenStore: TokenStore {
    let service = "site.appshare.client-app"
    let account: String

    public init(apiURL: URL) {
        account = apiURL.host() ?? apiURL.absoluteString
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func load() throws -> Token? {
        var query = self.query
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw keychainError(status) }
        return try JSONDecoder().decode(Token.self, from: data)
    }

    public func save(_ token: Token) throws {
        let data = try JSONEncoder().encode(token)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw keychainError(added) }
        } else if status != errSecSuccess {
            throw keychainError(status)
        }
    }

    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError(status) }
    }

    private func keychainError(_ status: OSStatus) -> Error {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"])
    }
}
