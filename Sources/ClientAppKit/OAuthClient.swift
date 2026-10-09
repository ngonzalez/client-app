import Foundation

/// Signs the user in through the browser, like `az login`: open the
/// backend's /oauth/authorize, wait for the redirect on the local server,
/// exchange the code (with the PKCE verifier) for tokens. Then hands out a
/// valid access token, renewing it with the refresh token when it expires.
public struct OAuthClient: Sendable {
    public static let scope = "uploads.write"

    let configuration: Configuration
    let store: TokenStore
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
        guard let token = try store.load() else { throw ClientAppError.notSignedIn }
        if !token.isExpired() { return token.accessToken }
        guard let refreshToken = token.refreshToken else { throw ClientAppError.notSignedIn }

        do {
            let renewed = try await requestToken([
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "client_id": configuration.clientID,
            ])
            try store.save(renewed)
            return renewed.accessToken
        } catch ClientAppError.http(let status, _) where status == 400 || status == 401 {
            // The refresh token expired or was revoked: sign in again
            try store.delete()
            throw ClientAppError.notSignedIn
        }
    }

    public func logout() throws {
        try store.delete()
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
