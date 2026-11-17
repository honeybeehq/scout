import Foundation
import Speech

nonisolated enum TranscriptionModule: String, CaseIterable, Identifiable, Sendable {
    case speech
    case dictation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .speech: "Speech"
        case .dictation: "Dictation"
        }
    }

    var moduleName: String {
        switch self {
        case .speech: "SpeechTranscriber"
        case .dictation: "DictationTranscriber"
        }
    }

    var explanation: String {
        switch self {
        case .speech: "Apple's newest transcriber. It ignores the words you add below."
        case .dictation: "Apple's dictation transcriber. It uses the words you add and what Scout sees on screen, so names and jargon come out right."
        }
    }
}

nonisolated protocol TranscriptResult: SpeechModuleResult {
    var text: AttributedString { get }
}

nonisolated extension SpeechTranscriber.Result: TranscriptResult {}
nonisolated extension DictationTranscriber.Result: TranscriptResult {}
