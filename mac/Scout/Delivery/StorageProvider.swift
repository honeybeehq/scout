import CryptoKit
import Foundation

nonisolated struct LocalAsset: Sendable {
    enum Kind: String, Codable, Sendable {
        case image
        case video
    }

    let kind: Kind
    let url: URL
    let contentType: String
    let byteCount: Int
    let contentHash: String

    private init(kind: Kind, url: URL, contentType: String, byteCount: Int, contentHash: String) {
        self.kind = kind
        self.url = url
        self.contentType = contentType
        self.byteCount = byteCount
        self.contentHash = contentHash
    }

    static func image(at url: URL) -> LocalAsset? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return LocalAsset(kind: .image, url: url, contentType: "image/png", byteCount: data.count, contentHash: hash)
    }

    static func video(_ media: RenderedMedia, includeVideo: Bool) -> LocalAsset? {
        guard includeVideo, let handle = try? FileHandle(forReadingFrom: media.url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var count = 0
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            count += chunk.count
        }
        guard count > 0 else { return nil }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return LocalAsset(kind: .video, url: media.url, contentType: "video/mp4", byteCount: count, contentHash: hash)
    }
}

nonisolated enum StorageProviderID: String, Codable, Hashable, Sendable {
    case linear
}

nonisolated struct StoredAsset: Codable, Hashable, Sendable {
    var provider: StorageProviderID
    var name: String
    var url: URL
    var contentHash: String
    var kind: LocalAsset.Kind?
    var byteCount: Int?

    var isVideo: Bool { kind == .video }
}

nonisolated protocol StorageProvider: Sendable {
    var id: StorageProviderID { get }
    var maxBytes: Int? { get }
    func store(_ asset: LocalAsset, name: String, progress: @escaping @Sendable (Int, Int) -> Void) async throws -> StoredAsset
}
