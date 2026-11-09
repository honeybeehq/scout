import AppKit
import CoreGraphics
import SwiftUI

enum SnapshotMode {
    static var directory: URL? {
        let prefix = "--snapshot-dir="
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        return URL(fileURLWithPath: String(argument.dropFirst(prefix.count)), isDirectory: true)
    }

    static func captureSettings(model: AppModel, into directory: URL, pane: SettingsView.Pane) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(1))
        model.openSettingsWindow?()
        try? await Task.sleep(for: .seconds(1.5))
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue.contains("Settings") == true }),
           let image = windowImage(CGWindowID(window.windowNumber)) {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent("settings-\(pane.rawValue).png"))
        }
        await captureMenuBarPanel(model: model, into: directory)
        NSApp.terminate(nil)
    }

    private static func captureMenuBarPanel(model: AppModel, into directory: URL) async {
        let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 10, height: 10), styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = NSColor(Palette.canvas)
        window.sharingType = .readOnly
        let host = NSHostingView(rootView: MenuBarPanel().environment(model))
        window.contentView = host
        window.setContentSize(host.fittingSize)
        window.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(1))
        if let image = windowImage(CGWindowID(window.windowNumber)) {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent("menu-bar.png"))
        }
        window.orderOut(nil)
    }

    static func run(model: AppModel, into directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(1.5))
        for step in OnboardingModel.Step.allCases {
            model.onboarding.go(to: step)
            try? await Task.sleep(for: .seconds(step == .welcome ? 2.2 : 1.6))
            capture(named: "\(step.rawValue)-\(step.title.lowercased())", into: directory)
        }
        NSApp.terminate(nil)
    }

    static func capture(named name: String, into directory: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }) else { return }
        guard let image = windowImage(CGWindowID(window.windowNumber)) else { return }
        let bitmap = NSBitmapImageRep(cgImage: image)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
    }

    private typealias WindowImageFunction = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    static func windowImage(_ windowID: CGWindowID) -> CGImage? {
        if screenIsLocked, let window = NSApp.windows.first(where: { CGWindowID($0.windowNumber) == windowID }) {
            return offscreenImage(of: window)
        }
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let symbol = dlsym(handle, "CGWindowListCreateImage")
        else { return nil }
        let function = unsafeBitCast(symbol, to: WindowImageFunction.self)
        let options = CGWindowListOption.optionIncludingWindow.rawValue
        let imageOptions = CGWindowImageOption([.boundsIgnoreFraming, .bestResolution]).rawValue
        return function(.null, options, windowID, imageOptions)?.takeRetainedValue()
    }

    static var screenIsLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    static func offscreenImage(of window: NSWindow) -> CGImage? {
        guard let view = window.contentView?.superview ?? window.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }
}
