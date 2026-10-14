import Foundation
import Testing
@testable import ClientAppKit

/// The folders, through the endpoints MauiApp uses too, against a stubbed
/// network
extension Stubbed {
@Suite struct FolderClientTests {
    let session: URLSession

    init() {
        StubProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        session = URLSession(configuration: configuration)
    }

    var client: FolderClient {
        FolderClient(apiURL: URL(string: "https://api.example.test")!, session: session, accessToken: { "access" })
    }

    static func folder(_ id: Int, _ name: String, state: String = "created", tags: [String]? = []) -> [String: Any] {
        var folder: [String: Any] = ["id": id, "state": state, "name": name, "dataUrl": name.lowercased(),
                                     "webUrl": "https://acme.appshare.site/\(name.lowercased())", "folderUrl": "x"]
        folder["tags"] = tags ?? NSNull()
        return folder
    }

    static func page(_ folders: [[String: Any]], page: Int = 1, totalPages: Int = 1, totalCount: Int? = nil) -> StubProtocol.Response {
        (200, try! JSONSerialization.data(withJSONObject: ["folders": folders, "page": page, "totalPages": totalPages,
                                                           "totalCount": totalCount ?? folders.count]))
    }

    @Test func listsAPageOfFoldersWithTheToken() async throws {
        StubProtocol.responses = [Self.page([Self.folder(1, "Beach", tags: ["summer"]), Self.folder(2, "Snow", state: "published", tags: nil)])]

        let page = try await client.list()

        #expect(page.folders.map(\.name) == ["Beach", "Snow"])
        #expect(page.folders[0] == FolderClient.Folder(id: 1, state: "created", name: "Beach", tags: ["summer"], dataUrl: "beach",
                                                       webUrl: "https://acme.appshare.site/beach"))
        #expect(page.folders[1].tags == nil)
        #expect(page.totalCount == 2)
        let request = try #require(StubProtocol.requests.first)
        #expect(request.method == "GET")
        #expect(request.url == "https://api.example.test/folders?page=1&perPage=25")
        #expect(request.headers["Authorization"] == "Bearer access")
    }

    @Test func searchesByNameOrTagInAState() async throws {
        StubProtocol.responses = [Self.page([])]

        _ = try await client.list(query: "summer trip", state: "archived", page: 2, perPage: 10)

        let url = try #require(URLComponents(string: StubProtocol.requests.first?.url ?? ""))
        #expect(url.path == "/folders")
        #expect(url.queryItems == [URLQueryItem(name: "page", value: "2"), URLQueryItem(name: "perPage", value: "10"),
                                   URLQueryItem(name: "q", value: "summer trip"), URLQueryItem(name: "state", value: "archived")])
    }

    @Test func listsEveryPage() async throws {
        StubProtocol.responses = [Self.page([Self.folder(1, "A")], page: 1, totalPages: 2, totalCount: 2),
                                  Self.page([Self.folder(2, "B")], page: 2, totalPages: 2, totalCount: 2)]

        #expect(try await client.listAll(query: "x").map(\.id) == [1, 2])
        #expect(StubProtocol.requests.map(\.url) == ["https://api.example.test/folders?page=1&perPage=100&q=x",
                                                     "https://api.example.test/folders?page=2&perPage=100&q=x"])
    }

    @Test func listsNothingInOneRequest() async throws {
        StubProtocol.responses = [Self.page([], totalPages: 0)]

        #expect(try await client.listAll().isEmpty)
        #expect(StubProtocol.requests.count == 1)
    }

    @Test(arguments: FolderClient.Action.allCases)
    func changesTheFolders(_ action: FolderClient.Action) async throws {
        StubProtocol.responses = [(200, try JSONSerialization.data(withJSONObject: ["ids": [3]]))]

        #expect(try await client.perform(action, ids: [3, 5]) == [3])

        let request = try #require(StubProtocol.requests.first)
        #expect(request.method == "POST")
        #expect(request.url == "https://api.example.test/folders/\(action.rawValue)")
        #expect(request.headers["Authorization"] == "Bearer access")
        let body = try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: [Int]])
        #expect(body == ["id": [3, 5]])
    }

    @Test func aTokenWithoutTheFolderScopesIsRefused() async {
        StubProtocol.responses = [(403, Data())]

        await #expect(throws: ClientAppError.http(status: 403, message: "forbidden")) {
            try await client.perform(.delete, ids: [1])
        }
    }
}
}
