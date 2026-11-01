import Foundation
import Testing
@testable import ClientAppKit

/// What an account's plan allows and uses
@Suite struct PlanUsageTests {
    let usage = PlanUsage(name: "5GB", storage: .init(used: 51_357_725, limit: 5_368_709_120), users: .init(count: 1, limit: 3))

    @Test func sumsUpThePlanInBinaryUnits() {
        #expect(usage.summary == "5GB: \(PlanUsage.size(51_357_725)) of 5 GB, 1 of 3 users")
        #expect(PlanUsage.size(10_737_418_240) == "10 GB")
    }

    @Test func saysThereIsNoPlanWithoutOne() {
        let none = PlanUsage(name: "", storage: .init(used: 2048, limit: 0), users: .init(count: 1, limit: 1))

        #expect(!none.hasPlan)
        #expect(none.displayName == "No plan")
        #expect(none.summary == "No plan (site offline): \(PlanUsage.size(2048)) of files, 1 user")
        #expect(!none.full)
        #expect(usage.hasPlan)
        #expect(usage.displayName == "5GB")
    }

    @Test func isFullWhenTheFilesOrTheUsersReachTheLimit() {
        #expect(!usage.full)
        #expect(PlanUsage(name: "5GB", storage: .init(used: 5_368_709_120, limit: 5_368_709_120), users: .init(count: 1, limit: 3)).full)
        #expect(PlanUsage(name: "5GB", storage: .init(used: 0, limit: 5_368_709_120), users: .init(count: 3, limit: 3)).full)
    }
}

/// The accounts and their plans, for an admin, against a stubbed network
extension Stubbed {
@Suite struct AdminClientTests {
    let session: URLSession

    init() {
        StubProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        session = URLSession(configuration: configuration)
    }

    var client: AdminClient {
        AdminClient(apiURL: URL(string: "https://api.example.test")!, session: session, accessToken: { "access" })
    }

    nonisolated(unsafe) static let account: [String: Any] = [
        "uuid": "3bff5df7", "name": "Acme", "subdomain": "acme", "siteUrl": "https://acme.appshare.site",
        "plan": ["name": "10GB", "storage": ["used": 2048, "limit": 10_737_418_240], "users": ["count": 1, "limit": 10]],
        "createdAt": "2026-10-01T10:00:00Z",
        "users": [[
            "id": 7, "name": "Anna Smith", "emailAddress": "anna@example.com", "emailAddressValidatedAt": NSNull(),
            "admin": true, "apiEnabled": false, "clientAppEnabled": true, "createdAt": "2026-10-01T10:00:00Z",
            "oauthTokens": [["application": "client-app", "scopes": ["uploads.write", "admin"], "createdAt": "2026-10-31T09:00:00Z", "expired": false]],
        ]],
    ]

    static func json(_ object: Any, status: Int = 200) -> StubProtocol.Response {
        (status, try! JSONSerialization.data(withJSONObject: object))
    }

    @Test func listsThePlansAndTheAccounts() async throws {
        StubProtocol.responses = [Self.json(["plans": ["5GB": ["storage": 5_368_709_120, "users": 3], "10GB": ["storage": 10_737_418_240, "users": 10]],
                                             "accounts": [Self.account]])]

        let result = try await client.accounts()

        #expect(result.plans["5GB"] == AdminClient.Limits(storage: 5_368_709_120, users: 3))
        let account = try #require(result.accounts.first)
        #expect(account.subdomain == "acme")
        #expect(account.plan.name == "10GB")
        let user = try #require(account.users.first)
        #expect(user.admin && user.clientAppEnabled && !user.apiEnabled)
        #expect(user.emailAddressValidatedAt == nil)
        #expect(user.oauthTokens == [AdminClient.OAuthToken(application: "client-app", scopes: ["uploads.write", "admin"],
                                                             createdAt: "2026-10-31T09:00:00Z", expired: false)])
        #expect(StubProtocol.requests.first?.method == "GET")
        #expect(StubProtocol.requests.first?.url == "https://api.example.test/admin/accounts")
        #expect(StubProtocol.requests.first?.headers["Authorization"] == "Bearer access")
    }

    @Test func showsOneAccount() async throws {
        StubProtocol.responses = [Self.json(Self.account)]

        let account = try await client.account("acme")

        #expect(account.name == "Acme")
        #expect(StubProtocol.requests.first?.url == "https://api.example.test/admin/accounts/acme")
    }

    @Test func changesTheAccountsPlan() async throws {
        StubProtocol.responses = [Self.json(Self.account)]

        let account = try await client.setPlan("acme", plan: "10gb")

        #expect(account.plan.name == "10GB")
        #expect(StubProtocol.requests.first?.method == "PATCH")
        #expect(StubProtocol.requests.first?.url == "https://api.example.test/admin/accounts/acme")
        let body = try #require(try JSONSerialization.jsonObject(with: StubProtocol.requests[0].body) as? [String: Any])
        #expect(body as NSDictionary == ["plan": "10gb"] as NSDictionary)
    }

    @Test func tellsWhyAPlanWasRefused() async throws {
        StubProtocol.responses = [Self.json(["errors": ["Plan is not included in the list"]], status: 422)]

        await #expect(throws: ClientAppError.http(status: 422, message: "Plan is not included in the list")) {
            _ = try await client.setPlan("acme", plan: "20GB")
        }
    }

    @Test func refusesAUserWhoIsntAnAdminAndAnUnknownAccount() async throws {
        StubProtocol.responses = [(403, Data()), (404, Data())]

        await #expect(throws: ClientAppError.http(status: 403, message: HTTPURLResponse.localizedString(forStatusCode: 403))) {
            _ = try await client.accounts()
        }
        await #expect(throws: ClientAppError.http(status: 404, message: HTTPURLResponse.localizedString(forStatusCode: 404))) {
            _ = try await client.account("nobody")
        }
    }
}
}
