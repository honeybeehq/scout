import AppKit
import Foundation
import Observation
import Sparkle

@Observable
final class Updates {
    struct Available: Equatable {
        let version: String
        let readyToInstall: Bool

        var title: String { readyToInstall ? "Restart to update" : "Update available" }
    }

    @ObservationIgnored private let driverDelegate: UpdateDriverDelegate
    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private var deferredUntilRecordingEnds = false
    @ObservationIgnored private let simulation = UpdateSimulation.current
    private(set) var canCheck = false
    private(set) var available: Available?
    let isConfigured: Bool
    var isRecording = false {
        didSet {
            guard isRecording != oldValue else { return }
            simulation?.log("recording \(isRecording ? "started" : "ended")", updates: self)
            if !isRecording { presentDeferredUpdate() }
        }
    }
    var checksAutomatically: Bool {
        didSet {
            guard checksAutomatically != oldValue else { return }
            controller.updater.automaticallyChecksForUpdates = checksAutomatically
        }
    }

    init(starts: Bool) {
        let delegate = UpdateDriverDelegate()
        driverDelegate = delegate
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: delegate)
        isConfigured = Self.configured(in: .main)
        checksAutomatically = controller.updater.automaticallyChecksForUpdates
        delegate.updates = self
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        if starts && isConfigured {
            controller.startUpdater()
        }
        refresh()
        simulation?.start(updates: self)
    }

    var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var canCheckNow: Bool {
        canCheck && !isRecording
    }

    var unavailableReason: String? {
        if !isConfigured { return "Updates aren't set up in this build." }
        if isRecording { return "Available when this recording ends." }
        return nil
    }

    func check() {
        guard canCheckNow else { return }
        controller.checkForUpdates(nil)
    }

    func showAvailable() {
        guard available != nil, !isRecording else { return }
        present()
    }

    func shouldShowScheduledUpdate(immediateFocus: Bool) -> Bool {
        if isRecording {
            deferredUntilRecordingEnds = true
            simulation?.log("scheduled update found while recording: deferred", updates: self)
            return false
        }
        simulation?.log("scheduled update found, immediate focus \(immediateFocus): \(immediateFocus ? "shown now" : "gentle reminder")", updates: self)
        return immediateFocus
    }

    func willShowUpdate(handledBySparkle: Bool, version: String, readyToInstall: Bool) {
        available = handledBySparkle ? nil : Available(version: version, readyToInstall: readyToInstall)
        simulation?.log(available == nil ? "Sparkle shows the update" : "badge on: \(available!.title) \(version)", updates: self)
    }

    func updateSeen() {
        guard available != nil || deferredUntilRecordingEnds else { return }
        available = nil
        deferredUntilRecordingEnds = false
        simulation?.log("update shown, installed or dismissed: badge off", updates: self)
    }

    private func presentDeferredUpdate() {
        guard deferredUntilRecordingEnds else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, deferredUntilRecordingEnds, !isRecording else { return }
            deferredUntilRecordingEnds = false
            present()
        }
    }

    private func present() {
        if let simulation {
            simulation.log("showing the update (Sparkle's alert would open here)", updates: self)
            updateSeen()
            return
        }
        NSApp.activate()
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

final class UpdateDriverDelegate: NSObject, @preconcurrency SPUStandardUserDriverDelegate {
    weak var updates: Updates?

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        updates?.shouldShowScheduledUpdate(immediateFocus: immediateFocus) ?? immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        updates?.willShowUpdate(handledBySparkle: handleShowingUpdate, version: update.displayVersionString, readyToInstall: state.stage != .notDownloaded)
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        updates?.updateSeen()
    }

    func standardUserDriverWillFinishUpdateSession() {
        updates?.updateSeen()
    }
}

final class UpdateSimulation {
    static let current: UpdateSimulation? = {
        let prefix = "--simulate-update="
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }),
              let delay = Double(argument.dropFirst(prefix.count))
        else { return nil }
        return UpdateSimulation(delay: delay, directory: SimulationMode.outputDirectory)
    }()

    let delay: Double
    let directory: URL
    private let started = Date()
    private var lines: [String] = []
    private var step = 0

    init(delay: Double, directory: URL) {
        self.delay = delay
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func start(updates: Updates) {
        log("simulation armed: a scheduled update for 9.9.9 arrives at \(delay)s", updates: updates)
        Task { @MainActor [weak updates] in
            try? await Task.sleep(for: .seconds(delay))
            guard let updates else { return }
            let shown = updates.shouldShowScheduledUpdate(immediateFocus: true)
            updates.willShowUpdate(handledBySparkle: shown, version: "9.9.9", readyToInstall: false)
            if shown { updates.updateSeen() }
        }
    }

    func log(_ event: String, updates: Updates) {
        let elapsed = String(format: "%7.2f", Date().timeIntervalSince(started))
        let badge = updates.available.map { "\($0.title) \($0.version)" } ?? "none"
        lines.append("t=\(elapsed)s recording=\(updates.isRecording) badge=\(badge) | \(event)")
        try? (lines.joined(separator: "\n") + "\n").write(to: directory.appendingPathComponent("updates-log.txt"), atomically: true, encoding: .utf8)
        step += 1
        let image = MenuBarIcon.image(scouting: updates.isRecording, updateReady: updates.available != nil)
        if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: directory.appendingPathComponent(String(format: "menubar-%02d.png", step)))
        }
    }
}
