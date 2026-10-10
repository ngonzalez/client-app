import CryptoKit
import Foundation
import Testing
@testable import ClientAppKit

/// The whole browser sign-in, the token renewal edge cases, and where the
/// tokens and settings are kept. The token endpoint is stubbed
/// (`StubProtocol`); the local server is real, and the test plays the
/// browser by calling its callback.
extension Stubbed {
@Suite struct LoginAndStorageTests {
    let session: URLSession
    let configuration = Configuration(apiURL: URL(string: "https://api.example.test")!, clientID: "the-client")

    init() {
        StubProtocol.reset()
        let stubbed = URLSessionConfiguration.ephemeral
        stubbed.protocolClasses = [StubProtocol.self]
        session = URLSession(configuration: stubbed)
    }

    static let tokens = NetworkTests.json(200, ["access_token": "access", "refresh_token": "refresh", "expires_in": 3600, "token_type": "Bearer"])

    /// The browser: after the approval page, it is redirected to the app's
    /// local server with these query items
    static func browser(answering items: @escaping @Sendable (URLComponents) -> [URLQueryItem]) -> @Sendable (URL) -> Void {
        { authorizeURL in
            let authorize = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
            let redirect = authorize.queryItems!.first { $0.name == "redirect_uri" }!.value!
            var callback = URLComponents(string: redirect)!
            callback.queryItems = items(authorize)
            Task { _ = try? await URLSession.shared.data(from: callback.url!) }
        }
    }

    static func value(_ name: String, in components: URLComponents) -> String? {
        components.queryItems?.first { $0.name == name }?.value
    }

    @Test func signsInThroughTheBrowserAndKeepsTheTokens() async throws {
        StubProtocol.responses = [Self.tokens]
        let store = MemoryTokenStore()
        let challenge = ChallengeBox()

        let token = try await OAuthClient(configuration: configuration, store: store, session: session).login(
            openURL: Self.browser { authorize in
                challenge.set(Self.value("code_challenge", in: authorize))
                return [URLQueryItem(name: "code", value: "the-code"), URLQueryItem(name: "state", value: Self.value("state", in: authorize))]
            })

        #expect(token.accessToken == "access")
        #expect(try store.load()?.refreshToken == "refresh")

        // the code goes back with the verifier of the challenge sent to the browser
        let request = try #require(StubProtocol.requests.first)
        #expect(request.url == "https://api.example.test/oauth/token")
        let form = Dictionary(uniqueKeysWithValues: String(decoding: request.body, as: UTF8.self).split(separator: "&").map {
            let pair = $0.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding! }
            return (pair[0], pair[1])
        })
        #expect(form["grant_type"] == "authorization_code")
        #expect(form["code"] == "the-code")
        #expect(form["client_id"] == "the-client")
        #expect(form["redirect_uri"]?.hasPrefix("http://127.0.0.1:") == true)
        let verifier = try #require(form["code_verifier"])
        #expect(PKCE.challenge(for: verifier) == challenge.value)
    }

