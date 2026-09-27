import CoreGraphics
import Foundation
import Observation
import ScoutCore
import ScoutSegmenter

@Observable
final class ScoutingSession {
    enum Phase: Equatable {
        case starting
        case live
        case ended
        case failed(String)
    }

    let id: String
    let clock = SessionClock()
    let directory: URL
    let transcriber: LiveTranscriber
    let aim: AimController

    private(set) var phase: Phase = .starting
    private(set) var openSnippet: Snippet?
    private(set) var closedCount = 0
    private(set) var hoverTarget: Target?
    private(set) var context: AppContext?
    private(set) var elapsed: TimeInterval = 0
    private(set) var recorder: SegmentedScreenRecorder?
    private(set) var captureProblem: String?
    private(set) var ledger = SessionLedger()
    private(set) var video: ExportedClip?
    let segmentation: Segmentation

    var onSnippetClosed: ((Snippet, _ sendImmediately: Bool) -> Void)?
    var onSnippetDiscarded: ((String) -> Void)?
    private(set) var runtimeEvents: [RuntimeEvent] = []

    struct RuntimeEvent {
        var at: SessionTime
        var source: String
        var signal: BridgeSignalMessage
    }

    private var segmenter: Segmenter
    private let log: SignalLog
    private var contextTracker: ContextTracker?
    private var pointerTracker: PointerTracker?
    private var ticker: Task<Void, Never>?
    private var sendNextClosedImmediately = false
    private var startTask: Task<Void, Never>?
    private var stopRequested = false
    private let bridge: BridgeServer
    private var webDwell: (target: Target, since: SessionTime)?

    private static let idFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private let recordsScreen: Bool

    var startedAt: Date { clock.originDate }

    init(bridge: BridgeServer, recordsScreen: Bool, segmentation: Segmentation) {
        self.bridge = bridge
        self.recordsScreen = recordsScreen
        self.segmentation = segmentation
        let started = Date()
        let id = "session-" + Self.idFormatter.string(from: started) + "-" + UUID().uuidString.prefix(4).lowercased()
        self.id = id
        directory = ScoutPaths.newSessionDirectory(id: id, at: started)
        log = SignalLog(url: directory.appendingPathComponent("signals.jsonl"))
        segmenter = Segmenter(configuration: segmentation == .manual ? .manual : .default, idPrefix: "snippet-")
        transcriber = LiveTranscriber(clock: clock)
        aim = AimController(clock: clock)
    }

    func begin() {
        guard startTask == nil else { return }
        startTask = Task { await start() }
    }

    func end() async {
        guard !stopRequested else { return }
        stopRequested = true
        await startTask?.value
        await teardown()
    }

