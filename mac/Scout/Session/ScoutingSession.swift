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

    var onSnippetClosed: ((Snippet, _ sendImmediately: Bool) -> Void)?
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
    private let bridge: BridgeServer
    private var webDwell: (target: Target, since: SessionTime)?

    private static let idFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private let recordsScreen: Bool

    init(bridge: BridgeServer, recordsScreen: Bool) {
        self.bridge = bridge
        self.recordsScreen = recordsScreen
        let started = Date()
        let id = "session-" + Self.idFormatter.string(from: started)
        self.id = id
        directory = ScoutPaths.newSessionDirectory(id: id, at: started)
        log = SignalLog(url: directory.appendingPathComponent("signals.jsonl"))
        segmenter = Segmenter(idPrefix: "snippet-")
        transcriber = LiveTranscriber(clock: clock)
        aim = AimController(clock: clock)
    }

    func start() async {
        transcriber.onUtterance = { [weak self] utterance in self?.hear(utterance) }
        aim.onPin = { [weak self] mark in self?.ingest(.mark(mark)) }
        aim.onAimChanged = { [weak self] active in self?.bridge.setAim(active: active) }
        aim.enrich = { [weak self] mark, date in
            guard let self, let (client, element) = await self.bridge.requestPin(id: mark.id, at: date) else { return nil }
            return element.target(clientID: client.id)
        }
        aim.start()
        bridge.onHover = { [weak self] client, element, date in self?.webHover(element.target(clientID: client.id), at: date) }
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
        if case .failed(let message) = transcriber.phase {
            phase = .failed(message)
        } else {
            phase = .live
        }
    }

    func stop() async {
        guard phase == .live || phase == .starting else { return }
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
        handle(segmenter.finish(at: end))
        log.close()
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
        recorder.onFrameDifference = { [weak self] at, magnitude in
            guard magnitude >= 0.05 else { return }
            Task { @MainActor in self?.ingest(.visualChange(VisualChange(at: at, magnitude: magnitude))) }
        }
        recorder.onError = { [weak self] error in
            Task { @MainActor in self?.captureProblem = error.localizedDescription }
        }
        do {
            try await recorder.start(sessionStart: clock.originDate)
            self.recorder = recorder
        } catch {
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
            discardCurrent()
        case .send(let remainder):
            if !remainder.isEmpty {
                var trimmed = utterance
                trimmed.text = remainder
                ingest(.utterance(trimmed))
            }
            sendNextClosedImmediately = true
            ingest(.command(CommandSignal(at: utterance.range.end, command: .split)))
        case nil:
            ingest(.utterance(utterance))
        }
    }

    private func ingest(_ signal: Signal) {
        log.append(signal)
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
                if openSnippet?.id == id { openSnippet = nil }
            }
        }
    }
}

enum VoiceCommand: Equatable {
    case discard
    case send(remainder: String)

    static func match(_ text: String) -> VoiceCommand? {
        let normalized = text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        for phrase in ["scratch that", "never mind", "nevermind"] where normalized == phrase || normalized.hasSuffix(" " + phrase) {
            return .discard
        }
        for phrase in ["send it", "send that", "ship it"] where normalized == phrase || normalized.hasSuffix(" " + phrase) {
            guard let range = text.range(of: phrase, options: [.caseInsensitive, .backwards]) else { continue }
            let remainder = text[..<range.lowerBound].trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
            return .send(remainder: remainder)
        }
        return nil
    }
}
