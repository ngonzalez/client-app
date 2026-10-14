import Foundation
import Testing
@testable import ClientAppKit

/// The uploader and the token renewal against a stubbed network
/// (`StubProtocol` records the requests and answers in order)
extension Stubbed {
@Suite struct NetworkTests {
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
        #expect(requests[0].url == "https://api.example.test/upload/direct")
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

        #expect(requests[2].url == "https://api.example.test/upload/direct/\(Self.uuid)/complete")
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

        try await uploader.waitUntilDone(Self.uuid, first: .milliseconds(1))

        #expect(StubProtocol.requests.map(\.url) == Array(repeating: "https://api.example.test/upload/direct/\(Self.uuid)", count: 2))
    }

    @Test func stopsWaitingAfterTheTimeout() async {
        StubProtocol.responses = Array(repeating: Self.json(200, ["uuid": Self.uuid, "status": "processing"]), count: 50)

        await #expect(throws: ClientAppError.self) {
            try await uploader.waitUntilDone(Self.uuid, first: .milliseconds(1), maximum: .milliseconds(2), timeout: .milliseconds(20))
        }
    }

    // MARK: Several files

    /// A backend answering every step, with an upload uuid per file
    static func backend(failing failedName: String? = nil) -> @Sendable (StubProtocol.Request) -> StubProtocol.Response {
        let counter = Counter()
        return { request in
            switch (request.method, request.url) {
            case ("POST", let url) where url.hasSuffix("/upload/direct"):
                let body = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]) ?? [:]
                if let failedName, (body["filePath"] as? String)?.hasSuffix(failedName) == true {
                    return json(422, ["message": "This file type is not supported"])
                }
                let uuid = "upload-\(counter.next())"
                return json(201, ["uuid": uuid, "signedBlobId": "blob-\(uuid)",
                                  "directUpload": ["url": "https://storage.example.test/\(uuid)?sig=1", "headers": ["x-ms-blob-type": "BlockBlob"]]])
            case ("PUT", _):
                return (201, Data())
            case ("POST", let url) where url.hasSuffix("/complete"):
                let uuid = url.components(separatedBy: "/").dropLast().last!
                return json(202, ["uuid": uuid, "status": "processing"])
            case ("GET", let url):
                return json(200, ["uuid": url.components(separatedBy: "/").last!, "status": "done"])
            default:
                return (404, Data())
            }
        }
    }

    func files(_ count: Int) throws -> [UploadItem] {
        let folder = FileManager.default.temporaryDirectory.appending(path: "client-app-many-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try (1...count).map { index in
            let url = folder.appending(path: "file\(index).png")
            try Data("file \(index)".utf8).write(to: url)
            return UploadItem(url: url)
        }
    }

    @Test func uploadsEveryFileFourAtATime() async throws {
        StubProtocol.responder = Self.backend()
        StubProtocol.delay = 0.02
        let items = try files(10)

        let outcomes = await uploader.uploadAll(items, concurrency: 4)

        #expect(outcomes.count == 10)
        #expect(outcomes.allSatisfy { $0.step == .sent && $0.uuid != nil })
        #expect(Set(outcomes.map(\.item.url)) == Set(items.map(\.url)))
        #expect(StubProtocol.requests.filter { $0.method == "PUT" }.count == 10)
        let overlap = StubProtocol.lock.withLock { StubProtocol.maxInFlight["PUT"] ?? 0 }
        #expect(overlap > 1)
        #expect(StubProtocol.lock.withLock { StubProtocol.maxInFlight.values.max() ?? 0 } <= 4)
    }

    @Test func waitsForTheFilesOnceAllAreSent() async throws {
        StubProtocol.responder = Self.backend()
        let items = try files(6)

        let outcomes = await uploader.uploadAll(items, concurrency: 4, wait: true)

        #expect(outcomes.count == 12)
        let lastSent = try #require(outcomes.lastIndex { $0.step == .sent })
        let firstDone = try #require(outcomes.firstIndex { $0.step == .done })
        #expect(lastSent < firstDone)
        #expect(outcomes.filter { $0.step == .done }.count == 6)
    }

    @Test func aFailedFileDoesNotStopTheOthers() async throws {
        StubProtocol.responder = Self.backend(failing: "file2.png")
        let items = try files(5)
        let reported = OutcomeBox()

        let outcomes = await uploader.uploadAll(items, concurrency: 2, wait: true) { reported.append($0) }

        #expect(outcomes.filter { $0.step == .failed }.map(\.item.url.lastPathComponent) == ["file2.png"])
        #expect(outcomes.filter { $0.step == .done }.count == 4)
        #expect(reported.count == outcomes.count)
    }

    @Test func checksSoonThenLessOften() async throws {
        StubProtocol.responses = [Self.json(200, ["uuid": Self.uuid, "status": "processing"]),
                                  Self.json(200, ["uuid": Self.uuid, "status": "done"])]
        let start = ContinuousClock.now

        try await uploader.waitUntilDone(Self.uuid)

        // 250 ms, then 500 ms: done in well under the old 2 s per check
        let elapsed = ContinuousClock.now - start
        #expect(elapsed >= .milliseconds(700))
        #expect(elapsed < .milliseconds(1500))
    }

    // MARK: Token renewal

    @Test func uploadsSideBySideRenewAnExpiredTokenOnce() async throws {
        let store = CountingTokenStore(Token(accessToken: "old", refreshToken: "refresh", expiresAt: Date().addingTimeInterval(-10)))
        StubProtocol.responder = { _ in Self.json(200, ["access_token": "new", "refresh_token": "refresh-2", "expires_in": 3600]) }
        StubProtocol.delay = 0.05
        let client = self.client(store)

        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<4 { group.addTask { try await client.accessToken() } }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        #expect(tokens == ["new", "new", "new", "new"])
        #expect(StubProtocol.requests.count == 1)
        #expect(store.saves == 1)
    }

    @Test func uploadsSideBySideShareARefusedRenewal() async throws {
        let store = CountingTokenStore(Token(accessToken: "old", refreshToken: "revoked", expiresAt: Date().addingTimeInterval(-10)))
        StubProtocol.responder = { _ in Self.json(400, ["error": "invalid_grant"]) }
        StubProtocol.delay = 0.05
        let client = self.client(store)

        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    do { _ = try await client.accessToken(); return false } catch { return (error as? ClientAppError) == .notSignedIn }
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }

        #expect(results == [true, true, true, true])
        #expect(StubProtocol.requests.count == 1)
        #expect(try store.load() == nil)
    }

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
}