    private func start() async {
        transcriber.onUtterance = { [weak self] utterance in self?.hear(utterance) }
        aim.onPin = { [weak self] mark in self?.ingest(.mark(mark)) }
        aim.onAimChanged = { [weak self] active in self?.bridge.setAim(active: active) }
        aim.enrich = { [weak self] mark, date in
            guard let self, let reply = await self.bridge.requestPin(id: mark.id, at: date) else { return nil }
            return reply.element.target(clientID: reply.client.id, viewport: reply.viewport)
        }
        aim.start()
        bridge.onHover = { [weak self] client, element, viewport, date in
            self?.webHover(element.target(clientID: client.id, viewport: viewport), at: date)
        }
        bridge.onSignal = { [weak self] client, signal in
            guard let self else { return }
            let at = signal.at.map { self.clock.seconds(at: Date(timeIntervalSince1970: $0 / 1000)) } ?? self.clock.now
            self.runtimeEvents.append(RuntimeEvent(at: at, source: client.name, signal: signal))
        }
        bridge.setSession(active: true)

        let contextTracker = ContextTracker(clock: clock) { [weak self] change in
            Task { @MainActor in self?.ingest(.context(change)) }
        }
        let pointerTracker = PointerTracker(
            clock: clock,
            onFocus: { [weak self] focus in
                Task { @MainActor in self?.accessibilityFocus(focus) }
            },
            onHover: { [weak self] target in
                Task { @MainActor in self?.hoverTarget = target }
            }
        )
        self.contextTracker = contextTracker
        self.pointerTracker = pointerTracker
        contextTracker.start()
        pointerTracker.start()

        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.elapsed = self.clock.now
                self.ingest(.clock(self.clock.now))
            }
        }

        async let screen: Void = startRecorder()
        await transcriber.start()
        await screen
        guard !stopRequested else { return }
        if case .failed(let message) = transcriber.phase {
            phase = .failed(message)
        } else {
            phase = .live
        }
    }

    private func teardown() async {
        ticker?.cancel()
        aim.stop()
        bridge.setSession(active: false)
        bridge.onHover = nil
        bridge.onSignal = nil
        closeWebDwell(at: clock.now)
        contextTracker?.stop()
        pointerTracker?.stop()
        await transcriber.stop()
        await recorder?.stop()
        let end = clock.now
        ledger.extend(to: end)
        handle(segmenter.finish(at: end))
        log.close()
        if let recorder {
            video = try? await recorder.exportClip(from: 0, to: end, padding: 0, into: directory.appendingPathComponent("session.mp4"))
        }
        phase = .ended
    }

    func splitNow() {
        ingest(.command(CommandSignal(at: clock.now, command: .split)))
    }

    func discardCurrent() {
        ingest(.command(CommandSignal(at: clock.now, command: .discardCurrent)))
    }

    private func startRecorder() async {
        guard recordsScreen else { return }
        guard CGPreflightScreenCaptureAccess() else {
            captureProblem = "Screen Recording is off, so tasks won't include clips."
            return
        }
        let recorder = SegmentedScreenRecorder(directory: directory)
        self.recorder = recorder
        recorder.onFrameDifference = { [weak self] at, magnitude in
            guard magnitude >= 0.05 else { return }
            Task { @MainActor in self?.ingest(.visualChange(VisualChange(at: at, magnitude: magnitude))) }
        }
        recorder.onError = { [weak self] error in
            Task { @MainActor in self?.captureProblem = error.localizedDescription }
        }
        do {
            try await recorder.start(sessionStart: clock.originDate)
        } catch {
            self.recorder = nil
            captureProblem = error.localizedDescription
        }
    }

    func runtimeEvents(around range: TimeRange) -> [RuntimeEvent] {
        runtimeEvents.filter { $0.at >= range.start - 3 && $0.at <= range.end + 1 }
    }

    private func accessibilityFocus(_ focus: Focus) {
        guard bridge.recentlyHovered(within: 1.0) == nil else { return }
        ingest(.focus(focus))
    }

    private func flushDwells(at now: SessionTime) {
        pointerTracker?.flushDwell()
        guard let dwell = webDwell else { return }
        closeWebDwell(at: now)
        webDwell = (dwell.target, now)
    }

    private func webHover(_ target: Target, at date: Date) {
        let at = clock.seconds(at: date)
        guard webDwell?.target.id != target.id else { return }
        closeWebDwell(at: at)
        webDwell = (target, at)
    }

    private func closeWebDwell(at end: SessionTime) {
        guard let dwell = webDwell else { return }
        webDwell = nil
        if end - dwell.since >= PointerTracker.dwellThreshold {
            ingest(.focus(Focus(range: TimeRange(start: dwell.since, end: end), target: dwell.target)))
        }
    }

    private func hear(_ utterance: Utterance) {
        switch VoiceCommand.match(utterance.text) {
        case .discard:
            ingest(.command(CommandSignal(at: utterance.range.end, command: .discardCurrent)))
        case .send:
            sendNextClosedImmediately = openSnippet != nil
            ingest(.command(CommandSignal(at: utterance.range.end, command: .split)))
        case nil:
            flushDwells(at: clock.now)
            ingest(.utterance(utterance))
        }
    }

    private func ingest(_ signal: Signal) {
        log.append(signal)
        ledger.record(signal)
        if case .context(let change) = signal { context = change.context }
        handle(segmenter.ingest(signal))
    }

    private func handle(_ events: [SegmenterEvent]) {
        for event in events {
            switch event {
            case .opened(let snippet), .updated(let snippet):
                openSnippet = snippet
            case .closed(let snippet):
                if openSnippet?.id == snippet.id { openSnippet = nil }
                closedCount += 1
                let immediate = sendNextClosedImmediately
                sendNextClosedImmediately = false
                onSnippetClosed?(snippet, immediate)
            case .discarded(let id):
                if openSnippet?.id == id {
                    openSnippet = nil
                } else {
                    onSnippetDiscarded?(id)
                }
            }
        }
    }
}

enum VoiceCommand: Equatable {
    case discard
    case send

    private static let leadingFillers: Set<String> = ["okay", "ok", "alright", "right", "so", "and", "um", "uh", "yeah", "actually", "no"]
    private static let commands: [String: VoiceCommand] = [
        "scratch that": .discard, "never mind": .discard, "nevermind": .discard, "forget that": .discard,
        "send it": .send, "send that": .send, "ship it": .send, "send it now": .send,
    ]

    static func match(_ text: String) -> VoiceCommand? {
        var words = text.lowercased()
            .split { !$0.isLetter && $0 != "'" }
            .map(String.init)
        while let first = words.first, words.count > 1, leadingFillers.contains(first) {
            words.removeFirst()
        }
        return commands[words.joined(separator: " ")]
    }
}
