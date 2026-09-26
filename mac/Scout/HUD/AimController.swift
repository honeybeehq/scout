import AppKit
import Observation
import ScoutCore
import SwiftUI

@Observable
final class AimController {
    struct Pulse: Identifiable, Equatable {
        let id: Int
        let point: CGPoint
    }

    private(set) var isAiming = false
    private(set) var hovered: Target?
    private(set) var pulses: [Pulse] = []
    private(set) var isAvailable = false

    var onPin: ((Mark) -> Void)?
    var onAimChanged: ((Bool) -> Void)?
    var enrich: ((Mark, Date) async -> Target?)?

    static let activationDelay: Duration = .milliseconds(200)

    private let clock: SessionClock
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pendingActivation: Task<Void, Never>?
    private var hoverLoop: Task<Void, Never>?
    private var optionHeld = false
    private var suppressedUntilRelease = false
    private var swallowingClick = false
    private var pinCount = 0
    private var panels: [NSPanel] = []

    init(clock: SessionClock) {
        self.clock = clock
    }

    func start() {
        guard tap == nil else { return }
        let events: [CGEventType] = [.flagsChanged, .keyDown, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
        let mask = events.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let reference = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: aimTapCallback, userInfo: reference) else {
            isAvailable = false
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        runLoopSource = source
        isAvailable = true
    }

    func stop() {
        deactivate()
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil
        runLoopSource = nil
        panels.forEach { $0.orderOut(nil) }
        panels = []
    }

    fileprivate func reenableTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    fileprivate func handle(_ type: CGEventType, flags: CGEventFlags, location: CGPoint) -> Bool {
        switch type {
        case .flagsChanged:
            optionChanged(flags)
            return false
        case .keyDown:
            if optionHeld {
                suppressedUntilRelease = true
                deactivate()
            }
            return false
        case .leftMouseDown:
            guard isAiming else { return false }
            swallowingClick = true
            pin(at: location)
            return true
        case .leftMouseDragged:
            return swallowingClick
        case .leftMouseUp:
            guard swallowingClick else { return false }
            swallowingClick = false
            return true
        default:
            return false
        }
    }

    private func optionChanged(_ flags: CGEventFlags) {
        let optionDown = flags.contains(.maskAlternate)
        guard optionDown else {
            optionHeld = false
            suppressedUntilRelease = false
            deactivate()
            return
        }
        guard flags.isDisjoint(with: [.maskCommand, .maskControl, .maskShift]) else {
            suppressedUntilRelease = true
            deactivate()
            return
        }
        guard !optionHeld else { return }
        optionHeld = true
        guard !suppressedUntilRelease else { return }
        pendingActivation = Task { [weak self] in
            try? await Task.sleep(for: Self.activationDelay)
            guard !Task.isCancelled, let self, self.optionHeld, !self.suppressedUntilRelease else { return }
            self.activate()
        }
    }

    private func activate() {
        guard !isAiming else { return }
        isAiming = true
        onAimChanged?(true)
        showPanels()
        hoverLoop = Task { [weak self] in
            var lastID: String?
            while !Task.isCancelled {
                let target = await Self.targetUnderPointer()
                if target?.id != lastID {
                    lastID = target?.id
                    self?.hovered = target
                }
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    @concurrent
    nonisolated private static func targetUnderPointer() async -> Target? {
        guard let point = CGEvent(source: nil)?.location else { return nil }
        return TargetResolver.target(at: point)
    }

    private func deactivate() {
        pendingActivation?.cancel()
        pendingActivation = nil
        guard isAiming else { return }
        isAiming = false
        onAimChanged?(false)
        hoverLoop?.cancel()
        hoverLoop = nil
        hovered = nil
        if pulses.isEmpty { hidePanels() }
    }

    private func pin(at point: CGPoint) {
        pinCount += 1
        let target = hovered.flatMap { target in
            target.frame.map { Rect(x: $0.x, y: $0.y, width: $0.width, height: $0.height).contains(Point(x: point.x, y: point.y)) } == true ? target : nil
        } ?? TargetResolver.target(at: point)
        var mark = Mark(id: "pin-\(pinCount)", at: clock.now, point: Point(x: point.x, y: point.y), target: target)
        let pinnedAt = Date()
        Task { [weak self] in
            if let enrich = self?.enrich, let richer = await enrich(mark, pinnedAt) {
                mark.target = richer.merged(withAccessibility: mark.target)
            }
            self?.onPin?(mark)
        }

        let pulse = Pulse(id: pinCount, point: point)
        withAnimation(Motion.bouncy) { pulses.append(pulse) }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self else { return }
            self.pulses.removeAll { $0 == pulse }
            if !self.isAiming, self.pulses.isEmpty { self.hidePanels() }
        }
    }

    private func showPanels() {
        if panels.isEmpty {
            panels = NSScreen.screens.map(makePanel)
        }
        panels.forEach { $0.orderFrontRegardless() }
    }

    private func hidePanels() {
        panels.forEach { $0.orderOut(nil) }
    }

    private func makePanel(for screen: NSScreen) -> NSPanel {
        let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.sharingType = SimulationMode.audioFile == nil ? .none : .readOnly
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.maxY
        let origin = CGPoint(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY)
        let host = NSHostingView(rootView: AimOverlay(aim: self, screenOrigin: origin))
        host.sizingOptions = []
        panel.contentView = host
        panel.setFrame(screen.frame, display: false)
        return panel
    }
}

private let aimTapCallback: CGEventTapCallBack = { _, type, event, reference in
    guard let reference else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<AimController>.fromOpaque(reference).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { controller.reenableTap() }
        return Unmanaged.passUnretained(event)
    }
    let flags = event.flags
    let location = event.location
    let swallow = MainActor.assumeIsolated { controller.handle(type, flags: flags, location: location) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}

private struct AimOverlay: View {
    let aim: AimController
    let screenOrigin: CGPoint

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if aim.isAiming, let target = aim.hovered, let frame = target.frame {
                let local = CGRect(x: frame.x - screenOrigin.x, y: frame.y - screenOrigin.y, width: frame.width, height: frame.height)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Palette.beam.opacity(0.12))
                    .strokeBorder(Palette.beam, lineWidth: 2)
                    .shadow(color: Palette.beam.opacity(0.7), radius: 10)
                    .frame(width: local.width + 6, height: local.height + 6)
                    .offset(x: local.minX - 3, y: local.minY - 3)
                    .animation(Motion.snappy, value: local)

                Text(target.displayName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .background(Palette.beam, in: .capsule)
                    .fixedSize()
                    .offset(x: local.minX - 3, y: max(4, local.minY - 30))
                    .animation(Motion.snappy, value: local)
            }
            ForEach(aim.pulses) { pulse in
                PinPulse()
                    .position(x: pulse.point.x - screenOrigin.x, y: pulse.point.y - screenOrigin.y)
            }
        }
        .ignoresSafeArea()
    }
}

private struct PinPulse: View {
    @State private var expanded = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Palette.flare, lineWidth: 2.5)
                .frame(width: 44, height: 44)
                .scaleEffect(expanded ? 1.8 : 0.3)
                .opacity(expanded ? 0 : 1)
            Circle()
                .fill(Palette.flareGradient)
                .frame(width: 16, height: 16)
                .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                .shadow(color: Palette.flare.opacity(0.8), radius: 10)
                .scaleEffect(expanded ? 1 : 0.3)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.9)) { expanded = true }
        }
    }
}
