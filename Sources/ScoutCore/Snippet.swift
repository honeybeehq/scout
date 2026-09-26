import Foundation

public struct BreakpointReason: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case pause
        case cuePhrase
        case closingPhrase
        case appChange
        case windowChange
        case locationChange
        case targetChange
        case targetContinuity
        case topicShift
        case topicContinuity
        case visualChange
        case minimumLength
        case maximumLength
        case silenceTimeout
        case command
        case sessionEnd
    }

    public var kind: Kind
    public var weight: Double
    public var detail: String?

    public init(kind: Kind, weight: Double, detail: String? = nil) {
        self.kind = kind
        self.weight = weight
        self.detail = detail
    }
}

public struct Breakpoint: Codable, Hashable, Sendable {
    public var at: SessionTime
    public var score: Double
    public var isHard: Bool
    public var reasons: [BreakpointReason]

    public init(at: SessionTime, score: Double, isHard: Bool, reasons: [BreakpointReason]) {
        self.at = at
        self.score = score
        self.isHard = isHard
        self.reasons = reasons
    }
}

public struct Snippet: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var range: TimeRange
    public var utterances: [Utterance]
    public var focuses: [Focus]
    public var marks: [Mark]
    public var contexts: [ContextChange]
    public var openingContext: AppContext?
    public var closedBy: Breakpoint?

    public init(
        id: String,
        range: TimeRange,
        utterances: [Utterance] = [],
        focuses: [Focus] = [],
        marks: [Mark] = [],
        contexts: [ContextChange] = [],
        openingContext: AppContext? = nil,
        closedBy: Breakpoint? = nil
    ) {
        self.id = id
        self.range = range
        self.utterances = utterances
        self.focuses = focuses
        self.marks = marks
        self.contexts = contexts
        self.openingContext = openingContext
        self.closedBy = closedBy
    }

    public var transcript: String {
        utterances.map(\.text).joined(separator: " ")
    }

    public var primaryContext: AppContext? {
        let spokenAt = utterances.last?.range.start ?? marks.last?.at ?? range.end
        return contexts.last { $0.at <= spokenAt }?.context ?? openingContext ?? contexts.first?.context
    }

    public var targets: [Target] {
        var seen = Set<String>()
        let pinned = marks.compactMap(\.target)
        let dwelled = focuses.sorted { $0.range.duration > $1.range.duration }.map(\.target)
        return (pinned + dwelled).filter { seen.insert($0.id).inserted }
    }
}
