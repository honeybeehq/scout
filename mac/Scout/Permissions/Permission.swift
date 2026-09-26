import Foundation

enum Permission: String, CaseIterable, Identifiable, Codable {
    case screenRecording
    case microphone
    case accessibility

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenRecording: "Screen Recording"
        case .microphone: "Microphone"
        case .accessibility: "Accessibility"
        }
    }

    var purpose: String {
        switch self {
        case .screenRecording: "See the app you are talking about."
        case .microphone: "Hear your notes as you talk."
        case .accessibility: "Know which button, field or view you point at."
        }
    }

    var symbol: String {
        switch self {
        case .screenRecording: "rectangle.dashed.badge.record"
        case .microphone: "waveform"
        case .accessibility: "cursorarrow.rays"
        }
    }

    var settingsAnchor: String {
        switch self {
        case .screenRecording: "Privacy_ScreenCapture"
        case .microphone: "Privacy_Microphone"
        case .accessibility: "Privacy_Accessibility"
        }
    }

    var settingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settingsAnchor)")!
    }

    var usesSystemSettingsToggle: Bool {
        self != .microphone
    }
}

enum PermissionState: Equatable {
    case notRequested
    case waiting
    case granted
    case denied
    case needsRelaunch

    var isGranted: Bool { self == .granted }
}
