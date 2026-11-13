import Foundation

nonisolated struct LinearStorage: StorageProvider {
    let api: any LinearAPI
    let credential: LinearCredential
    let teamID: String

    var id: StorageProviderID { .linear }
    var maxBytes: Int? { nil }

    func store(_ asset: LocalAsset, name: String) async throws -> StoredAsset {
        let operation = LinearOperations.fileUpload(contentType: asset.contentType, filename: name, size: asset.byteCount, teamID: teamID)
        let reply = try await api.perform(operation, credential: credential).fileUpload
        guard reply.success, var target = reply.uploadFile else { throw LinearError.uploadFailed }
        target.contentType = asset.contentType
        try await api.upload(asset.url, to: target)
        return StoredAsset(provider: .linear, name: name, url: target.assetURL, contentHash: asset.contentHash)
    }
}
