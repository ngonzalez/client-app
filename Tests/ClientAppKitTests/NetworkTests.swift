import Foundation
import Testing
@testable import ClientAppKit

/// The uploader and the token renewal against a stubbed network
/// (`StubProtocol` records the requests and answers in order)
@Suite(.serialized) struct NetworkTests {
    static let uuid = "0f8fad5b-d9cb-469f-a165-70867728950e"
    static let signedURL = "https://storage.example.test/container/key?sig=abc"

    let session: URLSession
    let file: URL

    init() throws {
        StubProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        session = URLSession(configuration: configuration)
        file = FileManager.default.temporaryDirectory.appending(path: "client-app-\(UUID().uuidString).png")
        try Data("hello".utf8).write(to: file)
    }

    static func json(_ status: Int, _ body: [String: Any]) -> StubProtocol.Response {
        (status, try! JSONSerialization.data(withJSONObject: body))
    }

    static let created = json(201, [
        "uuid": uuid, "signedBlobId": "signed-blob",
        "directUpload": ["url": signedURL, "headers": ["Content-MD5": "XUFAKrxLKna5cZ2REBfFkg==", "x-ms-blob-type": "BlockBlob"]],
    ])

    var uploader: DirectUploader {
        DirectUploader(apiURL: URL(string: "https://api.example.test")!, session: session, accessToken: { "access" })
    }

    // MARK: DirectUploader

    @Test func uploadsInOnePutBetweenTheTwoAPICalls() async throws {
        // a backend that doesn't send the account: no event
        StubProtocol.responses = [Self.created, (201, Data()), Self.json(202, ["uuid": Self.uuid, "status": "processing"])]

        #expect(try await uploader.upload(UploadItem(url: file, source: .folder)) == Self.uuid)

        let requests = StubProtocol.requests
        try #require(requests.count == 3)
        #expect(requests[0].url == "https://api.example.test/api/v1/direct_uploads")
        #expect(requests[0].headers["Authorization"] == "Bearer access")
        let details = try #require(try JSONSerialization.jsonObject(with: requests[0].body) as? [String: Any])
        #expect(details["source"] as? String == "folder")
        #expect(details["byteSize"] as? Int == 5)
        #expect(details["checksum"] as? String == "XUFAKrxLKna5cZ2REBfFkg==")
        #expect(details["mimeType"] as? String == "image/png")

        #expect(requests[1].method == "PUT")
        #expect(requests[1].url == Self.signedURL)
        #expect(requests[1].headers["Authorization"] == nil)
        #expect(requests[1].headers["x-ms-blob-type"] == "BlockBlob")

        #expect(requests[2].url == "https://api.example.test/api/v1/direct_uploads/\(Self.uuid)/complete")
    }

    static let completed = json(202, ["uuid": uuid, "status": "processing", "accountUuid": "8683e470-9ce2-4c56-8814-20e751b7bdc3"])

    @Test func recordsTheUploadEventOfTheAccount() async throws {
        StubProtocol.responses = [Self.created, (201, Data()), Self.completed, Self.json(200, ["event": [:]])]

        #expect(try await uploader.upload(UploadItem(url: file, source: .folder)) == Self.uuid)

        let requests = StubProtocol.requests
        try #require(requests.count == 4)
        let event = requests[3]
        #expect(event.method == "POST")
        #expect(event.url == "https://api.example.test/event")
        #expect(event.headers["Authorization"] == nil)
        let body = try #require(try JSONSerialization.jsonObject(with: event.body) as? [String: Any])
        #expect(body["accountUuid"] as? String == "8683e470-9ce2-4c56-8814-20e751b7bdc3")
        #expect(body["eventType"] as? String == "upload")
        #expect(body["url"] as? String == "https://api.example.test/upload/\(Self.uuid)")
        let encoded = try #require(body["parameters"] as? String)
        let decoded = try #require(Data(base64Encoded: encoded))
        let parameters = try #require(try JSONSerialization.jsonObject(with: decoded) as? [String: Any])
        let upload = try #require(parameters["uploadDetails"] as? [String: Any])
        #expect(upload["fileSize"] as? Int == 5)
        #expect(upload["fileName"] as? String == file.path)
        #expect(upload["mimeType"] as? String == "image/png")
        let platform = try #require(parameters["platformDetails"] as? [String: String])
        #expect(platform["Application"] == "client-app")
        #expect(platform["Platform"] == "macOS")
    }

    @Test func aFailedEventDoesNotFailTheUpload() async throws {
        StubProtocol.responses = [Self.created, (201, Data()), Self.completed, Self.json(422, ["message": "Invalid event"])]
        let errors = ErrorBox()
        let uploader = DirectUploader(apiURL: URL(string: "https://api.example.test")!, session: session,
                                      onEventError: { errors.append($0) }, accessToken: { "access" })

        #expect(try await uploader.upload(UploadItem(url: file)) == Self.uuid)
        #expect(errors.all.count == 1)
        #expect(errors.all.first as? ClientAppError == .http(status: 422, message: "Invalid event"))
    }

