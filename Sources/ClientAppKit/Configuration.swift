import Foundation

/// Where the backend is and which registered app this is
/// (`bin/rails oauth:register` on the backend prints the client id).
/// Saved in ~/.config/client-app/config.json by `client-app login`.
public struct Configuration: Codable, Sendable, Equatable {
    public static let defaultAPIURL = URL(string: "https://api.appshare.site")!

    public var apiURL: URL
    public var clientID: String

    public init(apiURL: URL = Configuration.defaultAPIURL, clientID: String) {
        self.apiURL = apiURL
        self.clientID = clientID
    }

    public static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".config/client-app/config.json")
    }

    public static func load(from url: URL = fileURL) throws -> Configuration? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL = Configuration.fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
