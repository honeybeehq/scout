import Foundation
import ScoutCore

public struct Segmenter: Sendable {
    public let configuration: SegmenterConfiguration
    public let recordsEvaluations: Bool

    private let scorer: BoundaryScorer
    private let fillerWords: Set<String>
    private let closingRemarks: Set<String>
    private let idPrefix: String

    private var open: SnippetDraft?
    private var pending = PendingBuffer()
    private var contexts = ContextTimeline()
    private var deferredCommands: [CommandSignal] = []
    private var watermark: SessionTime = -.infinity
    private var openedCount = 0
    private var lastClosed: (id: String, decidedAt: SessionTime)?
    private var evaluations: [BoundaryEvaluation] = []
    private var outbox: [SegmenterEvent] = []

    public init(
        configuration: SegmenterConfiguration = .default,
        similarity: any SemanticSimilarity = LexicalSimilarity(),
        recordsEvaluations: Bool = false,
        idPrefix: String = "snippet-"
    ) {
        self.configuration = configuration
        self.recordsEvaluations = recordsEvaluations
        self.idPrefix = idPrefix
        scorer = BoundaryScorer(configuration: configuration, similarity: similarity)
        fillerWords = Set(configuration.fillerWords.flatMap(TextAnalysis.tokens))
        closingRemarks = Set(configuration.closingPhrases.map { TextAnalysis.tokens($0).joined(separator: " ") })
    }

    public var openSnippet: Snippet? { open?.snippet }

    public mutating func ingest(_ signal: Signal) -> [SegmenterEvent] {
        switch signal {
        case .utterance(let utterance):
            if isFillerOnly(utterance) {
                advanceWatermark(to: signal.time)
                route(PendingItem(anchor: utterance.range.start, payload: .filler(utterance)))
            } else {
                receiveSpeech(utterance)
            }
        case .context(let change):
            advanceWatermark(to: signal.time)
            contexts.insert(change)
            if contexts.count > 256 { pruneContexts() }
            refreshOpeningContext(after: change)
            route(PendingItem(anchor: change.at, payload: .context(change)))
        case .focus(let focus):
            advanceWatermark(to: signal.time)
            route(PendingItem(anchor: (focus.range.start + focus.range.end) / 2, payload: .focus(focus)))
        case .mark(let mark):
            advanceWatermark(to: signal.time)
            route(PendingItem(anchor: mark.at, payload: .mark(mark)))
        case .visualChange(let change):
            advanceWatermark(to: signal.time)
            route(PendingItem(anchor: change.at, payload: .visual(change)))
        case .command(let command):
            let index = deferredCommands.firstIndex { $0.at > command.at } ?? deferredCommands.endIndex
            deferredCommands.insert(command, at: index)
            advanceWatermark(to: signal.time)
        case .clock(let time):
            advanceWatermark(to: time)
        }
        return drainOutbox()
    }

    public mutating func finish(at time: SessionTime) -> [SegmenterEvent] {
        watermark = max(watermark, time)
        settle(before: watermark, commandsThrough: .infinity)
        if var draft = open {
            for item in pending.removeAllItems() { attribute(item, to: &draft) }
            let reason = BreakpointReason(kind: .sessionEnd, weight: 1, detail: "session ended")
            close(draft, at: max(time, draft.snippet.range.end), reason: reason)
        }
        pending = PendingBuffer()
        contexts = ContextTimeline()
        lastClosed = nil
        watermark = -.infinity
        return drainOutbox()
    }

    public mutating func takeEvaluations() -> [BoundaryEvaluation] {
        defer { evaluations.removeAll() }
        return evaluations
    }

    private mutating func receiveSpeech(_ utterance: Utterance) {
        let span = speechSpan(of: utterance)
        advance(to: max(watermark, span.start))
        let midpoint = (span.start + span.end) / 2
        settle(before: span.start, commandsThrough: midpoint)

        if var draft = open, let previous = draft.lastSpeech, let previousSpan = draft.lastSpeechSpan {
            if span.end <= previousSpan.end {
                draft.addSpeech(utterance, span: span, cohesionWindow: configuration.cohesionWindow)
                open = draft
            } else {
                decideBoundary(draft: draft, previous: previous, previousSpan: previousSpan, next: utterance, nextSpan: span)
            }
        } else if var draft = open {
            draft.addSpeech(utterance, span: span, cohesionWindow: configuration.cohesionWindow)
            for item in pending.removeAll(through: utterance.range.end) { attribute(item, to: &draft) }
            open = draft
        } else {
            openSnippet(with: utterance, span: span, claimingFrom: span.start - configuration.leadWindow)
        }

        advanceWatermark(to: utterance.range.end)
    }

