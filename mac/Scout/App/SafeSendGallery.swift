import AppKit
import ScoutCore
import SwiftUI

enum SafeSendGallery {
    static var directory: URL? {
        argument("safe-send-gallery").map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private static func argument(_ name: String) -> String? {
        let prefix = "--\(name)="
        return ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    private static var schemes: [String] {
        (argument("picker-schemes") ?? "dark,light").split(separator: ",").map(String.init)
    }

    private static var pace: Double {
        argument("picker-pace").flatMap(Double.init) ?? 1
    }

    private static var clickTarget: String { argument("safe-send-click") ?? "apiary" }

    private static var suggestTarget: String { argument("safe-send-suggest") ?? "scout" }

    private static var deliveryLog: URL? {
        argument("safe-send-log").map { URL(fileURLWithPath: $0) }
    }

    private static var events: [[String: Any]] = []
    private static let began = Date()

    static func note(_ text: String, _ extra: [String: Any] = [:]) {
        var row = extra
        row["t"] = Int(Date().timeIntervalSince(began) * 1000)
        row["epochMs"] = Int(Date().timeIntervalSince1970 * 1000)
        row["event"] = text
        events.append(row)
    }

    static func delivered() -> [(epochMs: Int, line: String)] {
        guard let deliveryLog, let text = try? String(contentsOf: deliveryLog, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let first = line.split(separator: " ").first, let epoch = Int(first) else { return nil }
            return (epoch, String(line))
        }
    }

    static func run(model: AppModel, into directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var report: [String: Any] = ["schemes": schemes, "pace": pace, "undoSeconds": TargetPickerModel.undoSeconds, "trusted": AXIsProcessTrusted(), "deliveryLog": deliveryLog?.path ?? ""]
        guard let folder = argument("picker-walkthrough"),
              let data = FileManager.default.contents(atPath: folder + "/" + WalkthroughBundle.entryName),
              let walkthrough = try? JSONDecoder().decode(Walkthrough.self, from: data)
        else {
            report["error"] = "pass --picker-walkthrough=<folder with walkthrough.json>"
            write(report, into: directory)
            NSApp.terminate(nil)
            return
        }
        let finished = FinishedWalkthrough(directory: URL(fileURLWithPath: folder, isDirectory: true), walkthrough: walkthrough, timings: [:])
        try? await Task.sleep(for: .milliseconds(600))
        var checks: [[String: Any]] = []
        var shots: [[String: Any]] = []
        for scheme in schemes {
            NSApp.appearance = NSAppearance(named: scheme == "light" ? .aqua : .darkAqua)
            var driver = Driver(model: model, finished: finished, scheme: scheme, directory: directory)
            await driver.flow()
            checks += driver.checks
            shots += driver.shots
        }
        report["checks"] = checks
        report["shots"] = shots
        report["targets"] = model.picker.model.targets.map { ["key": $0.key, "title": $0.title] }
        var driver = Driver(model: model, finished: finished, scheme: schemes.last ?? "dark", directory: directory)
        await driver.open()
        await driver.press(.enter, "↩")
        await driver.shot("quit-window")
        report["quit"] = ["deliveriesBeforeQuit": delivered().count, "pending": driver.state.pending?.target.title ?? "", "quitEpochMs": Int(Date().timeIntervalSince1970 * 1000)]
        note("quit during the undo window")
        report["events"] = events
        report["shots"] = shots + driver.shots
        write(report, into: directory)
        NSApp.terminate(nil)
    }

    private static func write(_ report: [String: Any], into directory: URL) {
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("safe-send.json"))
        }
    }

    static func pause(_ milliseconds: Double) async {
        try? await Task.sleep(for: .milliseconds(Int(milliseconds * pace)))
    }

    private struct Driver {
        var model: AppModel
        var finished: FinishedWalkthrough
        var scheme: String
        var directory: URL
        var shots: [[String: Any]] = []
        var checks: [[String: Any]] = []

