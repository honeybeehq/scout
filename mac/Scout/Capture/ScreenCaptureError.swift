import Foundation
@preconcurrency import ScreenCaptureKit

nonisolated enum ScreenCaptureError: LocalizedError, Sendable {
    case permissionDenied
    case noDisplay
    case alreadyStarted
    case streamFailed(String)
    case streamStopped(String)
    case writerFailed(String)
    case noMedia(from: Double, to: Double)
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Scout can't record the screen. Allow Scout in System Settings › Privacy & Security › Screen & System Audio Recording, then relaunch Scout."
        case .noDisplay:
            "Scout couldn't find a display to record."
        case .alreadyStarted:
            "This recorder has already been started. Use a new recorder for each session."
        case .streamFailed(let reason):
            "Screen recording couldn't start: \(reason)"
        case .streamStopped(let reason):
            "Screen recording stopped: \(reason)"
        case .writerFailed(let reason):
            "Scout couldn't save the screen recording: \(reason)"
        case .noMedia(let start, let end):
            "There is no recorded video between \(String(format: "%.1f", start)) s and \(String(format: "%.1f", end)) s."
        case .exportFailed(let reason):
            "Scout couldn't cut the clip: \(reason)"
        }
    }

    static func starting(_ error: any Error) -> ScreenCaptureError {
        if let error = error as? ScreenCaptureError { return error }
        if let streamError = error as? SCStreamError, streamError.code == .userDeclined { return .permissionDenied }
        return .streamFailed(error.localizedDescription)
    }

    static func stopped(_ error: any Error) -> ScreenCaptureError {
        guard let streamError = error as? SCStreamError else { return .streamStopped(error.localizedDescription) }
        switch streamError.code {
        case .userDeclined: return .permissionDenied
        case .noCaptureSource, .noDisplayList: return .streamStopped("the display was disconnected.")
        case .userStopped: return .streamStopped("recording was stopped from the menu bar.")
        case .systemStoppedStream: return .streamStopped("macOS stopped the recording.")
        default: return .streamStopped(streamError.localizedDescription)
        }
    }
}
