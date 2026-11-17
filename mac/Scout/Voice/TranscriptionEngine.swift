@preconcurrency import AVFoundation
import ScoutCore
import Speech

nonisolated struct TranscriptionRequest: Sendable {
    var audio: URL
    var locale: Locale
    var contextualStrings: [String] = []
    var module: TranscriptionModule = .speech
}

nonisolated struct EngineTranscript: Sendable {
    var engine: String
    var locale: String?
    var segments: [TranscribedSegment]
}

nonisolated protocol TranscriptionEngine: Sendable {
    var name: String { get }
    func prepare() async throws
    func transcribe(_ request: TranscriptionRequest) async throws -> EngineTranscript
}

extension TranscriptionEngine {
    func prepare() async throws {}
}

nonisolated struct AppleTranscriptionEngine: TranscriptionEngine {
    enum EngineError: LocalizedError {
        case unsupportedLanguage(String)
        case unsupportedModule

        var errorDescription: String? {
            switch self {
            case .unsupportedLanguage(let identifier): "SpeechTranscriber doesn't support \(identifier)."
            case .unsupportedModule: "The transcriber module isn't available."
            }
        }
    }

    let name = "Apple.file"

    func transcribe(_ request: TranscriptionRequest) async throws -> EngineTranscript {
        let (module, locale) = try await Self.chooseModule(request.module, equivalentTo: request.locale)
        let transcriber: any SpeechModule
        switch module {
        case .speech:
            transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        case .dictation:
            transcriber = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation], reportingOptions: [], attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        }
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await install.downloadAndInstall()
        }
        let file = try AVAudioFile(forReading: request.audio)
        let context = AnalysisContext()
        if !request.contextualStrings.isEmpty { context.contextualStrings[.general] = request.contextualStrings }
        let engineName = "\(module.moduleName).file"
        VoiceLog.log("second pass module=\(module.moduleName)\(module == request.module ? "" : " (requested \(request.module.moduleName))") locale=\(locale.identifier(.bcp47)) terms=\(request.contextualStrings.count)\(module == .speech ? " (SpeechTranscriber ignores terms)" : "")")
        let collector: Task<[TranscribedSegment], any Error>
        switch transcriber {
        case let speech as SpeechTranscriber: collector = Self.collect(speech.results, splittingAtPauses: false)
        case let dictation as DictationTranscriber: collector = Self.collect(dictation.results, splittingAtPauses: true)
        default: throw EngineError.unsupportedModule
        }
        let analyzer: SpeechAnalyzer
        do {
            analyzer = try await SpeechAnalyzer(inputAudioFile: file, modules: [transcriber], analysisContext: context, finishAfterFile: true)
        } catch {
            collector.cancel()
            throw error
        }
        let segments = try await withTaskCancellationHandler {
            try await collector.value
        } onCancel: {
            collector.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
        return EngineTranscript(engine: engineName, locale: locale.identifier(.bcp47), segments: segments)
    }

    private static func chooseModule(_ requested: TranscriptionModule, equivalentTo locale: Locale) async throws -> (TranscriptionModule, Locale) {
        if requested == .dictation {
            if let match = await DictationTranscriber.supportedLocale(equivalentTo: locale),
               await DictationTranscriber.supportedLocales.contains(where: { $0.identifier(.bcp47) == match.identifier(.bcp47) }) {
                return (.dictation, match)
            }
            VoiceLog.log("second pass: DictationTranscriber has no locale for \(locale.identifier); using SpeechTranscriber")
        }
        guard let match = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw EngineError.unsupportedLanguage(locale.identifier)
        }
        return (.speech, match)
    }

    private static func collect<Results: AsyncSequence & Sendable>(_ results: Results, splittingAtPauses: Bool) -> Task<[TranscribedSegment], any Error> where Results.Element: TranscriptResult {
        Task {
            var segments: [TranscribedSegment] = []
            for try await result in results where result.isFinal {
                segments.append(contentsOf: self.segments(from: result, splittingAtPauses: splittingAtPauses))
            }
            return segments
        }
    }

    private static func segments(from result: some TranscriptResult, splittingAtPauses: Bool) -> [TranscribedSegment] {
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        return LiveTranscriber.utterances(from: result.text, range: result.range, text: text, splittingAtPauses: splittingAtPauses)
            .map { TranscribedSegment(range: $0.range, text: $0.text, words: $0.words) }
    }
}