    @Test func aDeniedSignInKeepsNoTokens() async throws {
        let store = MemoryTokenStore()

        await #expect(throws: ClientAppError.signInDenied("access_denied")) {
            try await OAuthClient(configuration: configuration, store: store, session: session).login(
                openURL: Self.browser { authorize in
                    [URLQueryItem(name: "error", value: "access_denied"), URLQueryItem(name: "state", value: Self.value("state", in: authorize))]
                })
        }
        #expect(try store.load() == nil)
        #expect(StubProtocol.requests.isEmpty)
    }

    @Test func refusesACallbackOfAnotherSignIn() async throws {
        await #expect(throws: ClientAppError.stateMismatch) {
            try await OAuthClient(configuration: configuration, store: MemoryTokenStore(), session: session).login(
                openURL: Self.browser { _ in [URLQueryItem(name: "code", value: "c"), URLQueryItem(name: "state", value: "another")] })
        }
    }

    @Test func anExpiredTokenWithoutRefreshTokenAsksForALogin() async throws {
        let store = MemoryTokenStore()
        try store.save(Token(accessToken: "old", refreshToken: nil, expiresAt: Date().addingTimeInterval(-10)))

        await #expect(throws: ClientAppError.notSignedIn) {
            try await OAuthClient(configuration: configuration, store: store, session: session).accessToken()
        }
        #expect(StubProtocol.requests.isEmpty)
    }

    @Test func aRevokedRefreshTokenAnsweredWith401AsksForALogin() async throws {
        let store = MemoryTokenStore()
        try store.save(Token(accessToken: "old", refreshToken: "revoked", expiresAt: Date().addingTimeInterval(-10)))
        StubProtocol.responses = [NetworkTests.json(401, ["error": "invalid_client"])]

        await #expect(throws: ClientAppError.notSignedIn) {
            try await OAuthClient(configuration: configuration, store: store, session: session).accessToken()
        }
        #expect(try store.load() == nil)
    }

    @Test func logoutForgetsTheTokens() async throws {
        let store = MemoryTokenStore()
        try store.save(Token(accessToken: "a", refreshToken: "r", expiresAt: Date().addingTimeInterval(3600)))
        let client = OAuthClient(configuration: configuration, store: store)
        #expect(try await client.accessToken() == "a")

        try await client.logout()

        #expect(try store.load() == nil)
        await #expect(throws: ClientAppError.notSignedIn) { try await client.accessToken() }
    }

    // MARK: One Keychain read per command

    @Test func readsTheStoreOnceForManyRequests() async throws {
        let store = CountingTokenStore(Token(accessToken: "valid", refreshToken: "r", expiresAt: Date().addingTimeInterval(3600)))
        let client = OAuthClient(configuration: configuration, store: store, session: session)

        for _ in 0..<50 { #expect(try await client.accessToken() == "valid") }

        #expect(store.loads == 1)
        #expect(store.saves == 0)
    }

    @Test func aRenewedTokenIsSavedOnceAndKeptInMemory() async throws {
        let store = CountingTokenStore(Token(accessToken: "old", refreshToken: "refresh", expiresAt: Date().addingTimeInterval(-10)))
        StubProtocol.responses = [Self.tokens]
        let client = OAuthClient(configuration: configuration, store: store, session: session)

        for _ in 0..<10 { #expect(try await client.accessToken() == "access") }

        #expect(store.loads == 1)
        #expect(store.saves == 1)
        #expect(StubProtocol.requests.count == 1)
    }

    @Test func aLoginIsUsedWithoutReadingTheStoreAgain() async throws {
        StubProtocol.responses = [Self.tokens]
        let store = CountingTokenStore(nil)
        let client = OAuthClient(configuration: configuration, store: store, session: session)

        try await client.login(openURL: Self.browser { authorize in
            [URLQueryItem(name: "code", value: "c"), URLQueryItem(name: "state", value: Self.value("state", in: authorize))]
        })

        #expect(try await client.accessToken() == "access")
        #expect(store.loads == 0)
    }

    @Test func aRefusedRenewalForgetsTheCachedTokens() async throws {
        let store = CountingTokenStore(Token(accessToken: "old", refreshToken: "revoked", expiresAt: Date().addingTimeInterval(-10)))
        StubProtocol.responses = [NetworkTests.json(400, ["error": "invalid_grant"])]
        let client = OAuthClient(configuration: configuration, store: store, session: session)

        await #expect(throws: ClientAppError.notSignedIn) { try await client.accessToken() }
        await #expect(throws: ClientAppError.notSignedIn) { try await client.accessToken() }

        #expect(store.loads == 1)
        #expect(StubProtocol.requests.count == 1)
    }

    @Test func eachCommandReadsTheStoreAgain() async throws {
        let store = CountingTokenStore(Token(accessToken: "valid", refreshToken: "r", expiresAt: Date().addingTimeInterval(3600)))

        _ = try await OAuthClient(configuration: configuration, store: store).accessToken()
        _ = try await OAuthClient(configuration: configuration, store: store).accessToken()

        #expect(store.loads == 2)
    }

    // MARK: Keychain and settings

    @Test func keepsTheTokensInTheKeychain() throws {
        // a host of its own, so the test never touches a real sign-in
        let store = KeychainTokenStore(apiURL: URL(string: "https://client-app-test-\(UUID().uuidString).invalid")!)
        defer { try? store.delete() }
        let expiresAt = Date(timeIntervalSince1970: 1_800_000_000)

        #expect(try store.load() == nil)
        try store.save(Token(accessToken: "first", refreshToken: "r1", expiresAt: expiresAt))
        try store.save(Token(accessToken: "second", refreshToken: "r2", expiresAt: expiresAt))
        #expect(try store.load() == Token(accessToken: "second", refreshToken: "r2", expiresAt: expiresAt))

        try store.delete()
        #expect(try store.load() == nil)
        try store.delete()
    }

    @Test func savesAndLoadsTheSettings() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "client-app-\(UUID().uuidString)/config.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        #expect(try Configuration.load(from: file) == nil)
        try configuration.save(to: file)
        #expect(try Configuration.load(from: file) == configuration)
    }

    @Test func theDefaultBackendIsAppshare() {
        #expect(Configuration(clientID: "c").apiURL.absoluteString == "https://api.appshare.site")
    }

    // MARK: Files

    @Test func md5OfAFileLargerThanOnePiece() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "client-app-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: file) }
        let data = Data((0..<(9 * 1024 * 1024)).map { UInt8($0 % 251) })
        try data.write(to: file)

        #expect(try FileDetails.md5(of: file) == Data(Insecure.MD5.hash(data: data)).base64EncodedString())
    }

    @Test func anUnknownTypeIsSentAsBinary() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "client-app-\(UUID().uuidString).unknownext")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("x".utf8).write(to: file)

        #expect(try FileDetails(url: file).mimeType == "application/octet-stream")
    }

    @Test func aSingleFileIsInTheFolderItself() {
        #expect(UploadItem(url: URL(fileURLWithPath: "/tmp/a.png")).source == .root)
    }
}
}

/// A value set from a Sendable closure, for the tests
final class ChallengeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    func set(_ value: String?) { lock.withLock { stored = value } }
    var value: String? { lock.withLock { stored } }
}

/// A token store that counts how often it is read and written
final class CountingTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: Token?
    private var loadCount = 0
    private var saveCount = 0

    init(_ token: Token?) { self.token = token }

    var loads: Int { lock.withLock { loadCount } }
    var saves: Int { lock.withLock { saveCount } }

    func load() throws -> Token? { lock.withLock { loadCount += 1; return token } }
    func save(_ token: Token) throws { lock.withLock { saveCount += 1; self.token = token } }
    func delete() throws { lock.withLock { token = nil } }
}
