import Foundation
import Observation

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

    static let agents = ["claude", "codex", "grok", "kimi"]

    init() {
        defaults.register(defaults: [
            "delivery.autoSend": true,
            "delivery.autoSendDelay": 5.0,
            "delivery.defaultAgent": "claude",
            "capture.includeClips": true,
        ])
        autoSend = defaults.bool(forKey: "delivery.autoSend")
        autoSendDelay = defaults.double(forKey: "delivery.autoSendDelay")
        defaultAgent = defaults.string(forKey: "delivery.defaultAgent") ?? "claude"
        includeClips = defaults.bool(forKey: "capture.includeClips")
    }
}
