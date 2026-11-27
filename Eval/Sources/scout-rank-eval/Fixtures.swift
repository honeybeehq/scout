import Foundation
import ScoutRanking

struct BridgeRow: Codable {
    var kind: String
    var id: String
    var sessionId: String?
    var title: String?
    var handle: String?
    var subtitle: String?
    var name: String?
    var displayName: String?
    var sessionTitle: String?
    var championName: String?
    var championId: String?
    var workspaceId: String?
    var workspaceName: String?
    var focused: Bool?
    var bio: String?
    var lastActiveAt: String?

    var key: String { "\(kind):\(id)" }

    var alias: String {
        switch rankKind {
        case .champion: "c:\(id)"
        case .project: "p:\(id)"
        case .session: "s:\(title ?? id)"
        }
    }

    var rankKind: RankCandidate.Kind {
        if kind == "project" { return .project }
        if kind == "champion" || championName != nil { return .champion }
        return .session
    }

    func candidate(lastActive: Date?) -> RankCandidate {
        let label = title ?? championName ?? displayName ?? name ?? handle ?? id
        return RankCandidate(
            key: key,
            kind: rankKind,
            name: label,
            bio: bio ?? sessionTitle,
            project: rankKind == .project ? nil : subtitle,
            workspace: workspaceName ?? workspaceId,
            lastActiveAt: lastActive
        )
    }
}

struct CaseFeedback: Codable {
    var app: String
    var url: String
    var pageTitle: String
    var transcript: String
}

struct EvalCase: Codable {
    var id: String
    var tags: [String]
    var gold: String
    var feedback: CaseFeedback
    var candidates: [String]
    var recency: [String: Double]
}

struct ResolvedCase {
    var id: String
    var tags: [String]
    var gold: String
    var feedback: RankFeedback
    var candidates: [RankCandidate]
    var rows: [BridgeRow]
}

struct FixtureSet {
    static let referenceNow = ISO8601DateFormatter().date(from: "2026-11-27T12:00:00Z")!
    static let defaultMinutesAgo = 4320.0

    var cases: [ResolvedCase]
    var problems: [String]

    static func load(directory: URL) throws -> FixtureSet {
        struct Pool: Codable { var targets: [BridgeRow] }
        struct Cases: Codable { var cases: [EvalCase] }
        let pool = try JSONDecoder().decode(Pool.self, from: Data(contentsOf: directory.appendingPathComponent("targets.json")))
        let raw = try JSONDecoder().decode(Cases.self, from: Data(contentsOf: directory.appendingPathComponent("cases.json")))
        var problems: [String] = []
        var byAlias: [String: BridgeRow] = [:]
        for row in pool.targets {
            if byAlias[row.alias] != nil { problems.append("duplicate target alias \(row.alias)") }
            byAlias[row.alias] = row
        }
        var seen = Set<String>()
        var cases: [ResolvedCase] = []
        for item in raw.cases {
            if !seen.insert(item.id).inserted { problems.append("\(item.id): duplicate case id") }
            if !(6...15).contains(item.candidates.count) { problems.append("\(item.id): \(item.candidates.count) candidates, want 6–15") }
            if Set(item.candidates).count != item.candidates.count { problems.append("\(item.id): repeated candidate") }
            if !item.candidates.contains(item.gold) { problems.append("\(item.id): gold \(item.gold) is not a candidate") }
            for alias in item.recency.keys where !item.candidates.contains(alias) { problems.append("\(item.id): recency for non-candidate \(alias)") }
            var rows: [BridgeRow] = []
            for alias in item.candidates {
                guard let row = byAlias[alias] else { problems.append("\(item.id): unknown target \(alias)"); continue }
                var copy = row
                let minutes = item.recency[alias] ?? defaultMinutesAgo
                copy.lastActiveAt = ISO8601DateFormatter().string(from: referenceNow.addingTimeInterval(-minutes * 60))
                rows.append(copy)
            }
            let candidates = rows.map { $0.candidate(lastActive: $0.lastActiveAt.flatMap { ISO8601DateFormatter().date(from: $0) }) }
            let gold = byAlias[item.gold]?.key ?? item.gold
            let feedback = RankFeedback(transcript: item.feedback.transcript, pageURL: item.feedback.url.isEmpty ? nil : item.feedback.url, pageTitle: item.feedback.pageTitle, appName: item.feedback.app)
            cases.append(ResolvedCase(id: item.id, tags: item.tags, gold: gold, feedback: feedback, candidates: candidates, rows: rows))
        }
        return FixtureSet(cases: cases, problems: problems)
    }
}
