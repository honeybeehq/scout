import Foundation

nonisolated struct LinearStorage: StorageProvider {
    let api: any LinearAPI
    let credential: LinearCredential
    let teamID: String

    var id: StorageProviderID { .linear }
    var maxBytes: Int? { nil }

    func store(_ asset: LocalAsset, name: String, progress: @escaping @Sendable (Int, Int) -> Void) async throws -> StoredAsset {
        if let maxBytes, asset.byteCount > maxBytes { throw LinearError.tooLarge }
        let operation = LinearOperations.fileUpload(contentType: asset.contentType, filename: name, size: asset.byteCount, teamID: teamID)
        let reply: LinearOperations.FileUploadData.Payload
        do {
            reply = try await api.perform(operation, credential: credential).fileUpload
        } catch LinearError.server(let message) where Self.meansTooLarge(message) {
            throw LinearError.tooLarge
        }
        guard reply.success, var target = reply.uploadFile else { throw asset.kind == .video ? LinearError.videoUploadFailed : LinearError.uploadFailed }
        target.contentType = asset.contentType
        do {
            try await api.upload(asset.url, to: target) { sent, total in progress(Int(sent), Int(total)) }
        } catch LinearError.uploadFailed where asset.kind == .video {
            throw LinearError.videoUploadFailed
        }
        return StoredAsset(provider: .linear, name: name, url: target.assetURL, contentHash: asset.contentHash, kind: asset.kind, byteCount: asset.byteCount)
    }

    private static func meansTooLarge(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("too large") || lowered.contains("file size") || lowered.contains("exceeds")
    }
}
