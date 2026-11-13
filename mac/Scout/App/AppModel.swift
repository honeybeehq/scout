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
    let apiary = ApiaryBridge()
    let picker = TargetPickerController()
    private(set) var lastDelivery: DeliveryOutcome?
    private(set) var lastDeliveryLine: String?
    private(set) var boundTarget: ApiaryTarget?
    private(set) var pickerTimings: [String: Double] = [:]
    @ObservationIgnored private var finishPressedAt: ContinuousClock.Instant?
    let preferences = Preferences()
    let linear: LinearAccount
    private(set) var session: ScoutingSession?
    private(set) var lastWalkthrough: FinishedWalkthrough?
    private(set) var walkthroughProblem: String?
    private(set) var review: SessionReview?
    private var reviews: [String: SessionReview] = [:]
    private var latestSessionID: String?
    @ObservationIgnored private var opensOnceSettled: Set<String> = []
    var openOnboarding: (() -> Void)?
    var openSettingsWindow: (() -> Void)?
    var openReviewWindow: (() -> Void)?
    let breakShortcut = KeyShortcut.nextTask
    private var breakHotkey: GlobalHotkey?
    let widenShortcut = KeyShortcut.widenCapture
    let followShortcut = KeyShortcut.followPointer
    private(set) var scopeHotkeys: (widen: GlobalHotkey, follow: GlobalHotkey)?
    let discardShortcut = KeyShortcut.discardRecording
    private(set) var discardHotkeys: (discard: GlobalHotkey, cancel: GlobalHotkey)?
    private var openWindows = 0

    private(set) var shortcut: KeyShortcut
    private(set) var shortcutRegistered = false
    private(set) var isScouting = false
    var confirmingDiscard = false {
        didSet {
            guard confirmingDiscard != oldValue else { return }
            if confirmingDiscard { discardHotkeys?.cancel.register(.escape) } else { discardHotkeys?.cancel.unregister() }
        }
    }

    var canDiscardScouting: Bool {
        session?.cards.contains { $0.isLocked } != true
    }

    private var hotkey: GlobalHotkey?

    static var rendersOnly: Bool {
        PanelGallery.directory != nil || ReviewGallery.directory != nil
    }

    private static let shortcutKey = "shortcut.startScouting"

    init() {
        let integrations = Integrations()
        self.integrations = integrations
        linear = SnapshotMode.makeLinearAccount()
        dispatcher = Dispatcher(integrations: integrations, bridge: bridge, preferences: preferences)
        if let data = UserDefaults.standard.data(forKey: Self.shortcutKey),
           let saved = try? JSONDecoder().decode(KeyShortcut.self, from: data) {
            shortcut = saved
        } else {
            shortcut = .startScouting
        }
        if let directory = PanelGallery.directory {
            Task { await PanelGallery.run(model: self, into: directory) }
            return
        }
        let hotkey = GlobalHotkey { [weak self] in self?.toggleScouting(input: GlobalHotkey.lastPressTime) }
        self.hotkey = hotkey
        shortcutRegistered = Self.rendersOnly ? false : hotkey.register(shortcut)
        dispatcher.dryRun = SimulationMode.isDryRun
        dispatcher.onCardChanged = { [weak self] card in self?.cardChanged(card) }
        if !Self.rendersOnly { bridge.start() }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            hud.prepare(model: self)
            picker.prepare()
        }
        picker.model.onChoose = { [weak self] target, mode in self?.choose(target, mode: mode) }
        picker.model.onDismiss = { [weak self] in self?.dismissPicker() }
        ScoutAppDelegate.onRecord = { [weak self] request in self?.record(request) }
        if !Self.rendersOnly {
            Task.detached(priority: .background) {
                ScoutPaths.prune()
                WalkthroughBundle.sweepPartials()
            }
        }
        if let pane = SettingsView.requestedPane, let directory = SnapshotMode.directory {
            Task { await SnapshotMode.captureSettings(model: self, into: directory, pane: pane) }
        }
        if let directory = ReviewGallery.directory {
            Task { await ReviewGallery.run(model: self, into: directory) }
        }
        if let directory = SimulationMode.deliveryCheck {
            Task { await SimulationMode.runDeliveryCheck(model: self, directory: directory) }
        }
        if let output = SimulationMode.openSettingsOutput {
            SimulationMode.listenForOpenSettings(output: output)
        }
        if SimulationMode.reopensLatest {
            Task { await SimulationMode.reopenLatest(model: self) }
        }
        if let output = CaptureUXDemo.outputDirectory {
            Task { await CaptureUXDemo.run(model: self, output: output) }
        }
        if let output = ExpandKeyCheck.outputDirectory {
            Task { await ExpandKeyCheck.run(model: self, output: output) }
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

    var simulatedInput: URL?
    var onSessionCreated: ((ScoutingSession) -> Void)?

    func triggerHotkey(at time: TimeInterval) {
        hotkey?.press(at: time)
    }

    func toggleScouting(input: TimeInterval = InteractionTimings.now) {
        isScouting ? finishScouting(input: input) : startScouting(inputFile: simulatedInput, input: input)
    }

    func finishScouting(input: TimeInterval) {
        guard isScouting else { return }
        let timings = InteractionTimings.shared
        timings.measure("finish→pill-hidden", from: input)
        stopScouting { timings.mark("finish→handoff", from: input) }
    }

    func record(_ request: RecordRequest) {
        if isScouting {
            if session?.walkthrough != nil { boundTarget = request.target } else { NSSound.beep() }
            return
        }
        startScouting(inputFile: simulatedInput, input: InteractionTimings.now, target: request.target)
    }

    func startSplitTasks() {
        startScouting(result: .tasks)
    }

    func startScouting(inputFile: URL? = nil, segmentation: Segmentation? = nil, result: SessionResult = .walkthrough, input: TimeInterval = InteractionTimings.now, target: ApiaryTarget? = nil, onInputFinished: (() -> Void)? = nil) {
        guard !isScouting else { return }
        guard inputFile != nil || permissions.state(of: .microphone).isGranted else {
            onboarding.go(to: .access)
            openOnboarding?()
            return
        }
        let timings = InteractionTimings.shared
        hud.showPill(model: self)
        timings.measure("hotkey→pill", from: input, committed: InteractionTimings.now)
        let session = ScoutingSession(
            bridge: bridge,
            recordsScreen: preferences.includeClips && SimulationMode.fixtureVideo == nil,
            segmentation: segmentation ?? preferences.segmentation,
            producesWalkthrough: result == .walkthrough,
            apiary: apiary
        )
        session.transcriber.inputFile = inputFile
        if let scenario = SimulationMode.microphoneScenario, let inputFile {
            let transcriber = session.transcriber
            if let route = try? SimulatedRoute(scenario: scenario, audio: inputFile, onFinish: { Task { @MainActor in transcriber.onInputFinished?() } }) {
                transcriber.microphone = MicrophoneCapture(simulated: true, device: route.makeDevice)
                transcriber.inputFile = nil
            }
        }
        session.transcriber.faultAfter = SimulationMode.analyzerFaultAfter
        if SimulationMode.secondPassFails { session.transcriptionEngine = FailingTranscriptionEngine() }
        session.transcriber.onInputFinished = onInputFinished
        if result == .tasks { connectTasks(of: session) }
        onSessionCreated?(session)
        self.session = session
        isScouting = true
        boundTarget = result == .walkthrough ? target : nil
        timings.begin(logging: session.directory.appendingPathComponent("timings.jsonl"))
        session.presentScope = { [weak session] change, changeInput in
            guard let session else { return }
            if session.capture.scopes.count == 1 {
                timings.measure("hotkey→recording", from: input, detail: "pill and capture frame on screen")
            } else {
                let name = change.byUser ? "expand" : change.refined ? "refine" : "follow"
                timings.measure(name, from: changeInput, detail: "\(change.scope.rawValue) \(change.region ?? "")")
            }
        }
        session.aim.measure = { name, input in timings.measure(name, from: input) }
        session.onFirstFrame = { time in timings.mark("hotkey→first-frame", from: input, at: time) }
        hud.attach(session, model: self)
        let breakHotkey = breakHotkey ?? GlobalHotkey { [weak self] in self?.session?.splitNow() }
        self.breakHotkey = breakHotkey
        breakHotkey.register(breakShortcut)
        let scopeHotkeys = scopeHotkeys ?? (
            widen: GlobalHotkey { [weak self] in self?.session?.follower.expand(input: GlobalHotkey.lastPressTime) },
            follow: GlobalHotkey { [weak self] in self?.session?.follower.follow(input: GlobalHotkey.lastPressTime) }
        )
        self.scopeHotkeys = scopeHotkeys
        scopeHotkeys.widen.register(widenShortcut)
        scopeHotkeys.follow.register(followShortcut)
        let discardHotkeys = discardHotkeys ?? (
            discard: GlobalHotkey { [weak self] in self?.pressDiscard() },
            cancel: GlobalHotkey { [weak self] in self?.confirmingDiscard = false }
        )
        self.discardHotkeys = discardHotkeys
        discardHotkeys.discard.register(discardShortcut)
        session.begin()
        if result == .walkthrough, boundTarget == nil {
            Task { await prefetchTargets() }
        }
    }

    @ObservationIgnored private var prefetched = TargetDirectory(targets: [], source: .loading)

    private func prefetchTargets() async {
        prefetched = TargetDirectory(targets: [], source: .loading)
        prefetched = await TargetDirectory.load(apiary: apiary, hive: integrations.hiveClient)
    }

    private func connectTasks(of session: ScoutingSession) {
        session.onSnippetClosed = { [weak self, weak session] snippet, immediate in
            guard let self, let session else { return }
            session.adopt(dispatcher.accept(snippet, from: session, sendImmediately: immediate))
        }
        session.refineCard = { [weak self] card, snippet in
            self?.dispatcher.refine(card, to: snippet)
        }
        session.onSnippetDiscarded = { [weak self, weak session] snippetID in
            guard let self, let card = session?.cards.first(where: { $0.snippet.id == snippetID }), !card.isLocked else { return nil }
            dispatcher.withdraw(card)
            return card
        }
    }

    private func endScoutingControls() {
        isScouting = false
        confirmingDiscard = false
        breakHotkey?.unregister()
        scopeHotkeys?.widen.unregister()
        scopeHotkeys?.follow.unregister()
        discardHotkeys?.discard.unregister()
        hud.hidePill()
    }

    func pressDiscard() {
        guard isScouting else { return }
        guard canDiscardScouting else {
            NSSound.beep()
            return
        }
        if confirmingDiscard {
            Task { await discardScouting() }
        } else {
            confirmingDiscard = true
        }
    }

    func discardScouting() async {
        guard isScouting, canDiscardScouting, let session else { return }
        endScoutingControls()
        boundTarget = nil
        session.onSnippetClosed = nil
        for card in dispatcher.cards where card.sessionID == session.id {
            dispatcher.withdraw(card)
        }
        stackChanged()
        await session.end(refiningTranscript: false)
        session.walkthrough?.discard()
        Self.removeSessionFiles(at: session.directory)
    }

    func discard(_ review: SessionReview) {
        guard review.canDiscard else { return }
        for card in review.tasks {
            dispatcher.withdraw(card)
        }
        reviews[review.sessionID] = nil
        if latestSessionID == review.sessionID { latestSessionID = nil }
        if self.review === review { self.review = nil }
        Self.removeSessionFiles(at: review.directory)
        stackChanged()
    }

    private static func removeSessionFiles(at directory: URL) {
        let manager = FileManager.default
        try? manager.removeItem(at: directory)
        let day = directory.deletingLastPathComponent()
        if (try? manager.contentsOfDirectory(atPath: day.path))?.isEmpty == true {
            try? manager.removeItem(at: day)
        }
    }

    func stopScouting(handedOff: (() -> Void)? = nil) {
        guard isScouting, let session else { return }
        endScoutingControls()
        if let walkthrough = session.walkthrough {
            let pressed = ContinuousClock.now
            if let target = boundTarget {
                boundTarget = nil
                openBound(target, expecting: walkthrough.bundle.id, pressedAt: pressed)
            } else {
                openPicker(for: nil, expecting: walkthrough.bundle.id, pressedAt: pressed)
            }
            Task { await finishWalkthrough(walkthrough, of: session, pressedAt: pressed, handedOff: handedOff) }
            return
        }
        Task {
            await session.end()
            let review = SessionReview(session: session, dispatcher: dispatcher)
            guard !review.tasks.isEmpty || !review.leftoverSpeech.isEmpty else {
                handedOff?()
                stackChanged()
                return
            }
            reviews[session.id] = review
            latestSessionID = session.id
            handedOff?()
            if let first = review.tasks.first { review.select(first) }
            review.save()
            if !isScouting {
                if shouldOpenReview(review) {
                    show(review)
                } else {
                    if review.isPreparing { opensOnceSettled.insert(review.sessionID) }
                    if self.review == nil { self.review = review }
                    stackChanged()
                }
            }
            await session.exportVideo()
            review.videoFinished()
            removeSegments(of: session)
        }
    }

    private func finishWalkthrough(_ walkthrough: WalkthroughRecorder, of session: ScoutingSession, pressedAt: ContinuousClock.Instant, handedOff: (() -> Void)? = nil) async {
        await session.end()
        let ended = ContinuousClock.now
        do {
            let outcome = try await walkthrough.finish(at: session.ledger.end, sources: walkthroughSources(of: session, recorder: walkthrough))
            WalkthroughPasteboard.put(outcome.directory)
            var timings = outcome.timings.mapValues { $0 + (ended - pressedAt).seconds }
            timings["sessionEnded"] = (ended - pressedAt).seconds
            let finished = FinishedWalkthrough(directory: outcome.directory, walkthrough: outcome.walkthrough, timings: timings)
            lastWalkthrough = finished
            walkthroughProblem = nil
            handedOff?()
            walkthroughReady(finished)
        } catch {
            walkthrough.discard()
            lastWalkthrough = nil
            walkthroughProblem = "The walkthrough couldn't be saved: \(error)"
            if pickerWalkthroughID == walkthrough.bundle.id {
                picker.model.failed("The walkthrough couldn't be saved.")
                if picker.model.isBound {
                    lastDeliveryLine = "The walkthrough couldn't be saved, so nothing was added to the review."
                    picker.model.confirm(lastDeliveryLine ?? "", caution: true)
                    picker.close(after: .seconds(4))
                }
            }
        }
        stackChanged()
        let media = session.directory.appendingPathComponent("media", isDirectory: true)
        Task.detached(priority: .background) {
            try? FileManager.default.removeItem(at: media)
        }
    }

    private func walkthroughSources(of session: ScoutingSession, recorder: WalkthroughRecorder) -> WalkthroughRecorder.Sources {
        let transcriber = session.transcriber
        let microphone = transcriber.microphoneSummary
        let failure: Walkthrough.TranscriptFailure?
        if case .refined = session.transcriptPass, !session.ledger.utterances.isEmpty {
            failure = nil
        } else if let failed = transcriber.failure, let reason = failed.microphone, let microphone {
            failure = microphone.buffers == 0
                ? Walkthrough.TranscriptFailure(reason: .noAudio, message: reason)
                : Walkthrough.TranscriptFailure(reason: .micStopped, message: reason, t: failed.at.map(Walkthrough.milliseconds))
        } else if let failed = transcriber.failure {
            failure = Walkthrough.TranscriptFailure(reason: .analyzerFailed, message: failed.message, t: failed.at.map(Walkthrough.milliseconds))
        } else if let microphone, microphone.buffers == 0 {
            failure = Walkthrough.TranscriptFailure(reason: .noAudio, message: "\(microphone.device ?? "the microphone") sent no audio")
        } else if session.ledger.utterances.isEmpty, transcriber.heardSound {
            failure = Walkthrough.TranscriptFailure(reason: .noWords)
        } else {
            failure = nil
        }
        let granted = session.transcriber.inputFile != nil || session.transcriber.microphone.isSimulated || permissions.state(of: .microphone).isGranted
        let screen: Walkthrough.Grant? = recorder.hasMedia || CGPreflightScreenCaptureAccess() ? .granted : (preferences.includeClips ? .denied : nil)
        return WalkthroughRecorder.Sources(
            screen: screen,
            microphone: granted ? .granted : .denied,
            accessibility: AXIsProcessTrusted() ? .granted : .denied,
            transcript: failure == nil ? .ready : .unavailable,
            transcriptFailure: failure,
            language: transcriber.localeIdentifier,
            failed: session.captureProblem != nil && preferences.includeClips,
            microphoneSummary: microphone.map {
                Walkthrough.Microphone(device: $0.device, sampleRate: $0.sampleRate, channels: $0.channels, buffers: $0.buffers, peakDb: $0.peakDecibels, restarts: $0.restarts, retries: $0.retries, channelMode: $0.channelMode, channelSwitches: ($0.channels ?? 1) > 1 ? $0.channelSwitches : nil, droppedBuffers: $0.droppedBuffers > 0 ? $0.droppedBuffers : nil, unlearnedClasses: $0.unlearnedClasses > 0 ? $0.unlearnedClasses : nil)
            }
        )
    }

    func sendLastWalkthrough() {
        guard let lastWalkthrough, !isScouting else { return }
        openPicker(for: lastWalkthrough, expecting: lastWalkthrough.walkthrough.id, pressedAt: .now)
    }

    @ObservationIgnored private var pickerWalkthroughID: String?

    private func openPicker(for finished: FinishedWalkthrough?, expecting walkthroughID: String, pressedAt: ContinuousClock.Instant) {
        pickerWalkthroughID = walkthroughID
        chosen = nil
        finishPressedAt = pressedAt
        pickerTimings = ["finishEpochMs": (Date().timeIntervalSince1970 * 1000).rounded() - ApiaryBridge.milliseconds(.now - pressedAt)]
        picker.model.reset(with: finished)
        if !prefetched.targets.isEmpty { picker.model.setTargets(prefetched.targets, source: prefetched.source) }
        picker.open(near: NSEvent.mouseLocation)
        pickerTimings["pickerShown"] = ApiaryBridge.milliseconds(.now - pressedAt)
        if !prefetched.targets.isEmpty { pickerTimings["targetsListed"] = pickerTimings["pickerShown"] }
        DispatchQueue.main.async { [weak self] in
            self?.pickerTimings["pickerPainted"] = ApiaryBridge.milliseconds(.now - pressedAt)
        }
        Task { await loadTargets(pressedAt: pressedAt) }
    }

    private func openBound(_ target: ApiaryTarget, expecting walkthroughID: String, pressedAt: ContinuousClock.Instant) {
        pickerWalkthroughID = walkthroughID
        chosen = (target, .paste, pressedAt)
        finishPressedAt = pressedAt
        lastDeliveryLine = nil
        pickerTimings = ["finishEpochMs": (Date().timeIntervalSince1970 * 1000).rounded() - ApiaryBridge.milliseconds(.now - pressedAt)]
        picker.model.reset()
        picker.model.bind(target, saying: "Adding to the proof review…")
        picker.open(near: NSEvent.mouseLocation, takingKeys: false)
        picker.compact()
        pickerTimings["pickerShown"] = ApiaryBridge.milliseconds(.now - pressedAt)
    }

    func loadTargets(pressedAt: ContinuousClock.Instant) async {
        let result = await TargetDirectory.load(apiary: apiary, hive: integrations.hiveClient)
        picker.model.setTargets(result.targets, source: result.source)
        pickerTimings["targetsRefreshed"] = ApiaryBridge.milliseconds(.now - pressedAt)
        if pickerTimings["targetsListed"] == nil { pickerTimings["targetsListed"] = pickerTimings["targetsRefreshed"] }
    }

    @ObservationIgnored private var chosen: (target: ApiaryTarget, mode: DeliveryMode, at: ContinuousClock.Instant)?

    private func choose(_ target: ApiaryTarget, mode: DeliveryMode) {
        chosen = (target, mode, .now)
        if let finishPressedAt { pickerTimings["finishToChoice"] = ApiaryBridge.milliseconds(.now - finishPressedAt) }
        guard let finished = picker.model.walkthrough else { return }
        deliver(finished, to: target, mode: mode)
    }

    private func walkthroughReady(_ finished: FinishedWalkthrough) {
        guard picker.isOpen, picker.model.confirmation == nil, pickerWalkthroughID == finished.walkthrough.id else { return }
        picker.model.ready(finished)
        if let chosen, picker.model.queued != nil {
            deliver(finished, to: chosen.target, mode: chosen.mode)
        }
    }

    private func deliver(_ finished: FinishedWalkthrough, to target: ApiaryTarget, mode: DeliveryMode) {
        let model = picker.model
        model.began()
        let viaApiary = model.source == .apiary && target.viaApiary
        let bound = model.isBound
        let delivery = WalkthroughDelivery(apiary: apiary, hive: integrations.hiveClient)
        let started = ContinuousClock.now
        pickerTimings["deliverStartEpochMs"] = (Date().timeIntervalSince1970 * 1000).rounded()
        Task {
            do {
                let outcome = try await delivery.deliver(bundle: finished.directory, walkthrough: finished.walkthrough.id, to: target, mode: mode, viaApiary: viaApiary)
                lastDelivery = outcome
                pickerTimings["deliverRoundTrip"] = ApiaryBridge.milliseconds(.now - started)
                if let chosenAt = chosen?.at { pickerTimings["chooseToDelivered"] = ApiaryBridge.milliseconds(.now - chosenAt) }
                if let finishPressedAt { pickerTimings["finishToDelivered"] = ApiaryBridge.milliseconds(.now - finishPressedAt) }
                chosen = nil
                if bound {
                    let line = Self.boundLine(outcome)
                    lastDeliveryLine = line
                    model.confirm(line, caution: outcome.route != .apiary)
                    picker.close(after: outcome.route == .apiary ? .milliseconds(1400) : .seconds(4))
                    return
                }
                model.confirm(outcome.confirmation)
                picker.compact()
                picker.close(after: .milliseconds(1400))
            } catch {
                if bound {
                    chosen = nil
                    let line = "On the clipboard: \(Self.boundReason(error))."
                    lastDeliveryLine = line
                    model.confirm(line, caution: true)
                    picker.close(after: .seconds(4))
                    return
                }
                model.refuse(error.localizedDescription)
                if (error as? WalkthroughDelivery.Failure)?.code == "targetGone", let finishPressedAt {
                    await loadTargets(pressedAt: finishPressedAt)
                }
            }
        }
    }

    private static func boundLine(_ outcome: DeliveryOutcome) -> String {
        switch outcome.route {
        case .apiary:
            return "In the review: \(outcome.title)"
        case .hive, .clipboard:
            let reason = switch outcome.fallbackReason {
            case "absent": "Apiary isn't running"
            case "noRenderer": "no Apiary window is open"
            default: "Apiary didn't answer in time"
            }
            return "On the clipboard: \(reason)."
        }
    }

    private static func boundReason(_ error: Error) -> String {
        let message = (error as? WalkthroughDelivery.Failure)?.message ?? error.localizedDescription
        let trimmed = message.trimmingCharacters(in: CharacterSet(charactersIn: ". \n"))
        switch (error as? WalkthroughDelivery.Failure)?.code {
        case "targetGone": return "the proof was decided or is gone"
        case "badRequest": return "Apiary refused it (\(trimmed))"
        default: return trimmed
        }
    }

    private func dismissPicker() {
        guard !picker.model.delivering else { return }
        chosen = nil
        picker.model.confirm("On the clipboard")
        picker.compact()
        picker.close(after: .milliseconds(700))
    }

    func copyLastWalkthrough() {
        guard let lastWalkthrough else { return }
        WalkthroughPasteboard.put(lastWalkthrough.directory)
    }

    func revealLastWalkthrough() {
        guard let lastWalkthrough else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastWalkthrough.directory])
    }

    private func cardChanged(_ card: SnippetCard) {
        guard let review = reviews[card.sessionID] else { return }
        review.cardChanged(card)
        guard !review.isPreparing, opensOnceSettled.remove(review.sessionID) != nil else { return }
        if !isScouting, shouldOpenReview(review) { show(review) }
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
        let directory = session.directory
        Task.detached(priority: .background) {
            await ScoutPaths.removeFinishedMedia(of: directory)
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
                card.sessionDisplays = record.displays
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
