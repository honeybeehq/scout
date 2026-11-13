import Foundation
import ScoutCore
import WhisperKit

actor WhisperEngine: TranscriptionEngine {
    nonisolated let name = WhisperPins.engineName
    let modelFolder: URL
    let tokenizerFolder: URL
    private var whisper: WhisperKit?
    private var loading: Task<Void, Error>?

    init(modelFolder: URL, tokenizerFolder: URL) {
        self.modelFolder = modelFolder
        self.tokenizerFolder = tokenizerFolder
    }

    var isLoaded: Bool { whisper != nil }

    func prepare() async throws {
        _ = try await load()
    }

    func unload() {
        loading?.cancel()
        loading = nil
        whisper = nil
    }

    func encode(_ text: String) async throws -> [Int] {
        let whisper = try await load()
        guard let tokenizer = whisper.tokenizer else { throw WhisperError.tokenizerUnavailable() }
        return tokenizer.encode(text: text)
    }

    func transcribe(_ request: TranscriptionRequest) async throws -> EngineTranscript {
        let whisper = try await load()
        try Task.checkCancellation()
        var options = DecodingOptions(wordTimestamps: true)
        options.skipSpecialTokens = true
        options.language = Self.language(for: request.locale)
        options.detectLanguage = options.language == nil
        if let tokenizer = whisper.tokenizer, let prompt = Self.prompt(from: request.contextualStrings) {
            options.promptTokens = tokenizer.encode(text: " " + prompt).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }
        let started = Date()
        let results: [TranscriptionResult]
        do {
            results = try await whisper.transcribe(audioPath: request.audio.path, decodeOptions: options)
        } catch {
            whisper.clearState()
            throw error
        }
        let segments = results.flatMap(\.segments).compactMap(Self.segment(from:))
        NSLog("[scout-transcript] %@ decoded %d segments in %.1f s (language %@)", name, segments.count, Date().timeIntervalSince(started), results.first?.language ?? "?")
        return EngineTranscript(engine: name, locale: results.first?.language, segments: segments)
    }

    private func load() async throws -> WhisperKit {
        if let whisper { return whisper }
        if loading == nil {
            let config = WhisperKitConfig(
                modelFolder: modelFolder.path,
                tokenizerFolder: tokenizerFolder,
                verbose: false,
                logLevel: .none,
                prewarm: false,
                load: true,
                download: false
            )
            loading = Task {
                let started = Date()
                let loaded = try await WhisperKit(config)
                guard loaded.tokenizer != nil else { throw WhisperError.tokenizerUnavailable() }
                NSLog("[scout-transcript] %@ loaded from %@ in %.1f s", WhisperPins.engineName, modelFolder.lastPathComponent, Date().timeIntervalSince(started))
                whisper = loaded
            }
        }
        defer { loading = nil }
        try await loading?.value
        guard let whisper else { throw WhisperError.modelsUnavailable("The model did not load.") }
        return whisper
    }

    static func language(for locale: Locale) -> String? {
        guard var code = locale.language.languageCode?.identifier.lowercased() else { return nil }
        if code == "nb" || code == "nn" { code = "no" }
        return Constants.languageCodes.contains(code) ? code : nil
    }

    static func prompt(from strings: [String]) -> String? {
        var seen: Set<String> = []
        let terms = strings
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        guard !terms.isEmpty else { return nil }
        return String(terms.joined(separator: ", ").prefix(600))
    }

    static func segment(from segment: TranscriptionSegment) -> TranscribedSegment? {
        let words: [Word] = (segment.words ?? []).compactMap { timing in
            let text = timing.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let start = Double(timing.start)
            return Word(text: text, range: TimeRange(start: start, end: max(start, Double(timing.end))), confidence: Double(timing.probability))
        }
        let text = words.isEmpty ? segment.text.trimmingCharacters(in: .whitespacesAndNewlines) : words.map(\.text).joined(separator: " ")
        guard !text.isEmpty else { return nil }
        let start = words.first.map(\.range.start) ?? Double(segment.start)
        let end = words.last.map(\.range.end) ?? Double(segment.end)
        return TranscribedSegment(range: TimeRange(start: start, end: max(start, end)), text: text, words: words)
    }
}
