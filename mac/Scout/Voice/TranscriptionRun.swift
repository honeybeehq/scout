import Foundation

nonisolated struct TranscriptionRun: Codable, Equatable, Sendable {
    enum Assets: String, Codable, Sendable {
        case installed
        case downloaded
    }

    var engine: String
    var module: String
    var requestedModule: String
    var preset: String
    var locale: String
    var requestedLocale: String
    var fellBack: Bool
    var assets: Assets
    var contextualTerms: Int
    var userTerms: Int
    var secondPass: String?

    static let appleEngine = "SpeechAnalyzer"

    var logLine: String {
        "engine=\(engine) module=\(module)\(module == requestedModule ? "" : " (requested \(requestedModule))") preset=\(preset) locale=\(locale) requested=\(requestedLocale)\(fellBack ? " (fell back)" : "") assets=\(assets.rawValue) terms=\(contextualTerms) userTerms=\(userTerms)\(module == "SpeechTranscriber" ? " (SpeechTranscriber ignores terms)" : "")"
    }

    static let fileName = "transcription.json"

    func write(to directory: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }
}
