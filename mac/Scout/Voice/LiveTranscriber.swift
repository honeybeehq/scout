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
    private(set) var run: TranscriptionRun?
    private(set) var terms = SpeechContextTerms()
    var localePreference = TranscriptionLocale.automatic
    var modulePreference = TranscriptionModule.speech
    private(set) var failure: (message: String, at: SessionTime?, microphone: String?)?
    private(set) var sound = SoundMeter()
    private(set) var events: [Walkthrough.TranscriptEvent] = []
    private(set) var stalledSince: SessionTime?

    var heardSound: Bool { sound.heardSound }
    var faultAfter: Double?

    var onUtterance: ((Utterance) -> Void)?
    var onEvent: ((Walkthrough.TranscriptEvent) -> Void)?
    var inputFile: URL?
    var onInputFinished: (() -> Void)?
    var audioURL: URL?
    private(set) var recordedAudio: (url: URL, seconds: Double)?

    private let clock: SessionClock?
    private let preset: SpeechTranscriber.Preset
    var microphone = MicrophoneCapture()
    private let fileFeeder = AudioFileFeeder()
    private var utteranceCount = 0
    private var generation = 0
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var audioWriter: SessionAudioWriter?
    private var resultsFinished = false
    private var watchdog: Task<Void, Never>?
    private var lastResult: (at: SessionTime, heard: Double) = (0, 0)
    private var soundResumedAt: SessionTime?
    private var seenRestarts = 0

    static let stallSound: Double = 3
    static let stallWait: Double = 5
    static let finishWait: Duration = .seconds(3)
    static let watchInterval: Duration = .milliseconds(500)
    private var pushedTerms: [String] = []
    private var contextRefresh: Task<Void, Never>?

    init(clock: SessionClock? = nil) {
        self.clock = clock
        preset = clock == nil ? .progressiveTranscription : .timeIndexedProgressiveTranscription
    }

    private func presetName(for module: TranscriptionModule) -> String {
        switch (module, clock == nil) {
        case (.speech, true): "progressiveTranscription"
        case (.speech, false): "timeIndexedProgressiveTranscription"
        case (.dictation, true): "progressiveLongDictation+frequentFinalization"
        case (.dictation, false): "progressiveLongDictation+frequentFinalization+timeIndexed"
        }
    }

    private func makeModule(_ module: TranscriptionModule, locale: Locale) -> any SpeechModule {
        switch module {
        case .speech:
            SpeechTranscriber(locale: locale, preset: preset)
        case .dictation:
            DictationTranscriber(
                locale: locale,
                contentHints: [],
                transcriptionOptions: [.punctuation],
                reportingOptions: [.volatileResults, .frequentFinalization],
                attributeOptions: clock == nil ? [.transcriptionConfidence] : [.audioTimeRange, .transcriptionConfidence]
            )
        }
    }

    var microphoneSummary: MicrophoneCapture.Summary? {
        inputFile == nil ? microphone.summary : nil
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
        events = []
        stalledSince = nil
        soundResumedAt = nil
        seenRestarts = 0
        resultsFinished = false
        sound = SoundMeter()
        inputName = microphone.inputName

        do {
            let (module, choice) = try await chooseModule()
            let transcriber = makeModule(module, locale: choice.locale)
            let assets = try await installAssetsIfNeeded(for: transcriber, module: module, locale: choice.locale)
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            try await analyzer.prepareToAnalyze(in: format)
            guard attempt == generation else { return }
            let strings = terms.all
            try await analyzer.setContext(Self.context(for: strings))
            pushedTerms = strings
            let run = TranscriptionRun(engine: TranscriptionRun.appleEngine, module: module.moduleName, requestedModule: modulePreference.moduleName, preset: presetName(for: module), locale: choice.identifier, requestedLocale: choice.requested, fellBack: choice.fellBack, assets: assets, contextualTerms: strings.count, userTerms: terms.pinned.count)
            self.run = run
            VoiceLog.log("started \(run.logLine)")

            let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
            inputContinuation = continuation
            self.analyzer = analyzer
            switch transcriber {
            case let speech as SpeechTranscriber: consume(speech.results)
            case let dictation as DictationTranscriber: consume(dictation.results)
            default: break
            }

            if audioWriter == nil, let audioURL, let clock { audioWriter = SessionAudioWriter(url: audioURL, clock: clock) }
            let onBuffer = Self.feed(into: continuation, clock: clock, faultAfter: faultAfter, sound: sound, audio: audioWriter)
            let onLevel: @Sendable (Float) -> Void = { [weak self] level in
                Task { @MainActor in self?.level = level }
            }
            if let inputFile {
                try fileFeeder.start(url: inputFile, convertingTo: format, onBuffer: onBuffer, onLevel: onLevel) { [weak self] in
                    VoiceLog.log("input file finished")
                    Task { @MainActor in self?.onInputFinished?() }
                }
            } else {
                let onFailure: @Sendable (Error) -> Void = { [weak self] error in
                    Task { @MainActor in await self?.inputStopped(error, attempt: attempt) }
                }
                try microphone.start(convertingTo: format, onBuffer: onBuffer, onLevel: onLevel, onFailure: onFailure)
            }
            try await analyzer.start(inputSequence: stream)
            guard attempt == generation else {
                await teardown()
                return
            }
            phase = .listening
            lastResult = (clock?.now ?? 0, sound.seconds)
            watch()
            if terms.all != pushedTerms { scheduleContextRefresh() }
        } catch {
            guard attempt == generation else { return }
            await teardown()
            fail(error)
        }
    }

    private func inputStopped(_ error: Error, attempt: Int) async {
        guard attempt == generation else { return }
        generation += 1
        let stopped = clock?.now
        await flush()
        await teardown()
        settle(at: stopped)
        level = 0
        fail(error)
    }

    private func watch() {
        guard let clock else { return }
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.watchInterval)
                guard let self else { return }
                guard !Task.isCancelled, self.phase == .listening else { continue }
                self.check(at: clock.now)
            }
        }
    }

    private func check(at now: SessionTime) {
        let restarts = microphone.summary.restarts
        if restarts > seenRestarts {
            seenRestarts = restarts
            record(Walkthrough.TranscriptEvent(kind: .restart, t: Walkthrough.milliseconds(now), message: microphone.summary.device))
        }
        guard stalledSince == nil else { return }
        let heard = sound.seconds
        if soundResumedAt == nil, heard > lastResult.heard { soundResumedAt = now }
        guard let soundResumedAt, heard - lastResult.heard >= Self.stallSound, now - lastResult.at >= Self.stallWait else { return }
        stalledSince = soundResumedAt
        NSLog("[scout-voice] stalled: %.1f s of sound and no result since %.1f s", heard - lastResult.heard, lastResult.at)
    }

    private func settle(at now: SessionTime?) {
        watchdog?.cancel()
        watchdog = nil
        guard let clock else { return }
        let end = now ?? clock.now
        if let since = stalledSince {
            stalledSince = nil
            record(Walkthrough.TranscriptEvent(kind: .stall, t: Walkthrough.milliseconds(since), until: Walkthrough.milliseconds(end)))
        }
        let pending = volatileText.split(whereSeparator: \.isWhitespace).count
        if pending > 0 {
            record(Walkthrough.TranscriptEvent(kind: .dropped, t: Walkthrough.milliseconds(end), words: pending))
        }
    }

    private func record(_ event: Walkthrough.TranscriptEvent) {
        events.append(event)
        onEvent?(event)
        NSLog("[scout-voice] %@ at %d ms%@%@%@", event.kind.rawValue, event.t, event.until.map { " until \($0) ms" } ?? "", event.words.map { " words \($0)" } ?? "", event.message.map { " · \($0)" } ?? "")
    }

    private func fail(_ error: Error) {
        guard !(error is CancellationError) else { return }
        let message = error.localizedDescription
        VoiceLog.log("failed: \(message)")
        phase = .failed(message)
        if failure == nil { failure = (message, clock?.now, (error as? MicrophoneCapture.CaptureError)?.reason) }
    }

    func stop() async {
        generation += 1
        let stopped = clock?.now
        await flush()
        await teardown()
        if let audioWriter {
            audioWriter.close()
            let seconds = audioWriter.seconds
            recordedAudio = seconds > 0 ? (audioWriter.url, seconds) : nil
            self.audioWriter = nil
        }
        settle(at: stopped)
        phase = .idle
        level = 0
    }

    private func flush() async {
        microphone.stop()
        fileFeeder.stop()
        inputContinuation?.finish()
        inputContinuation = nil
        guard let analyzer, phase == .listening else { return }
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            record(Walkthrough.TranscriptEvent(kind: .error, t: Walkthrough.milliseconds(clock?.now ?? 0), message: "Finishing the transcript failed: \(error.localizedDescription)"))
        }
        if let resultsTask {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await resultsTask.value }
                group.addTask { try? await Task.sleep(for: Self.finishWait) }
                await group.next()
                group.cancelAll()
            }
            if !resultsFinished {
                record(Walkthrough.TranscriptEvent(kind: .error, t: Walkthrough.milliseconds(clock?.now ?? 0), message: "The transcriber did not finish within \(Self.finishWait.components.seconds) seconds"))
            }
        }
        self.analyzer = nil
    }

    nonisolated static func feed(into continuation: AsyncStream<AnalyzerInput>.Continuation, clock: SessionClock?, faultAfter: Double? = nil, sound: SoundMeter? = nil, audio: SessionAudioWriter? = nil) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        let timeline = clock.map(AnalyzerTimeline.init)
        let fault = faultAfter.map(AnalyzerFault.init)
        return { buffer, time in
            sound?.measure(buffer)
            audio?.append(buffer, at: time)
            if let input = fault?.input(after: buffer) { continuation.yield(input) }
            if let timeline, time.isHostTimeValid {
                for input in timeline.inputs(for: buffer, at: time) { continuation.yield(input) }
            } else {
                continuation.yield(AnalyzerInput(buffer: buffer))
            }
        }
    }

    private func chooseModule() async throws -> (TranscriptionModule, TranscriptionLocale.Choice) {
        var module = modulePreference
        var choice = await TranscriptionLocale.resolve(preference: localePreference, module: module)
        if choice == nil, module != .speech {
            VoiceLog.log("\(module.moduleName) has no locale for \(localePreference); using SpeechTranscriber")
            module = .speech
            choice = await TranscriptionLocale.resolve(preference: localePreference, module: module)
        }
        guard let choice else { throw TranscriberError.unsupportedLanguage }
        localeName = TranscriptionLocale.title(for: choice.identifier)
        localeIdentifier = choice.identifier
        return (module, choice)
    }

    func pin(terms phrases: [String]) {
        if terms.pin(phrases) { scheduleContextRefresh() }
    }

    func note(_ context: AppContext) {
        if terms.note(context) { scheduleContextRefresh() }
    }

    func note(_ target: Target) {
        if terms.note(target) { scheduleContextRefresh() }
    }

    func learn(_ phrases: [String]) {
        if terms.remember(phrases) { scheduleContextRefresh() }
    }

    func noteSecondPass(engine: String) {
        run?.secondPass = engine
    }

    private func scheduleContextRefresh() {
        guard analyzer != nil, contextRefresh == nil else { return }
        contextRefresh = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.contextRefresh = nil
            await self.pushContext()
        }
    }

    private func pushContext() async {
        guard let analyzer, phase == .listening else { return }
        let strings = terms.all
        guard strings != pushedTerms else { return }
        do {
            try await analyzer.setContext(Self.context(for: strings))
            pushedTerms = strings
            run?.contextualTerms = strings.count
            VoiceLog.log("context refreshed terms=\(strings.count)")
        } catch {
            VoiceLog.log("context refresh failed: \(error.localizedDescription)")
        }
    }

    private static func context(for strings: [String]) -> AnalysisContext {
        let context = AnalysisContext()
        context.contextualStrings = strings.isEmpty ? [:] : [.general: strings]
        return context
    }

    private func installAssetsIfNeeded(for transcriber: any SpeechModule, module: TranscriptionModule, locale: Locale) async throws -> TranscriptionRun.Assets {
        let identifier = locale.identifier(.bcp47)
        let installedLocales: [Locale]
        switch module {
        case .speech: installedLocales = await SpeechTranscriber.installedLocales
        case .dictation: installedLocales = await DictationTranscriber.installedLocales
        }
        let installed = installedLocales.contains { $0.identifier(.bcp47) == identifier }
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return .installed }
        if !installed { VoiceLog.log("downloading speech assets for \(identifier)") }
        let progress = request.progress
        let watcher = Task { [weak self] in
            while !Task.isCancelled {
                self?.phase = .preparing(progress: progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
        defer { watcher.cancel() }
        try await request.downloadAndInstall()
        return installed ? .installed : .downloaded
    }

    private func consume<Results: AsyncSequence & Sendable>(_ results: Results) where Results.Element: TranscriptResult {
        resultsTask = Task { [weak self] in
            do {
                for try await result in results {
                    self?.apply(result.text, isFinal: result.isFinal, range: result.range)
                }
                self?.resultsFinished = true
                VoiceLog.log("results ended")
            } catch {
                self?.resultsFinished = true
                guard !Task.isCancelled else { return }
                self?.fail(error)
            }
        }
    }

    private func apply(_ attributed: AttributedString, isFinal: Bool, range: CMTimeRange) {
        let now = clock?.now ?? 0
        if let since = stalledSince {
            stalledSince = nil
            record(Walkthrough.TranscriptEvent(kind: .stall, t: Walkthrough.milliseconds(since), until: Walkthrough.milliseconds(now)))
        }
        lastResult = (now, sound.seconds)
        soundResumedAt = nil
        let text = String(attributed.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal {
            finalizedText = [finalizedText, text].filter { !$0.isEmpty }.joined(separator: " ")
            volatileText = ""
            guard !text.isEmpty, let onUtterance else { return }
            let splitsAtPauses = run?.module == TranscriptionModule.dictation.moduleName
            for piece in Self.utterances(from: attributed, range: range, text: text, splittingAtPauses: splitsAtPauses) {
                utteranceCount += 1
                onUtterance(Utterance(id: "u\(utteranceCount)", range: piece.range, text: piece.text, words: piece.words))
            }
        } else {
            volatileText = text
        }
    }

    nonisolated static func words(in attributed: AttributedString) -> [Word] {
        var words: [Word] = []
        for run in attributed.runs {
            guard let range = run.audioTimeRange else { continue }
            let word = String(attributed[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { continue }
            words.append(Word(text: word, range: TimeRange(start: range.start.seconds, end: range.end.seconds), confidence: run.transcriptionConfidence))
        }
        return words
    }

    nonisolated static func utterances(from attributed: AttributedString, range: CMTimeRange, text: String, splittingAtPauses: Bool) -> [(range: TimeRange, text: String, words: [Word])] {
        let words = words(in: attributed)
        let whole = TimeRange(start: range.start.seconds, end: range.end.seconds)
        guard splittingAtPauses, words.count > 1 else { return [(whole, text, words)] }
        let groups = WordGapSplitter.groups(words)
        guard groups.count > 1 else { return [(whole, text, words)] }
        return groups.map { group in
            (TimeRange(start: group[0].range.start, end: group[group.count - 1].range.end), group.map(\.text).joined(separator: " "), group)
        }
    }

    private func teardown() async {
        contextRefresh?.cancel()
        contextRefresh = nil
        pushedTerms = []
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
        watchdog?.cancel()
        watchdog = nil
    }
}
