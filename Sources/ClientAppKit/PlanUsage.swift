import Foundation

/// An account's plan and what it uses of it, as the backend sends it (the
/// account's `plan`): files up to `storage.limit` bytes, up to `users.limit`
/// users
public struct PlanUsage: Decodable, Sendable, Equatable {
    public struct Storage: Decodable, Sendable, Equatable {
        public let used: Int
        public let limit: Int
    }

    public struct Users: Decodable, Sendable, Equatable {
        public let count: Int
        public let limit: Int
    }

    /// 5GB or 10GB
    public let name: String
    public let storage: Storage
    public let users: Users

    public init(name: String, storage: Storage, users: Users) {
        self.name = name
        self.storage = storage
        self.users = users
    }

    /// "5GB: 49 MB of 5 GB, 1 of 3 users" (binary units, like the backend)
    public var summary: String {
        "\(name): \(PlanUsage.size(storage.used)) of \(PlanUsage.size(storage.limit)), \(users.count) of \(users.limit) users"
    }

    /// True when the account has no room left for files or users
    public var full: Bool {
        storage.used >= storage.limit || users.count >= users.limit
    }

    /// A size in binary units: 5 GB for 5 GiB, like the plans' names
    public static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
    }
}