    private mutating func settle(before speechStart: SessionTime, commandsThrough commandLimit: SessionTime) {
        while true {
            let silenceStart = open.map { $0.lastActivity + configuration.silenceTimeout } ?? .infinity
            if let command = deferredCommands.first, command.at <= commandLimit, command.at <= silenceStart {
                deferredCommands.removeFirst()
                apply(command)
            } else if let draft = open, silenceStart <= speechStart {
                closeForSilence(draft)
            } else if let command = deferredCommands.first, command.at <= commandLimit {
                deferredCommands.removeFirst()
                apply(command)
            } else {
                return
            }
        }
    }

    private mutating func decideBoundary(draft: SnippetDraft, previous: Utterance, previousSpan: TimeRange, next: Utterance, nextSpan: TimeRange) {
        let upcoming = pending.items(through: next.range.end)
        let leadFillers = upcoming.compactMap { item -> String? in
            guard case .filler(let filler) = item.payload, item.anchor >= previousSpan.end, item.anchor < nextSpan.start else { return nil }
            return filler.text
        }
        let candidate = BoundaryCandidate(
            draft: draft,
            previous: previous,
            previousSpan: previousSpan,
            next: next,
            nextSpan: nextSpan,
            leadText: (leadFillers + [next.text]).joined(separator: " "),
            upcoming: upcoming,
            contextBefore: contexts.context(at: previousSpan.end),
            contextAfter: contexts.context(at: min(nextSpan.start + configuration.leadWindow, next.range.end))
        )
        let result = scorer.score(candidate)
        let splits = result.isHard || result.score >= configuration.threshold
        record(BoundaryEvaluation(
            at: candidate.cut,
            score: result.score,
            threshold: configuration.threshold,
            isHard: result.isHard,
            decision: splits ? .split : .keep,
            reasons: result.reasons,
            snippetID: draft.snippet.id,
            previousUtteranceID: previous.id,
            nextUtteranceID: next.id
        ))

        var draft = draft
        if splits {
            let claimFrom = min(candidate.cut, nextSpan.start - configuration.leadWindow)
            for item in pending.removeAll(before: claimFrom) { attribute(item, to: &draft) }
            let breakpoint = Breakpoint(at: candidate.cut, score: result.score, isHard: result.isHard, reasons: result.reasons)
            finalize(draft, breakpoint: breakpoint)
            openSnippet(with: next, span: nextSpan, claimingFrom: claimFrom)
        } else {
            draft.addSpeech(next, span: nextSpan, cohesionWindow: configuration.cohesionWindow)
            for item in pending.removeAll(through: next.range.end) { attribute(item, to: &draft) }
            open = draft
        }
    }

    private mutating func openSnippet(with utterance: Utterance, span: TimeRange, claimingFrom start: SessionTime) {
        _ = pending.removeAll(before: start)
        var draft = SnippetDraft(id: nextSnippetID(), start: utterance.range.start)
        draft.addSpeech(utterance, span: span, cohesionWindow: configuration.cohesionWindow)
        for item in pending.removeAll(through: utterance.range.end) { attribute(item, to: &draft) }
        publishOpened(&draft)
    }

    private mutating func openSnippetFromPendingMarks() {
        guard open == nil, let firstMark = pending.firstMarkAnchor else { return }
        _ = pending.removeAll(before: firstMark - configuration.leadWindow)
        let lastMark = pending.items.last(where: \.isMark)?.anchor ?? firstMark
        var draft = SnippetDraft(id: nextSnippetID(), start: firstMark)
        for item in pending.removeAll(through: lastMark) { attribute(item, to: &draft) }
        publishOpened(&draft)
    }

    private mutating func publishOpened(_ draft: inout SnippetDraft) {
        draft.snippet.openingContext = contexts.context(at: draft.snippet.range.start)
        draft.hasUnpublishedChanges = false
        outbox.append(.opened(draft.snippet))
        open = draft
    }

    private mutating func route(_ item: PendingItem) {
        guard var draft = open else {
            pending.insert(item)
            if item.isMark {
                openSnippetFromPendingMarks()
            } else if pending.count > 512 {
                _ = pending.removeAll(before: watermark - 60)
            }
            return
        }
        if item.anchor <= draft.committedThrough {
            attributeLate(item, to: &draft)
        } else if draft.isMarksOnly, item.isMark {
            for earlier in pending.removeAll(before: item.anchor) { attribute(earlier, to: &draft) }
            attribute(item, to: &draft)
        } else {
            pending.insert(item)
            return
        }
        open = draft
    }

    private func attributeLate(_ item: PendingItem, to draft: inout SnippetDraft) {
        guard item.anchor < draft.snippet.range.start else {
            attribute(item, to: &draft)
            return
        }
        switch item.payload {
        case .mark:
            attribute(item, to: &draft)
        case .focus(let focus) where focus.range.end > draft.snippet.range.start:
            attribute(item, to: &draft)
        default:
            return
        }
    }

    private func attribute(_ item: PendingItem, to draft: inout SnippetDraft) {
        draft.attribute(item, markWeight: configuration.markDwellEquivalent, halfLife: configuration.targetHalfLife)
    }

