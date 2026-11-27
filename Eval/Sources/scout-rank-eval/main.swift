import Foundation
import ScoutRanking

struct Options {
    var fixtures = URL(fileURLWithPath: "Eval/Fixtures", isDirectory: true)
    var jev = false
    var repeats = 1
    var model = JevRanker.defaultModel
    var record: URL?
    var replay: URL?
    var report: URL?
    var sampleRequest: URL?
    var check = false

    static func parse(_ arguments: [String]) -> Options {
        var options = Options()
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            func value() -> String {
                guard let next = iterator.next() else { fail("\(argument) needs a value") }
                return next
            }
            switch argument {
            case "--fixtures": options.fixtures = URL(fileURLWithPath: value(), isDirectory: true)
            case "--jev": options.jev = true
            case "--repeat": options.repeats = max(1, Int(value()) ?? 1)
            case "--model": options.model = value()
            case "--record": options.record = URL(fileURLWithPath: value())
            case "--replay": options.replay = URL(fileURLWithPath: value())
            case "--report": options.report = URL(fileURLWithPath: value())
            case "--sample-request": options.sampleRequest = URL(fileURLWithPath: value())
            case "--check": options.check = true
            default: fail("unknown argument \(argument)\nusage: scout-rank-eval [--check] [--jev [--repeat N] [--model ID] [--record FILE]] [--replay FILE] [--report FILE] [--sample-request FILE] [--fixtures DIR]")
            }
        }
        return options
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

struct Run: Codable {
    struct Entry: Codable {
        var key: String
        var probability: Double
        var fit: Double?
    }

    var caseID: String
    var attempt: Int
    var ranked: [Entry]
    var confidence: Double
    var anyFits: Double?
    var model: String?
    var milliseconds: Double
    var inputTokens: Int?
    var error: String?

    init(caseID: String, attempt: Int, ranking: TargetRanking) {
        self.caseID = caseID
        self.attempt = attempt
        ranked = ranking.ranked.map { Entry(key: $0.key, probability: $0.probability, fit: $0.fit) }
        confidence = ranking.confidence
        anyFits = ranking.anyFits
        model = ranking.model
        milliseconds = Double(ranking.elapsed.components.seconds) * 1000 + Double(ranking.elapsed.components.attoseconds) / 1e15
        inputTokens = ranking.inputTokens
    }

    init(caseID: String, attempt: Int, error: String, milliseconds: Double) {
        self.caseID = caseID
        self.attempt = attempt
        ranked = []
        confidence = 0
        self.milliseconds = milliseconds
        self.error = error
    }

    var keys: [String] { ranked.map(\.key) }
    var fitKeys: [String] { ranked.sorted { ($0.fit ?? 0) > ($1.fit ?? 0) }.map(\.key) }
    var top: Double { ranked.first?.probability ?? 0 }
}

struct Recording: Codable {
    var model: String
    var recordedAt: String
    var warmupMilliseconds: Double?
    var runs: [Run]
}

let options = Options.parse(Array(CommandLine.arguments.dropFirst()))
let fixtures: FixtureSet
do { fixtures = try FixtureSet.load(directory: options.fixtures) } catch { fail("cannot read fixtures: \(error)") }
if !fixtures.problems.isEmpty { fail("fixture problems:\n" + fixtures.problems.joined(separator: "\n")) }

var privacyProblems: [String] = []
for item in fixtures.cases {
    let prepared = try JevRanker.prepare(item.feedback, candidates: item.candidates, now: FixtureSet.referenceNow)
    let body = String(decoding: prepared.body, as: UTF8.self)
    if let url = item.feedback.pageURL, let components = URLComponents(string: url) {
        let path = components.percentEncodedPath
        if path.count > 1, body.contains(path) { privacyProblems.append("\(item.id): URL path sent") }
        if let query = components.percentEncodedQuery, body.contains(query) { privacyProblems.append("\(item.id): URL query sent") }
    }
    if item.feedback.transcriptPrefix.count > RankFeedback.transcriptLimit { privacyProblems.append("\(item.id): transcript over limit") }
    for row in item.rows {
        if row.rankKind != .champion, body.contains(row.id) { privacyProblems.append("\(item.id): target id \(row.id) sent") }
        if let handle = row.handle, body.contains(handle), !(item.feedback.pageTitle ?? "").contains(handle), !item.feedback.transcript.contains(handle) { privacyProblems.append("\(item.id): handle sent") }
    }
}
if !privacyProblems.isEmpty { fail("payload problems:\n" + privacyProblems.joined(separator: "\n")) }

if let sample = options.sampleRequest, let first = fixtures.cases.first {
    let prepared = try JevRanker.prepare(first.feedback, candidates: first.candidates, now: FixtureSet.referenceNow, model: options.model)
    let object = try JSONSerialization.jsonObject(with: prepared.body)
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: sample)
}

