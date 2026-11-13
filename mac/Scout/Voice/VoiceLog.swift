import Foundation

nonisolated enum VoiceLog {
    static func log(_ message: String) {
        NSLog("[scout-voice] %@", message)
    }
}
