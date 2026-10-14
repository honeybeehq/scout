import AppKit
import Foundation
import QuartzCore

nonisolated struct InteractionSample: Codable, Sendable {
    var name: String
    var input: TimeInterval
    var handledMs: Double
    var committedMs: Double?
    var paintedMs: Double?
    var budgetMs: Double
    var detail: String?
}

@MainActor
final class InteractionTimings {
    static let shared = InteractionTimings()

    static let budgets: [String: Double] = [
        "hotkey→pill": 50,
        "hotkey→recording": 150,
        "hotkey→first-frame": 150,
        "follow": 16,
        "refine": 150,
        "expand": 16,
        "pin": 16,
        "stroke": 16,
        "finish→pill-hidden": 100,
        "finish→handoff": 2000,
    ]

    private struct Pending {
        let name: String
        let input: TimeInterval
        let handled: TimeInterval
        let detail: String?
    }

    private(set) var samples: [InteractionSample] = []
    private var log: SignalLog?
    private var awaitingCommit: [Pending] = []
    private var observer: CFRunLoopObserver?
    private let frames = FrameClock()

    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    static let quiet: Set<String> = ["stroke"]

    func begin(logging url: URL) {
        log?.close()
        log = SignalLog(url: url)
        samples = []
    }

    static func afterCommit() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max) { _, _ in
                continuation.resume()
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }

    func measure(_ name: String, from input: TimeInterval, detail: String? = nil) {
        awaitingCommit.append(Pending(name: name, input: input, handled: Self.now, detail: detail))
        installObserver()
    }

    func measure(_ name: String, from input: TimeInterval, committed: TimeInterval, detail: String? = nil) {
        let pending = Pending(name: name, input: input, handled: committed, detail: detail)
        frames.next { [weak self] grid in
            self?.record(pending, committed: committed, presented: grid.firstFrame(atLeastOneFrameAfter: committed))
        }
    }

    func mark(_ name: String, from input: TimeInterval, at time: TimeInterval = now, detail: String? = nil) {
        record(Pending(name: name, input: input, handled: time, detail: detail), committed: nil, presented: nil)
    }

    private func installObserver() {
        guard observer == nil else { return }
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.committed() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    private func committed() {
        guard !awaitingCommit.isEmpty else { return }
        let committed = Self.now
        let pending = awaitingCommit
        awaitingCommit = []
        frames.next { [weak self] grid in
            let presented = grid.firstFrame(atLeastOneFrameAfter: committed)
            pending.forEach { self?.record($0, committed: committed, presented: presented) }
        }
    }

    private func record(_ pending: Pending, committed: TimeInterval?, presented: TimeInterval?) {
        let sample = InteractionSample(
            name: pending.name,
            input: pending.input,
            handledMs: (pending.handled - pending.input) * 1000,
            committedMs: committed.map { ($0 - pending.input) * 1000 },
            paintedMs: presented.map { max(0, $0 - pending.input) * 1000 },
            budgetMs: Self.budgets[pending.name] ?? 150,
            detail: pending.detail
        )
        samples.append(sample)
        log?.append(sample)
        guard !Self.quiet.contains(pending.name) else { return }
        let committedText = sample.committedMs.map { String(format: ", committed %.1f ms", $0) } ?? ""
        let paintedText = sample.paintedMs.map { String(format: ", on screen %.1f ms", $0) } ?? ""
        NSLog("[scout-timing] %@ handled %.1f ms%@%@ (budget %.0f ms)%@", pending.name, sample.handledMs, committedText, paintedText, sample.budgetMs, pending.detail.map { " · \($0)" } ?? "")
    }
}

struct VsyncGrid {
    let target: TimeInterval
    let duration: TimeInterval

    func firstFrame(atLeastOneFrameAfter committed: TimeInterval) -> TimeInterval {
        guard duration > 0 else { return target }
        let frames = ((committed + duration - target) / duration).rounded(.up)
        return target + frames * duration
    }
}

@MainActor
private final class FrameClock: NSObject {
    private var waiting: [(VsyncGrid) -> Void] = []
    private var link: CADisplayLink?

    func next(_ completion: @escaping (VsyncGrid) -> Void) {
        waiting.append(completion)
        if link == nil, let screen = NSScreen.main ?? NSScreen.screens.first {
            let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        link?.isPaused = false
    }

    @objc private func tick(_ link: CADisplayLink) {
        let grid = VsyncGrid(target: link.targetTimestamp, duration: link.targetTimestamp - link.timestamp)
        let done = waiting
        waiting = []
        link.isPaused = true
        done.forEach { $0(grid) }
    }
}
