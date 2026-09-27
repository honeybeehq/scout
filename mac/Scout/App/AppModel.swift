import AppKit
import Observation
import ScoutCore
import ServiceManagement

@Observable
final class AppModel {
    let permissions = PermissionCenter()
    let onboarding = OnboardingModel()
    let transcriber = LiveTranscriber()
    let integrations: Integrations
    let dispatcher: Dispatcher
    let hud = HUDController()
    let bridge = BridgeServer()
    let preferences = Preferences()
    private(set) var session: ScoutingSession?
    private(set) var review: SessionReview?
    var openOnboarding: (() -> Void)?
    var openSettingsWindow: (() -> Void)?
    var openReviewWindow: (() -> Void)?
    let breakShortcut = KeyShortcut.nextTask
    private var breakHotkey: GlobalHotkey?
    private var openWindows = 0

    private(set) var shortcut: KeyShortcut
    private(set) var shortcutRegistered = false
    private(set) var isScouting = false

    private var hotkey: GlobalHotkey?

    private static let shortcutKey = "shortcut.startScouting"

    init() {
        let integrations = Integrations()
        self.integrations = integrations
        dispatcher = Dispatcher(integrations: integrations, bridge: bridge, preferences: preferences)
        if let data = UserDefaults.standard.data(forKey: Self.shortcutKey),
           let saved = try? JSONDecoder().decode(KeyShortcut.self, from: data) {
            shortcut = saved
        } else {
            shortcut = .startScouting
        }
        let hotkey = GlobalHotkey { [weak self] in self?.toggleScouting() }
        self.hotkey = hotkey
        shortcutRegistered = hotkey.register(shortcut)
        dispatcher.dryRun = SimulationMode.isDryRun
        bridge.start()
        Task.detached(priority: .background) { ScoutPaths.prune() }
        if let pane = SettingsView.requestedPane, let directory = SnapshotMode.directory {
            Task { await SnapshotMode.captureSettings(model: self, into: directory, pane: pane) }
        }
        if let audio = SimulationMode.audioFile {
            if SimulationMode.isQuickStop {
                Task { await SimulationMode.runQuickStop(model: self, audio: audio) }
            } else {
                Task { await SimulationMode.run(model: self, audio: audio) }
            }
        }
    }

    func updateShortcut(_ newShortcut: KeyShortcut) {
        shortcut = newShortcut
        shortcutRegistered = hotkey?.register(newShortcut) ?? false
        if let data = try? JSONEncoder().encode(newShortcut) {
            UserDefaults.standard.set(data, forKey: Self.shortcutKey)
        }
    }

    func suspendShortcut() {
        hotkey?.unregister()
    }

    func resumeShortcut() {
        shortcutRegistered = hotkey?.register(shortcut) ?? false
    }

    func toggleScouting() {
        isScouting ? stopScouting() : startScouting()
    }

    func startScouting(inputFile: URL? = nil, segmentation: Segmentation? = nil, onInputFinished: (() -> Void)? = nil) {
        guard !isScouting else { return }
        guard inputFile != nil || permissions.state(of: .microphone).isGranted else {
            onboarding.go(to: .access)
            openOnboarding?()
            return
        }
        let session = ScoutingSession(bridge: bridge, recordsScreen: preferences.includeClips, segmentation: segmentation ?? preferences.segmentation)
        session.transcriber.inputFile = inputFile
        session.transcriber.onInputFinished = onInputFinished
        session.onSnippetClosed = { [weak self, weak session] snippet, immediate in
            guard let self, let session else { return }
            dispatcher.accept(snippet, from: session, sendImmediately: immediate)
        }
        session.onSnippetDiscarded = { [weak self, weak session] snippetID in
            guard let self, let session else { return }
            dispatcher.retract(snippetID: snippetID, sessionID: session.id)
        }
        self.session = session
        isScouting = true
        hud.show(model: self)
        let breakHotkey = breakHotkey ?? GlobalHotkey { [weak self] in self?.session?.splitNow() }
        self.breakHotkey = breakHotkey
        breakHotkey.register(breakShortcut)
        session.begin()
    }

    func stopScouting() {
        guard isScouting, let session else { return }
        isScouting = false
        breakHotkey?.unregister()
        Task {
            await session.end()
            guard self.session === session, !isScouting else { return }
            hud.hidePill()
            let review = SessionReview(session: session, dispatcher: dispatcher)
            review.refreshFromSession()
            if let first = review.tasks.first { review.select(first) }
            review.save()
            if shouldOpenReview(review) {
                self.review = review
                hud.hideAll()
                openReviewWindow?()
            } else {
                if self.review == nil || self.review?.isLive == true { self.review = review }
                stackChanged()
            }
        }
    }

    private func shouldOpenReview(_ review: SessionReview) -> Bool {
        switch preferences.reviewOpening {
        case .always: return !review.tasks.isEmpty || !review.leftoverSpeech.isEmpty
        case .never: return false
        case .whenNeeded:
            return review.tasks.contains { card in
                switch card.state {
                case .needsDestination, .held, .failed: true
                default: false
                }
            } || !review.leftoverSpeech.isEmpty
        }
    }

    func openLatestReview() {
        if review == nil, let latest = SessionLibrary.recent(limit: 1).first {
            openReview(latest)
            return
        }
        openReviewWindow?()
    }

    func openReview(_ summary: SessionSummary) {
        review?.save()
        if let existing = review, existing.sessionID == summary.id {
            openReviewWindow?()
            return
        }
        guard let record = ReviewRecord.read(from: summary.directory) else { return }
        let ledger = SessionLibrary.ledger(in: summary.directory)
        let loaded = SessionReview(directory: summary.directory, record: record, ledger: ledger, dispatcher: dispatcher)
        if dispatcher.cards(inSession: record.sessionID).isEmpty {
            for task in record.tasks {
                let card = SnippetCard(snippet: ledger.snippet(id: task.id, range: TimeRange(start: task.start, end: task.end)), sessionID: record.sessionID, sessionDirectory: summary.directory)
                card.restoreTitle(task.title, custom: task.titleIsCustom)
                card.transcriptOverride = task.transcriptOverride
                card.excludedTargetIDs = Set(task.excludedTargetIDs)
                card.sessionVideo = loaded.video
                card.sessionDisplay = loaded.display
                if let sentTo = task.sentTo {
                    card.state = .sent(sentTo)
                    dispatcher.insert(card)
                } else {
                    card.state = .held
                    dispatcher.prepareHeld(card)
                }
            }
        }
        if let first = loaded.tasks.first { loaded.select(first) }
        review = loaded
        openReviewWindow?()
    }

    func sendAll(in review: SessionReview) async {
        for card in review.tasks where !card.isLocked && card.destination != nil {
            await dispatcher.send(card)
        }
        review.save()
    }

    func windowOpened() {
        openWindows += 1
        guard SimulationMode.audioFile == nil else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func windowClosed() {
        openWindows = max(0, openWindows - 1)
        if openWindows == 0 { NSApp.setActivationPolicy(.accessory) }
    }

    func stackChanged() {
        if !isScouting && dispatcher.cards.isEmpty {
            hud.hideAll()
        }
    }

    var opensAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSSound.beep()
            }
        }
    }
}
