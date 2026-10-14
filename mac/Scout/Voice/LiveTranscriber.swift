@preconcurrency import AVFoundation
import Observation
import ScoutCore
import Speech

@Observable
final class LiveTranscriber {
    enum Phase: Equatable {
        case idle
        case preparing(progress: Double)
        case listening
        case failed(String)
    }

    enum TranscriberError: LocalizedError {
        case unsupportedLanguage

        var errorDescription: String? {
            "Speech recognition isn't available for your language yet."
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var finalizedText = ""
    private(set) var volatileText = ""
    private(set) var level: Float = 0
    private(set) var inputName: String?
    private(set) var localeName: String?
    private(set) var localeIdentifier: String?
    private(set) var failure: (message: String, at: SessionTime?)?
    private(set) var soundedInputs = 0

    static let soundLevel: Float = 0.4
    static let soundedInputsForAudio = 5

    var heardSound: Bool { soundedInputs >= Self.soundedInputsForAudio }
    var faultAfter: Double?

    var onUtterance: ((Utterance) -> Void)?
    var inputFile: URL?
    var onInputFinished: (() -> Void)?

    private let clock: SessionClock?
    private let preset: SpeechTranscriber.Preset
    private let microphone = MicrophoneCapture()
    private let fileFeeder = AudioFileFeeder()
    private var utteranceCount = 0
    private var generation = 0
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    init(clock: SessionClock? = nil) {
        self.clock = clock
        preset = clock == nil ? .progressiveTranscription : .timeIndexedProgressiveTranscription
    }

    var wordCount: Int {
        (finalizedText + " " + volatileText).split(whereSeparator: \.isWhitespace).count
    }

    func start() async {
        switch phase {
        case .preparing, .listening: return
        case .idle, .failed: break
        }
        generation += 1
        let attempt = generation
        phase = .preparing(progress: 0)
        finalizedText = ""
        volatileText = ""
        failure = nil
        soundedInputs = 0
        inputName = microphone.inputName

        do {
            let transcriber = try await makeTranscriber()
            try await installAssetsIfNeeded(for: transcriber)
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            try await analyzer.prepareToAnalyze(in: format)
            guard attempt == generation else { return }

            let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
            inputContinuation = continuation
            self.analyzer = analyzer
            consumeResults(of: transcriber)

            let onBuffer = Self.feed(into: continuation, clock: clock, faultAfter: faultAfter)
            let onLevel: @Sendable (Float) -> Void = { [weak self] level in
                Task { @MainActor in
                    self?.level = level
                    if level >= Self.soundLevel { self?.soundedInputs += 1 }
                }
            }
            if let inputFile {
                try fileFeeder.start(url: inputFile, convertingTo: format, onBuffer: onBuffer, onLevel: onLevel) { [weak self] in
                    Task { @MainActor in self?.onInputFinished?() }
                }
            } else {
                try microphone.start(convertingTo: format, onBuffer: onBuffer, onLevel: onLevel)
            }
            try await analyzer.start(inputSequence: stream)
            guard attempt == generation else {
                await teardown()
                return
            }
            phase = .listening
        } catch {
            guard attempt == generation else { return }
            await teardown()
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        let message = error.localizedDescription
        phase = .failed(message)
        if failure == nil { failure = (message, clock?.now) }
    }

    func stop() async {
        generation += 1
        await flush()
        await teardown()
        phase = .idle
        level = 0
    }

    private func flush() async {
        microphone.stop()
        fileFeeder.stop()
        inputContinuation?.finish()
        inputContinuation = nil
        guard let analyzer, phase == .listening else { return }
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        if let resultsTask {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await resultsTask.value }
                group.addTask { try? await Task.sleep(for: .seconds(3)) }
                await group.next()
                group.cancelAll()
            }
        }
        self.analyzer = nil
    }

    nonisolated static func feed(into continuation: AsyncStream<AnalyzerInput>.Continuation, clock: SessionClock?, faultAfter: Double? = nil) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        let timeline = clock.map(AnalyzerTimeline.init)
        let fault = faultAfter.map(AnalyzerFault.init)
        return { buffer, time in
            if let input = fault?.input(after: buffer) { continuation.yield(input) }
            if let timeline, time.isHostTimeValid {
                for input in timeline.inputs(for: buffer, at: time) { continuation.yield(input) }
            } else {
                continuation.yield(AnalyzerInput(buffer: buffer))
            }
        }
    }

    private func makeTranscriber() async throws -> SpeechTranscriber {
        let preferred = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
        let fallback = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
        guard let locale = preferred ?? fallback else { throw TranscriberError.unsupportedLanguage }
        localeName = Locale.current.localizedString(forIdentifier: locale.identifier)
        localeIdentifier = locale.identifier(.bcp47)
        return SpeechTranscriber(locale: locale, preset: preset)
    }

    private func installAssetsIfNeeded(for transcriber: SpeechTranscriber) async throws {
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return }
        let progress = request.progress
        let watcher = Task { [weak self] in
            while !Task.isCancelled {
                self?.phase = .preparing(progress: progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
        defer { watcher.cancel() }
        try await request.downloadAndInstall()
    }

    private func consumeResults(of transcriber: SpeechTranscriber) {
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    self?.apply(result)
                }
            } catch {
                self?.fail(error)
            }
        }
    }

    private func apply(_ result: SpeechTranscriber.Result) {
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isFinal {
            finalizedText = [finalizedText, text].filter { !$0.isEmpty }.joined(separator: " ")
            volatileText = ""
            if !text.isEmpty, let onUtterance {
                utteranceCount += 1
                onUtterance(Self.utterance(from: result, text: text, id: "u\(utteranceCount)"))
            }
        } else {
            volatileText = text
        }
    }

    private static func utterance(from result: SpeechTranscriber.Result, text: String, id: String) -> Utterance {
        var words: [Word] = []
        for run in result.text.runs {
            guard let range = run.audioTimeRange else { continue }
            let word = String(result.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { continue }
            words.append(Word(text: word, range: TimeRange(start: range.start.seconds, end: range.end.seconds), confidence: run.transcriptionConfidence))
        }
        let range = TimeRange(start: result.range.start.seconds, end: result.range.end.seconds)
        return Utterance(id: id, range: range, text: text, words: words)
    }

    private func teardown() async {
        microphone.stop()
        fileFeeder.stop()
        inputContinuation?.finish()
        inputContinuation = nil
        if let analyzer {
            await analyzer.cancelAndFinishNow()
        }
        analyzer = nil
        resultsTask?.cancel()
        resultsTask = nil
    }
}
