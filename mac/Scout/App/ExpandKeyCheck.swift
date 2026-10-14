import AppKit
import SwiftUI
import Carbon.HIToolbox
import ScoutCore

enum ExpandKeyCheck {
    private static func argument(_ name: String) -> String? {
        let prefix = "--\(name)="
        return ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    static var outputDirectory: URL? {
        argument("expand-key-check").map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func run(model: AppModel, output: URL) async {
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var report: [String: Any] = [
            "accessibilityTrusted": AXIsProcessTrusted(),
            "postEventAccess": CGPreflightPostEventAccess(),
            "screenRecordingGranted": CGPreflightScreenCaptureAccess(),
        ]
        defer {
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: output.appendingPathComponent("report.json"))
            }
            NSApp.terminate(nil)
        }
        try? await Task.sleep(for: .seconds(1))
        let window = TextFieldWindow()
        window.open()
        try? await Task.sleep(for: .milliseconds(400))
        report["fieldFocusedBeforeRecording"] = window.isFieldFocused

        model.simulatedInput = argument("expand-key-audio").map { URL(fileURLWithPath: $0) }
        model.onSessionCreated = { session in session.follower.resolver.include(CGWindowID(window.window.windowNumber)) }
        CGWarpMouseCursorPosition(window.center)
        model.triggerHotkey(at: InteractionTimings.now)
        try? await Task.sleep(for: .seconds(1.5))
        guard let session = model.session else {
            report["error"] = "no session"
            return
        }
        report["recording"] = model.isScouting
        report["windows"] = NSApp.windows.filter(\.isVisible).map { "\(type(of: $0)) \(NSStringFromRect($0.frame)) alpha \($0.alphaValue)" }
        report["hotkeysWhileRecording"] = [
            "widen": ["shortcut": model.widenShortcut.label, "registered": model.scopeHotkeys?.widen.isRegistered ?? false],
            "follow": ["shortcut": model.followShortcut.label, "registered": model.scopeHotkeys?.follow.isRegistered ?? false],
        ]
        report["bareKeysThroughPinTap"] = bareKeysThroughPinTap()

        window.focusField()
        try? await Task.sleep(for: .milliseconds(200))
        report["fieldFocusedWhileRecording"] = window.isFieldFocused
        report["bareKeyPath"] = await typeKeys([(UInt16(kVK_ANSI_E), []), (UInt16(kVK_ANSI_E), .shift), (UInt16(kVK_ANSI_E), [])], into: window)
        try? await Task.sleep(for: .milliseconds(300))
        report["fieldAfterBareKeys"] = window.text
        snapshot(window: window.window, name: "field-after-bare-e", into: output)
        snapshotPill(model, name: "pill-following", into: output)

        var steps: [[String: Any]] = []
        for follow in [false, false, false, true] {
            let before = session.capture.scopes.count
            let pressedBefore = GlobalHotkey.lastPressTime
            let path = await CaptureUXDemo.pressScopeKey(model: model, follow: follow)
            try? await Task.sleep(for: .milliseconds(500))
            let change = session.capture.scopes.count > before ? session.capture.scopes.last : nil
            steps.append([
                "key": follow ? model.followShortcut.label : model.widenShortcut.label,
                "path": path,
                "handlerCalled": GlobalHotkey.lastPressTime != pressedBefore,
                "scopeChanges": session.capture.scopes.count - before,
                "scope": change?.scope.rawValue ?? "",
                "byUser": change?.byUser ?? false,
                "bounds": change.map { [$0.bounds.x, $0.bounds.y, $0.bounds.width, $0.bounds.height] } ?? [],
            ])
            if !follow, steps.count == 1 { snapshotPill(model, name: "pill-locked", into: output) }
        }
        report["scopeKeys"] = steps
        report["fieldAfterScopeKeys"] = window.text
        ViewShot.write(KeepBothBubble(), to: output.appendingPathComponent("keep-both-bubble.png"))

        model.triggerHotkey(at: InteractionTimings.now)
        try? await Task.sleep(for: .seconds(1))
        report["hotkeysAfterFinish"] = [
            "widen": model.scopeHotkeys?.widen.isRegistered ?? false,
            "follow": model.scopeHotkeys?.follow.isRegistered ?? false,
        ]
        report["recordingAfterFinish"] = model.isScouting
        window.close()
    }

    private static func bareKeysThroughPinTap() -> [[String: Any]] {
        let tap = PinEventTap { _ in }
        tap.setAiming(true)
        let cases: [(String, CGEventFlags)] = [("e", []), ("⇧e", .maskShift), ("⌥e", .maskAlternate)]
        return cases.map { name, flags in
            let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_E), keyDown: true)!
            event.flags = flags
            return ["key": name, "swallowed": tap.handle(.keyDown, event)]
        }
    }

    private static func typeKeys(_ keys: [(UInt16, NSEvent.ModifierFlags)], into window: TextFieldWindow) async -> String {
        if CGPreflightPostEventAccess() {
            for (key, modifiers) in keys {
                CaptureUXDemo.postKey(key, flags: modifiers.contains(.shift) ? .maskShift : [])
                try? await Task.sleep(for: .milliseconds(60))
            }
            return "CGEvent posted to the HID event tap"
        }
        for (key, modifiers) in keys {
            let characters = modifiers.contains(.shift) ? "E" : "e"
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: "e", isARepeat: false, keyCode: key) else { continue }
                NSApp.sendEvent(event)
            }
            try? await Task.sleep(for: .milliseconds(60))
        }
        return "NSEvent sent through NSApplication.sendEvent (posting system key events needs Accessibility, which this build does not have)"
    }

    private static func snapshot(window: NSWindow, name: String, into directory: URL, backdrop: NSColor? = nil) {
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        var output = rep
        if let backdrop, let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
            backdrop.setFill()
            NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh).fill()
            rep.draw(in: NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            output = canvas
        }
        try? output.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
    }

    private static func snapshotPill(_ model: AppModel, name: String, into directory: URL) {
        ViewShot.write(ScoutingPill().environment(model).frame(width: HUDController.pillSize.width, height: HUDController.pillSize.height), to: directory.appendingPathComponent("\(name).png"))
    }
}

@MainActor
private final class TextFieldWindow {
    let window: NSWindow
    private let field = NSTextField(string: "")

    init() {
        window = NSWindow(contentRect: CGRect(x: 240, y: 360, width: 520, height: 160), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Search (S7 test window)"
        window.isReleasedWhenClosed = false
        let label = NSTextField(labelWithString: "Type here while recording")
        label.frame = CGRect(x: 24, y: 100, width: 472, height: 20)
        field.frame = CGRect(x: 24, y: 52, width: 472, height: 32)
        field.font = .systemFont(ofSize: 18)
        field.placeholderString = "Search"
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 520, height: 160))
        content.addSubview(label)
        content.addSubview(field)
        window.contentView = content
    }

    var text: String { field.stringValue }

    var center: CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 1080
        return CGPoint(x: window.frame.midX, y: primaryHeight - window.frame.midY)
    }

    var isFieldFocused: Bool {
        window.isKeyWindow && (window.firstResponder === field || window.firstResponder === field.currentEditor())
    }

    func open() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        focusField()
    }

    func focusField() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)
    }

    func close() {
        window.close()
    }
}

enum ViewShot {
    static func write(_ view: some View, to url: URL, padding: CGFloat = 12) {
        let renderer = ImageRenderer(content: view.padding(padding).background(Color(red: 0.11, green: 0.12, blue: 0.14)).environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let image = renderer.cgImage else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }
}
