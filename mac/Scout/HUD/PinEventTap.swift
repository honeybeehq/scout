import CoreGraphics
import Foundation
import Synchronization

nonisolated final class PinEventTap: @unchecked Sendable {
    enum Event: Sendable {
        case modifiers(CGEventFlags)
        case keyDown
        case pin(CGPoint)
    }

    private let onEvent: @Sendable (Event) -> Void
    private let aiming = Atomic<Bool>(false)
    private let swallowingClick = Atomic<Bool>(false)
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?

    init(onEvent: @escaping @Sendable (Event) -> Void) {
        self.onEvent = onEvent
    }

    func start() -> Bool {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let events: [CGEventType] = [.flagsChanged, .keyDown, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
            let mask = events.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
            let reference = Unmanaged.passUnretained(self).toOpaque()
            if let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: pinTapCallback, userInfo: reference) {
                let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
                CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
                self.tap = tap
                self.runLoop = CFRunLoopGetCurrent()
            }
            ready.signal()
            if self.tap != nil { CFRunLoopRun() }
        }
        thread.name = "scout.pin-tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread
        ready.wait()
        return tap != nil
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoop { CFRunLoopStop(runLoop) }
        tap = nil
        runLoop = nil
        thread = nil
    }

    func setAiming(_ active: Bool) {
        aiming.store(active, ordering: .releasing)
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        case .flagsChanged:
            onEvent(.modifiers(event.flags))
            return false
        case .keyDown:
            onEvent(.keyDown)
            return false
        case .leftMouseDown:
            guard aiming.load(ordering: .acquiring), event.flags.contains(.maskAlternate) else { return false }
            swallowingClick.store(true, ordering: .releasing)
            onEvent(.pin(event.location))
            return true
        case .leftMouseDragged:
            return swallowingClick.load(ordering: .acquiring)
        case .leftMouseUp:
            return swallowingClick.exchange(false, ordering: .acquiringAndReleasing)
        default:
            return false
        }
    }
}

nonisolated private let pinTapCallback: CGEventTapCallBack = { _, type, event, reference in
    guard let reference else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<PinEventTap>.fromOpaque(reference).takeUnretainedValue()
    return tap.handle(type, event) ? nil : Unmanaged.passUnretained(event)
}
