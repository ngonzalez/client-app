import Foundation
import Testing
@testable import ClientAppKit

@Suite struct PKCETests {
    @Test func challengeIsTheBase64URLSHA256OfTheVerifier() {
        // reference computed with: printf %s VERIFIER | openssl dgst -sha256 -binary | base64 (URL-safe, no padding)
        #expect(PKCE(verifier: "client-app-test-verifier-0123456789-abcdefghijklmnop").challenge == "NajUzjV-DZYuIh34zoghiGWfj3Yb3Jl6qYVgdRyVYkw")
    }

    @Test func verifiersAreRandomAndURLSafe() {
        let first = PKCE(), second = PKCE()
        #expect(first.verifier != second.verifier)
        #expect(first.verifier.count >= 43)
        #expect(first.verifier.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }
}

@Suite struct OAuthClientTests {
    let client = OAuthClient(configuration: Configuration(apiURL: URL(string: "https://api.example.test")!, clientID: "the-client"),
                             store: MemoryTokenStore())

    @Test func authorizeURLAsksForACodeWithPKCE() throws {
        let pkce = PKCE()
        let url = client.authorizeURL(redirectURI: "http://127.0.0.1:5000/callback", pkce: pkce, state: "xyz")
        let items = Dictionary(uniqueKeysWithValues: try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems).map { ($0.name, $0.value) })

        #expect(url.path() == "/oauth/authorize")
        #expect(items["client_id"] == "the-client")
        #expect(items["response_type"] == "code")
        #expect(items["scope"] == "uploads.write folders.read folders.write")
        #expect(items["state"] == "xyz")
        #expect(items["code_challenge"] == pkce.challenge)
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["redirect_uri"] == "http://127.0.0.1:5000/callback")
    }

    @Test func codeOfTheRedirect() throws {
        #expect(try OAuthClient.code(from: URL(string: "http://127.0.0.1:1/callback?code=abc&state=xyz")!, state: "xyz") == "abc")
    }

    @Test func refusesAnotherState() {
        #expect(throws: ClientAppError.stateMismatch) {
            try OAuthClient.code(from: URL(string: "http://127.0.0.1:1/callback?code=abc&state=other")!, state: "xyz")
        }
    }

    @Test func reportsADeniedSignIn() {
        #expect(throws: ClientAppError.signInDenied("access_denied")) {
            try OAuthClient.code(from: URL(string: "http://127.0.0.1:1/callback?error=access_denied&state=xyz")!, state: "xyz")
        }
    }

    @Test func withoutTokensTheUserIsNotSignedIn() async {
        await #expect(throws: ClientAppError.notSignedIn) { try await client.accessToken() }
    }

    @Test func aValidTokenIsUsedAsIs() async throws {
        let store = MemoryTokenStore()
        try store.save(Token(accessToken: "valid", refreshToken: "r", expiresAt: Date().addingTimeInterval(3600)))
        let client = OAuthClient(configuration: Configuration(clientID: "c"), store: store)
        #expect(try await client.accessToken() == "valid")
    }

    @Test func formBodyIsPercentEncoded() {
        #expect(String(decoding: OAuthClient.formBody(["b": "a b&c", "a": "http://x/y"]), as: UTF8.self) == "a=http%3A%2F%2Fx%2Fy&b=a%20b%26c")
    }

    @Test func tokensAreRenewedAMinuteEarly() {
        let now = Date()
        #expect(Token(accessToken: "a", refreshToken: nil, expiresAt: now.addingTimeInterval(30)).isExpired(now: now))
        #expect(!Token(accessToken: "a", refreshToken: nil, expiresAt: now.addingTimeInterval(120)).isExpired(now: now))
    }
}

@Suite struct LoopbackServerTests {
    @Test func waitsForTheCallbackAndIgnoresOtherRequests() async throws {
        let server = try LoopbackServer()
        defer { server.stop() }
        let port = try await server.start()
        #expect(port > 0)

        let (_, favicon) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/favicon.ico")!)
        #expect((favicon as? HTTPURLResponse)?.statusCode == 404)

        let (page, callback) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/callback?code=abc&state=xyz")!)
        #expect((callback as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: page, as: UTF8.self).contains("You are signed in"))

        let url = try await server.waitForCallback()
        #expect(url.path() == "/callback")
        #expect(url.query() == "code=abc&state=xyz")
    }

    @Test func requestTargetOfAGET() {
        #expect(LoopbackServer.requestTarget(of: Data("GET /callback?code=a HTTP/1.1\r\nHost: x\r\n\r\n".utf8)) == "/callback?code=a")
        #expect(LoopbackServer.requestTarget(of: Data("POST /callback HTTP/1.1\r\n\r\n".utf8)) == nil)
        #expect(LoopbackServer.requestTarget(of: Data("garbage".utf8)) == nil)
    }
}

@Suite struct FilesTests {
    func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "client-app-tests-\(UUID().uuidString)/Holidays")
        try FileManager.default.createDirectory(at: folder.appending(path: "Beach/Day 1/Too deep"), withIntermediateDirectories: true)
        for path in ["a.jpg", ".hidden", "Beach/b.png", "Beach/Day 1/c.mp4", "Beach/Day 1/Too deep/d.jpg"] {
            try Data(path.utf8).write(to: folder.appending(path: path))
        }
        return folder
    }

    @Test func detailsOfAFile() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "client-app-\(UUID().uuidString).png")
        try Data("hello".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let details = try FileDetails(url: file)
        #expect(details.byteSize == 5)
        #expect(details.checksum == "XUFAKrxLKna5cZ2REBfFkg==") // openssl dgst -md5 -binary | base64
        #expect(details.mimeType == "image/png")
    }

    @Test func filesOfAFolderDownToTwoLevels() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        let items = Dictionary(uniqueKeysWithValues: try UploadItem.items(inFolder: folder).map { ($0.url.lastPathComponent, $0.source) })
        #expect(items == ["a.jpg": .root, "b.png": .folder, "c.mp4": .subfolder])
    }
}

/// Tokens in memory, for the tests
final class MemoryTokenStore: TokenStore, @unchecked Sendable {
    private var token: Token?
    func load() throws -> Token? { token }
    func save(_ token: Token) throws { self.token = token }
    func delete() throws { token = nil }
}
