import Foundation
import ScoutCore

struct UnsentWalkthrough: Codable, Identifiable, Equatable {
    var id: String
    var directory: URL
    var title: String
    var target: String
    var reason: String
    var at: Date
}

enum UnsentWalkthroughs {
    static var file: URL { ScoutPaths.support.appendingPathComponent("unsent.json") }

    static func load() -> [UnsentWalkthrough] {
        guard let data = try? Data(contentsOf: file), let items = try? JSONDecoder().decode([UnsentWalkthrough].self, from: data) else { return [] }
        return items.filter { FileManager.default.fileExists(atPath: $0.directory.appendingPathComponent(WalkthroughBundle.entryName).path) }
    }

    static func save(_ items: [UnsentWalkthrough]) {
        if items.isEmpty {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(items).write(to: file, options: .atomic)
    }

    static func finished(_ item: UnsentWalkthrough) -> FinishedWalkthrough? {
        guard let data = try? Data(contentsOf: item.directory.appendingPathComponent(WalkthroughBundle.entryName)),
              let walkthrough = try? JSONDecoder().decode(Walkthrough.self, from: data)
        else { return nil }
        return FinishedWalkthrough(directory: item.directory, walkthrough: walkthrough, timings: [:])
    }
}
