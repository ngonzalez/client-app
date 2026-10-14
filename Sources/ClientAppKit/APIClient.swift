import Foundation

/// The backend's JSON requests, with the access token: the endpoints the
/// apps share (MauiApp and DemoApp send a session token, this app its OAuth
/// token)
struct APIClient: Sendable {
    let apiURL: URL
    let session: URLSession
    let accessToken: @Sendable () async throws -> String

    /// Send a request and decode its JSON answer
    func send<Response: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [],
                                   body: [String: Any]? = nil) async throws -> Response {
        try JSONDecoder().decode(Response.self, from: try await send(method, path, query: query, body: body))
    }

    /// Send a request
    /// - Returns: the answer's body, once its status is 2xx (`checked`)
    @discardableResult
    func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> Data {
        var components = URLComponents(url: apiURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        return try checked(data, response)
    }
}
