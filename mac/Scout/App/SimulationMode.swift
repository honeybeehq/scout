import AppKit
import Foundation
import FoundationModels

enum SimulationMode {
    private static func argument(_ name: String) -> String? {
        let prefix = "--\(name)="
        return ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    static var audioFile: URL? {
        argument("simulate-session").map { URL(fileURLWithPath: $0) }
    }

    static var outputDirectory: URL {
        URL(fileURLWithPath: argument("simulate-output") ?? "/tmp/scout-simulation", isDirectory: true)
    }

    static var isQuickStop: Bool {
        ProcessInfo.processInfo.arguments.contains("--simulate-quick-stop")
    }

    static func runQuickStop(model: AppModel, audio: URL) async {
        let output = outputDirectory
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(1))
        model.startScouting(inputFile: audio)
        try? await Task.sleep(for: .milliseconds(250))
        model.stopScouting()
        try? await Task.sleep(for: .seconds(3))
        let framesEarly = model.session?.recorder?.statistics.framesCaptured ?? -1
        try? await Task.sleep(for: .seconds(3))
        let framesLate = model.session?.recorder?.statistics.framesCaptured ?? -1
        let report: [String: Any] = [
            "sessionPhase": String(describing: model.session?.phase),
            "transcriberPhase": String(describing: model.session?.transcriber.phase),
            "transcriberLevel": Double(model.session?.transcriber.level ?? -1),
            "framesAfter3s": framesEarly,
            "framesAfter6s": framesLate,
            "isScouting": model.isScouting,
            "aimActiveTap": model.session?.aim.isAiming ?? false,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appendingPathComponent("quick-stop.json"))
        }
        NSApp.terminate(nil)
    }

    static var isDryRun: Bool {
        ProcessInfo.processInfo.arguments.contains("--dry-run-delivery")
    }

    static func run(model: AppModel, audio: URL) async {
        let output = outputDirectory
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(1))

        var finished = false
        model.startScouting(inputFile: audio) { finished = true }
        let started = Date()
        var snapped = false
        if ProcessInfo.processInfo.arguments.contains("--simulate-pin") {
            Task {
                try? await Task.sleep(for: .seconds(4))
                await postPin()
            }
        }
        while !finished, Date().timeIntervalSince(started) < 600 {
            try? await Task.sleep(for: .milliseconds(250))
            if !snapped, (model.session?.closedCount ?? 0) >= 1 {
                snapped = true
                try? await Task.sleep(for: .milliseconds(600))
                snapshotPanels(into: output, suffix: "live")
            }
        }
        try? await Task.sleep(for: .seconds(10))
        snapshotPanels(into: output, suffix: "before-stop")
        model.stopScouting()
        try? await Task.sleep(for: .seconds(4))
        for card in model.dispatcher.cards where card.state == .needsDestination || card.state == .held {
            model.dispatcher.choose(.clipboard, for: card)
            await model.dispatcher.send(card)
        }
        try? await Task.sleep(for: .seconds(4))
        snapshotPanels(into: output, suffix: "after-stop")
        writeReport(model: model, into: output, elapsed: Date().timeIntervalSince(started))
        NSApp.terminate(nil)
    }

    private static func postPin() async {
        let source = CGEventSource(stateID: .hidSystemState)
        let location = CGEvent(source: nil)?.location ?? .zero
        let optionDown = CGEvent(keyboardEventSource: source, virtualKey: 58, keyDown: true)
        optionDown?.flags = .maskAlternate
        optionDown?.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(450))
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: location, mouseButton: .left).map { $0.flags = .maskAlternate; $0.post(tap: .cghidEventTap) }
        try? await Task.sleep(for: .milliseconds(60))
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: location, mouseButton: .left).map { $0.flags = .maskAlternate; $0.post(tap: .cghidEventTap) }
        try? await Task.sleep(for: .milliseconds(200))
        let optionUp = CGEvent(keyboardEventSource: source, virtualKey: 58, keyDown: false)
        optionUp?.flags = []
        optionUp?.post(tap: .cghidEventTap)
    }

    private static func snapshotPanels(into directory: URL, suffix: String) {
        for (index, panel) in NSApp.windows.enumerated() where panel is NSPanel && panel.isVisible {
            guard let image = SnapshotMode.windowImage(CGWindowID(panel.windowNumber)) else { continue }
            let name = panel.frame.height < 80 ? "pill" : "stack-\(index)"
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent("\(name)-\(suffix).png"))
        }
    }

    private static func writeReport(model: AppModel, into directory: URL, elapsed: TimeInterval) {
        let cards: [[String: Any]] = model.dispatcher.cards.map { card in
            [
                "id": card.snippet.id,
                "range": [card.snippet.range.start, card.snippet.range.end],
                "title": card.title,
                "transcript": card.snippet.transcript,
                "state": String(describing: card.state),
                "destination": card.destination?.label ?? "none",
                "context": card.snippet.primaryContext.map { "\($0.app.name) \($0.location ?? $0.windowTitle ?? "")" } ?? "none",
                "targets": card.snippet.targets.map(\.displayName),
                "marks": card.snippet.marks.map { "\($0.id) at \($0.at) \($0.target?.displayName ?? "no target")" },
                "breakpoint": card.snippet.closedBy.map { ["score": $0.score, "hard": $0.isHard, "reasons": $0.reasons.map { "\($0.kind.rawValue) \($0.weight)" }] } ?? [:],
            ]
        }
        let report: [String: Any] = [
            "elapsed": elapsed,
            "session": model.session?.directory.path ?? "",
            "transcript": model.session?.transcriber.finalizedText ?? "",
            "onDeviceTitles": String(describing: SystemLanguageModel.default.availability),
            "aimAvailable": model.session?.aim.isAvailable ?? false,
            "bridgePort": model.bridge.port.map(Int.init) ?? 0,
            "bridgeFailure": model.bridge.failure ?? "",
            "captureProblem": model.session?.captureProblem ?? "",
            "attachments": model.dispatcher.cards.flatMap { $0.attachments.map(\.line) },
            "cards": cards,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("report.json"))
        }
    }
}
