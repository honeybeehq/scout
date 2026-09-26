import Foundation
import ScoutCore

struct BoundaryCandidate {
    var draft: SnippetDraft
    var previous: Utterance
    var previousSpan: TimeRange
    var next: Utterance
    var nextSpan: TimeRange
    var leadText: String
    var upcoming: ArraySlice<PendingItem>
    var contextBefore: AppContext?
    var contextAfter: AppContext?

    var gap: Double { max(0, nextSpan.start - previousSpan.end) }
    var cut: SessionTime { previousSpan.end + gap / 2 }
}

struct BoundaryScore {
    var score: Double
    var isHard: Bool
    var reasons: [BreakpointReason]
}

struct BoundaryScorer: Sendable {
    let configuration: SegmenterConfiguration
    let similarity: any SemanticSimilarity
    private let cues: PhraseSet
    private let tasks: PhraseSet
    private let closings: PhraseSet
    private let continuations: PhraseSet
    private let openers: Set<String>

    init(configuration: SegmenterConfiguration, similarity: any SemanticSimilarity) {
        self.configuration = configuration
        self.similarity = similarity
        cues = PhraseSet(configuration.cuePhrases)
        tasks = PhraseSet(configuration.taskPhrases, weight: configuration.taskPhraseWeight)
        closings = PhraseSet(configuration.closingPhrases, weight: configuration.closingWeight)
        continuations = PhraseSet(configuration.continuationPhrases, weight: configuration.continuationWeight)
        openers = Set(configuration.leadOpeners.flatMap(TextAnalysis.tokens))
    }

    func score(_ candidate: BoundaryCandidate) -> BoundaryScore {
        var reasons: [BreakpointReason] = []
        func add(_ reason: BreakpointReason?) {
            guard let reason, abs(reason.weight) >= 0.005 else { return }
            reasons.append(reason)
        }
        func add(_ kind: BreakpointReason.Kind, _ weight: Double, _ detail: String) {
            add(BreakpointReason(kind: kind, weight: weight, detail: detail))
        }

        add(.pause, configuration.pauseWeight(for: candidate.gap), "\(formatSeconds(candidate.gap)) s pause")

        let lead = leadPhrases(in: candidate.leadText)
        if let task = lead.task { add(.cuePhrase, task.weight, "task phrase “\(task.phrase)”") }
        if let cue = lead.cue { add(.cuePhrase, cue.weight, "cue “\(cue.phrase)”") }
        if let continuation = lead.continuation { add(.topicContinuity, continuation.weight, "continues with “\(continuation.phrase)”") }

        let previousTokens = TextAnalysis.tokens(candidate.previous.text)
        if let closing = closings.matchInTail(of: previousTokens, depth: configuration.closingSearchDepth) {
            add(.closingPhrase, closing.weight, "closed with “\(closing.phrase)”")
        }

        add(contextReason(before: candidate.contextBefore, after: candidate.contextAfter))
        add(targetReason(candidate))
        add(topicReason(candidate))

        let visualMagnitude = candidate.upcoming.reduce(0.0) { strongest, item in
            guard case .visual(let change) = item.payload, change.at > candidate.previousSpan.end, change.at <= candidate.nextSpan.start else { return strongest }
            return max(strongest, change.magnitude)
        }
        add(.visualChange, configuration.visualChangeWeight * min(1, visualMagnitude), "screen changed \(Int((min(1, visualMagnitude) * 100).rounded()))%")

        let speech = candidate.draft.speechDuration
        if speech < configuration.minimumSpeechDuration, configuration.minimumSpeechDuration > 0 {
            let shortfall = 1 - speech / configuration.minimumSpeechDuration
            add(.minimumLength, configuration.minimumLengthWeight * shortfall, "only \(formatSeconds(speech)) s of speech so far")
        }
        let length = candidate.previousSpan.end - candidate.draft.snippet.range.start
        if length > configuration.softMaximumDuration {
            add(.maximumLength, configuration.maximumLengthWeight, "snippet already \(Int(length.rounded())) s long")
        }

        return BoundaryScore(score: reasons.reduce(0) { $0 + $1.weight }, isHard: lead.task != nil, reasons: reasons)
    }

    private func leadPhrases(in text: String) -> (task: PhraseMatch?, cue: PhraseMatch?, continuation: PhraseMatch?) {
        let tokens = TextAnalysis.tokens(text)
        let depth = configuration.leadSearchDepth
        let task = tasks.matchAtLead(of: tokens, openers: openers, depth: depth)
        var cue = cues.matchAtLead(of: tokens, openers: openers, depth: depth)
        var continuation = continuations.matchAtLead(of: tokens, openers: openers, depth: depth)
        if let task, let found = cue, found.overlaps(task) { cue = nil }
        if let task, let found = continuation, found.overlaps(task) { continuation = nil }
        if let found = cue, let other = continuation, found.overlaps(other) {
            if found.length > other.length { continuation = nil } else { cue = nil }
        }
        return (task, cue, continuation)
    }

