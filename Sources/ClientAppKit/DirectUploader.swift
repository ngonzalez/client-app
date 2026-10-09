import Foundation

/// Uploads a file straight to the storage, in one PUT and without chunks:
/// 1. `POST /api/v1/direct_uploads`: the file's details → a signed URL
/// 2. `PUT` the file to that URL (streamed from the disk)
/// 3. `POST /api/v1/direct_uploads/:uuid/complete`
/// 4. `GET /api/v1/direct_uploads/:uuid` until `done` (optional)
public struct DirectUploader: Sendable {
    public struct Created: Decodable, Sendable {
        public struct DirectUpload: Decodable, Sendable {
            public let url: URL
            public let headers: [String: String]
        }
        public let uuid: String
        public let signedBlobId: String
        public let directUpload: DirectUpload
    }

    public struct State: Decodable, Sendable {
        public let uuid: String
        public let status: String
    }

    let apiURL: URL
    let accessToken: @Sendable () async throws -> String
    let session: URLSession

    public init(apiURL: URL, session: URLSession = .shared, accessToken: @escaping @Sendable () async throws -> String) {
        self.apiURL = apiURL
        self.session = session
        self.accessToken = accessToken
    }

    /// Upload one file
    /// - Returns: the upload's uuid, once the backend took it (`processing`)
    public func upload(_ item: UploadItem) async throws -> String {
        let details = try FileDetails(url: item.url)
        let created: Created = try await api("POST", "api/v1/direct_uploads", body: [
            "filePath": item.url.path,
            "source": item.source.rawValue,
            "mimeType": details.mimeType,
            "byteSize": details.byteSize,
            "checksum": details.checksum,
            "createdAt": ISO8601DateFormatter().string(from: details.createdAt),
            "updatedAt": ISO8601DateFormatter().string(from: details.updatedAt),
        ])

        var put = URLRequest(url: created.directUpload.url)
        put.httpMethod = "PUT"
        created.directUpload.headers.forEach { put.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, response) = try await session.upload(for: put, fromFile: item.url)
        _ = try checked(data, response)

        let state: State = try await api("POST", "api/v1/direct_uploads/\(created.uuid)/complete", body: ["signedBlobId": created.signedBlobId])
        return state.uuid
    }

    /// Wait until the backend attached the file
    public func waitUntilDone(_ uuid: String, every interval: Duration = .seconds(2), timeout: Duration = .seconds(600)) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let state: State = try await api("GET", "api/v1/direct_uploads/\(uuid)")
            if state.status == "done" { return }
            try await Task.sleep(for: interval)
        }
        throw ClientAppError.http(status: 408, message: "The upload \(uuid) is still processing")
    }

    private func api<Response: Decodable>(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Response {
        var request = URLRequest(url: apiURL.appending(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        return try JSONDecoder().decode(Response.self, from: try checked(data, response))
    }
}
