import Foundation
import OSLog
import ScoutCore

nonisolated struct LiveTranscriptEntry: Encodable, Sendable {
    var t: SessionTime
    var final: Bool
    var text: String
    var start: SessionTime?
    var end: SessionTime?
    var words: [Word]
}

nonisolated struct DebugTranscriberSetup: Encodable, Sendable {
    var engine: String
    var module: String
    var preset: String?
    var requestedLocale: String?
    var locale: String?
    var contextualStrings: [String]
}

nonisolated struct DebugSecondPass: Encodable, Sendable {
    var engine: String
    var requestedLocale: String
    var locale: String?
    var contextualStrings: [String]
    var limitSeconds: Double
    var startedAt: SessionTime
    var finishedAt: SessionTime?
    var audioSeconds: Double
    var elapsedSeconds: Double?
    var outcome: String
    var reason: String?
    var engines: [String]
    var failures: [String]
    var segments: [TranscribedSegment]
}

nonisolated struct DebugRunRecord: Encodable, Sendable {
    nonisolated struct App: Encodable, Sendable {
        var bundleID: String?
        var version: String?
        var build: String?
        var dataRoot: String
    }

    nonisolated struct Audio: Encodable, Sendable {
        var file: String
        var format: String
        var sampleRate: Double
        var channels: Int
        var seconds: Double?
    }

    nonisolated struct Input: Encodable, Sendable {
        var kind: String
        var file: String?
        var microphone: String?
    }

    var schema = 1
    var id: String
    var kind: String
    var startedAt: Date
    var endedAt: SessionTime?
    var clock = "Every time in debug/ is seconds on the session clock (t = 0 when the run started), except events.jsonl, which uses milliseconds on the same clock. Sample n of audio.wav is at n / 16000 s."
    var app: App
    var input: Input
    var audio: Audio
    var live: DebugTranscriberSetup
    var secondPass: DebugTranscriberSetup?
    var walkthrough: String?
    var walkthroughBundle: String?
    var files: [String]
}

@MainActor
final class DebugRun {
    nonisolated static let folderName = "debug"
    nonisolated static let retention: TimeInterval = 7 * 86_400

    enum File {
        static let run = "run.json"
        static let audio = "audio.wav"
        static let live = "live.jsonl"
        static let secondPass = "second-pass.json"
        static let events = "events.jsonl"
        static let log = "scout.log"
        static let timings = "timings.json"
    }

    let directory: URL
    let sessionDirectory: URL
    let clock: SessionClock
    private let live: SignalLog
    private var phases: [String: SessionTime] = [:]
    private var record: DebugRunRecord
    private(set) var finished = false

    nonisolated static func directory(in sessionDirectory: URL) -> URL {
        sessionDirectory.appendingPathComponent(folderName, isDirectory: true)
    }

