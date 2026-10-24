import Foundation
import Testing
@testable import ClientAppKit

/// The status page's events and the account's summary, against a stubbed
/// network
extension Stubbed {
@Suite struct StatusClientTests {
    let session: URLSession

    init() {
        StubProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        session = URLSession(configuration: configuration)
    }

    var client: StatusClient {
        StatusClient(apiURL: URL(string: "https://api.example.test")!, session: session, accessToken: { "access" })
    }

    nonisolated(unsafe) static let event: [String: Any] = ["id": 12, "eventType": "incident", "service": "api", "title": "Slow uploads",
                                       "description": NSNull(), "occurredAt": "2026-10-24T14:20:00Z", "endedAt": NSNull(), "ongoing": true]

    static func json(_ object: Any, status: Int = 200) -> StubProtocol.Response {
        (status, try! JSONSerialization.data(withJSONObject: object))
    }

    func body(_ index: Int = 0) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: StubProtocol.requests[index].body) as? [String: Any])
    }

    @Test func listsTheServicesAndEvents() async throws {
        StubProtocol.responses = [Self.json(["services": ["website", "api"], "since": "2026-07-26T00:00:00Z", "events": [Self.event]])]

        let status = try await client.status()

        #expect(status.services == ["website", "api"])
        #expect(status.events == [StatusClient.Event(id: 12, eventType: "incident", service: "api", title: "Slow uploads", description: nil,
                                                     occurredAt: "2026-10-24T14:20:00Z", endedAt: nil, ongoing: true)])
        #expect(StubProtocol.requests.first?.method == "GET")
        #expect(StubProtocol.requests.first?.url == "https://api.example.test/system_events")
    }

    @Test func addsAnEventWithOnlyWhatIsGiven() async throws {
        StubProtocol.responses = [Self.json(Self.event, status: 201)]

        let event = try await client.add(type: "incident", title: "Slow uploads", service: "api")

        #expect(event.id == 12)
        #expect(StubProtocol.requests.first?.method == "POST")
        #expect(try body() as NSDictionary == ["eventType": "incident", "title": "Slow uploads", "service": "api"] as NSDictionary)
    }

    @Test func editsEndsAndDeletesAnEvent() async throws {
        StubProtocol.responses = [Self.json(Self.event), Self.json(Self.event), Self.json(Self.event), (204, Data())]

        _ = try await client.edit(12, description: "Uploads take longer")
        _ = try await client.end(12, at: "2026-10-24T15:00:00Z")
        _ = try await client.end(12)
        try await client.delete(12)

        #expect(StubProtocol.requests.map(\.method) == ["PATCH", "PATCH", "PATCH", "DELETE"])
        #expect(StubProtocol.requests.map(\.url).allSatisfy { $0 == "https://api.example.test/system_events/12" })
        #expect(try body(0) as NSDictionary == ["description": "Uploads take longer"] as NSDictionary)
        #expect(try body(1)["endedAt"] as? String == "2026-10-24T15:00:00Z")
        let now = try #require(ISO8601DateFormatter().date(from: try body(2)["endedAt"] as? String ?? ""))
        #expect(abs(now.timeIntervalSinceNow) < 60)
    }

    @Test func tellsTheBackendsErrors() async throws {
        StubProtocol.responses = [Self.json(["errors": ["Event type is not included in the list", "Parameters service must be one of website, api"]], status: 422)]

        await #expect(throws: ClientAppError.http(status: 422, message: "Event type is not included in the list; Parameters service must be one of website, api")) {
            _ = try await client.add(type: "outage", title: "x", service: "mail")
        }
    }

    @Test func refusesWithoutTheRight() async throws {
        StubProtocol.responses = [(403, Data())]

        await #expect(throws: ClientAppError.self) { try await client.delete(12) }
    }

    @Test func sumsUpTheAccount() async throws {
        StubProtocol.responses = [Self.json([
            "account": ["name": "Acme", "subdomain": "acme", "siteUrl": "https://acme.appshare.site"],
            "user": ["name": "Anna Smith", "emailAddress": "anna@example.com", "statusAdmin": true],
            "folders": ["created": 1, "published": 2, "archived": 0, "total": 3],
            "files": ["count": 4, "byteSize": 2048, "lastUploadAt": NSNull()],
        ])]

        let summary = try await AccountClient(apiURL: URL(string: "https://api.example.test")!, session: session, accessToken: { "access" }).summary()

        #expect(summary.account.subdomain == "acme")
        #expect(summary.user.statusAdmin)
        #expect(summary.folders == AccountClient.Summary.Folders(created: 1, published: 2, archived: 0, total: 3))
        #expect(summary.files.lastUploadAt == nil)
        #expect(StubProtocol.requests.first?.url == "https://api.example.test/account")
        #expect(StubProtocol.requests.first?.headers["Authorization"] == "Bearer access")
    }
}
}
