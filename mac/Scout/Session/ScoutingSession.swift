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

    private(set) var phase: Phase = .starting
    private(set) var openSnippet: Snippet?
    private(set) var closedCount = 0
    private(set) var hoverTarget: Target?
    private(set) var context: AppContext?
    private(set) var elapsed: TimeInterval = 0

    var onSnippetClosed: ((Snippet, _ sendImmediately: Bool) -> Void)?

    private var segmenter: Segmenter
    private let log: SignalLog
    private var contextTracker: ContextTracker?
    private var pointerTracker: PointerTracker?
    private var ticker: Task<Void, Never>?
    private var sendNextClosedImmediately = false

    private static let idFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    init() {
        let started = Date()
        let id = "session-" + Self.idFormatter.string(from: started)
        self.id = id
        directory = ScoutPaths.newSessionDirectory(id: id, at: started)
        log = SignalLog(url: directory.appendingPathComponent("signals.jsonl"))
        segmenter = Segmenter(idPrefix: "snippet-")
        transcriber = LiveTranscriber(clock: clock)
    }

    func start() async {
        transcriber.onUtterance = { [weak self] utterance in self?.hear(utterance) }

        let contextTracker = ContextTracker(clock: clock) { [weak self] change in
            Task { @MainActor in self?.ingest(.context(change)) }
        }
        let pointerTracker = PointerTracker(
            clock: clock,
            onFocus: { [weak self] focus in
                Task { @MainActor in self?.ingest(.focus(focus)) }
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

        await transcriber.start()
        if case .failed(let message) = transcriber.phase {
            phase = .failed(message)
        } else {
            phase = .live
        }
    }

    func stop() async {
        guard phase == .live || phase == .starting else { return }
        ticker?.cancel()
        contextTracker?.stop()
        pointerTracker?.stop()
        await transcriber.stop()
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