    private func contextReason(before: AppContext?, after: AppContext?) -> BreakpointReason? {
        guard let before, let after else { return nil }
        if !before.app.isSameApp(as: after.app) {
            return BreakpointReason(kind: .appChange, weight: configuration.appChangeWeight, detail: "\(before.app.name) → \(after.app.name)")
        }
        if before.location != after.location, before.location != nil || after.location != nil {
            let detail = "\(Self.shortLocation(before.location)) → \(Self.shortLocation(after.location))"
            return BreakpointReason(kind: .locationChange, weight: configuration.locationChangeWeight, detail: detail)
        }
        if before.windowTitle != after.windowTitle {
            let detail = "“\(before.windowTitle ?? "untitled")” → “\(after.windowTitle ?? "untitled")”"
            return BreakpointReason(kind: .windowChange, weight: configuration.windowChangeWeight, detail: detail)
        }
        return nil
    }

    private func targetReason(_ candidate: BoundaryCandidate) -> BreakpointReason? {
        let previous = candidate.draft.targets.dominant(
            at: candidate.previousSpan.end,
            halfLife: configuration.targetHalfLife,
            minimumWeight: configuration.minimumTargetWeight
        )
        guard let previous, let next = upcomingTarget(candidate) else { return nil }
        if previous.isRelated(to: next) {
            return BreakpointReason(kind: .targetContinuity, weight: configuration.targetContinuityWeight, detail: "still on \(next.target.displayName)")
        }
        let weight = next.isPinned ? configuration.pinnedTargetChangeWeight : configuration.targetChangeWeight
        let verb = next.isPinned ? "pinned" : "pointing at"
        return BreakpointReason(kind: .targetChange, weight: weight, detail: "\(previous.target.displayName) → \(verb) \(next.target.displayName)")
    }

    private func upcomingTarget(_ candidate: BoundaryCandidate) -> DominantTarget? {
        let window = TimeRange(
            start: max(candidate.previousSpan.end, candidate.nextSpan.start - configuration.leadWindow),
            end: candidate.nextSpan.end
        )
        var tally = TargetTally()
        let halfLife = configuration.targetHalfLife
        let carriedFocuses = candidate.draft.snippet.focuses.suffix(8)
        for focus in carriedFocuses where focus.range.overlap(with: window) > 0 {
            tally.add(focus.target, weight: focus.range.overlap(with: window), at: window.end, pinned: false, halfLife: halfLife)
        }
        for item in candidate.upcoming {
            switch item.payload {
            case .focus(let focus) where focus.range.overlap(with: window) > 0:
                tally.add(focus.target, weight: focus.range.overlap(with: window), at: window.end, pinned: false, halfLife: halfLife)
            case .mark(let mark) where window.contains(mark.at):
                if let target = mark.target {
                    tally.add(target, weight: configuration.markDwellEquivalent, at: window.end, pinned: true, halfLife: halfLife)
                }
            default:
                continue
            }
        }
        return tally.dominant(at: window.end, halfLife: halfLife, minimumWeight: configuration.minimumTargetWeight)
    }

    private func topicReason(_ candidate: BoundaryCandidate) -> BreakpointReason? {
        let context = candidate.draft.recentTexts.joined(separator: " ")
        guard let value = similarity.similarity(of: candidate.next.text, to: context) else { return nil }
        let low = configuration.lowSimilarity
        let high = configuration.highSimilarity
        let position = high > low ? min(1, max(0, (value - low) / (high - low))) : (value >= high ? 1 : 0)
        let weight = configuration.topicShiftWeight + position * (configuration.topicContinuityWeight - configuration.topicShiftWeight)
        let kind: BreakpointReason.Kind = weight >= 0 ? .topicShift : .topicContinuity
        return BreakpointReason(kind: kind, weight: weight, detail: "similarity \(String(format: "%.2f", value)) to recent speech")
    }

    private static func shortLocation(_ location: String?) -> String {
        guard var location else { return "none" }
        for scheme in ["https://", "http://"] where location.hasPrefix(scheme) {
            location.removeFirst(scheme.count)
        }
        return location
    }
}

func formatSeconds(_ seconds: Double) -> String {
    String(format: "%.1f", seconds)
}
