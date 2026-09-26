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

enum ScoutPaths {
    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Scout", isDirectory: true)
    }

    static func newSessionDirectory(id: String, at date: Date) -> URL {
        let day = date.formatted(.iso8601.year().month().day())
        let url = support.appendingPathComponent("Sessions/\(day)/\(id)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
