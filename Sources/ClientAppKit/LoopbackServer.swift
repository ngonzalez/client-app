import Foundation
import Network

/// The app's local server for the sign-in (RFC 8252): it listens on
/// 127.0.0.1 on a port the system picks, and waits for the browser's
/// redirect to /callback after the approval page. Any other request (e.g.
/// /favicon.ico) gets a 404 and the server keeps waiting.
public final class LoopbackServer: @unchecked Sendable {
    public static let callbackPath = "/callback"

    // Everything below is only touched on `queue`
    private let queue = DispatchQueue(label: "client-app.loopback")
    private let listener: NWListener
    private var startContinuation: CheckedContinuation<UInt16, Error>?
    private var continuation: CheckedContinuation<URL, Error>?
    private var result: Result<URL, Error>?

    public init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    /// Start listening
    /// - Returns: the port the system picked
    public func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (started: CheckedContinuation<UInt16, Error>) in
            startContinuation = started
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, let started = self.startContinuation else { return }
                switch state {
                case .ready:
                    self.startContinuation = nil
                    started.resume(returning: self.listener.port?.rawValue ?? 0)
                case .failed(let error):
                    self.startContinuation = nil
                    started.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.start(queue: queue)
        }
    }

    /// The redirect's URL, with `code` and `state` (or `error`)
    public func waitForCallback() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let result = self.result {
                    continuation.resume(with: result)
                } else {
                    self.continuation = continuation
                }
            }
        }
    }

    public func stop() {
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let target = data.flatMap { LoopbackServer.requestTarget(of: $0) }
            guard let target, let url = URL(string: "http://127.0.0.1:\(self.listener.port?.rawValue ?? 0)\(target)"),
                  url.path == LoopbackServer.callbackPath else {
                LoopbackServer.respond(connection, status: "404 Not Found", body: "Not found")
                return
            }
            LoopbackServer.respond(connection, status: "200 OK", body: LoopbackServer.page(for: url))
            self.finish(.success(url))
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
    }

    /// The target of an HTTP request's first line: "GET /callback?code=… HTTP/1.1"
    static func requestTarget(of request: Data) -> String? {
        guard let line = String(decoding: request, as: UTF8.self).split(separator: "\r\n").first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[0] == "GET", parts[1].hasPrefix("/") else { return nil }
        return String(parts[1])
    }

    static func page(for url: URL) -> String {
        let denied = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "error" } ?? true
        let message = denied ? "The sign-in was cancelled." : "You are signed in. You can close this window and go back to the terminal."
        return "<!doctype html><meta charset=\"utf-8\"><title>client-app</title><body style=\"font-family: -apple-system, sans-serif; margin: 3em\"><p>\(message)</p></body>"
    }

    private static func respond(_ connection: NWConnection, status: String, body: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}
