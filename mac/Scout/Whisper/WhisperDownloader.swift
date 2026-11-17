import Foundation

nonisolated struct WhisperDownloader: Sendable {
    enum DownloadError: LocalizedError {
        case badResponse(String, Int)
        case shortFile(String, Int64, Int64)
        case insecureRedirect

        var errorDescription: String? {
            switch self {
            case .badResponse(let path, let status): "The server answered \(status) for \(path)."
            case .shortFile(let path, let got, let expected): "\(path) stopped at \(got) of \(expected) bytes."
            case .insecureRedirect: "The download was redirected away from HTTPS."
            }
        }
    }

    static let chunkBytes = 256 << 10

    var destination: URL
    var onProgress: @Sendable (Int64) -> Void

    func run() async throws {
        let session = URLSession(configuration: .ephemeral, delegate: SecureRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var done: Int64 = 0
        for file in WhisperPins.files {
            try Task.checkCancellation()
            let target = destination.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            var existing = WhisperModelFiles.size(of: target) ?? 0
            if existing > file.bytes {
                try FileManager.default.removeItem(at: target)
                existing = 0
            }
            if existing < file.bytes {
                NSLog("[scout-whisper] fetching %@ from byte %lld of %lld", file.path, existing, file.bytes)
                try await fetch(file, into: target, resumingFrom: existing, session: session, reported: done)
            }
            done += file.bytes
            onProgress(done)
        }
    }

    private func fetch(_ file: WhisperPins.File, into target: URL, resumingFrom existing: Int64, session: URLSession, reported: Int64) async throws {
        var request = URLRequest(url: file.url)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if existing > 0 { request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw DownloadError.badResponse(file.path, 0) }
        var offset = existing
        switch http.statusCode {
        case 206 where existing > 0:
            break
        case 200:
            offset = 0
        case 416:
            try? FileManager.default.removeItem(at: target)
            return try await fetch(file, into: target, resumingFrom: 0, session: session, reported: reported)
        default:
            throw DownloadError.badResponse(file.path, http.statusCode)
        }
        if offset == 0 { FileManager.default.createFile(atPath: target.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(offset))
        try handle.seek(toOffset: UInt64(offset))
        var buffer = Data(capacity: Self.chunkBytes)
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= Self.chunkBytes {
                try handle.write(contentsOf: buffer)
                offset += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                onProgress(reported + offset)
                try Task.checkCancellation()
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            offset += Int64(buffer.count)
        }
        try handle.synchronize()
        guard offset == file.bytes else { throw DownloadError.shortFile(file.path, offset, file.bytes) }
    }

    private final class SecureRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(request.url?.scheme == "https" ? request : nil)
        }
    }
}