    private mutating func advanceWatermark(to time: SessionTime) {
        watermark = max(watermark, time)
        advance(to: watermark)
    }

    private mutating func advance(to time: SessionTime) {
        while true {
            let silenceDeadline = open.map { $0.lastActivity + configuration.silenceTimeout + configuration.silenceGrace } ?? .infinity
            if let command = deferredCommands.first, command.at <= silenceDeadline {
                guard command.at + configuration.reorderTolerance <= time else { return }
                deferredCommands.removeFirst()
                apply(command)
                continue
            }
            guard silenceDeadline <= time, let draft = open else { return }
            closeForSilence(draft)
        }
    }

    private mutating func closeForSilence(_ draft: SnippetDraft) {
        var draft = draft
        let cut = draft.lastActivity + configuration.silenceTimeout / 2
        for item in pending.removeAll(before: cut) { attribute(item, to: &draft) }
        let quiet = draft.isMarksOnly ? "without speech or marks" : "without speech"
        let reason = BreakpointReason(kind: .silenceTimeout, weight: 1, detail: "\(formatSeconds(configuration.silenceTimeout)) s \(quiet)")
        close(draft, at: cut, reason: reason)
        openSnippetFromPendingMarks()
    }

    private mutating func apply(_ command: CommandSignal) {
        switch command.command {
        case .split:
            guard var draft = open else { return }
            for item in pending.removeAll(before: command.at) { attribute(item, to: &draft) }
            close(draft, at: command.at, reason: BreakpointReason(kind: .command, weight: 1, detail: "split command"))
        case .discardCurrent:
            if let draft = open {
                _ = pending.removeAll(before: command.at)
                open = nil
                outbox.append(.discarded(id: draft.snippet.id))
            } else if let lastClosed, command.at - lastClosed.decidedAt <= configuration.discardGrace {
                outbox.append(.discarded(id: lastClosed.id))
                self.lastClosed = nil
            }
        }
        openSnippetFromPendingMarks()
    }

    private mutating func close(_ draft: SnippetDraft, at time: SessionTime, reason: BreakpointReason) {
        let breakpoint = Breakpoint(at: time, score: reason.weight, isHard: true, reasons: [reason])
        record(BoundaryEvaluation(
            at: time,
            score: reason.weight,
            threshold: configuration.threshold,
            isHard: true,
            decision: .split,
            reasons: [reason],
            snippetID: draft.snippet.id,
            previousUtteranceID: draft.lastSpeech?.id
        ))
        finalize(draft, breakpoint: breakpoint)
    }

    private mutating func finalize(_ draft: SnippetDraft, breakpoint: Breakpoint) {
        var snippet = draft.snippet
        snippet.closedBy = breakpoint
        outbox.append(.closed(snippet))
        lastClosed = (snippet.id, watermark)
        open = nil
        pruneContexts()
    }

    private mutating func pruneContexts() {
        let recentSpeech = open?.lastSpeechSpan?.end ?? watermark
        let earliestNeeded = min(pending.items.first?.anchor ?? watermark, recentSpeech, watermark)
        contexts.prune(keepingFrom: earliestNeeded - 120)
    }

    private mutating func refreshOpeningContext(after change: ContextChange) {
        guard var draft = open, change.at <= draft.snippet.range.start else { return }
        draft.snippet.openingContext = contexts.context(at: draft.snippet.range.start)
        draft.hasUnpublishedChanges = true
        open = draft
    }

    private mutating func record(_ evaluation: BoundaryEvaluation) {
        guard recordsEvaluations else { return }
        evaluations.append(evaluation)
    }

    private mutating func nextSnippetID() -> String {
        openedCount += 1
        return "\(idPrefix)\(openedCount)"
    }

    private mutating func drainOutbox() -> [SegmenterEvent] {
        if var draft = open, draft.hasUnpublishedChanges {
            draft.hasUnpublishedChanges = false
            outbox.append(.updated(draft.snippet))
            open = draft
        }
        defer { outbox.removeAll() }
        return outbox
    }

    public func isFiller(_ utterance: Utterance) -> Bool {
        isFillerOnly(utterance)
    }

    private func isFillerOnly(_ utterance: Utterance) -> Bool {
        let tokens = TextAnalysis.tokens(utterance.text)
        if tokens.allSatisfy(fillerWords.contains) { return true }
        let firstMeaningful = tokens.firstIndex { !fillerWords.contains($0) } ?? tokens.count
        let lastMeaningful = tokens.lastIndex { !fillerWords.contains($0) } ?? -1
        for start in 0...firstMeaningful {
            for end in (lastMeaningful + 1)...tokens.count where start < end {
                if closingRemarks.contains(tokens[start..<end].joined(separator: " ")) { return true }
            }
        }
        return false
    }

    private func speechSpan(of utterance: Utterance) -> TimeRange {
        guard let first = utterance.words.first, let last = utterance.words.last else { return utterance.range }
        return TimeRange(start: first.range.start, end: last.range.end)
    }
}