let tagCounts = fixtures.cases.flatMap(\.tags).reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
let candidateCounts = fixtures.cases.map(\.candidates.count)
print("fixtures: \(fixtures.cases.count) cases, \(candidateCounts.min()!)–\(candidateCounts.max()!) candidates (mean \(String(format: "%.1f", Double(candidateCounts.reduce(0, +)) / Double(candidateCounts.count)))), tags \(tagCounts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
print("payload check: transcript ≤ \(RankFeedback.transcriptLimit) chars, URL host only, no ids or handles: ok")

var baseline: [String: Run] = [:]
var untuned: [String: Run] = [:]
for item in fixtures.cases {
    baseline[item.id] = Run(caseID: item.id, attempt: 0, ranking: try await HeuristicRanker().rank(item.feedback, candidates: item.candidates, now: FixtureSet.referenceNow))
    untuned[item.id] = Run(caseID: item.id, attempt: 0, ranking: try await HeuristicRanker.untuned.rank(item.feedback, candidates: item.candidates, now: FixtureSet.referenceNow))
}

if options.check {
    let labelled = fixtures.cases.filter { !$0.isNoFit }
    let hits = labelled.filter { baseline[$0.id]?.keys.first == $0.gold }.count
    print("check: ok, baseline top-1 \(hits)/\(labelled.count)")
    exit(0)
}

var recording: Recording?
if let replay = options.replay {
    recording = try JSONDecoder().decode(Recording.self, from: Data(contentsOf: replay))
} else if options.jev {
    guard let key = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"], !key.isEmpty else { fail("set TYPESAFE_API_KEY in the environment") }
    let endpoint = ProcessInfo.processInfo.environment["TYPESAFE_ENDPOINT"].flatMap { URL(string: $0) } ?? JevRanker.defaultEndpoint
    let jev = JevRanker(apiKey: key, model: options.model, endpoint: endpoint, timeout: 20)
    var warmup: Double?
    if let first = fixtures.cases.first {
        let started = ContinuousClock.now
        _ = try? await jev.rank(first.feedback, candidates: first.candidates, now: FixtureSet.referenceNow)
        let elapsed = ContinuousClock.now - started
        warmup = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }
    var runs: [Run] = []
    for attempt in 0..<options.repeats {
        for item in fixtures.cases {
            let started = ContinuousClock.now
            do {
                let ranking = try await jev.rank(item.feedback, candidates: item.candidates, now: FixtureSet.referenceNow)
                runs.append(Run(caseID: item.id, attempt: attempt, ranking: ranking))
            } catch {
                let elapsed = ContinuousClock.now - started
                runs.append(Run(caseID: item.id, attempt: attempt, error: "\(error)", milliseconds: Double(elapsed.components.seconds) * 1000))
                FileHandle.standardError.write(Data("\(item.id): \(error)\n".utf8))
            }
        }
    }
    recording = Recording(model: runs.compactMap(\.model).first ?? options.model, recordedAt: ISO8601DateFormatter().string(from: Date()), warmupMilliseconds: warmup, runs: runs)
    if let path = options.record {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(recording).write(to: path)
    }
}

let report = Report(all: fixtures.cases, baseline: baseline, untuned: untuned, recording: recording).markdown
print(report)
if let path = options.report { try Data(report.utf8).write(to: path) }
