import AppKit
import ScoutCore
import SwiftUI

enum QueuedSendDrill {
    static var fixture: URL? {
        guard !ScoutDataRoot.current.isRelease else { return nil }
        return argument("queued-send-drill").map { URL(fileURLWithPath: $0) }
    }

    private static func argument(_ name: String) -> String? {
        let prefix = "--\(name)="
        return ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    private static var scenario: String { argument("queued-send-scenario") ?? "drop" }
    private static var queuedTarget: String { argument("queued-send-target") ?? "apiary" }
    private static var otherTarget: String { argument("queued-send-other") ?? "polytext" }
    private static var deliveryLog: URL? { argument("queued-send-log").map { URL(fileURLWithPath: $0) } }

    private static var events: [[String: Any]] = []
    private static let began = Date()

    private static func note(_ text: String, _ extra: [String: Any] = [:]) {
        var row = extra
        row["t"] = Int(Date().timeIntervalSince(began) * 1000)
        row["epochMs"] = Int(Date().timeIntervalSince1970 * 1000)
        row["event"] = text
        events.append(row)
        NSLog("[scout-drill] %@", text)
    }

    private static func delivered() -> [String] {
        guard let deliveryLog, let text = try? String(contentsOf: deliveryLog, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    private static func waitFor(_ seconds: Double, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    static func run(model: AppModel, fixtureURL: URL) async {
        let output = SimulationMode.outputDirectory
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var report: [String: Any] = ["scenario": scenario, "fixture": fixtureURL.path, "undoSeconds": TargetPickerModel.undoSeconds, "deliveriesAtStart": delivered()]
        func write() {
            report["events"] = events
            report["deliveries"] = delivered()
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: output.appendingPathComponent("queued-send-\(scenario).json"))
            }
        }
        guard let fixture = try? WalkthroughFixture.load(fixtureURL) else {
            report["error"] = "fixture"
            write()
            NSApp.terminate(nil)
            return
        }
        try? await Task.sleep(for: .seconds(1))
        let drill = Drill(model: model, audio: fixture.audio, output: output)
        func unsentReport() -> [[String: Any]] {
            model.unsent.map { ["walkthrough": $0.id, "reason": $0.reason, "folderExists": FileManager.default.fileExists(atPath: $0.directory.path)] }
        }
        switch scenario {
        case "typing":
            TargetPickerController.traceFile = output.appendingPathComponent("keys.jsonl")
            let rounds = Int(argument("typing-rounds") ?? "") ?? 6
            let hold = Double(argument("typing-hold") ?? "") ?? 25
            var results: [[String: Any]] = []
            for round in 1...rounds {
                let marker = { (name: String) in try? "\(Int(Date().timeIntervalSince1970 * 1000))".write(to: output.appendingPathComponent("\(name)-\(round)"), atomically: true, encoding: .utf8) }
                marker("recording")
                note("typing round \(round): recording")
                guard await drill.record() else { break }
                await waitFor(3) { model.picker.model.source != .loading }
                model.picker.trace("round \(round) ready")
                marker("ready")
                if let text = argument("typing-inapp") {
                    try? await Task.sleep(for: .milliseconds(300))
                    for character in text { model.picker.post(.character(character)) }
                }
                let deadline = Date().addingTimeInterval(hold)
                while Date() < deadline, !FileManager.default.fileExists(atPath: output.appendingPathComponent("done-\(round)").path) {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                drill.shot("typing-\(round)")
                model.picker.trace("round \(round) end")
                results.append(["round": round, "state": model.picker.keyState])
                if model.picker.model.pending != nil { model.picker.model.release() }
                model.picker.model.onDismiss?()
                try? await Task.sleep(for: .milliseconds(1500))
            }
            report["typing"] = results
        case "relaunch":
            report["unsentAtLaunch"] = unsentReport()
            report["unsentFile"] = FileManager.default.fileExists(atPath: UnsentWalkthroughs.file.path)
            drill.menu("1-relaunch")
        case "fail":
            guard let first = await drill.recordAndDismiss() else { break }
            report["first"] = first
            let queued = await drill.recordAndQueue(queuedTarget)
            report["queued"] = queued
            drill.reopenLast()
            await waitFor(3) { model.picker.model.source != .loading }
            await drill.send(otherTarget)
            await waitFor(30) { !model.unsent.isEmpty }
            try? await Task.sleep(for: .seconds(3))
            report["unsentAfterFailure"] = unsentReport()
            drill.menu("3-not-delivered")
            guard let item = model.unsent.first else { break }
            note("send again from the menu", ["walkthrough": item.id])
            model.resend(item)
            await waitFor(3) { model.picker.model.source != .loading }
            drill.shot("4-send-again")
            await drill.send(argument("queued-send-retry") ?? "apiary")
            await waitFor(10) { model.picker.model.confirmation != nil || model.picker.model.problem != nil }
            drill.shot("5-sent-again")
            try? await Task.sleep(for: .seconds(2))
            report["unsentAfterRetry"] = unsentReport()
            drill.menu("6-after-retry")
            report["newLines"] = Array(delivered().dropFirst((report["deliveriesAtStart"] as? [String])?.count ?? 0))
        case "quit":
            guard let first = await drill.recordAndDismiss() else { break }
            report["first"] = first
            let queued = await drill.recordAndQueue(queuedTarget)
            report["queued"] = queued
            drill.reopenLast()
            await waitFor(3) { model.picker.model.source != .loading }
            drill.shot("2-other-picker")
            note("quit with the send queued", ["deliveries": delivered().count])
            report["quitEpochMs"] = Int(Date().timeIntervalSince1970 * 1000)
            write()
            NSApp.terminate(nil)
            return
        default:
            guard let first = await drill.recordAndDismiss() else { break }
            report["first"] = first
            let queued = await drill.recordAndQueue(queuedTarget)
            report["queued"] = queued
            drill.reopenLast()
            await waitFor(3) { model.picker.model.source != .loading }
            drill.shot("2-other-picker")
            await drill.send(otherTarget)
            await waitFor(30) { model.lastWalkthrough?.walkthrough.id == queued["walkthrough"] as? String }
            note("queued recording finished", ["walkthrough": model.lastWalkthrough?.walkthrough.id ?? ""])
            try? await Task.sleep(for: .seconds(4))
            drill.shot("3-after")
            drill.menu("4-menu")
            let lines = delivered().dropFirst((report["deliveriesAtStart"] as? [String])?.count ?? 0)
            report["check"] = [
                "queuedTarget": queuedTarget,
                "otherTarget": otherTarget,
                "queuedDelivered": lines.contains { $0.lowercased().contains(queuedTarget) },
                "otherDelivered": lines.contains { $0.lowercased().contains(otherTarget) },
                "newLines": Array(lines),
            ]
        }
        write()
        NSApp.terminate(nil)
    }

    private struct Drill {
        var model: AppModel
        var audio: URL
        var output: URL

        var picker: TargetPickerController { model.picker }

        func record() async -> Bool {
            var finished = false
            model.startScouting(inputFile: audio, result: .walkthrough) { finished = true }
            guard let session = model.session else { return false }
            await QueuedSendDrill.waitFor(120) { finished }
            note("recorded", ["session": session.id])
            try? await Task.sleep(for: .milliseconds(800))
            model.stopScouting()
            note("stopped", ["finishing": picker.model.phase == .finishing])
            return true
        }

        func recordAndDismiss() async -> String? {
            guard await record() else { return nil }
            await QueuedSendDrill.waitFor(60) { model.lastWalkthrough != nil }
            await QueuedSendDrill.waitFor(3) { picker.model.source != .loading }
            picker.post(.escape)
            try? await Task.sleep(for: .milliseconds(1500))
            note("first recording dismissed", ["walkthrough": model.lastWalkthrough?.walkthrough.id ?? ""])
            return model.lastWalkthrough?.walkthrough.id
        }

        func recordAndQueue(_ name: String) async -> [String: Any] {
            let before = model.lastWalkthrough?.walkthrough.id
            guard await record() else { return [:] }
            await QueuedSendDrill.waitFor(3) { picker.model.source != .loading }
            await pick(name)
            picker.post(.enter)
            await QueuedSendDrill.waitFor(1) { picker.model.pending != nil }
            shot("1-held")
            try? await Task.sleep(for: .milliseconds(400))
            picker.post(.enter)
            try? await Task.sleep(for: .milliseconds(300))
            let finishing = picker.model.phase == .finishing
            let queued = picker.model.queued != nil
            note("released while finishing", ["finishing": finishing, "queued": queued, "selected": picker.model.selected?.title ?? ""])
            shot("1b-queued")
            return ["finishing": finishing, "queued": queued, "previousWalkthrough": before ?? "", "walkthrough": model.pickerWalkthroughID ?? ""]
        }

        func reopenLast() {
            note("open the picker for the previous recording", ["walkthrough": model.lastWalkthrough?.walkthrough.id ?? ""])
            model.sendLastWalkthrough()
        }

        func send(_ name: String) async {
            await pick(name)
            picker.post(.enter)
            await QueuedSendDrill.waitFor(1) { picker.model.pending != nil }
            try? await Task.sleep(for: .milliseconds(300))
            picker.post(.enter)
            note("sent the other recording", ["target": name])
        }

        func pick(_ name: String) async {
            guard let index = picker.model.filtered.firstIndex(where: { $0.title.lowercased().contains(name) }) else {
                note("pick \(name): not in the list")
                return
            }
            var presses = 0
            while picker.model.selection != index, presses < 20 {
                picker.post(.down)
                presses += 1
                try? await Task.sleep(for: .milliseconds(60))
            }
            var via = "↓ × \(presses)"
            if picker.model.selection != index {
                via = "direct"
                picker.model.select(index)
            }
            try? await Task.sleep(for: .milliseconds(150))
            note("picked \(name)", ["via": via, "selected": picker.model.selected?.title ?? ""])
        }

        func shot(_ name: String) {
            try? picker.snapshot()?.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("picker-\(name).png"))
        }

        func menu(_ name: String) {
            PanelGallery.render(MenuBarPanel().environment(model), scheme: .dark, to: output.appendingPathComponent("menu-\(name).png"))
        }
    }
}