/// Records each request and answers with the next queued response
final class StubProtocol: URLProtocol, @unchecked Sendable {
    typealias Response = (status: Int, body: Data)
    struct Request { let method: String; let url: String; let headers: [String: String]; let body: Data }

    nonisolated(unsafe) static var responses: [Response] = []
    nonisolated(unsafe) static var requests: [Request] = []
    /// Answers by request instead of in order (requests sent side by side)
    nonisolated(unsafe) static var responder: (@Sendable (Request) -> Response)?
    /// How long each answer takes, to see the requests that overlap
    nonisolated(unsafe) static var delay: TimeInterval = 0
    nonisolated(unsafe) static var inFlight = 0
    nonisolated(unsafe) static var maxInFlight: [String: Int] = [:]
    static let lock = NSLock()

    static func reset() {
        lock.withLock { responses = []; requests = []; responder = nil; delay = 0; inFlight = 0; maxInFlight = [:] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let recorded = Request(method: request.httpMethod ?? "GET", url: request.url!.absoluteString,
                               headers: request.allHTTPHeaderFields ?? [:], body: Self.body(of: request))
        let (response, delay) = Self.lock.withLock { () -> (Response, TimeInterval) in
            Self.requests.append(recorded)
            Self.inFlight += 1
            Self.maxInFlight[recorded.method] = max(Self.maxInFlight[recorded.method] ?? 0, Self.inFlight)
            if let responder = Self.responder { return (responder(recorded), Self.delay) }
            return (Self.responses.isEmpty ? (500, Data()) : Self.responses.removeFirst(), Self.delay)
        }
        // answered later without blocking the loading thread, so that the
        // requests sent side by side really overlap
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            Self.lock.withLock { Self.inFlight -= 1 }
            let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response.body)
            client?.urlProtocolDidFinishLoading(self)
        }
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

/// A counter shared by the stub's answers
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}

/// The outcomes a closure reported, for the tests
final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [DirectUploader.Outcome] = []
    func append(_ outcome: DirectUploader.Outcome) { lock.withLock { outcomes.append(outcome) } }
    var count: Int { lock.withLock { outcomes.count } }
}
