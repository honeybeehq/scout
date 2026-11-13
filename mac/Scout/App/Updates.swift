import Foundation
import Observation
import Sparkle

@Observable
final class Updates {
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observation: NSKeyValueObservation?
    private(set) var canCheck = false
    let isConfigured: Bool
    var checksAutomatically: Bool {
        didSet {
            guard checksAutomatically != oldValue else { return }
            controller.updater.automaticallyChecksForUpdates = checksAutomatically
        }
    }

    init(starts: Bool) {
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        isConfigured = Self.configured(in: .main)
        checksAutomatically = controller.updater.automaticallyChecksForUpdates
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        if starts && isConfigured {
            controller.startUpdater()
        }
        refresh()
    }

    var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var unavailableReason: String? {
        isConfigured ? nil : "Updates aren't set up in this build."
    }

    func check() {
        guard canCheck else { return }
        controller.checkForUpdates(nil)
    }

    private func refresh() {
        canCheck = isConfigured && controller.updater.canCheckForUpdates
    }

    private static func configured(in bundle: Bundle) -> Bool {
        let feed = (bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? "").trimmingCharacters(in: .whitespaces)
        let key = (bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? "").trimmingCharacters(in: .whitespaces)
        return feed.hasPrefix("https://") && !key.isEmpty
    }
}
