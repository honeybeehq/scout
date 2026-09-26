import AppKit
import Foundation

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
        try? await Task.sleep(for: .seconds(8))
        snapshotPanels(into: output, suffix: "after-stop")
        writeReport(model: model, into: output, elapsed: Date().timeIntervalSince(started))
        NSApp.terminate(nil)
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
                "breakpoint": card.snippet.closedBy.map { ["score": $0.score, "hard": $0.isHard, "reasons": $0.reasons.map { "\($0.kind.rawValue) \($0.weight)" }] } ?? [:],
            ]
        }
        let report: [String: Any] = [
            "elapsed": elapsed,
            "session": model.session?.directory.path ?? "",
            "transcript": model.session?.transcriber.finalizedText ?? "",
            "cards": cards,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("report.json"))
        }
    }
}