    @Test func aRefusedFileIsNotSent() async {
        StubProtocol.responses = [Self.json(422, ["message": "This file type is not supported"])]

        await #expect(throws: ClientAppError.http(status: 422, message: "This file type is not supported")) {
            try await uploader.upload(UploadItem(url: file))
        }
        #expect(StubProtocol.requests.count == 1)
    }

    @Test func aFailedPutIsNotCompleted() async {
        StubProtocol.responses = [Self.created, (403, Data("<Error/>".utf8))]

        await #expect(throws: ClientAppError.self) { try await uploader.upload(UploadItem(url: file)) }
        #expect(StubProtocol.requests.count == 2)
    }

    @Test func waitsUntilTheUploadIsDone() async throws {
        StubProtocol.responses = [Self.json(200, ["uuid": Self.uuid, "status": "processing"]), Self.json(200, ["uuid": Self.uuid, "status": "done"])]

        try await uploader.waitUntilDone(Self.uuid, every: .milliseconds(1))

        #expect(StubProtocol.requests.map(\.url) == Array(repeating: "https://api.example.test/api/v1/direct_uploads/\(Self.uuid)", count: 2))
    }

    @Test func stopsWaitingAfterTheTimeout() async {
        StubProtocol.responses = Array(repeating: Self.json(200, ["uuid": Self.uuid, "status": "processing"]), count: 50)

        await #expect(throws: ClientAppError.self) {
            try await uploader.waitUntilDone(Self.uuid, every: .milliseconds(1), timeout: .milliseconds(20))
        }
    }

    // MARK: Token renewal

    func client(_ store: TokenStore) -> OAuthClient {
        OAuthClient(configuration: Configuration(apiURL: URL(string: "https://api.example.test")!, clientID: "the-client"), store: store, session: session)
    }

    @Test func renewsAnExpiredTokenWithTheRefreshToken() async throws {
        let store = MemoryTokenStore()
        try store.save(Token(accessToken: "old", refreshToken: "refresh", expiresAt: Date().addingTimeInterval(-10)))
        StubProtocol.responses = [Self.json(200, ["access_token": "new", "refresh_token": "refresh-2", "expires_in": 3600, "token_type": "Bearer"])]

        #expect(try await client(store).accessToken() == "new")

        let request = try #require(StubProtocol.requests.first)
        #expect(request.url == "https://api.example.test/oauth/token")
        #expect(String(decoding: request.body, as: UTF8.self) == "client_id=the-client&grant_type=refresh_token&refresh_token=refresh")
        #expect(try store.load()?.refreshToken == "refresh-2")
    }

    @Test func anExpiredRefreshTokenAsksForANewLogin() async throws {
        let store = MemoryTokenStore()
        try store.save(Token(accessToken: "old", refreshToken: "revoked", expiresAt: Date().addingTimeInterval(-10)))
        StubProtocol.responses = [Self.json(400, ["error": "invalid_grant"])]

        await #expect(throws: ClientAppError.notSignedIn) { try await client(store).accessToken() }
        #expect(try store.load() == nil)
    }

    @Test func aServerErrorKeepsTheTokens() async throws {
        let store = MemoryTokenStore()
        try store.save(Token(accessToken: "old", refreshToken: "refresh", expiresAt: Date().addingTimeInterval(-10)))
        StubProtocol.responses = [(503, Data())]

        await #expect(throws: ClientAppError.self) { try await client(store).accessToken() }
        #expect(try store.load()?.refreshToken == "refresh")
    }
}

/// Records each request and answers with the next queued response
final class StubProtocol: URLProtocol, @unchecked Sendable {
    typealias Response = (status: Int, body: Data)
    struct Request { let method: String; let url: String; let headers: [String: String]; let body: Data }

    nonisolated(unsafe) static var responses: [Response] = []
    nonisolated(unsafe) static var requests: [Request] = []
    static let lock = NSLock()

    static func reset() {
        lock.withLock { responses = []; requests = [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = Self.lock.withLock { () -> Response in
            Self.requests.append(Request(method: request.httpMethod ?? "GET", url: request.url!.absoluteString,
                                         headers: request.allHTTPHeaderFields ?? [:], body: Self.body(of: request)))
            return Self.responses.isEmpty ? (500, Data()) : Self.responses.removeFirst()
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// The errors a closure reported, for the tests
final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [Error] = []
    func append(_ error: Error) { lock.withLock { errors.append(error) } }
    var all: [Error] { lock.withLock { errors } }
}
