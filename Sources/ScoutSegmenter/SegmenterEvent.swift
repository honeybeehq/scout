import Foundation
import ScoutCore

public enum SegmenterEvent: Hashable, Sendable {
    case opened(Snippet)
    case updated(Snippet)
    case closed(Snippet)
    case discarded(id: String)
}

public struct BoundaryEvaluation: Codable, Hashable, Sendable {
    public enum Decision: String, Codable, Sendable {
        case split
        case keep
    }

    public var at: SessionTime
    public var score: Double
    public var threshold: Double
    public var isHard: Bool
    public var decision: Decision
    public var reasons: [BreakpointReason]
    public var snippetID: String
    public var previousUtteranceID: String?
    public var nextUtteranceID: String?

    public init(
        at: SessionTime,
        score: Double,
        threshold: Double,
        isHard: Bool,
        decision: Decision,
        reasons: [BreakpointReason],
        snippetID: String,
        previousUtteranceID: String? = nil,
        nextUtteranceID: String? = nil
    ) {
        self.at = at
        self.score = score
        self.threshold = threshold
        self.isHard = isHard
        self.decision = decision
        self.reasons = reasons
        self.snippetID = snippetID
        self.previousUtteranceID = previousUtteranceID
        self.nextUtteranceID = nextUtteranceID
    }

    public var breakpoint: Breakpoint {
        Breakpoint(at: at, score: score, isHard: isHard, reasons: reasons)
    }
}
