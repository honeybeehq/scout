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

    private static var misclick: String { argument("safe-send-misclick") ?? "apiary" }

    private static var outsider: String { argument("safe-send-outsider") ?? "polytext" }

    private static var events: [[String: Any]] = []
    private static let began = Date()

    private static func note(_ text: String, _ extra: [String: Any] = [:]) {
        var row = extra
        row["t"] = Int(Date().timeIntervalSince(began) * 1000)
        row["epochMs"] = Int(Date().timeIntervalSince1970 * 1000)
        row["event"] = text
        events.append(row)
    }

    static func run(model: AppModel, into directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let variant = SafeSendVariant.current
        var report: [String: Any] = ["variant": variant.rawValue, "schemes": schemes, "pace": pace, "undoSeconds": SafeSendVariant.undoSeconds, "trusted": AXIsProcessTrusted()]
        defer {
            report["events"] = events
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: directory.appendingPathComponent("safe-send-\(variant.rawValue).json"))
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
            NSApp.appearance = NSAppearance(named: scheme == "light" ? .aqua : .darkAqua)
            var driver = Driver(model: model, finished: finished, scheme: scheme, directory: directory, variant: variant)
            shots += await driver.flow()
        }
        report["shots"] = shots
        report["targets"] = model.picker.model.targets.map { ["key": $0.key, "title": $0.title, "workspace": $0.workspaceLabel ?? "", "open": $0.open] }
    }

    private static func pause(_ milliseconds: Double) async {
        try? await Task.sleep(for: .milliseconds(Int(milliseconds * pace)))
    }

    private struct Driver {
        var model: AppModel
        var finished: FinishedWalkthrough
        var scheme: String
        var directory: URL
        var variant: SafeSendVariant
        var shots: [[String: Any]] = []

        var picker: TargetPickerController { model.picker }
        var state: TargetPickerModel { model.picker.model }

        mutating func flow() async -> [[String: Any]] {
            switch variant {
            case .select:
                await open()
                await shot("1-suggested")
                await click(SafeSendGallery.misclick)
                await shot("2-armed")
                await click(SafeSendGallery.misclick)
                await shot("3-sent")
                await settle()
                await open()
                await press(.enter, "↩")
                await shot("4-enter-sent")
                await settle()
            case .undo:
                await open()
                await shot("1-suggested")
                await click(SafeSendGallery.misclick)
                await SafeSendGallery.pause(700)
                await shot("2-undo-window")
                await click("undo")
                await shot("3-undone")
                while state.selection != 0, state.pending == nil {
                    await press(.up, "↑")
                }
                await press(.enter, "↩")
                await SafeSendGallery.pause(500)
                await shot("4-enter-window")
                await SafeSendGallery.pause(SafeSendVariant.undoSeconds * 1000)
                await shot("5-sent")
                await settle()
            case .unusual:
                await open()
                await shot("1-suggested")
                await click(SafeSendGallery.misclick)
                await shot("2-usual-sent")
                await settle()
                await open()
                await click(SafeSendGallery.outsider)
                await shot("3-confirm")
                await click(SafeSendGallery.outsider)
                await shot("4-sent")
                await settle()
                await open()
                await press(.enter, "↩")
                await shot("5-enter-sent")
                await settle()
            case .off:
                await open()
                await shot("1-open")
                await click(SafeSendGallery.misclick)
                await shot("2-sent")
                await settle()
            }
            return shots
        }

        func open() async {
            let started = ContinuousClock.now
            state.reset()
            let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            let size = TargetPickerController.size
            picker.prepare()
            picker.open(near: CGPoint(x: visible.midX - size.width / 2 - 12, y: visible.midY + size.height / 2 + 12))
            NSApp.activate()
            SafeSendGallery.note("recording finished, picker open", ["scheme": scheme])
            await model.loadTargets(pressedAt: started)
            await SafeSendGallery.pause(900)
            state.ready(finished)
            SafeSendGallery.note("walkthrough ready", ["selected": state.selected?.title ?? ""])
            await SafeSendGallery.pause(900)
        }

        func settle() async {
            await SafeSendGallery.pause(2600)
            picker.close()
            await SafeSendGallery.pause(400)
        }

        func press(_ key: PickerKey, _ label: String) async {
            picker.post(key)
            SafeSendGallery.note("key \(label)", ["selected": state.selected?.title ?? ""])
            await SafeSendGallery.pause(260)
        }

        private func screenPoint(_ frame: CGRect) -> CGPoint? {
            guard let panel = picker.frame else { return nil }
            let height = NSScreen.screens.first?.frame.height ?? 0
            return CGPoint(x: panel.minX + frame.midX, y: height - (panel.maxY - frame.midY))
        }

        private var signature: String {
            "\(state.selection)|\(state.armed ?? "")|\(state.pending?.target.key ?? "")|\(state.delivering)|\(state.confirmation ?? "")|\(state.queued.map(\.rawValue) ?? "")"
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
                    state.tap(index)
                }
            }
            SafeSendGallery.note("click \(name)", ["via": via, "selected": state.selected?.title ?? "", "armed": state.armed ?? "", "pending": state.pending?.target.title ?? "", "confirmation": state.confirmation ?? ""])
        }

        mutating func shot(_ name: String) async {
            await SafeSendGallery.pause(450)
            let file = "safe-send-\(variant.rawValue)-\(scheme)-\(name).png"
            try? picker.snapshot()?.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(file))
            shots.append([
                "file": file,
                "selected": state.selected?.title ?? "",
                "suggested": state.suggested?.title ?? "",
                "armed": state.armed ?? "",
                "pending": state.pending?.target.title ?? "",
                "confirmation": state.confirmation ?? "",
                "delivering": state.delivering,
            ])
            SafeSendGallery.note("shot \(name)")
        }
    }
}
