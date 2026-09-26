import Foundation
import ScoutCore
import ScoutSegmenter

struct Expectations {
    var snippetCount: Int?
    var breaks: [Double]?
    var discarded: Int?
    var tolerance: Double = 1.5

    var isEmpty: Bool { snippetCount == nil && breaks == nil && discarded == nil }
}

struct Fixture {
    var path: String
    var signals: [Signal]
    var expectations: Expectations

    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

struct FixtureError: Error, CustomStringConvertible {
    var description: String
}

enum TraceEntry {
    case evaluation(BoundaryEvaluation)
    case closed(Snippet)
    case discarded(String)
}

struct StreamEntry {
    var signalTime: SessionTime
    var event: SegmenterEvent
}

struct RunResult {
    var snippets: [Snippet] = []
    var discarded: [String] = []
    var evaluations: [BoundaryEvaluation] = []
    var trace: [TraceEntry] = []
    var stream: [StreamEntry] = []

    var breaks: [Double] {
        snippets.dropLast().compactMap { $0.closedBy?.at }
    }
}

struct Verdict {
    var passed: Bool
    var problems: [String]
}

func loadFixture(at path: String) throws -> Fixture {
    guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) else {
        throw FixtureError(description: "\(path): cannot read file")
    }
    var signals: [Signal] = []
    var expectations = Expectations()
    let decoder = JSONDecoder()
    for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        let lineNumber = index + 1
        if line.isEmpty { continue }
        if line.hasPrefix("#") {
            try parseHeader(line, into: &expectations, location: "\(path):\(lineNumber)")
            continue
        }
        do {
            signals.append(try decoder.decode(Signal.self, from: Data(line.utf8)))
        } catch {
            throw FixtureError(description: "\(path):\(lineNumber): \(describe(error))")
        }
    }
    return Fixture(path: path, signals: signals, expectations: expectations)
}

func parseHeader(_ line: String, into expectations: inout Expectations, location: String) throws {
    let body = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
    func value(after key: String) -> String? {
        guard body.hasPrefix(key) else { return nil }
        return body.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
    }
    if let raw = value(after: "expect-breaks:") {
        let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let times = parts.compactMap(Double.init)
        guard times.count == parts.count else { throw FixtureError(description: "\(location): invalid expect-breaks “\(raw)”") }
        expectations.breaks = times.sorted()
    } else if let raw = value(after: "expect-discarded:") {
        guard let count = Int(raw) else { throw FixtureError(description: "\(location): invalid expect-discarded “\(raw)”") }
        expectations.discarded = count
    } else if let raw = value(after: "expect:") {
        guard let count = Int(raw) else { throw FixtureError(description: "\(location): invalid expect “\(raw)”") }
        expectations.snippetCount = count
    }
}

func describe(_ error: Error) -> String {
    switch error {
    case DecodingError.dataCorrupted(let context):
        return "invalid JSON (\(context.debugDescription))"
    case DecodingError.keyNotFound(let key, let context):
        return "missing “\(key.stringValue)” at \(codingPath(context.codingPath))"
    case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
        return "\(context.debugDescription) at \(codingPath(context.codingPath))"
    default:
        return String(describing: error)
    }
}

func codingPath(_ path: [CodingKey]) -> String {
    path.isEmpty ? "top level" : path.map(\.stringValue).joined(separator: ".")
}

func run(_ fixture: Fixture) -> RunResult {
    var segmenter = Segmenter(recordsEvaluations: true)
    var result = RunResult()
    func absorb(_ events: [SegmenterEvent], at time: SessionTime) {
        result.stream += events.map { StreamEntry(signalTime: time, event: $0) }
        for evaluation in segmenter.takeEvaluations() {
            result.evaluations.append(evaluation)
            result.trace.append(.evaluation(evaluation))
        }
        for event in events {
            switch event {
            case .closed(let snippet):
                result.snippets.append(snippet)
                result.trace.append(.closed(snippet))
            case .discarded(let id):
                result.snippets.removeAll { $0.id == id }
                result.discarded.append(id)
                result.trace.append(.discarded(id))
            case .opened, .updated:
                continue
            }
        }
    }
    var end: SessionTime = 0
    for signal in fixture.signals {
        end = max(end, signal.time)
        absorb(segmenter.ingest(signal), at: signal.time)
    }
    absorb(segmenter.finish(at: end), at: end)
    return result
}

