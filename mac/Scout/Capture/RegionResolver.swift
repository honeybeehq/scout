import AppKit
import ApplicationServices
import ScoutCore

nonisolated final class RegionResolver: @unchecked Sendable {
    struct WindowInfo: Sendable {
        let id: CGWindowID
        let processID: pid_t
        let bounds: CGRect
        let owner: String
        let title: String?

        var label: String {
            guard let title, !title.isEmpty else { return owner }
            return "\(owner) — \(title)"
        }
    }

    struct Pane: Sendable {
        let id: String
        let bounds: CGRect
        let label: String
    }

    typealias PaneProvider = @Sendable (CGPoint, WindowInfo) -> Pane?

    static let minimumPaneSize = CGSize(width: 160, height: 120)
    static let paneWalkDepth = 16
    static let paneWalkBudget: TimeInterval = 0.03
    static let paneWalkInterval: TimeInterval = 0.1

    private let lock = NSLock()
    private var provider: PaneProvider?
    private var includedWindows: Set<CGWindowID> = []
    private var cachedPane: (windowID: CGWindowID, pane: Pane)?
    private var lastWalk: (windowID: CGWindowID, at: TimeInterval)?
    private let ownProcessID = ProcessInfo.processInfo.processIdentifier

    var paneProvider: PaneProvider? {
        get { lock.withLock { provider } }
        set { lock.withLock { provider = newValue } }
    }

    func include(_ windowID: CGWindowID) {
        lock.withLock { _ = includedWindows.insert(windowID) }
    }

    func region(at point: CGPoint, panes: Bool = true) -> CaptureRegion? {
        guard let display = Self.display(at: point) else { return nil }
        let displayBounds = Rect(display.bounds)
        guard let window = window(at: point) else {
            return CaptureRegion(id: "d\(display.id)", kind: .display, bounds: displayBounds, label: "Screen", displayID: display.id, displayBounds: displayBounds)
        }
        let windowBounds = Rect(window.bounds)
        if panes, let pane = pane(at: point, in: window) {
            return CaptureRegion(id: "w\(window.id)/\(pane.id)", kind: .pane, bounds: Rect(pane.bounds), label: pane.label, displayID: display.id, displayBounds: displayBounds, windowBounds: windowBounds)
        }
        return CaptureRegion(id: "w\(window.id)", kind: .window, bounds: windowBounds, label: window.label, displayID: display.id, displayBounds: displayBounds, windowBounds: windowBounds)
    }

    static func display(at point: CGPoint) -> (id: CGDirectDisplayID, bounds: CGRect)? {
        var id: CGDirectDisplayID = 0
        var count: UInt32 = 0
        if CGGetDisplaysWithPoint(point, 1, &id, &count) == .success, count > 0 {
            return (id, CGDisplayBounds(id))
        }
        let main = CGMainDisplayID()
        return (main, CGDisplayBounds(main))
    }

    private func window(at point: CGPoint) -> WindowInfo? {
        let included = lock.withLock { includedWindows }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for entry in list {
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsInfo = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo),
                  bounds.contains(point)
            else { continue }
            if pid == ownProcessID, !included.contains(id) { continue }
            guard bounds.width >= 80, bounds.height >= 60 else { continue }
            return WindowInfo(
                id: id,
                processID: pid,
                bounds: bounds,
                owner: entry[kCGWindowOwnerName as String] as? String ?? "Window",
                title: entry[kCGWindowName as String] as? String
            )
        }
        return nil
    }

    private func pane(at point: CGPoint, in window: WindowInfo) -> Pane? {
        let (provider, cached) = lock.withLock { (self.provider, cachedPane) }
        if let provider {
            return provider(point, window)
        }
        if let cached, cached.windowID == window.id, cached.pane.bounds.contains(point) {
            return cached.pane
        }
        let now = ProcessInfo.processInfo.systemUptime
        let recent = lock.withLock { lastWalk.map { $0.windowID == window.id && now - $0.at < Self.paneWalkInterval } ?? false }
        guard AXIsProcessTrusted(), !recent else { return nil }
        let pane = Self.splitPane(at: point, in: window)
        lock.withLock {
            lastWalk = (window.id, now)
            cachedPane = pane.map { (window.id, $0) }
        }
        return pane
    }

    private static func splitPane(at point: CGPoint, in window: WindowInfo) -> Pane? {
        let app = AXUIElementCreateApplication(window.processID)
        AXUIElementSetMessagingTimeout(app, 0.02)
        guard var element = AXElement(element: app).element(at: point) else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + paneWalkBudget
        for _ in 0..<paneWalkDepth {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            AXUIElementSetMessagingTimeout(element.element, 0.02)
            guard let parent = element.parent, let role = parent.role else { return nil }
            if role == "AXWindow" || role == "AXApplication" { return nil }
            if role == "AXSplitGroup", let frame = element.frame,
               frame.width >= minimumPaneSize.width, frame.height >= minimumPaneSize.height,
               frame.contains(point), frame.width < window.bounds.width - 1 || frame.height < window.bounds.height - 1 {
                return Pane(id: "p\(CFHash(element.element))", bounds: frame, label: "\(window.owner) pane")
            }
            element = parent
        }
        return nil
    }
}

extension Rect {
    nonisolated init(_ rect: CGRect) {
        self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }

    nonisolated var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}