    nonisolated static func existing(in sessionDirectory: URL) -> URL? {
        let url = directory(in: sessionDirectory)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    init?(sessionID: String, sessionDirectory: URL, clock: SessionClock, kind: String) {
        let directory = Self.directory(in: sessionDirectory)
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else { return nil }
        self.directory = directory
        self.sessionDirectory = sessionDirectory
        self.clock = clock
        live = SignalLog(url: directory.appendingPathComponent(File.live))
        let info = Bundle.main.infoDictionary
        record = DebugRunRecord(
            id: sessionID,
            kind: kind,
            startedAt: clock.originDate,
            app: .init(bundleID: Bundle.main.bundleIdentifier, version: info?["CFBundleShortVersionString"] as? String, build: info?["CFBundleVersion"] as? String, dataRoot: ScoutDataRoot.url.path),
            input: .init(kind: "microphone"),
            audio: .init(file: File.audio, format: "pcm_s16le", sampleRate: SessionAudioWriter.sampleRate, channels: 1),
            live: .init(engine: "SpeechTranscriber", module: "SpeechTranscriber", contextualStrings: []),
            files: []
        )
        NSLog("[scout-debug] keeping debug data for %@ in %@", sessionID, directory.path)
    }

    func mark(_ phase: String, at time: SessionTime? = nil) {
        guard phases[phase] == nil else { return }
        phases[phase] = time ?? clock.now
    }

    func heard(_ entry: LiveTranscriptEntry) {
        mark(entry.final ? "firstFinal" : "firstVolatile", at: entry.t)
        live.append(entry)
    }

    func started(input: DebugRunRecord.Input, live setup: DebugTranscriberSetup) {
        record.input = input
        record.live = setup
        mark("transcriberReady")
        writeRecord()
    }

    func updateLive(_ setup: DebugTranscriberSetup) {
        record.live = setup
    }

    func recordSecondPass(_ pass: DebugSecondPass) {
        record.secondPass = DebugTranscriberSetup(engine: pass.engine, module: pass.engine, requestedLocale: pass.requestedLocale, locale: pass.locale, contextualStrings: pass.contextualStrings)
        mark("secondPassStarted", at: pass.startedAt)
        if let finishedAt = pass.finishedAt { mark("secondPassFinished", at: finishedAt) }
        write(pass, to: File.secondPass)
    }

    func sessionEnded(audioSeconds: Double?) {
        mark("sessionEnded")
        live.close()
        record.audio.seconds = audioSeconds
        record.endedAt = clock.now
        link(sessionDirectory.appendingPathComponent(SessionAudioWriter.fileName), as: File.audio)
        link(sessionDirectory.appendingPathComponent("transcript-events.jsonl"), as: File.events)
        writeRecord()
    }

    func finish(walkthroughID: String? = nil, walkthroughBundle: URL? = nil, interactions: [InteractionSample], afterStopPressed: [String: Double] = [:]) async {
        guard !finished else { return }
        finished = true
        mark("finished")
        record.walkthrough = walkthroughID
        record.walkthroughBundle = walkthroughBundle?.path
        let offset = InteractionTimings.now - clock.now
        let timings = DebugTimings(
            phases: phases,
            audioSeconds: record.audio.seconds,
            afterStopPressed: afterStopPressed,
            interactions: interactions.map { DebugTimings.Interaction(t: $0.input - offset, sample: $0) }
        )
        write(timings, to: File.timings)
        let from = clock.originDate.addingTimeInterval(-1)
        let origin = clock.originDate
        let url = directory.appendingPathComponent(File.log)
        let lines = await Task.detached(priority: .utility) { Self.logLines(since: from, origin: origin) }.value
        try? Data(lines.utf8).write(to: url, options: .atomic)
        writeRecord()
        NSLog("[scout-debug] finished %@: %@", record.id, record.files.joined(separator: ", "))
    }

    private func writeRecord() {
        let manager = FileManager.default
        record.files = ((try? manager.contentsOfDirectory(atPath: directory.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        if !record.files.contains(File.run) { record.files = (record.files + [File.run]).sorted() }
        write(record, to: File.run)
    }

    private func write(_ value: some Encodable, to name: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    private func link(_ source: URL, as name: String) {
        let manager = FileManager.default
        let target = directory.appendingPathComponent(name)
        guard manager.fileExists(atPath: source.path), !manager.fileExists(atPath: target.path) else { return }
        do {
            try manager.linkItem(at: source, to: target)
        } catch {
            let copied = (try? manager.copyItem(at: source, to: target)) != nil
            NSLog("[scout-debug] hard link for %@ failed (%@); %@", name, error.localizedDescription, copied ? "copied it instead" : "copy failed too")
        }
    }

    nonisolated private static func logLines(since start: Date, origin: Date) -> String {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return "log unavailable: OSLogStore could not open this process's log\n" }
        let position = store.position(date: start)
        guard let entries = try? store.getEntries(at: position) else { return "log unavailable: no entries\n" }
        var lines: [String] = []
        let stamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        for case let entry as OSLogEntryLog in entries {
            let message = entry.composedMessage
            guard message.hasPrefix("[scout") || entry.level == .error || entry.level == .fault else { continue }
            let t = entry.date.timeIntervalSince(origin)
            lines.append(String(format: "%10.3f  ", t) + "\(entry.date.formatted(stamp))  \(Self.level(entry.level))  \(message)")
        }
        return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }

    nonisolated private static func level(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: "debug"
        case .info: "info"
        case .notice: "notice"
        case .error: "error"
        case .fault: "fault"
        default: "default"
        }
    }

    nonisolated static func prune(sessionFolder folder: URL, now: Date, trash: (URL, TimeInterval) -> Void) {
        let debug = directory(in: folder)
        guard let modified = (try? debug.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return }
        let age = now.timeIntervalSince(modified)
        if age > retention { trash(debug, age) }
    }
}

nonisolated struct DebugTimings: Encodable, Sendable {
    nonisolated struct Interaction: Encodable, Sendable {
        var t: SessionTime
        var sample: InteractionSample
    }

    var phases: [String: SessionTime]
    var audioSeconds: Double?
    var afterStopPressed: [String: Double]
    var interactions: [Interaction]
}
