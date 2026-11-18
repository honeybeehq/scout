import AppKit
import ScoutCore
import ScoutSegmenter

enum OptimiseReplay {
    static var output: URL? { argument("--optimise-replay=").map { URL(fileURLWithPath: $0) } }

    static func argument(_ prefix: String) -> String? {
        ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    static func run(dispatcher: Dispatcher, output: URL) async {
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let review: SessionReview
            if let source = argument("--optimise-session=") {
                let copy = output.appendingPathComponent("session-" + UUID().uuidString)
                try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: copy)
                if FileManager.default.fileExists(atPath: copy.appendingPathComponent("walkthrough.json").path) {
                    review = try SessionReview.openWalkthrough(directory: copy, dispatcher: dispatcher)
                } else {
                    guard let record = ReviewRecord.read(from: copy) else { throw CocoaError(.fileReadCorruptFile) }
                    let ledger = SessionLibrary.ledger(in: copy)
                    let cards = record.tasks.map { item in
                        let card = SnippetCard(snippet: ledger.snippet(id: item.id, range: TimeRange(start: item.start, end: item.end)), sessionID: record.sessionID, sessionDirectory: copy)
                        card.restoreTitle(item.title, custom: item.titleIsCustom)
                        card.optimiseAttachments = item.optimiseAttachments
                        card.state = .held
                        return card
                    }
                    review = SessionReview(directory: copy, record: record, ledger: ledger, cards: cards, dispatcher: dispatcher)
                }
            } else {
                var signals: [Signal] = []
                let decoder = JSONDecoder()
                if let path = argument("--optimise-signals=") {
                    signals = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").filter { !$0.hasPrefix("#") }.map { try decoder.decode(Signal.self, from: Data($0.utf8)) }
                } else {
                    let dense = argument("--optimise-dense=") == "yes"
                    for index in 0..<31 {
                        let start = Double(index) * (dense ? 1800.0 / 31 : 12)
                        signals.append(.utterance(Utterance(id: "u-\(index)-a", range: TimeRange(start: start, end: start + 4), text: "Fix playtest issue \(index + 1)." + (dense ? String(repeating: " The selected interface control needs a clearer label and more space to explain the action before the player proceeds.", count: 4) : ""))))
                        signals.append(.utterance(Utterance(id: "u-\(index)-b", range: TimeRange(start: start + 6, end: start + 10), text: "Make the selected control easier to read." + (dense ? String(repeating: " The tooltip should explain the effect using the current scene and highlighted entity so the player can decide what to do.", count: 4) : ""))))
                        signals.append(.command(CommandSignal(at: start + 11, command: .split)))
                    }
                    signals.append(.mark(Mark(id: "pointer-1", at: 2, point: Point(x: 30, y: 40))))
                    if dense {
                        let target = Target(id: "dense-focus", provider: .accessibility, role: "AXButton", label: "Selected playtest control in the current scene", ancestry: ["window", "canvas", "toolbar"])
                        for index in 0..<7200 {
                            let start = Double(index) / 4
                            signals.append(.focus(Focus(range: TimeRange(start: start, end: start + 0.25), target: target)))
                        }
                    }
                    signals.sort { $0.time < $1.time }
                }
                var ledger = SessionLedger(replaying: signals)
                var segmenter = Segmenter(configuration: .manual)
                var snippets: [Snippet] = []
                for signal in signals {
                    for event in segmenter.ingest(signal) { if case .closed(let snippet) = event { snippets.append(snippet) } }
                }
                for event in segmenter.finish(at: ledger.end + 1) { if case .closed(let snippet) = event { snippets.append(snippet) } }
                let directory = output.appendingPathComponent("synthetic-session-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                let log = try signals.map { String(decoding: try encoder.encode($0), as: UTF8.self) }.joined(separator: "\n")
                try Data(log.utf8).write(to: directory.appendingPathComponent("signals.jsonl"))
                let finalUtterances = ledger.utterances.map { utterance in
                    var final = utterance
                    final.text = "[final-pass] " + final.text
                    return final
                }
                try FinalTranscript(engine: "replay-final", locale: "en", audioSeconds: ledger.end, elapsedSeconds: 1, utterances: finalUtterances).write(to: directory)
                let cuts = ledger.markedCuts
                ledger = SessionLibrary.ledger(in: directory)
                guard ledger.utterances == finalUtterances, Set(ledger.markedCuts ?? []).isSuperset(of: cuts ?? []) else { throw CocoaError(.fileReadCorruptFile) }
                let cards = snippets.enumerated().map { index, snippet in
                    var snippet = snippet
                    snippet.id = "task-\(index + 1)"
                    snippet = ledger.snippet(id: snippet.id, range: snippet.range, closedBy: snippet.closedBy)
                    let card = SnippetCard(snippet: snippet, sessionID: "optimise-replay", sessionDirectory: directory)
                    card.destination = .clipboard
                    card.state = .held
                    return card
                }
                let record = ReviewRecord(sessionID: "optimise-replay", startedAt: Date(), segmentation: "manual", duration: ledger.end, video: nil, display: nil, displayHops: nil, discarded: nil, tasks: cards.map(ReviewRecord.Task.init))
                review = SessionReview(directory: directory, record: record, ledger: ledger, cards: cards, dispatcher: dispatcher)
            }
            if let card = review.tasks.first {
                let state = card.state
                card.state = .preparing
                review.optimise.start()
                guard review.optimise.state == .idle else { throw CocoaError(.validationMissingMandatoryProperty) }
                card.state = state
            }
            guard let fixture = argument("--optimise-fixture=") else { throw CocoaError(.fileReadNoSuchFile) }
            if argument("--optimise-via-agent=") == "yes" {
                let unchanged = review.tasks.map { ($0.snippet.id, $0.title, $0.snippet.range) }
                let expected = argument("--optimise-expect=")
                let started = Date()
                review.optimise.start()
                if expected == "cancel" {
                    while review.optimise.state == .preparing { try await Task.sleep(for: .milliseconds(10)) }
                    review.optimise.cancel()
                    try await Task.sleep(for: .milliseconds(300))
                }
                while review.optimise.state == .preparing || review.optimise.state == .running { try await Task.sleep(for: .milliseconds(50)) }
                if let expected {
                    await review.optimise.waitForCleanup()
                    try await Task.sleep(for: .milliseconds(500))
                    let same = zip(unchanged, review.tasks).allSatisfy { before, card in before.0 == card.snippet.id && before.1 == card.title && before.2 == card.snippet.range } && unchanged.count == review.tasks.count && review.undoDepth == 0
                    let matched: Bool
                    switch (expected, review.optimise.state) {
                    case ("cancel", .idle), ("failure", .failed), ("timeout", .failed): matched = true
                    default: matched = false
                    }
                    guard same && matched else { throw CocoaError(.validationMissingMandatoryProperty) }
                    let report: [String: Any] = ["expected": expected, "reviewUntouched": same, "elapsed": Date().timeIntervalSince(started), "state": String(describing: review.optimise.state), "error": review.optimise.error ?? ""]
                    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    try data.write(to: output.appendingPathComponent("report.json"))
                    print(String(decoding: data, as: UTF8.self))
                    exit(0)
                }
                guard review.optimise.state == .ready else { throw NSError(domain: "Replay", code: 3, userInfo: [NSLocalizedDescriptionKey: review.optimise.error ?? "Agent run did not finish"]) }
            } else {
                try review.optimise.loadProposals(from: URL(fileURLWithPath: fixture))
            }
            func taskList() -> [String] { review.tasks.map { "\($0.snippet.id) [\($0.snippet.range.start)-\($0.snippet.range.end)] \($0.title)" } }
            let before = taskList()
            var manualEditsStale = false
            if let proposal = review.optimise.proposals.first, let card = review.tasks.first(where: { proposal.tasks.contains($0.snippet.id) }) {
                let title = card.title
                let custom = card.titleIsCustom
                card.restoreTitle("Manual edit made after optimisation", custom: true)
                manualEditsStale = review.optimise.status(for: proposal) == .stale
                card.restoreTitle(title, custom: custom)
                guard manualEditsStale else { throw CocoaError(.validationMissingMandatoryProperty) }
            }
            let depth = review.undoDepth
            let invalid = review.optimise.proposals.compactMap { proposal -> String? in
                review.optimise.validationMessage(for: proposal).map { "\(proposal.id): \($0)" }
            }
            review.optimise.acceptAll()
            let after = taskList()
            let accepted = review.optimise.acceptedIDs.sorted()
            guard !accepted.isEmpty, review.undoDepth == depth + 1 else { throw NSError(domain: "Replay", code: 1, userInfo: [NSLocalizedDescriptionKey: "Accept all did not create one undo step."]) }
            let crossings = review.optimise.proposals.filter { $0.crossesMarkedCut == true }
            guard crossings.allSatisfy({ !review.optimise.acceptedIDs.contains($0.id) }) else { throw CocoaError(.validationMissingMandatoryProperty) }
            var individualCrossingAccepted = false
            if let crossing = crossings.first(where: { review.optimise.validationMessage(for: $0) == nil }) {
                review.optimise.accept(crossing.id)
                guard review.optimise.acceptedIDs.contains(crossing.id), review.undoDepth == depth + 2 else { throw CocoaError(.validationMissingMandatoryProperty) }
                individualCrossingAccepted = true
                review.undo()
                guard taskList() == after else { throw CocoaError(.validationMissingMandatoryProperty) }
            }
            let questions = try review.tasks.compactMap { card -> String? in
                guard let question = card.optimiseAttachments?.question else { return nil }
                let composed = try dispatcher.compose(card)
                guard composed.markdown.contains("Open question: " + question) else { throw CocoaError(.validationMissingMandatoryProperty) }
                return question
            }
            review.save()
            let persisted = ReviewRecord.read(from: review.directory)?.tasks.map(\.title) ?? []
            guard persisted == review.tasks.map(\.title) else { throw CocoaError(.fileReadCorruptFile) }
            review.undo()
            guard taskList() == before, review.optimise.acceptedIDs.isEmpty else { throw NSError(domain: "Replay", code: 2, userInfo: [NSLocalizedDescriptionKey: "Undo did not restore tasks and pending proposals."]) }
            review.optimise.acceptAll()
            if let pending = review.optimise.proposals.first(where: { review.optimise.status(for: $0) == .pending || review.optimise.status(for: $0) == .stale }) { review.optimise.reject(pending.id) }
            review.save()
            let report: [String: Any] = ["source": argument("--optimise-session=") ?? "synthetic segmenter replay", "before": before, "after": after, "accepted": accepted, "validation": invalid, "undoRestored": true, "singleUndoStep": true, "crossingsSkippedByAcceptAll": true, "individualCrossingAccepted": individualCrossingAccepted, "deliveredQuestions": questions, "manualEditsStale": manualEditsStale, "preparingBlocked": true, "finalTranscriptEngine": FinalTranscript.read(from: review.directory)?.engine ?? "walkthrough", "persisted": true, "sessionCopy": review.directory.path, "error": review.optimise.error ?? ""]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: output.appendingPathComponent("report.json"), options: .atomic)
            print(String(decoding: data, as: UTF8.self))
            exit(0)
        } catch {
            print("Optimise replay failed: \(error)")
            exit(1)
        }
    }
}
