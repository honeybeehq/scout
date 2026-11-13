import Foundation
import ScoutCore

nonisolated struct LinearReceipt: Codable, Hashable, Sendable {
    enum Status: Codable, Hashable, Sendable {
        case pending
        case filed(LinearIssueRef)
        case deletedRemotely
    }

    var key: String
    var status: Status
    var assets: [StoredAsset]
    var clipAttachmentID: String?
    var unlinkedClip: Bool?
    var parent: LinearIssueRef?

    var video: StoredAsset? {
        assets.first(where: \.isVideo)
    }

    var issue: LinearIssueRef? {
        if case .filed(let issue) = status { issue } else { nil }
    }
}

nonisolated struct LinearTaskOptions: Codable, Hashable, Sendable {
    var labelIDs: [String]?
    var priority: Int?
    var includeVideo: Bool?
    var redaction: ClipRedaction?
}

nonisolated enum LinearPriority: Int, CaseIterable, Identifiable, Sendable {
    case none = 0, urgent, high, medium, low

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .none: "No priority"
        case .urgent: "Urgent"
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        }
    }

    init(_ urgency: TaskBrief.Urgency) {
        switch urgency {
        case .none: self = .none
        case .low: self = .low
        case .medium: self = .medium
        case .high: self = .high
        case .urgent: self = .urgent
        }
    }
}

nonisolated enum LinearInference {
    static func labelIDs(for kind: TaskBrief.Kind, in labels: [LinearLabel]) -> [String] {
        let names: [String] = switch kind {
        case .bug: ["bug"]
        case .polish: ["improvement", "polish"]
        case .feature: ["feature"]
        case .question: ["question"]
        }
        for name in names {
            if let label = labels.first(where: { $0.name.lowercased() == name }) { return [label.id] }
        }
        return []
    }
}