func verdict(for result: RunResult, expecting expectations: Expectations) -> Verdict {
    var problems: [String] = []
    if let expected = expectations.snippetCount, expected != result.snippets.count {
        problems.append("expected \(expected) snippets, got \(result.snippets.count)")
    }
    if let expected = expectations.discarded, expected != result.discarded.count {
        problems.append("expected \(expected) discarded, got \(result.discarded.count)")
    }
    if let expected = expectations.breaks {
        var unmatched = result.breaks
        for time in expected {
            let nearest = unmatched.indices.min { abs(unmatched[$0] - time) < abs(unmatched[$1] - time) }
            if let nearest, abs(unmatched[nearest] - time) <= expectations.tolerance {
                unmatched.remove(at: nearest)
            } else {
                problems.append("missing break ≈\(seconds(time))")
            }
        }
        problems += unmatched.map { "unexpected break at \(seconds($0))" }
    }
    return Verdict(passed: problems.isEmpty, problems: problems)
}

func seconds(_ time: Double) -> String {
    String(format: "%.1f", time)
}

func clock(_ time: Double) -> String {
    let minutes = Int(time) / 60
    return String(format: "%d:%04.1f", minutes, time - Double(minutes * 60))
}

func signed(_ weight: Double) -> String {
    String(format: "%+.2f", weight)
}

func contextLine(_ snippet: Snippet) -> String {
    guard let context = snippet.primaryContext else { return "no context" }
    var parts = [context.app.name]
    if let location = context.location {
        parts.append(location.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: ""))
    } else if let title = context.windowTitle {
        parts.append("“\(title)”")
    }
    return parts.joined(separator: " · ")
}

func reasonSummary(_ reasons: [BreakpointReason]) -> String {
    reasons.map { "\($0.detail ?? $0.kind.rawValue) \(signed($0.weight))" }.joined(separator: ", ")
}

func printSnippet(_ snippet: Snippet, index: Int) {
    let duration = snippet.range.duration
    print("#\(index)  \(clock(snippet.range.start))–\(clock(snippet.range.end))  (\(seconds(duration)) s)  \(contextLine(snippet))")
    let targets = snippet.targets.prefix(3).map(\.displayName)
    if !targets.isEmpty { print("    targets: \(targets.joined(separator: ", "))") }
    if !snippet.marks.isEmpty { print("    marks: \(snippet.marks.count)") }
    if let breakpoint = snippet.closedBy {
        print("    closed at \(clock(breakpoint.at)) by \(reasonSummary(breakpoint.reasons))  [score \(String(format: "%.2f", breakpoint.score))]")
    }
    let transcript = snippet.transcript
    print("    “\(transcript.isEmpty ? "(no speech)" : transcript)”")
    print("")
}

func printEvaluation(_ evaluation: BoundaryEvaluation) {
    let verdict = evaluation.decision == .split ? (evaluation.isHard ? "SPLIT (hard)" : "SPLIT") : "keep"
    let comparison = evaluation.decision == .split ? "≥" : "<"
    let utterances = [evaluation.previousUtteranceID, evaluation.nextUtteranceID].compactMap { $0 }.joined(separator: " → ")
    var header = "  @ \(clock(evaluation.at))  \(verdict)  score \(signed(evaluation.score))"
    if !evaluation.isHard { header += " \(comparison) \(String(format: "%.2f", evaluation.threshold))" }
    if !utterances.isEmpty { header += "  [\(utterances)]" }
    print(header)
    for reason in evaluation.reasons {
        let kind = reason.kind.rawValue.padding(toLength: 17, withPad: " ", startingAt: 0)
        print("      \(signed(reason.weight))  \(kind) \(reason.detail ?? "")")
    }
}

func printHuman(_ fixture: Fixture, _ result: RunResult, explain: Bool) {
    print("\(fixture.name): \(fixture.signals.count) signals\n")
    var index = 0
    for entry in result.trace {
        switch entry {
        case .evaluation(let evaluation):
            if explain { printEvaluation(evaluation) }
        case .closed(let snippet):
            if explain { print("") }
            index += 1
            printSnippet(snippet, index: index)
        case .discarded(let id):
            print("×  discarded \(id)\n")
        }
    }
    let discarded = result.discarded.isEmpty ? "" : ", \(result.discarded.count) discarded"
    print("\(result.snippets.count) snippets\(discarded); breaks: \(result.breaks.map(seconds).joined(separator: ", "))")
    guard !fixture.expectations.isEmpty else { return }
    let outcome = verdict(for: result, expecting: fixture.expectations)
    print(outcome.passed ? "expectations: PASS" : "expectations: FAIL — \(outcome.problems.joined(separator: "; "))")
}

