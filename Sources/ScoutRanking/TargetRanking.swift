import Foundation

public struct RankFeedback: Sendable, Hashable {
    public var transcript: String
    public var pageURL: String?
    public var pageTitle: String?
    public var appName: String?

    public init(transcript: String, pageURL: String? = nil, pageTitle: String? = nil, appName: String? = nil) {
        self.transcript = transcript
        self.pageURL = pageURL
        self.pageTitle = pageTitle
        self.appName = appName
    }

    public static let transcriptLimit = 500

    public var transcriptPrefix: String {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > Self.transcriptLimit else { return text }
        let cut = text.prefix(Self.transcriptLimit)
        if let space = cut.lastIndex(where: \.isWhitespace), cut.distance(from: cut.startIndex, to: space) > Self.transcriptLimit * 3 / 4 {
            return String(cut[..<space])
        }
        return String(cut)
    }

    public var urlHost: String? {
        guard let pageURL, let components = URLComponents(string: pageURL), let host = components.host, !host.isEmpty else { return nil }
        return host.lowercased()
    }
}

public struct RankCandidate: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case champion
        case project
        case session

        public var label: String {
            switch self {
            case .champion: "Champion"
            case .project: "Project"
            case .session: "Session"
            }
        }
    }

    public var key: String
    public var kind: Kind
    public var name: String
    public var bio: String?
    public var project: String?
    public var workspace: String?
    public var lastActiveAt: Date?

    public var id: String { key }

    public init(key: String, kind: Kind, name: String, bio: String? = nil, project: String? = nil, workspace: String? = nil, lastActiveAt: Date? = nil) {
        self.key = key
        self.kind = kind
        self.name = name
        self.bio = bio
        self.project = project
        self.workspace = workspace
        self.lastActiveAt = lastActiveAt
    }
}

public enum RecencyBucket: String, Sendable, CaseIterable {
    case now = "active in the last 15 minutes"
    case hour = "active in the last 2 hours"
    case today = "active today"
    case week = "active this week"
    case idle = "idle for over a week"
    case unknown = "unknown"

    public init(lastActiveAt: Date?, now: Date) {
        guard let lastActiveAt else { self = .unknown; return }
        let minutes = max(0, now.timeIntervalSince(lastActiveAt) / 60)
        switch minutes {
        case ..<15: self = .now
        case ..<120: self = .hour
        case ..<1440: self = .today
        case ..<10080: self = .week
        default: self = .idle
        }
    }

    public var weight: Double {
        switch self {
        case .now: 1.0
        case .hour: 0.7
        case .today: 0.4
        case .week: 0.15
        case .idle, .unknown: 0
        }
    }
}

public struct ScoredTarget: Sendable, Hashable {
    public var key: String
    public var probability: Double
    public var fit: Double?
}

public struct TargetRanking: Sendable {
    public enum Source: String, Sendable {
        case heuristic
        case jev
    }

    public var source: Source
    public var ranked: [ScoredTarget]
    public var confidence: Double
    public var anyFits: Double?
    public var model: String?
    public var elapsed: Duration
    public var inputTokens: Int?

    public var top: ScoredTarget? { ranked.first }

    public func suggestion(minimumProbability: Double) -> ScoredTarget? {
        guard let top, top.probability >= minimumProbability else { return nil }
        return top
    }
}

public protocol TargetRanker: Sendable {
    func rank(_ feedback: RankFeedback, candidates: [RankCandidate], now: Date) async throws -> TargetRanking
}

extension TargetRanking {
    static func normalized(_ scores: [(String, Double)], source: Source, elapsed: Duration, fits: [String: Double] = [:], anyFits: Double? = nil, model: String? = nil, inputTokens: Int? = nil) -> TargetRanking {
        let total = scores.reduce(0) { $0 + max(0, $1.1) }
        let ranked = scores
            .map { ScoredTarget(key: $0.0, probability: total > 0 ? max(0, $0.1) / total : 1 / Double(max(scores.count, 1)), fit: fits[$0.0]) }
            .enumerated()
            .sorted { $0.element.probability != $1.element.probability ? $0.element.probability > $1.element.probability : $0.offset < $1.offset }
            .map(\.element)
        let n = Double(ranked.count)
        let top = ranked.first?.probability ?? 0
        let confidence = n > 1 ? max(0, (top - 1 / n) / (1 - 1 / n)) : 1
        return TargetRanking(source: source, ranked: ranked, confidence: confidence, anyFits: anyFits, model: model, elapsed: elapsed, inputTokens: inputTokens)
    }
}
