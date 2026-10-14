import AppKit
import ScoutCore

final class ApiaryPointing {
    static let dwellThreshold: SessionTime = 0.6
    static let reuseWindow: SessionTime = 5
    static let reuseArea: Double = 320 * 320

    private let bridge: ApiaryBridge
    private let clock: SessionClock
    private weak var recorder: WalkthroughRecorder?
    private var watch: DwellWatch?
    private var lastDwell: (stack: ApiaryStack, at: SessionTime)?
    private(set) var calls = 0
    private(set) var skipped = 0

    init(bridge: ApiaryBridge, clock: SessionClock, recorder: WalkthroughRecorder) {
        self.bridge = bridge
        self.clock = clock
        self.recorder = recorder
    }

    func start(watchesPointer: Bool) {
        let bridge = bridge
        Task.detached(priority: .utility) {
            guard let pid = await bridge.apiaryPID(), let point = DwellWatch.cursor(), ApiaryWindows.topmostOwner(at: point) == pid else { return }
            _ = await bridge.pointAt(point, reason: "hover", retry: false)
        }
        guard watchesPointer else { return }
        let watch = DwellWatch(clock: clock, threshold: Self.dwellThreshold) { [weak self] point, since in
            Task { @MainActor in self?.dwell(at: point, time: since) }
        }
        watch.start()
        self.watch = watch
    }

    func stop() {
        watch?.stop()
        watch = nil
    }

    func pin(_ mark: Mark) {
        resolve(at: mark.at, via: .pin, point: mark.point, markID: mark.id)
    }

    func dwell(at point: Point, time: SessionTime) {
        if let lastDwell, time - lastDwell.at <= Self.reuseWindow,
           let bounds = lastDwell.stack.elementBounds, bounds.width * bounds.height <= Self.reuseArea, bounds.contains(point) {
            skipped += 1
            return
        }
        resolve(at: time, via: .dwell, point: point, markID: nil)
    }

    private func resolve(at time: SessionTime, via: Walkthrough.Via, point: Point, markID: String?) {
        guard let recorder else { return }
        calls += 1
        let bridge = bridge
        let reason = via == .pin ? "pin" : "dwell"
        recorder.resolve(
            query: {
                await Task.detached(priority: .userInitiated) {
                    guard let pid = await bridge.apiaryPID(), ApiaryWindows.topmostOwner(at: point) == pid else { return nil }
                    return await bridge.pointAt(point, reason: reason, retry: via == .pin)
                }.value
            },
            accept: { [weak self] answer in
                guard let answer, answer.hit, !answer.stack.isEmpty else { return nil }
                let stack = ApiaryStack(levels: answer.stack)
                if via == .dwell {
                    guard let self else { return nil }
                    if let previous = self.lastDwell, previous.stack.identity == stack.identity, time - previous.at <= Self.reuseWindow {
                        self.lastDwell = (stack, time)
                        self.skipped += 1
                        return nil
                    }
                    self.lastDwell = (stack, time)
                }
                return SemanticHit(at: time, via: via, point: point, markID: markID, stack: stack)
            }
        )
    }
}

nonisolated final class DwellWatch: @unchecked Sendable {
    private let clock: SessionClock
    private let threshold: SessionTime
    private let onDwell: @Sendable (Point, SessionTime) -> Void
    private let queue = DispatchQueue(label: "scout.apiary.dwell", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var rest: (point: Point, since: SessionTime, fired: Bool)?

    init(clock: SessionClock, threshold: SessionTime, onDwell: @escaping @Sendable (Point, SessionTime) -> Void) {
        self.clock = clock
        self.threshold = threshold
        self.onDwell = onDwell
    }

    static func cursor() -> Point? {
        CGEvent(source: nil).map { Point(x: $0.location.x, y: $0.location.y) }
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func sample() {
        guard let point = Self.cursor() else { return }
        let now = clock.now
        guard let current = rest, hypot(point.x - current.point.x, point.y - current.point.y) < 2 else {
            rest = (point, now, false)
            return
        }
        guard !current.fired, now - current.since >= threshold else { return }
        rest?.fired = true
        onDwell(current.point, current.since)
    }
}
