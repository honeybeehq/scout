import AppKit
import ScoutCore
import SwiftUI

enum PickerGallery {
    static var directory: URL? {
        argument("picker-gallery").map { URL(fileURLWithPath: $0, isDirectory: true) }
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

    static func run(model: AppModel, into directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var report: [String: Any] = ["schemes": schemes, "pace": pace]
        defer {
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: directory.appendingPathComponent("picker-gallery.json"))
            }
            NSApp.terminate(nil)
        }
        guard let folder = argument("picker-walkthrough"),
              let data = FileManager.default.contents(atPath: folder + "/" + WalkthroughBundle.entryName),
              let walkthrough = try? JSONDecoder().decode(Walkthrough.self, from: data)
        else {
            report["error"] = "pass --picker-walkthrough=<folder with walkthrough.json>"
            return
        }
        let finished = FinishedWalkthrough(directory: URL(fileURLWithPath: folder, isDirectory: true), walkthrough: walkthrough, timings: [:])
        try? await Task.sleep(for: .milliseconds(600))
        var shots: [[String: Any]] = []
        for scheme in schemes {
            let appearance = NSAppearance(named: scheme == "light" ? .aqua : .darkAqua)
            NSApp.appearance = appearance
            shots += await drive(model: model, finished: finished, scheme: scheme, appearance: appearance, into: directory)
        }
        report["shots"] = shots
        report["targets"] = model.picker.model.targets.map(describe)
        report["bridgeLog"] = await model.apiary.log
    }

    private static func describe(_ target: ApiaryTarget) -> [String: Any] {
        var row: [String: Any] = ["key": target.key, "title": target.title, "sessionId": target.sessionID ?? "", "viaApiary": target.viaApiary, "state": target.state ?? ""]
        if let look = target.look {
            row["look"] = look.key
            if let avatar = LookStore.shared.avatar(look) {
                row["avatarScale"] = (avatar.scale * 1000).rounded() / 1000
                row["bodyOfFrame"] = (avatar.body * 1000).rounded() / 1000
            } else if look.iconSvg != nil {
                row["icon"] = "svg"
            }
        } else {
            row["look"] = "none"
        }
        return row
    }

    private static func render(_ view: some View, scheme: String, to url: URL) {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme == "light" ? .light : .dark))
        renderer.scale = 2
        guard let image = renderer.cgImage else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func pause(_ milliseconds: Double) async {
        try? await Task.sleep(for: .milliseconds(Int(milliseconds * pace)))
    }

    private static func drive(model: AppModel, finished: FinishedWalkthrough, scheme: String, appearance: NSAppearance?, into directory: URL) async -> [[String: Any]] {
        let picker = model.picker
        let state = picker.model
        var shots: [[String: Any]] = []
        func press(_ key: PickerKey, _ times: Int = 1) async {
            for _ in 0..<times {
                picker.post(key)
                await pause(220)
            }
        }
        func shot(_ name: String, _ keys: [String], fallback: String? = nil) async {
            await pause(450)
            let file = "picker-\(scheme)-\(name).png"
            try? picker.snapshot()?.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(file))
            let group = state.sections.last { $0.start <= state.selection }?.group.rawValue ?? ""
            var row: [String: Any] = [
                "file": file,
                "keys": keys,
                "query": state.query,
                "selected": state.selected.map { "\($0.key) \($0.title)" } ?? "",
                "selectedGroup": group,
                "sections": state.sections.map { "\($0.group.title) \($0.rows.count)" },
                "canPaste": state.canPaste,
                "source": String(describing: state.source),
                "confirmation": state.confirmation ?? "",
                "keyWindow": NSApp.keyWindow is PickerPanel,
            ]
            if let fallback { row["fallback"] = fallback }
            shots.append(row)
        }
        let started = ContinuousClock.now
        state.reset(with: finished)
        await model.loadTargets(pressedAt: started)
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = TargetPickerController.size
        picker.prepare()
        picker.open(near: CGPoint(x: visible.midX - size.width / 2 - 12, y: visible.midY + size.height / 2 + 12))
        NSApp.activate()
        await pause(500)
        await shot("1-open", [])
        shots[shots.count - 1]["window"] = picker.windowState
        render(VStack(alignment: .leading, spacing: 4) {
            ForEach(state.filtered, id: \.key) { target in
                HStack(spacing: 8) {
                    TargetIcon(target: target)
                    Text(target.title).font(.system(size: 11))
                }
            }
        }.padding(8).background(Palette.hud), scheme: scheme, to: directory.appendingPathComponent("icons-\(scheme).png"))
        for character in "scout" {
            picker.post(.character(character))
            await pause(180)
        }
        await shot("2-search", ["s", "c", "o", "u", "t"], fallback: state.query == "scout" ? nil : "typed text arrived as “\(state.query)”")
        await press(.down, 2)
        await shot("3-search-arrow", ["↓", "↓"])
        await press(.delete, 5)
        let cleared = state.query.isEmpty
        if !cleared { state.query = "" }
        await press(.down, 2)
        await shot("4-keyboard", ["⌫×5", "↓", "↓"], fallback: cleared ? nil : "query cleared directly")
        var tabs = 0
        while state.sections.last(where: { $0.start <= state.selection })?.group != .projects, tabs < state.sections.count {
            await press(.tab)
            tabs += 1
        }
        await shot("5-tab-projects", Array(repeating: "⇥", count: tabs))
        await press(.tab)
        if let sessions = state.sections.first(where: { $0.group == .sessions }), let fallback = sessions.rows.firstIndex(where: { $0.look == nil }) {
            await press(.down, fallback)
        }
        await shot("6-fallback", ["⇥", "↓"])
        await press(.enter)
        await pause(300)
        await shot("7-chosen", ["↩"])
        await pause(1600)
        return shots
    }
}
