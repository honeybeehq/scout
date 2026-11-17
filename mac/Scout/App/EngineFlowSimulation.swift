import AppKit
import Foundation

enum EngineFlowSimulation: String {
    case accept
    case decline
    case settings

    static var requested: EngineFlowSimulation? {
        let prefix = "--simulate-engine-flow="
        return ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }.flatMap { EngineFlowSimulation(rawValue: String($0.dropFirst(prefix.count))) }
    }

    private static let hold = Duration.seconds(4)
    private static let longest = Duration.seconds(45 * 60)

    static func run(_ flow: EngineFlowSimulation, model: AppModel) async {
        log("start \(flow.rawValue): model \(model.whisperModels.state.summary), engine \(model.preferences.transcriptionEngine.rawValue), data root \(ScoutPaths.support.path)")
        guard await waitForWindows(model) else {
            log("stopped: the menu bar item never set up its window openers")
            NSApp.terminate(nil)
            return
        }
        switch flow {
        case .accept: await accept(model)
        case .decline: await decline(model)
        case .settings: await settings(model)
        }
        log("done: model \(model.whisperModels.state.summary), engine \(model.preferences.transcriptionEngine.rawValue)")
        try? await Task.sleep(for: hold)
        NSApp.terminate(nil)
    }

    private static func accept(_ model: AppModel) async {
        await showOnboarding(model)
        step("Download and install")
        model.installWhisper()
        try? await Task.sleep(for: .seconds(10))
        step("Continue")
        model.onboarding.next()
        try? await Task.sleep(for: hold)
        step("Back")
        model.onboarding.back()
        guard await wait(model, until: "ready", { $0.state == .ready }) else { return }
        try? await Task.sleep(for: hold)
        step("Continue")
        model.onboarding.next()
        try? await Task.sleep(for: hold)
    }

    private static func decline(_ model: AppModel) async {
        await showOnboarding(model)
        step("Use Apple")
        model.useAppleTranscriber()
        model.onboarding.next()
        try? await Task.sleep(for: hold)
        let models = ScoutPaths.support.appendingPathComponent("Models", isDirectory: true)
        log("Models folder \(FileManager.default.fileExists(atPath: models.path) ? "exists" : "does not exist") at \(models.path)")
    }

    private static func settings(_ model: AppModel) async {
        model.openSettingsWindow?()
        try? await Task.sleep(for: hold)
        step("Download")
        model.installWhisper()
        guard await wait(model, until: "20% downloaded", { ($0.progress ?? 0) >= 0.2 }) else { return }
        await pause(model)
        step("Resume")
        model.installWhisper()
        guard await wait(model, until: "45% downloaded", { ($0.progress ?? 0) >= 0.45 }) else { return }
        await pause(model)
        tamper(model.whisperModels)
        try? await Task.sleep(for: .seconds(2))
        step("Resume")
        model.installWhisper()
        guard await wait(model, until: "the check rejects the tampered file", { $0.state.isFailed }, failureEnds: false) else { return }
        try? await Task.sleep(for: hold)
        step("Try again")
        model.installWhisper()
        guard await wait(model, until: "installed", { $0.state == .ready || $0.state == .installed }) else { return }
        try? await Task.sleep(for: hold)
        step("Remove")
        model.confirmingWhisperRemoval = true
        try? await Task.sleep(for: .seconds(2.5))
        step("Remove (confirm)")
        model.removeWhisper()
        _ = await wait(model, until: "not installed", { $0.state == .notInstalled && $0.partialBytes == 0 })
        try? await Task.sleep(for: hold)
    }

    private static func showOnboarding(_ model: AppModel) async {
        model.onboarding.go(to: .transcriber)
        model.openOnboarding?()
        try? await Task.sleep(for: hold)
    }

    private static func pause(_ model: AppModel) async {
        step("Cancel")
        model.whisperModels.cancel()
        _ = await wait(model, until: "paused", { $0.isPaused })
        try? await Task.sleep(for: hold)
    }

    private static func tamper(_ store: WhisperModelStore) {
        guard let largest = WhisperPins.files.max(by: { $0.bytes < $1.bytes }) else { return }
        let file = store.partialFolder.appendingPathComponent(largest.path)
        guard let handle = try? FileHandle(forWritingTo: file) else {
            log("tamper skipped: no partial \(largest.path)")
            return
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: Data("XXXX".utf8))
            log("tampered: overwrote the first 4 bytes of \(file.path), size unchanged")
        } catch {
            log("tamper failed: \(error.localizedDescription)")
        }
    }

    private static func waitForWindows(_ model: AppModel) async -> Bool {
        for _ in 0..<40 {
            if model.openOnboarding != nil && model.openSettingsWindow != nil { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    private static func wait(_ model: AppModel, until goal: String, _ reached: (WhisperModelSnapshot) -> Bool, failureEnds: Bool = true) async -> Bool {
        let deadline = ContinuousClock.now + longest
        while ContinuousClock.now < deadline {
            let snapshot = model.whisperModels.snapshot
            if reached(snapshot) {
                log("reached \(goal): \(snapshot.state.summary)")
                return true
            }
            if failureEnds, snapshot.state.isFailed {
                log("stopped waiting for \(goal): \(snapshot.state.summary)")
                return false
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        log("timed out waiting for \(goal): \(model.whisperModels.state.summary)")
        return false
    }

    private static func step(_ name: String) {
        log("step: \(name)")
    }

    private static func log(_ message: String) {
        NSLog("[scout-engine-flow] %@", message)
    }
}

extension WhisperModelStore.State {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}
