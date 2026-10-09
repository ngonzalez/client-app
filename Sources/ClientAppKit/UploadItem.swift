import Foundation

/// A file to upload and where it was in the imported folder: the backend
/// names the folder from the path's last directories (like DemoApp's import)
/// - `root`: in the folder itself (or a single file): the folder is its directory
/// - `folder`: one level down: "<folder> <subfolder>"
/// - `subfolder`: two levels down: "<subfolder> <subsubfolder>"
public struct UploadItem: Sendable, Equatable {
    public enum Source: String, Sendable {
        case root, folder, subfolder
    }

    public let url: URL
    public let source: Source

    public init(url: URL, source: Source = .root) {
        self.url = url
        self.source = source
    }

    /// The files of a folder, down to two levels (hidden files skipped)
    public static func items(inFolder folder: URL) throws -> [UploadItem] {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]

        func walk(_ directory: URL, depth: Int) throws -> [UploadItem] {
            let sources: [Source] = [.root, .folder, .subfolder]
            let entries = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            return try entries.flatMap { entry -> [UploadItem] in
                let values = try entry.resourceValues(forKeys: Set(keys))
                if values.isRegularFile == true { return [UploadItem(url: entry, source: sources[depth])] }
                if values.isDirectory == true, depth < 2 { return try walk(entry, depth: depth + 1) }
                return []
            }
        }
        return try walk(folder, depth: 0)
    }
}
