import AppKit
import ScoutCore

nonisolated final class PointerTracker: @unchecked Sendable {
    static let dwellThreshold: SessionTime = 0.6

    private static let interactiveRoles: Set<String> = [
        "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
        "AXComboBox", "AXMenuButton", "AXMenuItem", "AXSlider", "AXTab", "AXDisclosureTriangle", "AXCell", "AXImage",
    ]
    private static let containerRoles: Set<String> = ["AXGroup", "AXStaticText", "AXUnknown"]

    private let clock: SessionClock
    private let onFocus: @Sendable (Focus) -> Void
    private let onHover: @Sendable (Target?) -> Void
    private let queue = DispatchQueue(label: "scout.pointer", qos: .userInitiated)
    private let ownProcessID = ProcessInfo.processInfo.processIdentifier
    private let primaryScreenHeight: CGFloat
    private var timer: DispatchSourceTimer?
    private var dwell: (target: Target, since: SessionTime)?
    private var lastPoint: CGPoint?

    init(clock: SessionClock, onFocus: @escaping @Sendable (Focus) -> Void, onHover: @escaping @Sendable (Target?) -> Void) {
        self.clock = clock
        self.onFocus = onFocus
        self.onHover = onHover
        primaryScreenHeight = MainActor.assumeIsolated { NSScreen.screens.first?.frame.height ?? 0 }
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(40))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.sync { closeDwell(at: clock.now) }
    }

    private func sample() {
        let cocoaPoint = NSEvent.mouseLocation
        let point = CGPoint(x: cocoaPoint.x, y: primaryScreenHeight - cocoaPoint.y)
        let now = clock.now
        if let lastPoint, dwell != nil, hypot(point.x - lastPoint.x, point.y - lastPoint.y) < 1 {
            return
        }
        lastPoint = point
        guard let target = resolveTarget(at: point) else {
            closeDwell(at: now)
            onHover(nil)
            return
        }
        if dwell?.target.id == target.id { return }
        closeDwell(at: now)
        dwell = (target, now)
        onHover(target)
    }

    private func closeDwell(at now: SessionTime) {
        guard let dwell else { return }
        self.dwell = nil
        if now - dwell.since >= Self.dwellThreshold {
            onFocus(Focus(range: TimeRange(start: dwell.since, end: now), target: dwell.target))
        }
    }

    func resolveTarget(at point: CGPoint) -> Target? {
        guard var element = AXElement.systemWide.element(at: point),
              let pid = element.processID, pid != ownProcessID
        else { return nil }

        for _ in 0..<3 {
            guard let role = element.role, Self.containerRoles.contains(role) || element.label == nil,
                  let parent = element.parent, let parentRole = parent.role,
                  Self.interactiveRoles.contains(parentRole)
            else { break }
            element = parent
        }

        let role = element.role ?? "AXUnknown"
        guard role != "AXWindow", role != "AXApplication", role != "AXScrollArea" else { return nil }
        let frame = element.frame
        let label = element.label
        let identifier = element.identifier
        let ancestry = Self.ancestry(of: element)
        let frameKey = frame.map { "\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width))x\(Int($0.height))" } ?? "-"
        return Target(
            id: "\(pid):\(role):\(label ?? ""):\(identifier ?? ""):\(frameKey)",
            provider: .accessibility,
            role: Self.readableRole(role, description: element.roleDescription),
            label: label,
            identifier: identifier,
            frame: frame.map { Rect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height) },
            ancestry: ancestry
        )
    }

    private static func ancestry(of element: AXElement) -> [String] {
        var names: [String] = []
        var current = element.parent
        while let node = current, names.count < 4 {
            let role = node.role ?? "?"
            if role == "AXApplication" { break }
            if role != "AXGroup" || node.label != nil {
                names.append([readableRole(role, description: node.roleDescription), node.label.map { "“\($0)”" }].compactMap { $0 }.joined(separator: " "))
            }
            current = node.parent
        }
        return names
    }

    private static func readableRole(_ role: String, description: String?) -> String {
        if let description, !description.isEmpty { return description.prefix(1).uppercased() + description.dropFirst() }
        return role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
    }
}
