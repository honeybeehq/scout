import Foundation
import Observation

enum Segmentation: String, CaseIterable, Identifiable {
    case automatic
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .manual: "Manual"
        }
    }

    var explanation: String {
        switch self {
        case .automatic: "Scout starts a new task when you pause, move on, switch apps or point somewhere else."
        case .manual: "Scout only starts a new task when you press the break shortcut or say “new task”."
        }
    }
}

enum ReviewOpening: String, CaseIterable, Identifiable {
    case always
    case whenNeeded
    case never

    var id: String { rawValue }

    var title: String {
        switch self {
        case .always: "Always"
        case .whenNeeded: "When tasks are waiting"
        case .never: "Never"
        }
    }
}

@Observable
final class Preferences {
    private let defaults = UserDefaults.standard

    var autoSend: Bool {
        didSet { defaults.set(autoSend, forKey: "delivery.autoSend") }
    }

    var autoSendDelay: Double {
        didSet { defaults.set(autoSendDelay, forKey: "delivery.autoSendDelay") }
    }

    var defaultAgent: String {
        didSet { defaults.set(defaultAgent, forKey: "delivery.defaultAgent") }
    }

    var includeClips: Bool {
        didSet { defaults.set(includeClips, forKey: "capture.includeClips") }
    }

    var segmentation: Segmentation {
        didSet { defaults.set(segmentation.rawValue, forKey: "scouting.segmentation") }
    }

    var reviewOpening: ReviewOpening {
        didSet { defaults.set(reviewOpening.rawValue, forKey: "review.opening") }
    }

    static let agents = ["claude", "codex", "grok", "kimi"]

    init() {
        defaults.register(defaults: [
            "delivery.autoSend": true,
            "delivery.autoSendDelay": 5.0,
            "delivery.defaultAgent": "claude",
            "capture.includeClips": true,
            "scouting.segmentation": Segmentation.automatic.rawValue,
            "review.opening": ReviewOpening.whenNeeded.rawValue,
        ])
        autoSend = defaults.bool(forKey: "delivery.autoSend")
        autoSendDelay = defaults.double(forKey: "delivery.autoSendDelay")
        defaultAgent = defaults.string(forKey: "delivery.defaultAgent") ?? "claude"
        includeClips = defaults.bool(forKey: "capture.includeClips")
        segmentation = Segmentation(rawValue: defaults.string(forKey: "scouting.segmentation") ?? "") ?? .automatic
        reviewOpening = ReviewOpening(rawValue: defaults.string(forKey: "review.opening") ?? "") ?? .whenNeeded
    }
}
