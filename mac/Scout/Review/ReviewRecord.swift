import Foundation
import ScoutCore

nonisolated struct ReviewRecord: Codable, Sendable {
    struct Video: Codable, Sendable {
        var file: String
        var start: Double
        var end: Double
    }

    struct Span: Codable, Sendable {
        var start: Double
        var end: Double
    }

    struct Task: Codable, Sendable {
        var id: String
        var start: Double
        var end: Double
        var title: String
        var titleIsCustom: Bool
        var transcriptOverride: String?
        var excludedTargetIDs: [String]
        var sentTo: String?
        var destination: Destination?
        var destinationChosenByUser: Bool?
        var runtimeNotes: [String]?
        var project: ProjectReference?

        @MainActor
        init(_ card: SnippetCard) {
            id = card.snippet.id
            start = card.snippet.range.start
            end = card.snippet.range.end
            title = card.title
            titleIsCustom = card.titleIsCustom
            transcriptOverride = card.transcriptOverride
            excludedTargetIDs = card.excludedTargetIDs.sorted()
            if case .sent(let destination) = card.state { sentTo = destination }
            destination = card.destination
            destinationChosenByUser = card.destinationChosenByUser
            runtimeNotes = card.runtimeNotes.isEmpty ? nil : card.runtimeNotes
            project = card.project
        }
    }

    var sessionID: String
    var startedAt: Date
    var segmentation: String
    var duration: Double
    var video: Video?
    var display: CaptureDisplay?
    var displayHops: [CaptureDisplays.Hop]?

    var displays: CaptureDisplays? {
        display.map { CaptureDisplays(start: $0, hops: displayHops ?? []) }
    }
    var discarded: [Span]?
    var tasks: [Task]

    static let fileName = "review.json"

    static func write(_ record: ReviewRecord, to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: directory.appendingPathComponent(fileName), options: .atomic)
    }

    static func read(from directory: URL) -> ReviewRecord? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ReviewRecord.self, from: data)
    }
}

nonisolated struct SessionSummary: Identifiable, Sendable {
    var id: String
    var directory: URL
    var startedAt: Date
    var duration: Double
    var taskCount: Int
    var unsentCount: Int
    var titles: [String]
    var hasVideo: Bool
}

nonisolated enum SessionLibrary {
    static func recent(limit: Int = 12) -> [SessionSummary] {
        let manager = FileManager.default
        let days = (try? manager.contentsOfDirectory(at: ScoutPaths.sessions, includingPropertiesForKeys: nil)) ?? []
        let folders = days.flatMap { (try? manager.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
        return folders
            .compactMap { folder -> SessionSummary? in
                guard let record = ReviewRecord.read(from: folder) else { return nil }
                let hasVideo = record.video.map { manager.fileExists(atPath: folder.appendingPathComponent($0.file).path) } ?? false
                return SessionSummary(
                    id: record.sessionID,
                    directory: folder,
                    startedAt: record.startedAt,
                    duration: record.duration,
                    taskCount: record.tasks.count,
                    unsentCount: record.tasks.filter { $0.sentTo == nil }.count,
                    titles: record.tasks.map(\.title),
                    hasVideo: hasVideo
                )
            }
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(limit)
            .map { $0 }
    }

    static func ledger(in directory: URL) -> SessionLedger {
        guard let text = try? String(contentsOf: directory.appendingPathComponent("signals.jsonl"), encoding: .utf8) else { return SessionLedger() }
        let decoder = JSONDecoder()
        let signals = text.split(separator: "\n").compactMap { try? decoder.decode(Signal.self, from: Data($0.utf8)) }
        return SessionLedger(replaying: signals)
    }
}
