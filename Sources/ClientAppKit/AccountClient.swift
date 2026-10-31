import Foundation

/// The signed-in user's account at a glance: `GET /account` (scope
/// `account.show`)
public struct AccountClient: Sendable {
    /// The account and its plan, the user and their rights, the folders, the
    /// files
    public struct Summary: Decodable, Sendable, Equatable {
        public struct Account: Decodable, Sendable, Equatable {
            public let name: String?
            public let subdomain: String
            public let siteUrl: String
            /// The plan and what the account uses of it (none from a
            /// backend before plans)
            public let plan: PlanUsage?
        }

        public struct User: Decodable, Sendable, Equatable {
            public let name: String?
            public let emailAddress: String
            /// May enter the status page's events and change the accounts'
            /// plans (`client-app status`, `accounts`, `plan`)
            public let admin: Bool?
            /// The same right, as a backend before `admin` named it
            public let statusAdmin: Bool?

            /// True for an admin, whichever name the backend gives the right
            public var isAdmin: Bool { admin ?? statusAdmin ?? false }
        }

        /// The folders by state
        public struct Folders: Decodable, Sendable, Equatable {
            public let created: Int
            public let published: Int
            public let archived: Int
            public let total: Int
        }

        public struct Files: Decodable, Sendable, Equatable {
            public let count: Int
            public let byteSize: Int
            /// ISO 8601, none without files
            public let lastUploadAt: String?
        }

        public let account: Account
        public let user: User
        public let folders: Folders
        public let files: Files
    }

    let api: APIClient

    public init(apiURL: URL, session: URLSession = .shared, accessToken: @escaping @Sendable () async throws -> String) {
        api = APIClient(apiURL: apiURL, session: session, accessToken: accessToken)
    }

    public func summary() async throws -> Summary {
        try await api.send("GET", "account")
    }
}
