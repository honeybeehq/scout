import AppKit
import Observation
import ScoutCore

@Observable
final class CaptureFollower {
    private(set) var scope: CaptureScope = .follow
    private(set) var bounds: CGRect?
    private(set) var suggestion: CGRect?
    private(set) var scopeTitle = "Following"
    private(set) var isRunning = false

    let resolver = RegionResolver()
    var pointerSource: (() -> CGPoint)?
    var onChange: ((ScopeChange, _ input: TimeInterval) -> Void)?

    @ObservationIgnored private var machine = ScopeMachine()
    @ObservationIgnored private let clock: SessionClock
    @ObservationIgnored private var timer: DispatchSourceTimer?
    @ObservationIgnored private var resolving = false
    @ObservationIgnored private var lastPoint: CGPoint?
    @ObservationIgnored private var lastResolve: TimeInterval = 0

    static let pollInterval: DispatchTimeInterval = .milliseconds(16)
    static let idleResolveInterval: TimeInterval = 0.1

    init(clock: SessionClock) {
        self.clock = clock
    }

    private func publish() {
        let title = switch machine.scope {
        case .follow: machine.followed.map { "Following · \($0.label)" } ?? "Following"
        case .pair: "Locked · Both areas"
        case .window: "Locked · Window"
        case .screen: "Locked · Screen"
        }
        let bounds = machine.bounds?.cgRect
        let suggestion = machine.suggestion?.bounds.cgRect
        if scope != machine.scope { scope = machine.scope }
        if self.bounds != bounds { self.bounds = bounds }
        if self.suggestion != suggestion { self.suggestion = suggestion }
        if scopeTitle != title { scopeTitle = title }
    }

    func start() {
        guard timer == nil else { return }
        isRunning = true
        let point = pointerSource?() ?? Self.pointer()
        lastPoint = point
        lastResolve = InteractionTimings.now
        let change = machine.pointer(over: resolver.region(at: point), at: clock.now)
        publish()
        if let change { onChange?(change, lastResolve) }
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        isRunning = false
    }

    func expand(input: TimeInterval) {
        let now = clock.now
        let change = machine.expand(at: now)
        publish()
        guard let change else { return }
        onChange?(change, input)
    }

    func follow(input: TimeInterval) {
        let now = clock.now
        let change = machine.follow(at: now)
        publish()
        guard let change else { return }
        onChange?(change, input)
    }

    private func poll() {
        guard !resolving else { return }
        let point = pointerSource?() ?? Self.pointer()
        let sampled = InteractionTimings.now
        let moved = lastPoint.map { hypot($0.x - point.x, $0.y - point.y) >= 1 } ?? true
        guard moved || sampled - lastResolve >= Self.idleResolveInterval else { return }
        lastPoint = point
        lastResolve = sampled
        resolving = true
        let resolver = resolver
        Task { [weak self] in
            let region = await Self.resolve(resolver, at: point)
            guard let self else { return }
            self.resolving = false
            guard self.isRunning else { return }
            let change = self.machine.pointer(over: region, at: self.clock.now)
            self.publish()
            guard let change else { return }
            self.onChange?(change, sampled)
        }
    }

    @concurrent
    nonisolated private static func resolve(_ resolver: RegionResolver, at point: CGPoint) async -> CaptureRegion? {
        resolver.region(at: point)
    }

    static func pointer() -> CGPoint {
        let location = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: location.x, y: primaryHeight - location.y)
    }
}