        var picker: TargetPickerController { model.picker }
        var state: TargetPickerModel { model.picker.model }
        var hold: Double { TargetPickerModel.undoSeconds * 1000 }

        mutating func flow() async {
            await open()
            await shot("1-open")
            var before = delivered().count
            await click(SafeSendGallery.clickTarget)
            await SafeSendGallery.pause(600)
            await shot("2-undo-window")
            await click("undo")
            await shot("3-undone")
            try? await Task.sleep(for: .milliseconds(Int(hold) + 1000))
            check("click, then Undo", deliveries: delivered().count - before, expected: 0, ["selectedAfterUndo": state.selected?.title ?? "", "pendingAfterUndo": state.pending != nil])

            before = delivered().count
            await press(.enter, "↩")
            await shot("4-held")
            let pressed = Int((state.pending?.started.timeIntervalSince1970 ?? 0) * 1000)
            try? await Task.sleep(for: .milliseconds(Int(hold) + 1200))
            await shot("5-delivered")
            let held = delivered().dropFirst(before)
            check("↩, then wait", deliveries: held.count, expected: 1, ["pressedEpochMs": pressed, "deliveredAfterMs": held.first.map { $0.epochMs - pressed } ?? -1, "log": held.map { $0.line }])
            await settle()

            await open()
            before = delivered().count
            await press(.enter, "↩")
            let first = Int((state.pending?.started.timeIntervalSince1970 ?? 0) * 1000)
            await SafeSendGallery.pause(500)
            await press(.enter, "↩")
            await shot("6-enter-enter")
            try? await Task.sleep(for: .milliseconds(Int(hold) + 1000))
            let now = delivered().dropFirst(before)
            check("↩↩ sends at once", deliveries: now.count, expected: 1, ["firstEnterEpochMs": first, "deliveredAfterMs": now.first.map { $0.epochMs - first } ?? -1, "log": now.map { $0.line }])
            await settle()

            await open()
            before = delivered().count
            await press(.enter, "↩")
            await SafeSendGallery.pause(500)
            await press(.escape, "esc")
            await shot("7-esc-undone")
            await press(.enter, "↩")
            await SafeSendGallery.pause(500)
            await press(.commandZ, "⌘Z")
            await shot("8-cmdz-undone")
            try? await Task.sleep(for: .milliseconds(Int(hold) + 1000))
            check("esc and ⌘Z undo", deliveries: delivered().count - before, expected: 0, ["selected": state.selected?.title ?? ""])
            await settle()

            await open(suggesting: SafeSendGallery.suggestTarget)
            await shot("9-suggested")
            before = delivered().count
            await press(.enter, "↩")
            await shot("10-suggested-window")
            let suggestedAt = Int((state.pending?.started.timeIntervalSince1970 ?? 0) * 1000)
            let suggestedPending = state.pending?.target.title ?? ""
            try? await Task.sleep(for: .milliseconds(Int(hold) + 1200))
            let suggested = delivered().dropFirst(before)
            check("confident suggestion, ↩", deliveries: suggested.count, expected: 1, ["shownAs": state.suggestion.rawValue, "pendingTarget": suggestedPending, "deliveredAfterMs": suggested.first.map { $0.epochMs - suggestedAt } ?? -1, "log": suggested.map { $0.line }])
            await settle()

            await open()
            before = delivered().count
            await press(.enter, "↩")
            await SafeSendGallery.pause(1000)
            await shot("11-before-close")
            let closedAt = Int(Date().timeIntervalSince1970 * 1000)
            picker.close()
            SafeSendGallery.note("panel closed during the undo window")
            try? await Task.sleep(for: .milliseconds(Int(hold) + 2000))
            let closed = delivered().dropFirst(before)
            check("panel closed during the window", deliveries: closed.count, expected: 1, ["closedEpochMs": closedAt, "deliveredAfterCloseMs": closed.first.map { $0.epochMs - closedAt } ?? -1, "panelOpen": picker.isOpen, "log": closed.map { $0.line }])
        }

