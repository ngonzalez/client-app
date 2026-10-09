import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// What the backend needs to know about a file before it is sent
public struct FileDetails: Sendable, Equatable {
    public let url: URL
    public let byteSize: Int
    /// Base64 MD5: the storage checks the file against it
    public let checksum: String
    public let mimeType: String
    public let createdAt: Date
    public let updatedAt: Date

    public init(url: URL) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])
        self.url = url
        byteSize = values.fileSize ?? 0
        checksum = try FileDetails.md5(of: url)
        mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        createdAt = values.creationDate ?? Date()
        updatedAt = values.contentModificationDate ?? Date()
    }

    /// Read in 4 MiB pieces: a large video never sits in memory
    static func md5(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = Insecure.MD5()
        while let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty {
            hash.update(data: data)
        }
        return Data(hash.finalize()).base64EncodedString()
    }
}
