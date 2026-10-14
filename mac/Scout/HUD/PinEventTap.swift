import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Synchronization

nonisolated final class PinEventTap: @unchecked Sendable {
    enum Event: Sendable {
        case modifiers(CGEventFlags)
        case keyDown
        case press(CGPoint, TimeInterval)
        case drag(CGPoint, TimeInterval)
        case release(CGPoint, TimeInterval)
        case expand(TimeInterval)
        case follow(TimeInterval)
    }

    private static let nonTextRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXLink", "AXImage",
        "AXList", "AXOutline", "AXTable", "AXRow", "AXCell", "AXScrollArea", "AXWebArea", "AXSplitGroup",
        "AXTabGroup", "AXToolbar", "AXSlider", "AXStaticText", "AXLayoutArea", "AXDisclosureTriangle",
    ]

    private let onEvent: @Sendable (Event) -> Void
    private let aiming = Atomic<Bool>(false)
    private let swallowingClick = Atomic<Bool>(false)
    private let expandKeys = Atomic<Bool>(false)
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

    func setExpandKeys(_ active: Bool) {
        expandKeys.store(active, ordering: .releasing)
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
            if let key = expandKey(event) {
                onEvent(key)
                return true
            }
            onEvent(.keyDown)
            return false
        case .leftMouseDown:
            guard aiming.load(ordering: .acquiring), event.flags.contains(.maskAlternate) else { return false }
            swallowingClick.store(true, ordering: .releasing)
            onEvent(.press(event.location, ProcessInfo.processInfo.systemUptime))
            return true
        case .leftMouseDragged:
            guard swallowingClick.load(ordering: .acquiring) else { return false }
            onEvent(.drag(event.location, ProcessInfo.processInfo.systemUptime))
            return true
        case .leftMouseUp:
            guard swallowingClick.exchange(false, ordering: .acquiringAndReleasing) else { return false }
            onEvent(.release(event.location, ProcessInfo.processInfo.systemUptime))
            return true
        default:
            return false
        }
    }

    private func expandKey(_ event: CGEvent) -> Event? {
        guard expandKeys.load(ordering: .acquiring),
              event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_ANSI_E),
              event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
              event.flags.isDisjoint(with: [.maskCommand, .maskControl, .maskAlternate, .maskSecondaryFn]),
              Self.focusIsKnownNonText()
        else { return nil }
        let at = ProcessInfo.processInfo.systemUptime
        return event.flags.contains(.maskShift) ? .follow(at) : .expand(at)
    }

    private static func focusIsKnownNonText() -> Bool {
        guard let app = copyElement(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute) else { return false }
        AXUIElementSetMessagingTimeout(app, 0.03)
        guard let focused = copyElement(app, kAXFocusedUIElementAttribute) else { return false }
        AXUIElementSetMessagingTimeout(focused, 0.03)
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXRoleAttribute as CFString, &role) == .success,
              let role = role as? String, nonTextRoles.contains(role)
        else { return false }
        var editable: CFTypeRef?
        if AXUIElementCopyAttributeValue(focused, "AXEditableAncestor" as CFString, &editable) == .success, editable != nil {
            return false
        }
        return true
    }

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }
}

nonisolated private let pinTapCallback: CGEventTapCallBack = { _, type, event, reference in
    guard let reference else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<PinEventTap>.fromOpaque(reference).takeUnretainedValue()
    return tap.handle(type, event) ? nil : Unmanaged.passUnretained(event)
}