        mutating func check(_ name: String, deliveries: Int, expected: Int, _ extra: [String: Any] = [:]) {
            var row = extra
            row["scheme"] = scheme
            row["check"] = name
            row["deliveries"] = deliveries
            row["expected"] = expected
            row["passed"] = deliveries == expected
            checks.append(row)
            SafeSendGallery.note("check \(name)", ["deliveries": deliveries, "expected": expected])
        }

        func open(suggesting word: String? = nil) async {
            let started = ContinuousClock.now
            state.reset(with: finished)
            let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            let size = TargetPickerController.size
            picker.prepare()
            await model.loadTargets(pressedAt: started)
            picker.open(near: CGPoint(x: visible.midX - size.width / 2 - 12, y: visible.midY + size.height / 2 + 12))
            NSApp.activate()
            if let word, let key = state.targets.first(where: { $0.title.lowercased().contains(word) })?.key {
                state.suggest(key)
            }
            SafeSendGallery.note("picker open", ["scheme": scheme, "selected": state.selected?.title ?? "", "suggestion": state.suggestion.rawValue])
            await SafeSendGallery.pause(900)
        }

        func settle() async {
            await SafeSendGallery.pause(2200)
            picker.close()
            await SafeSendGallery.pause(400)
        }

        func press(_ key: PickerKey, _ label: String) async {
            picker.post(key)
            await SafeSendGallery.pause(260)
            SafeSendGallery.note("key \(label)", ["selected": state.selected?.title ?? "", "pending": state.pending?.target.title ?? ""])
        }

        private func screenPoint(_ frame: CGRect) -> CGPoint? {
            guard let panel = picker.frame else { return nil }
            let height = NSScreen.screens.first?.frame.height ?? 0
            return CGPoint(x: panel.minX + frame.midX, y: height - (panel.maxY - frame.midY))
        }

        private var signature: String {
            "\(state.selection)|\(state.pending?.target.key ?? "")|\(state.delivering)|\(state.confirmation ?? "")"
        }

        func click(_ name: String) async {
            let key = name == "undo" ? "undo" : state.filtered.first { $0.title.lowercased().contains(name) }?.key
            guard let key, let frame = state.frames[key], let point = screenPoint(frame) else {
                SafeSendGallery.note("click \(name): not found")
                return
            }
            let height = NSScreen.screens.first?.frame.height ?? 0
            let mouse = NSEvent.mouseLocation
            let from = CGPoint(x: mouse.x, y: height - mouse.y)
            for step in 1...18 {
                let f = Double(step) / 18
                let e = f * f * (3 - 2 * f)
                let p = CGPoint(x: from.x + (point.x - from.x) * e, y: from.y + (point.y - from.y) * e)
                CGWarpMouseCursorPosition(p)
                CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
                try? await Task.sleep(for: .milliseconds(Int(22 * SafeSendGallery.pace)))
            }
            await SafeSendGallery.pause(250)
            let before = signature
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(70))
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(300))
            var via = "mouse"
            if signature == before {
                via = "direct"
                if key == "undo" {
                    state.undo()
                } else if let index = state.filtered.firstIndex(where: { $0.key == key }) {
                    state.select(index)
                    state.choose(.paste)
                }
            }
            SafeSendGallery.note("click \(name)", ["via": via, "selected": state.selected?.title ?? "", "pending": state.pending?.target.title ?? ""])
        }

        mutating func shot(_ name: String) async {
            await SafeSendGallery.pause(450)
            let file = "safe-send-\(scheme)-\(name).png"
            try? picker.snapshot()?.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(file))
            shots.append([
                "file": file,
                "selected": state.selected?.title ?? "",
                "suggested": state.suggestedKey ?? "",
                "pending": state.pending?.target.title ?? "",
                "confirmation": state.confirmation ?? "",
                "deliveriesSoFar": delivered().count,
            ])
            SafeSendGallery.note("shot \(name)")
        }
    }
}
