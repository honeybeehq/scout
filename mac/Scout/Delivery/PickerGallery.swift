import AppKit
import SwiftUI

final class PickerProtoHost {
    let model: PickerProtoModel
    let panel: PickerPanel
    private var monitor: Any?
    var onExit: (() -> Void)?

    init(variant: PickerVariant) {
        model = PickerProtoModel(variant: variant, entries: PickerFixture.entries)
        let size = variant.size
        panel = PickerPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: PickerVariantView().environment(model))
        host.sizingOptions = []
        panel.contentView = host
    }

    func show(appearance: NSAppearance?) {
        if let appearance {
            NSApp.appearance = appearance
            panel.appearance = appearance
        }
        let size = model.variant.size
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrame(CGRect(x: (visible.midX - size.width / 2).rounded(), y: (visible.midY - size.height / 2).rounded(), width: size.width, height: size.height), display: true)
        NSApp.activate()
        panel.orderFrontRegardless()
        panel.makeKey()
        model.focusToken += 1
        listen()
    }

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        panel.orderOut(nil)
    }

    func post(_ key: PickerKey) {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: key.modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber,
            context: nil,
            characters: key.characters,
            charactersIgnoringModifiers: key.characters,
            isARepeat: false,
            keyCode: key.code
        )
        if let event { NSApp.postEvent(event, atStart: false) }
    }

    func snapshot(to url: URL) -> String {
        panel.displayIfNeeded()
        if let image = SnapshotMode.windowImage(CGWindowID(panel.windowNumber)) {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
            return "window"
        }
        guard let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return "none" }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        return "cache"
    }

    private func listen() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel || event.windowNumber == self.panel.windowNumber else { return event }
            let model = self.model
            if model.confirmation != nil { return nil }
            switch event.keyCode {
            case 125:
                model.vertical(1)
            case 126:
                model.vertical(-1)
            case 123:
                return model.horizontal(-1) ? nil : event
            case 124:
                return model.horizontal(1) ? nil : event
            case 48:
                model.tab(event.modifierFlags.contains(.shift) ? -1 : 1)
            case 36, 76:
                model.choose(send: event.modifierFlags.contains(.command))
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(1400))
                    self?.model.confirmation = nil
                }
            case 53:
                self.onExit?()
            default:
                return event
            }
            return nil
        }
    }
}

extension PickerKey {
    static let left = PickerKey(code: 123, characters: String(UnicodeScalar(NSLeftArrowFunctionKey)!))
    static let right = PickerKey(code: 124, characters: String(UnicodeScalar(NSRightArrowFunctionKey)!))
    static let tab = PickerKey(code: 48, characters: "\t")
}

enum PickerGallery {
    static var directory: URL? {
        let prefix = "--picker-variants="
        return ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }.map { URL(fileURLWithPath: String($0.dropFirst(prefix.count)), isDirectory: true) }
    }

    static var live: PickerVariant? {
        let prefix = "--picker-live="
        return ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }.flatMap { PickerVariant(rawValue: String($0.dropFirst(prefix.count))) }
    }

    static var requested: Bool { directory != nil || live != nil }

    static let searchTerm = "scout"

    private static var liveHost: PickerProtoHost?

    static func start() {
        if let directory {
            Task { await run(into: directory) }
        } else if let live {
            let host = PickerProtoHost(variant: live)
            host.onExit = { NSApp.terminate(nil) }
            liveHost = host
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                host.show(appearance: nil)
            }
        }
    }

    static func run(into directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? await Task.sleep(for: .milliseconds(400))
        let shots = ShotLog()
        let only = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--picker-only=") }.flatMap { PickerVariant(rawValue: String($0.dropFirst("--picker-only=".count))) }
        let avatars = PickerFixture.entries.compactMap(\.avatarID).map { [$0: PickerAvatars.image($0) != nil] }
        for variant in PickerVariant.allCases where only == nil || only == variant {
            for scheme in ["light", "dark"] {
                let host = PickerProtoHost(variant: variant)
                host.show(appearance: NSAppearance(named: scheme == "dark" ? .darkAqua : .aqua))
                try? await Task.sleep(for: .milliseconds(600))
                func shot(_ state: String, _ keys: [String]) async {
                    await capture(host, variant: variant, scheme: scheme, state: state, keys: keys, into: directory, log: shots)
                }
                await shot("1-open", [])
                for character in searchTerm { host.post(.character(character)) }
                try? await Task.sleep(for: .milliseconds(250))
                var typed = Array(searchTerm).map(String.init)
                if host.model.query != searchTerm {
                    typed.append("fallback: query set directly, typed text was “\(host.model.query)”")
                    host.model.query = searchTerm
                }
                await shot("2-search", typed)
                host.post(.down)
                host.post(.down)
                await shot("3-search-down2", ["↓", "↓"])
                host.model.query = ""
                try? await Task.sleep(for: .milliseconds(150))
                switch variant {
                case .palette:
                    for _ in 0..<4 { host.post(.down) }
                    await shot("4-keyboard", ["↓", "↓", "↓", "↓"])
                case .sections:
                    for _ in 0..<2 { host.post(.down) }
                    await shot("4-keyboard", ["↓", "↓"])
                    host.post(.tab)
                    host.post(.down)
                    await shot("5-next-group", ["⇥", "↓"])
                case .recent:
                    host.post(.right)
                    await shot("4-keyboard", ["→"])
                    host.post(.down)
                    host.post(.down)
                    await shot("5-keyboard-list", ["↓", "↓"])
                    host.post(.tab)
                    host.post(.tab)
                    await shot("6-scope-projects", ["⇥", "⇥"])
                }
                host.post(.enter)
                await shot("9-chosen", ["↩"])
                host.close()
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        let report: [String: Any] = ["shots": shots.rows, "avatars": avatars, "searchTerm": searchTerm]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("picker-variants.json"))
        }
        NSApp.terminate(nil)
    }

    private static func capture(_ host: PickerProtoHost, variant: PickerVariant, scheme: String, state: String, keys: [String], into directory: URL, log: ShotLog) async {
        try? await Task.sleep(for: .milliseconds(450))
        let name = "picker-\(variant.rawValue)-\(scheme)-\(state).png"
        let method = host.snapshot(to: directory.appendingPathComponent(name))
        let model = host.model
        log.rows.append([
            "file": name,
            "variant": variant.rawValue,
            "scheme": scheme,
            "state": state,
            "keys": keys,
            "capture": method,
            "query": model.query,
            "scope": model.scope.rawValue,
            "inStrip": model.inStrip && model.showsStrip,
            "selected": model.selected?.title ?? "",
            "selectedKind": model.selected?.kindLabel ?? "",
            "confirmation": model.confirmation ?? "",
            "visibleRows": model.flat.count,
            "isKeyWindow": host.panel.isKeyWindow,
        ])
    }
}

final class ShotLog {
    var rows: [[String: Any]] = []
}
