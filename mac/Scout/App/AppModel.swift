import AppKit
import ApplicationServices
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
    private(set) var lastWalkthrough: FinishedWalkthrough?
    private(set) var walkthroughProblem: String?
    private(set) var review: SessionReview?
    private var reviews: [String: SessionReview] = [:]
    private var latestSessionID: String?
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
        dispatcher.onCardChanged = { [weak self] card in self?.reviews[card.sessionID]?.cardChanged(card) }
        bridge.start()
        Task.detached(priority: .background) { ScoutPaths.prune() }
        if let pane = SettingsView.requestedPane, let directory = SnapshotMode.directory {
            Task { await SnapshotMode.captureSettings(model: self, into: directory, pane: pane) }
        }
        if let directory = SimulationMode.deliveryCheck {
            Task { await SimulationMode.runDeliveryCheck(model: self, directory: directory) }
        }
        if SimulationMode.reopensLatest {
            Task { await SimulationMode.reopenLatest(model: self) }
        }
        if let fixture = SimulationMode.walkthroughFixture {
            Task { await SimulationMode.runWalkthrough(model: self, fixtureURL: fixture) }
        } else if let audio = SimulationMode.audioFile {
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

    func startSplitTasks() {
        startScouting(result: .tasks)
    }

    func startScouting(inputFile: URL? = nil, segmentation: Segmentation? = nil, result: SessionResult = .walkthrough, onInputFinished: (() -> Void)? = nil) {
        guard !isScouting else { return }
        guard inputFile != nil || permissions.state(of: .microphone).isGranted else {
            onboarding.go(to: .access)
            openOnboarding?()
            return
        }
        let session = ScoutingSession(
            bridge: bridge,
            recordsScreen: preferences.includeClips && SimulationMode.fixtureVideo == nil,
            segmentation: segmentation ?? preferences.segmentation,
            producesWalkthrough: result == .walkthrough
        )
        session.transcriber.inputFile = inputFile
        session.transcriber.onInputFinished = onInputFinished
        if result == .tasks { connectTasks(of: session) }
        self.session = session
        isScouting = true
        hud.show(model: self)
        let breakHotkey = breakHotkey ?? GlobalHotkey { [weak self] in self?.session?.splitNow() }
        self.breakHotkey = breakHotkey
        breakHotkey.register(breakShortcut)
        session.begin()
    }

    private func connectTasks(of session: ScoutingSession) {
        session.onSnippetClosed = { [weak self, weak session] snippet, immediate in
            guard let self, let session else { return }
            session.adopt(dispatcher.accept(snippet, from: session, sendImmediately: immediate))
        }
        session.onSnippetDiscarded = { [weak self, weak session] snippetID in
            guard let self, let card = session?.cards.first(where: { $0.snippet.id == snippetID }), !card.isLocked else { return nil }
            dispatcher.withdraw(card)
            return card
        }
    }

    func stopScouting() {
        guard isScouting, let session else { return }
        isScouting = false
        breakHotkey?.unregister()
        hud.hidePill()
        if let walkthrough = session.walkthrough {
            Task { await finishWalkthrough(walkthrough, of: session, pressedAt: ContinuousClock.now) }
            return
        }
        Task {
            await session.end()
            let review = SessionReview(session: session, dispatcher: dispatcher)
            guard !review.tasks.isEmpty || !review.leftoverSpeech.isEmpty else {
                stackChanged()
                return
            }
            reviews[session.id] = review
            latestSessionID = session.id
            if let first = review.tasks.first { review.select(first) }
            review.save()
            if !isScouting {
                if shouldOpenReview(review) {
                    show(review)
                } else {
                    if self.review == nil { self.review = review }
                    stackChanged()
                }
            }
            await session.exportVideo()
            review.videoFinished()
            removeSegments(of: session)
        }
    }

    private func finishWalkthrough(_ walkthrough: WalkthroughRecorder, of session: ScoutingSession, pressedAt: ContinuousClock.Instant) async {
        await session.end()
        let ended = ContinuousClock.now
        do {
            let outcome = try await walkthrough.finish(at: session.ledger.end, sources: walkthroughSources(of: session, recorder: walkthrough))
            WalkthroughPasteboard.put(outcome.directory)
            var timings = outcome.timings.mapValues { $0 + (ended - pressedAt).seconds }
            timings["sessionEnded"] = (ended - pressedAt).seconds
            lastWalkthrough = FinishedWalkthrough(directory: outcome.directory, walkthrough: outcome.walkthrough, timings: timings)
            walkthroughProblem = nil
        } catch {
            walkthrough.discard()
            lastWalkthrough = nil
            walkthroughProblem = "The walkthrough couldn't be saved: \(error)"
        }
        stackChanged()
        let media = session.directory.appendingPathComponent("media", isDirectory: true)
        Task.detached(priority: .background) {
            try? await Task.sleep(for: .seconds(120))
            try? FileManager.default.removeItem(at: media)
        }
    }

    private func walkthroughSources(of session: ScoutingSession, recorder: WalkthroughRecorder) -> WalkthroughRecorder.Sources {
        let heard: Bool
        if case .failed = session.phase { heard = false } else { heard = true }
        let microphone = session.transcriber.inputFile != nil || permissions.state(of: .microphone).isGranted
        let screen: Walkthrough.Grant? = recorder.hasMedia || CGPreflightScreenCaptureAccess() ? .granted : (preferences.includeClips ? .denied : nil)
        return WalkthroughRecorder.Sources(
            screen: screen,
            microphone: microphone ? .granted : .denied,
            accessibility: AXIsProcessTrusted() ? .granted : .denied,
            transcript: heard ? .ready : .unavailable,
            language: session.transcriber.localeIdentifier,
            failed: session.captureProblem != nil && preferences.includeClips
        )
    }

    func copyLastWalkthrough() {
        guard let lastWalkthrough else { return }
        WalkthroughPasteboard.put(lastWalkthrough.directory)
    }

    func revealLastWalkthrough() {
        guard let lastWalkthrough else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastWalkthrough.directory])
    }

    private func shouldOpenReview(_ review: SessionReview) -> Bool {
        switch preferences.reviewOpening {
        case .always: return !review.tasks.isEmpty || !review.leftoverSpeech.isEmpty
        case .never: return false
        case .whenNeeded: return review.needsAttention
        }
    }

    private func show(_ review: SessionReview) {
        if let current = self.review, current !== review { current.save() }
        self.review = review
        hud.hideAll()
        openReviewWindow?()
    }

    private func removeSegments(of session: ScoutingSession) {
        guard session.video != nil else { return }
        let media = session.directory.appendingPathComponent("media", isDirectory: true)
        Task.detached(priority: .background) {
            try? await Task.sleep(for: .seconds(120))
            try? FileManager.default.removeItem(at: media)
        }
    }

    func openLatestReview() {
        if let latestSessionID, let cached = reviews[latestSessionID] {
            show(cached)
        } else if let latest = SessionLibrary.recent(limit: 1).first {
            openReview(latest)
        } else {
            openReviewWindow?()
        }
    }

    func openReview(_ summary: SessionSummary) {
        if let cached = reviews[summary.id] {
            show(cached)
            return
        }
        let directory = summary.directory
        Task {
            let loaded = await Task.detached(priority: .userInitiated) { () -> (ReviewRecord, SessionLedger)? in
                guard let record = ReviewRecord.read(from: directory) else { return nil }
                return (record, SessionLibrary.ledger(in: directory))
            }.value
            guard let (record, ledger) = loaded else { return }
            let video = record.video.map { ExportedClip(url: directory.appendingPathComponent($0.file), range: TimeRange(start: $0.start, end: $0.end)) }
            let cards = record.tasks.map { task -> SnippetCard in
                let card = SnippetCard(snippet: ledger.snippet(id: task.id, range: TimeRange(start: task.start, end: task.end)), sessionID: record.sessionID, sessionDirectory: directory)
                card.restoreTitle(task.title, custom: task.titleIsCustom)
                card.transcriptOverride = task.transcriptOverride
                card.excludedTargetIDs = Set(task.excludedTargetIDs)
                card.runtimeNotes = task.runtimeNotes ?? []
                card.project = task.project
                card.sessionVideo = video
                card.sessionDisplay = record.display
                card.holdRequested = true
                if let destination = task.destination {
                    card.destination = destination
                    card.destinationChosenByUser = task.destinationChosenByUser ?? true
                }
                if let sentTo = task.sentTo {
                    card.state = .sent(sentTo)
                } else {
                    card.state = card.destination == nil ? .needsDestination : .held
                    dispatcher.prepare(card)
                }
                return card
            }
            let review = SessionReview(directory: directory, record: record, ledger: ledger, cards: cards, dispatcher: dispatcher)
            if let first = review.tasks.first { review.select(first) }
            reviews[record.sessionID] = review
            show(review)
        }
    }

    func sendAll(in review: SessionReview) async {
        for card in review.tasks where !card.isLocked && card.destination != nil {
            await dispatcher.send(card)
        }
        review.save()
    }

    func windowOpened() {
        openWindows += 1
        guard !SimulationMode.isRunning else { return }
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

enum SessionResult {
    case walkthrough
    case tasks
}

struct FinishedWalkthrough {
    let directory: URL
    let walkthrough: Walkthrough
    let timings: [String: Double]
}
