@preconcurrency import AVFoundation
import ScoutCore
import Speech

nonisolated struct TranscriptionRequest: Sendable {
    var audio: URL
    var locale: Locale
    var contextualStrings: [String] = []
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

        var errorDescription: String? {
            switch self {
            case .unsupportedLanguage(let identifier): "SpeechTranscriber doesn't support \(identifier)."
            }
        }
    }

    let name = "SpeechTranscriber.file"

    func transcribe(_ request: TranscriptionRequest) async throws -> EngineTranscript {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: request.locale) else {
            throw EngineError.unsupportedLanguage(request.locale.identifier)
        }
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await install.downloadAndInstall()
        }
        let file = try AVAudioFile(forReading: request.audio)
        let context = AnalysisContext()
        if !request.contextualStrings.isEmpty { context.contextualStrings[.general] = request.contextualStrings }
        let collector = Task {
            var segments: [TranscribedSegment] = []
            for try await result in transcriber.results where result.isFinal {
                if let segment = Self.segment(from: result) { segments.append(segment) }
            }
            return segments
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
        return EngineTranscript(engine: name, locale: locale.identifier(.bcp47), segments: segments)
    }

    private static func segment(from result: SpeechTranscriber.Result) -> TranscribedSegment? {
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var words: [Word] = []
        for run in result.text.runs {
            guard let range = run.audioTimeRange else { continue }
            let word = String(result.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { continue }
            words.append(Word(text: word, range: TimeRange(start: range.start.seconds, end: range.end.seconds), confidence: run.transcriptionConfidence))
        }
        return TranscribedSegment(range: TimeRange(start: result.range.start.seconds, end: result.range.end.seconds), text: text, words: words)
    }
}
