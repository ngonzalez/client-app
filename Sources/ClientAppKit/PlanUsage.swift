import Foundation

/// An account's plan and what it uses of it, as the backend sends it (the
/// account's `plan`): files up to `storage.limit` bytes, up to `users.limit`
/// users. Every plan is paid: without one (an empty name) the account's site
/// is offline and it takes no file.
public struct PlanUsage: Decodable, Sendable, Equatable {
    public struct Storage: Decodable, Sendable, Equatable {
        public let used: Int
        public let limit: Int
    }

    public struct Users: Decodable, Sendable, Equatable {
        public let count: Int
        public let limit: Int
    }

    /// Pro or Business; empty without a plan
    public let name: String
    /// How the plan is billed: monthly or yearly; nil without a plan (or
    /// from a backend that doesn't send it)
    public let interval: String?
    public let storage: Storage
    public let users: Users

    public init(name: String, interval: String? = nil, storage: Storage, users: Users) {
        self.name = name
        self.interval = interval
        self.storage = storage
        self.users = users
    }

    /// False without a plan: no subscription, or it ended
    public var hasPlan: Bool {
        !name.isEmpty
    }

    /// The plan's name, "No plan" without one
    public var displayName: String {
        hasPlan ? name : "No plan"
    }

    /// "Pro, monthly: 49 MB of 5 GB, 1 of 3 users" (binary units, like the
    /// backend); "No plan (site offline): 49 MB of files, 1 user" without one
    public var summary: String {
        guard hasPlan else {
            return "No plan (site offline): \(PlanUsage.size(storage.used)) of files, \(users.count) \(users.count == 1 ? "user" : "users")"
        }
        let billed = interval.map { ", \($0)" } ?? ""
        return "\(name)\(billed): \(PlanUsage.size(storage.used)) of \(PlanUsage.size(storage.limit)), \(users.count) of \(users.limit) users"
    }

    /// True when the account's plan has no room left for files or users
    /// (never without a plan: it has none to fill)
    public var full: Bool {
        hasPlan && (storage.used >= storage.limit || users.count >= users.limit)
    }

    /// A size in binary units: 5 GB for 5 GiB, like the plans' names
    public static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
    }
}