func printEvents(_ result: RunResult) {
    for entry in result.stream {
        let prefix = "\(clock(entry.signalTime))  "
        switch entry.event {
        case .opened(let snippet): print(prefix + "opened    \(eventSummary(snippet))")
        case .updated(let snippet): print(prefix + "updated   \(eventSummary(snippet))")
        case .closed(let snippet): print(prefix + "closed    \(eventSummary(snippet))")
        case .discarded(let id): print(prefix + "discarded \(id)")
        }
    }
}

func eventSummary(_ snippet: Snippet) -> String {
    let utterances = snippet.utterances.map(\.id).joined(separator: ",")
    let marks = snippet.marks.isEmpty ? "" : "  marks \(snippet.marks.map(\.id).joined(separator: ","))"
    return "\(snippet.id)  \(clock(snippet.range.start))–\(clock(snippet.range.end))  [\(utterances)]\(marks)"
}

struct JSONReport: Encodable {
    var snippets: [Snippet]
    var discarded: [String]
    var evaluations: [BoundaryEvaluation]?
}

func printJSON(_ result: RunResult, explain: Bool) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let report = JSONReport(snippets: result.snippets, discarded: result.discarded, evaluations: explain ? result.evaluations : nil)
    print(String(decoding: try encoder.encode(report), as: UTF8.self))
}

func fixturePaths(in paths: [String]) throws -> [String] {
    var files: [String] = []
    let manager = FileManager.default
    for path in paths {
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw FixtureError(description: "\(path): no such file or directory")
        }
        if isDirectory.boolValue {
            let names = try manager.contentsOfDirectory(atPath: path).filter { $0.hasSuffix(".jsonl") }.sorted()
            files += names.map { URL(fileURLWithPath: path).appendingPathComponent($0).path }
        } else {
            files.append(path)
        }
    }
    return files
}

func check(_ paths: [String]) throws -> Bool {
    let files = try fixturePaths(in: paths)
    guard !files.isEmpty else { throw FixtureError(description: "no .jsonl fixtures found") }
    let width = files.map { URL(fileURLWithPath: $0).lastPathComponent.count }.max() ?? 0
    var failures = 0
    for file in files {
        let name = URL(fileURLWithPath: file).lastPathComponent.padding(toLength: width, withPad: " ", startingAt: 0)
        do {
            let fixture = try loadFixture(at: file)
            let result = run(fixture)
            let summary = "\(result.snippets.count) snippets, breaks \(result.breaks.map(seconds).joined(separator: " "))"
            if fixture.expectations.isEmpty {
                failures += 1
                print("FAIL  \(name)  no # expect header")
                continue
            }
            let outcome = verdict(for: result, expecting: fixture.expectations)
            if outcome.passed {
                print("PASS  \(name)  \(summary)")
            } else {
                failures += 1
                print("FAIL  \(name)  \(outcome.problems.joined(separator: "; "))  (\(summary))")
            }
        } catch {
            failures += 1
            print("FAIL  \(name)  \(error)")
        }
    }
    print("\n\(files.count - failures)/\(files.count) fixtures passed")
    return failures == 0
}

func printUsage() {
    let usage = """
    usage: scout-segment <fixture.jsonl> [--explain] [--json | --events]
           scout-segment --check <fixture-dir-or-file>...
    """
    FileHandle.standardError.write(Data((usage + "\n").utf8))
}

func main() -> Int32 {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let flags = Set(arguments.filter { $0.hasPrefix("--") })
    let paths = arguments.filter { !$0.hasPrefix("--") }
    let knownFlags: Set<String> = ["--explain", "--json", "--events", "--check", "--help"]
    if flags.contains("--help") || paths.isEmpty || !flags.isSubset(of: knownFlags) {
        printUsage()
        return 2
    }
    do {
        if flags.contains("--check") {
            return try check(paths) ? 0 : 1
        }
        guard paths.count == 1 else {
            printUsage()
            return 2
        }
        let fixture = try loadFixture(at: paths[0])
        let result = run(fixture)
        if flags.contains("--events") {
            printEvents(result)
        } else if flags.contains("--json") {
            try printJSON(result, explain: flags.contains("--explain"))
        } else {
            printHuman(fixture, result, explain: flags.contains("--explain"))
        }
        return 0
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        return 2
    }
}

exit(main())
