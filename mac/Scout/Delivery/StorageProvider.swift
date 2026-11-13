import CryptoKit
import Foundation

nonisolated struct LocalAsset: Sendable {
    enum Kind: String, Codable, Sendable {
        case image
    }

    var kind: Kind
    var url: URL
    var contentType: String
    var byteCount: Int
    var contentHash: String

    static func image(at url: URL) -> LocalAsset? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return LocalAsset(kind: .image, url: url, contentType: "image/png", byteCount: data.count, contentHash: hash)
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
}

nonisolated protocol StorageProvider: Sendable {
    var id: StorageProviderID { get }
    var maxBytes: Int? { get }
    func store(_ asset: LocalAsset, name: String) async throws -> StoredAsset
}
