import Foundation

/// The account's folders, through the endpoints MauiApp uses too:
/// `GET /folders` to list and search them (scope `folders.read`), and
/// `POST /folders/<action>` to publish, archive or delete them
/// (`folders.write`). Only the signed-in account's folders are listed and
/// changed: the backend ignores the others' ids.
public struct FolderClient: Sendable {
    /// A folder of the account
    public struct Folder: Decodable, Sendable, Equatable {
        public let id: Int
        /// created, published or archived
        public let state: String
        public let name: String?
        public let tags: [String]?
        public let dataUrl: String?
        /// Its page on the account's site
        public let webUrl: String?
    }

    /// One page of folders
    public struct Page: Decodable, Sendable, Equatable {
        public let folders: [Folder]
        public let page: Int
        public let totalPages: Int
        public let totalCount: Int
    }

    /// What `POST /folders/<action>` does to a folder
    public enum Action: String, CaseIterable, Sendable {
        /// created or archived → published
        case publish
        /// published → created
        case unpublish
        /// created or published → archived
        case archive
        /// archived → created
        case unarchive
        /// with its files
        case delete
    }

    /// The states a list can be limited to
    public static let states = ["created", "published", "archived"]
    /// The page sizes the backend accepts
    public static let pageSizes = [5, 10, 25, 100]

    let api: APIClient

    public init(apiURL: URL, session: URLSession = .shared, accessToken: @escaping @Sendable () async throws -> String) {
        api = APIClient(apiURL: apiURL, session: session, accessToken: accessToken)
    }

    /// One page of the account's folders, by name
    /// - Parameters:
    ///   - query: a part of the name, or a tag
    ///   - state: created, published or archived; every state when nil
    ///   - page: from 1
    ///   - perPage: 5, 10, 25 or 100
    public func list(query: String? = nil, state: String? = nil, page: Int = 1, perPage: Int = 25) async throws -> Page {
        var items = [URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "perPage", value: String(perPage))]
        if let query, !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
        if let state { items.append(URLQueryItem(name: "state", value: state)) }
        return try await api.send("GET", "folders", query: items)
    }

    /// Every page of the account's folders
    public func listAll(query: String? = nil, state: String? = nil) async throws -> [Folder] {
        var folders: [Folder] = []
        var page = 1
        while true {
            let result = try await list(query: query, state: state, page: page, perPage: 100)
            folders += result.folders
            guard page < result.totalPages else { return folders }
            page += 1
        }
    }

    /// Publish, unpublish, archive, unarchive or delete folders; a folder
    /// that can't take the action (an archived one published again, say)
    /// is left as it is
    public func perform(_ action: Action, ids: [Int]) async throws {
        try await api.send("POST", "folders/\(action.rawValue)", body: ["id": ids])
    }
}
