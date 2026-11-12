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
        let linearState = pane == .linear ? linearState : nil
        if let linearState { await prepareLinear(model.linear, state: linearState, into: directory) }
        model.openSettingsWindow?()
        try? await Task.sleep(for: .seconds(1.5))
        if linearState == .teamPicker {
            model.linear.openTeamPicker = "default"
            try? await Task.sleep(for: .seconds(1))
        }
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue.contains("Settings") == true }) {
            let popovers = NSApp.windows.filter { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
            let image = popovers.isEmpty
                ? windowImage(CGWindowID(window.windowNumber))
                : screenIsLocked ? offscreenComposite([window] + popovers) : windowsImage((popovers + [window]).map { CGWindowID($0.windowNumber) })
            let name = linearState.map { "settings-linear-\($0.rawValue)" } ?? "settings-\(pane.rawValue)"
            if let image {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                    .write(to: directory.appendingPathComponent("\(name).png"))
            }
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

    enum LinearState: String {
        case disconnected, connected, error, mappings, keychain
        case teamPicker = "team-picker"
    }

    static var linearState: LinearState? {
        argument("--linear-state=").flatMap(LinearState.init(rawValue:))
    }

    static var linearFixture: URL? {
        argument("--linear-fixture=").map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static var linearScrollAnchor: String? {
        directory != nil && linearState == .mappings ? "routing" : nil
    }

    static func makeLinearAccount() -> LinearAccount {
        let state = SettingsView.requestedPane == .linear ? linearState : nil
        let volatile = directory != nil && state != nil && state != .keychain
        var defaults = UserDefaults.standard
        if volatile {
            let suite = "com.trmdy.scout.linear-snapshot"
            UserDefaults.standard.removePersistentDomain(forName: suite)
            defaults = UserDefaults(suiteName: suite) ?? .standard
        }
        let api: any LinearAPI = linearFixture.map { FixtureLinearClient(directory: $0, rejectsKeys: state == .error) } ?? LinearClient()
        return LinearAccount(
            api: api,
            credentials: LinearCredentials(storage: volatile ? .memory : .keychain, defaults: defaults),
            preferences: LinearPreferences(defaults: defaults)
        )
    }

    private static func prepareLinear(_ account: LinearAccount, state: LinearState, into directory: URL) async {
        switch state {
        case .disconnected:
            return
        case .error:
            account.draftKey = "lin_api_" + String(repeating: "0", count: 36)
            await account.connect()
            return
        case .keychain:
            account.draftKey = ProcessInfo.processInfo.environment["SCOUT_LINEAR_SNAPSHOT_KEY"] ?? ""
            await account.connect()
            if case .connected(let hint, _) = account.status {
                try? "store: \(hint.store.rawValue)\nhint: \(hint.masked)\n".write(to: directory.appendingPathComponent("linear-keychain.txt"), atomically: true, encoding: .utf8)
            }
            return
        case .connected, .teamPicker, .mappings:
            account.draftKey = "lin_api_SCOUTFIXTURENOTAREALKEY00003f9a"
            await account.connect()
        }
        let teams = account.teams.value ?? []
        func team(_ key: String) -> LinearTeam? { teams.first { $0.key == key } }
        account.preferences.defaultTeam = team("ENG")
        guard state == .mappings, let web = team("WEB"), let game = team("GAME"), let design = team("DES") else { return }
        await account.loadTeamDetails(web.id)
        await account.loadTeamDetails(game.id)
        let checkout = account.projects[web.id]?.value?.first { $0.name == "Checkout v2" }
        let playtests = account.projects[game.id]?.value?.first
        account.preferences.routes = [
            LinearRoute(match: .repo(rootPath: NSHomeDirectory() + "/Projects/acme/web"), name: "web", team: web, project: checkout.map(LinearProjectRef.init)),
            LinearRoute(match: .app(bundleID: "com.apple.iphonesimulator"), name: "Simulator", team: game, project: playtests.map(LinearProjectRef.init)),
            LinearRoute(match: .app(bundleID: "com.figma.Desktop"), name: "Figma", team: design, project: nil),
        ]
    }

    private static func argument(_ prefix: String) -> String? {
        ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
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

    private typealias WindowsImageFunction = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?

    static func windowsImage(_ windowIDs: [CGWindowID]) -> CGImage? {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let symbol = dlsym(handle, "CGWindowListCreateImageFromArray")
        else { return nil }
        let function = unsafeBitCast(symbol, to: WindowsImageFunction.self)
        var pointers = windowIDs.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard let array = CFArrayCreate(nil, &pointers, pointers.count, nil) else { return nil }
        let imageOptions = CGWindowImageOption([.boundsIgnoreFraming, .bestResolution]).rawValue
        return function(.null, array, imageOptions)?.takeRetainedValue()
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

    static func offscreenComposite(_ windows: [NSWindow]) -> CGImage? {
        guard let base = windows.first else { return nil }
        let scale = base.backingScaleFactor
        let bounds = windows.map(\.frame).reduce(base.frame) { $0.union($1) }
        guard let context = CGContext(
            data: nil, width: Int(bounds.width * scale), height: Int(bounds.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        for window in windows {
            let view = window === base ? (window.contentView?.superview ?? window.contentView) : window.contentView
            guard let view, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds), let image = (view.cacheDisplay(in: view.bounds, to: rep), rep.cgImage).1 else { continue }
            let frame = view.convert(view.bounds, to: nil).offsetBy(dx: window.frame.minX - bounds.minX, dy: window.frame.minY - bounds.minY)
            context.draw(image, in: CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale))
        }
        return context.makeImage()
    }

    static func offscreenImage(of window: NSWindow) -> CGImage? {
        guard let view = window.contentView?.superview ?? window.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }
}
