import CryptoKit
import Foundation

/// Proof Key for Code Exchange (RFC 7636): the app keeps the verifier and
/// sends its SHA-256 (the challenge) with the authorization request, so a
/// code intercepted on its way to the local server is useless to anyone else.
public struct PKCE: Sendable {
    public let verifier: String
    public var challenge: String { PKCE.challenge(for: verifier) }
    public let method = "S256"

    public init(verifier: String = PKCE.randomString(byteCount: 48)) {
        self.verifier = verifier
    }

    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// A random URL-safe string (also used for the OAuth `state`)
    public static func randomString(byteCount: Int = 32) -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(Data((0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
