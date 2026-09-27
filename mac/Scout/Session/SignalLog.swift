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

    func append(_ signal: Signal) {
        queue.async { [encoder, handle] in
            guard var data = try? encoder.encode(signal) else { return }
            data.append(0x0A)
            try? handle?.write(contentsOf: data)
        }
    }

    func close() {
        queue.sync { try? handle?.close() }
    }
}

nonisolated enum ScoutPaths {
    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Scout", isDirectory: true)
    }

    static var sessions: URL {
        support.appendingPathComponent("Sessions", isDirectory: true)
    }

    static func prune(now: Date = Date(), mediaAge: TimeInterval = 86_400, videoAge: TimeInterval = 7 * 86_400, sessionAge: TimeInterval = 14 * 86_400) {
        let manager = FileManager.default
        let days = (try? manager.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil)) ?? []
        for day in days {
            let folders = (try? manager.contentsOfDirectory(at: day, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for folder in folders {
                let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
                let age = now.timeIntervalSince(modified)
                if age > sessionAge {
                    try? manager.removeItem(at: folder)
                    continue
                }
                if age > mediaAge {
                    try? manager.removeItem(at: folder.appendingPathComponent("media"))
                }
                if age > videoAge {
                    try? manager.removeItem(at: folder.appendingPathComponent("session.mp4"))
                }
            }
            if (try? manager.contentsOfDirectory(atPath: day.path))?.isEmpty == true {
                try? manager.removeItem(at: day)
            }
        }
    }

    static func newSessionDirectory(id: String, at date: Date) -> URL {
        let day = date.formatted(.iso8601.year().month().day())
        let url = sessions.appendingPathComponent("\(day)/\(id)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
