import Foundation

public enum ClientAppError: LocalizedError, Equatable {
    case notSignedIn
    case signInDenied(String)
    case stateMismatch
    case http(status: Int, message: String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .notSignedIn: "Not signed in: run `client-app login`."
        case .signInDenied(let error): "The sign-in was refused (\(error))."
        case .stateMismatch: "The sign-in answer doesn't match the request (state)."
        case .http(let status, let message): "HTTP \(status): \(message)"
        case .invalidResponse: "The server's answer can't be read."
        }
    }
}

/// Every response is checked: a status outside 2xx throws, with the
/// server's `message` (or OAuth `error_description`) when it sends one
func checked(_ data: Data, _ response: URLResponse) throws -> Data {
    guard let http = response as? HTTPURLResponse else { throw ClientAppError.invalidResponse }
    guard (200..<300).contains(http.statusCode) else {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let message = (json?["message"] ?? json?["error_description"] ?? json?["error"]) as? String
        throw ClientAppError.http(status: http.statusCode, message: message ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
    }
    return data
}
