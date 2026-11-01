import Foundation

/// Every account, its plan and its users, for an admin (scope `admin`,
/// `client-app login --admin`): `GET /admin/accounts`,
/// `GET|PATCH /admin/accounts/<subdomain>`
public struct AdminClient: Sendable {
    /// What a plan allows: files up to `storage` bytes, up to `users` users
    public struct Limits: Decodable, Sendable, Equatable {
        public let storage: Int
        public let users: Int
    }

    /// An app the user allowed, and what it may do now (its newest token)
    public struct OAuthToken: Decodable, Sendable, Equatable {
        public let application: String?
        public let scopes: [String]
        /// ISO 8601
        public let createdAt: String
        /// Expired tokens may still be renewed with their refresh token
        public let expired: Bool
    }

    public struct User: Decodable, Sendable, Equatable {
        public let id: Int
        public let name: String
        public let emailAddress: String
        public let emailAddressValidatedAt: String?
        public let admin: Bool
        public let apiEnabled: Bool
        public let clientAppEnabled: Bool
        public let oauthTokens: [OAuthToken]
        public let createdAt: String?
    }

    public struct Account: Decodable, Sendable, Equatable {
        public let uuid: String
        public let name: String
        public let subdomain: String
        public let siteUrl: String
        public let plan: PlanUsage
        public let createdAt: String?
        public let users: [User]
    }

    /// The plans by name, and every account, oldest first
    public struct Accounts: Decodable, Sendable, Equatable {
        public let plans: [String: Limits]
        public let accounts: [Account]
    }

    let api: APIClient

    public init(apiURL: URL, session: URLSession = .shared, accessToken: @escaping @Sendable () async throws -> String) {
        api = APIClient(apiURL: apiURL, session: session, accessToken: accessToken)
    }

    public func accounts() async throws -> Accounts {
        try await api.send("GET", "admin/accounts")
    }

    public func account(_ subdomain: String) async throws -> Account {
        try await api.send("GET", "admin/accounts/\(subdomain)")
    }

    /// Subscribe the account to another plan (Pro, Business: any case)
    public func setPlan(_ subdomain: String, plan: String) async throws -> Account {
        try await api.send("PATCH", "admin/accounts/\(subdomain)", body: ["plan": plan])
    }
}
