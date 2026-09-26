import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Observation

@Observable
final class PermissionCenter {
    private(set) var states: [Permission: PermissionState] = [:]
    private(set) var lastGranted: Permission?
    let guide = SettingsGuide()

    private var monitoring: Task<Void, Never>?
    private var returnedFromSettings: Set<Permission> = []
    private let defaults = UserDefaults.standard

    init() {
        refresh()
    }

    func state(of permission: Permission) -> PermissionState {
        states[permission] ?? .notRequested
    }

    var grantedCount: Int {
        Permission.allCases.filter { state(of: $0).isGranted }.count
    }

    var allGranted: Bool {
        grantedCount == Permission.allCases.count
    }

    var nextNeeded: Permission? {
        Permission.allCases.first { !state(of: $0).isGranted }
    }

    func startMonitoring() {
        guard monitoring == nil else { return }
        monitoring = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    func stopMonitoring() {
        monitoring?.cancel()
        monitoring = nil
    }

    func refresh() {
        for permission in Permission.allCases {
            let previous = states[permission]
            let current = resolveState(of: permission)
            guard previous != current else { continue }
            states[permission] = current
            if current == .granted, previous != nil {
                lastGranted = permission
                guide.complete(permission)
            }
        }
    }

    func request(_ permission: Permission) async {
        switch permission {
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            } else {
                NSWorkspace.shared.open(permission.settingsURL)
            }
        case .accessibility:
            if wasRequested(permission) {
                NSWorkspace.shared.open(permission.settingsURL)
            } else {
                let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
            guide.show(for: permission)
        case .screenRecording:
            if wasRequested(permission) {
                NSWorkspace.shared.open(permission.settingsURL)
            } else {
                _ = CGRequestScreenCaptureAccess()
            }
            guide.show(for: permission)
        }
        markRequested(permission)
        refresh()
    }

    func openSettings(for permission: Permission) {
        NSWorkspace.shared.open(permission.settingsURL)
        if permission.usesSystemSettingsToggle {
            guide.show(for: permission)
        }
    }

    func noteAppBecameActive() {
        for permission in Permission.allCases where state(of: permission) == .waiting {
            returnedFromSettings.insert(permission)
        }
        guide.hideIfIdle()
        refresh()
    }

    private func resolveState(of permission: Permission) -> PermissionState {
        switch permission {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .notDetermined: return .notRequested
            default: return .denied
            }
        case .accessibility:
            if AXIsProcessTrusted() { return .granted }
            return wasRequested(permission) ? .waiting : .notRequested
        case .screenRecording:
            if CGPreflightScreenCaptureAccess() { return .granted }
            guard wasRequested(permission) else { return .notRequested }
            return returnedFromSettings.contains(permission) ? .needsRelaunch : .waiting
        }
    }

    private func wasRequested(_ permission: Permission) -> Bool {
        defaults.bool(forKey: requestedKey(permission))
    }

    private func markRequested(_ permission: Permission) {
        defaults.set(true, forKey: requestedKey(permission))
    }

    private func requestedKey(_ permission: Permission) -> String {
        "permission.requested.\(permission.rawValue)"
    }
}
