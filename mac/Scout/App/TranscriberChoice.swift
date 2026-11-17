import Foundation

extension AppModel {
    func useAppleTranscriber() {
        preferences.transcriptionEngine = .apple
        whisperModels.cancel()
    }

    func useWhisperTranscriber() {
        preferences.transcriptionEngine = .whisper
    }

    func installWhisper() {
        preferences.transcriptionEngine = .whisper
        whisperModels.download()
    }

    func removeWhisper() {
        confirmingWhisperRemoval = false
        if preferences.transcriptionEngine == .whisper { preferences.transcriptionEngine = .apple }
        whisperModels.remove()
    }
}
