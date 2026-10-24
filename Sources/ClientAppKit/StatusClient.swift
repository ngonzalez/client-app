import Foundation

/// The status page's events (status.appshare.site): `GET /system_events`
/// lists them for anyone; a status admin adds, changes, ends and deletes
/// them (scope `status.admin`, `client-app login --status`)
public struct StatusClient: Sendable {
    /// A system event
    public struct Event: Decodable, Sendable, Equatable {
        public let id: Int
        /// incident, maintenance, deploy or info
        public let eventType: String
        /// website, api, streaming or registration; none for all of them
        public let service: String?
        public let title: String?
        public let description: String?
        /// ISO 8601
        public let occurredAt: String
        public let endedAt: String?
        public let ongoing: Bool
    }

    /// The services and the events of the past 90 days, newest first
    public struct Status: Decodable, Sendable, Equatable {
        public let services: [String]
        public let since: String
        public let events: [Event]
    }

    /// The kinds of events
    public static let types = ["incident", "maintenance", "deploy", "info"]

    let api: APIClient

    public init(apiURL: URL, session: URLSession = .shared, accessToken: @escaping @Sendable () async throws -> String) {
        api = APIClient(apiURL: apiURL, session: session, accessToken: accessToken)
    }

    public func status() async throws -> Status {
        try await api.send("GET", "system_events")
    }

    /// A new event, from now unless `occurredAt` is given
    public func add(type: String, title: String, service: String? = nil, description: String? = nil,
                    occurredAt: String? = nil, endedAt: String? = nil) async throws -> Event {
        var body: [String: Any] = ["eventType": type, "title": title]
        body["service"] = service
        body["description"] = description
        body["occurredAt"] = occurredAt
        body["endedAt"] = endedAt
        return try await api.send("POST", "system_events", body: body)
    }

    /// Change an event: only the fields given
    public func edit(_ id: Int, title: String? = nil, description: String? = nil, service: String? = nil) async throws -> Event {
        var body: [String: Any] = [:]
        body["title"] = title
        body["description"] = description
        body["service"] = service
        return try await api.send("PATCH", "system_events/\(id)", body: body)
    }

    /// End an incident or a maintenance, now unless `at` is given
    public func end(_ id: Int, at: String? = nil) async throws -> Event {
        try await api.send("PATCH", "system_events/\(id)", body: ["endedAt": at ?? ISO8601DateFormatter().string(from: Date())])
    }

    public func delete(_ id: Int) async throws {
        try await api.send("DELETE", "system_events/\(id)")
    }
}
