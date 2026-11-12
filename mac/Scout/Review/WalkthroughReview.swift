import Foundation
import ScoutCore
import ScoutSegmenter

extension SessionReview {
    static func openWalkthrough(directory: URL, dispatcher: Dispatcher) throws -> SessionReview {
        let walkthrough = try JSONDecoder().decode(Walkthrough.self, from: Data(contentsOf: directory.appendingPathComponent(WalkthroughBundle.entryName)))
        var ledger = SessionLedger()
        for segment in walkthrough.transcript.segments {
            ledger.record(.utterance(Utterance(id: segment.id, range: TimeRange(start: Double(segment.start) / 1000, end: Double(segment.end) / 1000), text: segment.text, words: (segment.words ?? []).map { Word(text: $0.text, range: TimeRange(start: Double($0.start) / 1000, end: Double($0.end) / 1000)) })))
        }
        for event in walkthrough.events ?? [] where event.kind == .break {
            ledger.record(.command(CommandSignal(at: Double(event.t) / 1000, command: .split)))
        }
        for pointer in walkthrough.pointers {
            ledger.record(.mark(Mark(id: pointer.id, at: Double(pointer.t) / 1000, point: Point(x: pointer.at.x, y: pointer.at.y))))
        }
        var segmenter = Segmenter()
        for utterance in ledger.utterances {
            for event in segmenter.ingest(.utterance(utterance)) {
                if case .closed(let snippet) = event, let boundary = snippet.closedBy { ledger.recordBoundary(boundary) }
            }
        }
        ledger.extend(to: Double(walkthrough.duration) / 1000)
        let asks = walkthrough.asks.items
        let cards = asks.compactMap { ask -> SnippetCard? in
            let segments = walkthrough.transcript.segments.filter { (ask.segments ?? []).contains($0.id) }
            guard let start = segments.map(\.start).min(), let end = segments.map(\.end).max(), end > start else { return nil }
            let card = SnippetCard(snippet: ledger.snippet(id: ask.id, range: TimeRange(start: Double(start) / 1000, end: Double(end) / 1000)), sessionID: walkthrough.id, sessionDirectory: directory)
            card.restoreTitle(ask.text, custom: true)
            card.state = .held
            return card
        }
        let initial = ReviewRecord(sessionID: walkthrough.id, startedAt: ISO8601DateFormatter().date(from: walkthrough.createdAt) ?? Date(), segmentation: "manual", duration: ledger.end, video: walkthrough.clip.map { .init(file: $0.file, start: 0, end: Double($0.duration) / 1000) }, display: nil, displayHops: nil, discarded: nil, tasks: cards.map(ReviewRecord.Task.init))
        let record = ReviewRecord.read(from: directory) ?? initial
        let restored = record.tasks.map { item in
            let card = SnippetCard(snippet: ledger.snippet(id: item.id, range: TimeRange(start: item.start, end: item.end)), sessionID: walkthrough.id, sessionDirectory: directory)
            card.restoreTitle(item.title, custom: item.titleIsCustom)
            card.optimiseAttachments = item.optimiseAttachments
            card.excludedTargetIDs = Set(item.excludedTargetIDs)
            card.state = .held
            return card
        }
        let review = SessionReview(directory: directory, record: record, ledger: ledger, cards: restored, dispatcher: dispatcher)
        review.walkthrough = walkthrough
        for card in review.tasks { card.sessionVideo = review.video }
        return review
    }

    func saveAgentAsks() throws {
        guard let walkthrough else { return }
        let asks = Walkthrough.Asks(status: .ready, engine: "agent", items: tasks.map { card in
            let segments = walkthrough.transcript.segments.filter { segment in
                let midpoint = Double(segment.start + segment.end) / 2000
                return midpoint >= card.snippet.range.start && midpoint < card.snippet.range.end
            }.map(\.id)
            let pointers = walkthrough.pointers.filter { pointer in
                let time = Double(pointer.t) / 1000
                return !((card.optimiseAttachments?.excludedPointers ?? []).contains(pointer.t)) && ((time >= card.snippet.range.start && time < card.snippet.range.end) || (card.optimiseAttachments?.pointers ?? []).contains(pointer.t))
            }.map(\.id)
            let frames = walkthrough.frames.filter { frame in
                let time = Double(frame.t) / 1000
                return !(card.optimiseAttachments?.excludedFrames ?? []).contains(frame.t) && ((time >= card.snippet.range.start && time < card.snippet.range.end) || (card.optimiseAttachments?.frames ?? []).contains(frame.t))
            }.map(\.id)
            let drawings = walkthrough.drawings.filter { Double($0.t) / 1000 >= card.snippet.range.start && Double($0.t) / 1000 < card.snippet.range.end }.map(\.id)
            return Walkthrough.Ask(id: card.snippet.id, text: card.title, segments: segments, pointers: pointers, drawings: drawings, frames: frames, question: card.optimiseAttachments?.question)
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(asks).write(to: directory.appendingPathComponent("asks.agent.json"), options: .atomic)
    }
}
