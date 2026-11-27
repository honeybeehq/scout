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
        case "typing-matrix":
            if let scheme = argument("typing-scheme") { NSApp.appearance = NSAppearance(named: scheme == "light" ? .aqua : .darkAqua) }
            let methods = (argument("typing-methods") ?? "cgevent,cgevent-hid,postevent").split(separator: ",").map(String.init)
            var rows: [[String: Any]] = []
            guard await drill.record() else { break }
            await waitFor(3) { model.picker.model.source != .loading }
            try? await Task.sleep(for: .milliseconds(700))
            for method in methods { rows += await drill.matrix(method, picker: "stop") }
            drill.press("postevent", .escape)
            await waitFor(30) { model.lastWalkthrough != nil }
            try? await Task.sleep(for: .seconds(2))
            for method in methods {
                model.sendLastWalkthrough()
                await waitFor(3) { model.picker.model.source != .loading }
                try? await Task.sleep(for: .milliseconds(700))
                rows += await drill.matrix(method, picker: "send-menu")
                drill.press("postevent", .escape)
                try? await Task.sleep(for: .seconds(1))
            }
            report["matrix"] = rows
            report["suggestState"] = model.suggestions.state
            report["passed"] = rows.allSatisfy { $0["pass"] as? Bool == true }
        case "typing":
            var probes: [[String: Any]] = []
            guard await drill.record() else { break }
            await waitFor(3) { model.picker.model.source != .loading }
            try? await Task.sleep(for: .milliseconds(700))
            probes.append(await drill.typeProbe("finishing-1s"))
            try? await Task.sleep(for: .seconds(2))
            probes.append(await drill.typeProbe("finishing-3s"))
            model.picker.post(.escape)
            await waitFor(30) { model.lastWalkthrough != nil }
            try? await Task.sleep(for: .seconds(2))
            model.sendLastWalkthrough()
            await waitFor(3) { model.picker.model.source != .loading }
            try? await Task.sleep(for: .milliseconds(700))
            probes.append(await drill.typeProbe("send-menu"))
            model.picker.post(.escape)
            report["probes"] = probes
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

        static let codes: [Character: CGKeyCode] = ["a": 0, "s": 1, "z": 6, "x": 7, "c": 8, "r": 15, "y": 16, "t": 17, "o": 31, "i": 34, "p": 35, "l": 37]

        func press(_ method: String, _ key: PickerKey) {
            switch method {
            case "postevent":
                picker.post(key)
            default:
                let source = method == "cgevent-hid" ? CGEventSource(stateID: .hidSystemState) : nil
                let pid = ProcessInfo.processInfo.processIdentifier
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: source, virtualKey: key.code, keyDown: down)
                    if key.modifiers.contains(.command) { event?.flags = .maskCommand }
                    event?.postToPid(pid)
                }
            }
        }

        func type(_ method: String, _ text: String) async {
            for character in text {
                press(method, method == "postevent" ? .character(character) : PickerKey(code: Self.codes[character] ?? 0, characters: String(character)))
                try? await Task.sleep(for: .milliseconds(30))
            }
            try? await Task.sleep(for: .milliseconds(350))
        }

        func matrix(_ method: String, picker name: String) async -> [[String: Any]] {
            let model = picker.model
            var rows: [[String: Any]] = []
            func check(_ step: String, expect query: String, pending: Bool = false) {
                let pass = model.query == query && (model.pending != nil) == pending
                rows.append(["method": method, "picker": name, "case": step, "expect": query, "query": model.query, "pending": model.pending != nil, "selected": model.selected?.title ?? "", "pass": pass, "offer": "\(model.offer)", "suggestion": "\(model.suggestion)", "key": picker.windowState["key"] ?? "", "firstResponder": picker.windowState["firstResponder"] ?? "", "appActive": NSApp.isActive, "frontmost": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""])
                shot("matrix-\(name)-\(method)-\(step)")
                note("matrix \(name) \(method) \(step)", ["query": model.query, "pass": pass])
            }
            await type(method, "poly")
            check("type", expect: "poly")
            press(method, .enter)
            try? await Task.sleep(for: .milliseconds(300))
            await type(method, "x")
            check("undo-window", expect: "poly", pending: true)
            press(method, .escape)
            try? await Task.sleep(for: .milliseconds(300))
            await type(method, "z")
            check("after-undo", expect: "polyz")
            model.query = ""
            try? await Task.sleep(for: .milliseconds(200))
            if let late = model.filtered.dropFirst(2).first?.key {
                model.suggest(late)
                try? await Task.sleep(for: .milliseconds(200))
                await type(method, "scout")
                check("late-highlight", expect: "scout")
            }
            model.query = ""
            try? await Task.sleep(for: .milliseconds(200))
            return rows
        }

        func typeProbe(_ name: String) async -> [String: Any] {
            let codes: [Character: CGKeyCode] = ["a": 0, "p": 35, "i": 34, "r": 15, "y": 16]
            var row: [String: Any] = ["probe": name, "before": picker.windowState, "appActive": NSApp.isActive, "frontmost": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "", "queryBefore": picker.model.query]
            let pid = ProcessInfo.processInfo.processIdentifier
            for character in "apiary" {
                guard let code = codes[character] else { continue }
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
                    event?.postToPid(pid)
                    try? await Task.sleep(for: .milliseconds(25))
                }
            }
            try? await Task.sleep(for: .milliseconds(400))
            row["queryAfter"] = picker.model.query
            row["rowsAfter"] = picker.model.matchCount
            row["after"] = picker.windowState
            shot("typing-\(name)")
            note("typing probe \(name)", ["query": picker.model.query, "key": picker.windowState["key"] ?? ""])
            picker.model.query = ""
            try? await Task.sleep(for: .milliseconds(200))
            return row
        }

        func shot(_ name: String) {
            try? picker.snapshot()?.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("picker-\(name).png"))
        }

        func menu(_ name: String) {
            PanelGallery.render(MenuBarPanel().environment(model), scheme: .dark, to: output.appendingPathComponent("menu-\(name).png"))
        }
    }
}
