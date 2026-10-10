import Foundation

/// Signs the user in through the browser, like `az login`: open the
/// backend's /oauth/authorize, wait for the redirect on the local server,
/// exchange the code (with the PKCE verifier) for tokens. Then hands out a
/// valid access token, renewing it with the refresh token when it expires.
public struct OAuthClient: Sendable {
    public static let scope = "uploads.write"

    let configuration: Configuration
    let store: TokenStore
    /// The tokens, read from the store once per client (one Keychain read
    /// for a whole upload, not one per request)
    let cache = TokenCache()
    let session: URLSession

    public init(configuration: Configuration, store: TokenStore, session: URLSession = .shared) {
        self.configuration = configuration
        self.store = store
        self.session = session
    }

    /// The approval page's address for this sign-in
    public func authorizeURL(redirectURI: String, pkce: PKCE, state: String) -> URL {
        var components = URLComponents(url: configuration.apiURL.appending(path: "oauth/authorize"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: OAuthClient.scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: pkce.method),
        ]
        return components.url!
    }

    /// Sign in through the browser and keep the tokens
    /// - Parameter openURL: opens the approval page (in the default browser)
    @discardableResult
    public func login(openURL: @Sendable (URL) -> Void) async throws -> Token {
        let server = try LoopbackServer()
        defer { server.stop() }
        let port = try await server.start()
        let redirectURI = "http://127.0.0.1:\(port)\(LoopbackServer.callbackPath)"
        let pkce = PKCE()
        let state = PKCE.randomString()

        openURL(authorizeURL(redirectURI: redirectURI, pkce: pkce, state: state))
        let code = try OAuthClient.code(from: try await server.waitForCallback(), state: state)

        let token = try await requestToken([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": configuration.clientID,
            "code_verifier": pkce.verifier,
        ])
        try store.save(token)
        await cache.set(token)
        return token
    }

    /// The code of the redirect, once its `state` is checked
    static func code(from callback: URL, state: String) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        if let error = value("error") { throw ClientAppError.signInDenied(error) }
        guard value("state") == state else { throw ClientAppError.stateMismatch }
        guard let code = value("code") else { throw ClientAppError.invalidResponse }
        return code
    }

    /// A valid access token: the stored one, or a renewed one
    public func accessToken() async throws -> String {
        try await cache.accessToken(store: store) { refreshToken in
            try await requestToken([
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "client_id": configuration.clientID,
            ])
        }
    }

    public func logout() async throws {
        try store.delete()
        await cache.set(nil)
    }

    private func requestToken(_ form: [String: String]) async throws -> Token {
        var request = URLRequest(url: configuration.apiURL.appending(path: "oauth/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = OAuthClient.formBody(form)
        let (data, response) = try await session.data(for: request)

        struct TokenResponse: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Double
        }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: try checked(data, response))
        return Token(accessToken: decoded.access_token, refreshToken: decoded.refresh_token,
                     expiresAt: Date().addingTimeInterval(decoded.expires_in))
    }

    static func formBody(_ form: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(form.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)" }
            .joined(separator: "&").utf8)
    }
}

/// The tokens kept in memory: the store (the Keychain) is read the first
/// time they are needed, then only written when they change. An expired
/// token is renewed once, even when several uploads need it at the same
/// time: they all wait for that one renewal (a refresh token is replaced
/// when it is used, so a second renewal with it could be refused)
actor TokenCache {
    private var token: Token?
    private var loaded = false
    private var renewal: Task<Token, Error>?

    func current(from store: TokenStore) throws -> Token? {
        if !loaded {
            token = try store.load()
            loaded = true
        }
        return token
    }

    func set(_ token: Token?) {
        self.token = token
        loaded = true
    }

    /// A valid access token: the kept one, or one renewal shared by everyone
    /// asking meanwhile
    func accessToken(store: TokenStore, renew: @escaping @Sendable (String) async throws -> Token) async throws -> String {
        if let renewal { return try await finish(renewal, store: store).accessToken }
        guard let token = try current(from: store) else { throw ClientAppError.notSignedIn }
        if !token.isExpired() { return token.accessToken }
        guard let refreshToken = token.refreshToken else { throw ClientAppError.notSignedIn }

        let task = Task { try await renew(refreshToken) }
        renewal = task
        return try await finish(task, store: store).accessToken
    }

    /// The outcome of a renewal, saved once: a refused one (400, 401) means
    /// the refresh token expired or was revoked, so sign in again
    private func finish(_ task: Task<Token, Error>, store: TokenStore) async throws -> Token {
        do {
            let renewed = try await task.value
            if renewal == task {
                renewal = nil
                try store.save(renewed)
                token = renewed
            }
            return renewed
        } catch ClientAppError.http(let status, _) where status == 400 || status == 401 {
            if renewal == task {
                renewal = nil
                try store.delete()
                token = nil
            }
            throw ClientAppError.notSignedIn
        } catch {
            if renewal == task { renewal = nil }
            throw error
        }
    }
}
