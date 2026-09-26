import AppKit
import ScoutCore

nonisolated final class ContextTracker: @unchecked Sendable {
    private let clock: SessionClock
    private let onChange: @Sendable (ContextChange) -> Void
    private let queue = DispatchQueue(label: "scout.context", qos: .userInitiated)
    private let ownProcessID = ProcessInfo.processInfo.processIdentifier
    private var timer: DispatchSourceTimer?
    private var current: AppContext?
    private var pending: (context: AppContext, since: SessionTime)?
    private var webAreas: [pid_t: AXElement] = [:]
    private var searchedWindows: [String: Date] = [:]
    private var enabledManualAccessibility: Set<pid_t> = []

    static let ignoredBundleIDs: Set<String> = ["com.apple.loginwindow", "com.apple.ScreenSaver.Engine", "com.apple.dock", "com.apple.controlcenter", "com.apple.notificationcenterui"]
    static let chromiumBundlePrefixes = ["com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser", "com.vivaldi", "org.chromium", "com.operasoftware"]

    init(clock: SessionClock, onChange: @escaping @Sendable (ContextChange) -> Void) {
        self.clock = clock
        self.onChange = onChange
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(400), leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func sample() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ownProcessID,
              !Self.ignoredBundleIDs.contains(app.bundleIdentifier ?? "")
        else { return }
        let pid = app.processIdentifier
        let identity = AppIdentity(bundleID: app.bundleIdentifier, name: app.localizedName ?? "App", processID: pid)
        let application = AXElement.application(pid)
        enableWebAccessibilityIfNeeded(for: app, element: application)
        let window = application.child(kAXFocusedWindowAttribute)
        let title = window?.title
        let context = AppContext(app: identity, windowTitle: title, location: window.flatMap { location(in: $0, pid: pid, title: title) })
        settle(context)
    }

    private func settle(_ context: AppContext) {
        let now = clock.now
        guard context != current else {
            pending = nil
            return
        }
        let appChanged = current.map { !$0.app.isSameApp(as: context.app) } ?? true
        if appChanged || pending?.context == context {
            let at = appChanged ? now : (pending?.since ?? now)
            current = context
            pending = nil
            onChange(ContextChange(at: at, context: context))
        } else {
            pending = (context, now)
        }
    }

    private func location(in window: AXElement, pid: pid_t, title: String?) -> String? {
        if let cached = webAreas[pid], let url: URL = cached.attribute("AXURL"),
           let cachedWindow = cached.child(kAXWindowAttribute), CFEqual(cachedWindow.element, window.element) {
            return Self.displayLocation(url)
        }
        let searchKey = "\(pid)|\(title ?? "")"
        if let searched = searchedWindows[searchKey], Date().timeIntervalSince(searched) < 5 { return nil }
        searchedWindows[searchKey] = Date()
        if searchedWindows.count > 512 { searchedWindows.removeAll() }
        guard let webArea = window.firstDescendant(maxDepth: 14, where: { $0.role == "AXWebArea" }) else { return nil }
        webAreas[pid] = webArea
        guard let url: URL = webArea.attribute("AXURL") else { return nil }
        return Self.displayLocation(url)
    }

    private func enableWebAccessibilityIfNeeded(for app: NSRunningApplication, element: AXElement) {
        guard !enabledManualAccessibility.contains(app.processIdentifier),
              let bundleID = app.bundleIdentifier,
              Self.chromiumBundlePrefixes.contains(where: bundleID.hasPrefix) || isElectron(app)
        else { return }
        element.setBool("AXManualAccessibility", true)
        enabledManualAccessibility.insert(app.processIdentifier)
    }

    private func isElectron(_ app: NSRunningApplication) -> Bool {
        guard let bundleURL = app.bundleURL else { return false }
        let framework = bundleURL.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        return FileManager.default.fileExists(atPath: framework.path)
    }

    static func displayLocation(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.string ?? url.absoluteString
    }
}
