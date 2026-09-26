import AppKit
import ScoutCore

nonisolated final class PointerTracker: @unchecked Sendable {
    static let dwellThreshold: SessionTime = 0.6

    private let clock: SessionClock
    private let onFocus: @Sendable (Focus) -> Void
    private let onHover: @Sendable (Target?) -> Void
    private let queue = DispatchQueue(label: "scout.pointer", qos: .userInitiated)
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
        guard let target = TargetResolver.target(at: point) else {
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
}
