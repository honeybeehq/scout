import AVFoundation
import Foundation
import ScoutCore

nonisolated final class SignalLog: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "scout.signal-log", qos: .utility)
    private let handle: FileHandle?
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    init(url: URL) {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
    }

    func append(_ value: some Encodable & Sendable) {
        queue.async { [encoder, handle] in
            guard var data = try? encoder.encode(value) else { return }
            data.append(0x0A)
            try? handle?.write(contentsOf: data)
        }
    }

    func close() {
        queue.sync { try? handle?.close() }
    }
}

nonisolated enum ScoutPaths {
    static var support: URL { ScoutDataRoot.url }

    static var allowsPruning: Bool { ScoutDataRoot.current.allowsPruning }

    static var sessions: URL {
        support.appendingPathComponent("Sessions", isDirectory: true)
    }

    static let mediaGrace: TimeInterval = 120

    static func removeFinishedMedia(of folder: URL) async {
        let media = folder.appendingPathComponent("media", isDirectory: true)
        guard FileManager.default.fileExists(atPath: media.path), let video = ReviewRecord.read(from: folder)?.video else { return }
        let file = folder.appendingPathComponent(video.file)
        guard let written = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return }
        let wait = mediaGrace - Date().timeIntervalSince(written)
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        guard let duration = try? await AVURLAsset(url: file).load(.duration).seconds, abs(duration - (video.end - video.start)) <= 0.1 else { return }
        let size = byteCount(of: media)
        let removed = (try? FileManager.default.removeItem(at: media)) != nil
        NSLog("[scout-prune] %@ %@ (segments already joined into %@) size %lld", removed ? "removed" : "failed to remove", media.path, video.file, size)
    }

    static func prune(now: Date = Date(), mediaAge: TimeInterval = 86_400, videoAge: TimeInterval = 7 * 86_400, sessionAge: TimeInterval = 14 * 86_400) {
        let resolution = ScoutDataRoot.current
        guard resolution.allowsPruning else {
            NSLog("[scout-prune] skipped: %@ (data root %@)", resolution.reason, resolution.root.path)
            return
        }
        let manager = FileManager.default
        func trash(_ url: URL, age: TimeInterval) {
            guard manager.fileExists(atPath: url.path) else { return }
            let size = byteCount(of: url)
            let trashed = (try? manager.trashItem(at: url, resultingItemURL: nil)) != nil
            NSLog("[scout-prune] %@ %@ age %.1f days size %lld", trashed ? "trashed" : "failed to trash", url.path, age / 86_400, size)
        }
        let days = (try? manager.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil)) ?? []
        for day in days {
            let folders = (try? manager.contentsOfDirectory(at: day, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for folder in folders {
                let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
                let age = now.timeIntervalSince(modified)
                if age > sessionAge {
                    trash(folder, age: age)
                    continue
                }
                Task.detached(priority: .background) { await removeFinishedMedia(of: folder) }
                SessionAudioWriter.repair(folder.appendingPathComponent(SessionAudioWriter.fileName))
                if age > mediaAge {
                    trash(folder.appendingPathComponent("media"), age: age)
                }
                if age > videoAge {
                    trash(folder.appendingPathComponent("session.mp4"), age: age)
                    trash(folder.appendingPathComponent(SessionAudioWriter.fileName), age: age)
                }
            }
            if (try? manager.contentsOfDirectory(atPath: day.path))?.isEmpty == true {
                try? manager.removeItem(at: day)
            }
        }
    }

    static func byteCount(of url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        var total = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    static func newSessionDirectory(id: String, at date: Date) -> URL {
        let day = date.formatted(.iso8601.year().month().day())
        let url = sessions.appendingPathComponent("\(day)/\(id)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
