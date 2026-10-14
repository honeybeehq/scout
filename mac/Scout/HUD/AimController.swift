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

    let ink = CaptureInk()

    var onPin: ((Mark) -> Void)?
    var onStroke: ((Stroke) -> Void)?
    var onExpand: ((TimeInterval) -> Void)?
    var onFollow: ((TimeInterval) -> Void)?
    var onAimChanged: ((Bool) -> Void)?
    var enrich: ((Mark, Date) async -> Target?)?
    var measure: ((String, TimeInterval) -> Void)?

    static let activationDelay: Duration = .milliseconds(200)
    static let strokeThreshold: CGFloat = 6

    private let clock: SessionClock
    private var tap: PinEventTap?
    private var pendingActivation: Task<Void, Never>?
    private var hoverLoop: Task<Void, Never>?
    private var optionHeld = false
    private var suppressedUntilRelease = false
    private var pinCount = 0
    private var strokeCount = 0
    private var press: (point: CGPoint, at: SessionTime, date: Date, pin: Int)?
    private var strokePoints: [StrokePoint] = []
    private var panels: [NSPanel] = []

    init(clock: SessionClock) {
        self.clock = clock
    }

    func start() {
        guard tap == nil, AXIsProcessTrusted() else { return }
        let tap = PinEventTap { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(event) }
            }
        }
        isAvailable = tap.start()
        self.tap = isAvailable ? tap : nil
        self.tap?.setExpandKeys(true)
    }

    func simulate(_ event: PinEventTap.Event) {
        handle(event)
    }

    func stop() {
        deactivate()
        tap?.stop()
        tap = nil
        panels.forEach { $0.orderOut(nil) }
        panels = []
    }

    private func handle(_ event: PinEventTap.Event) {
        switch event {
        case .modifiers(let flags):
            optionChanged(flags)
        case .keyDown:
            if optionHeld {
                suppressedUntilRelease = true
                deactivate()
            }
        case .press(let point, let input):
            begin(at: point, input: input)
        case .drag(let point, let input):
            drag(to: point, input: input)
        case .release(let point, let input):
            release(at: point, input: input)
        case .expand(let input):
            onExpand?(input)
        case .follow(let input):
            onFollow?(input)
        }
    }

    private func begin(at point: CGPoint, input: TimeInterval) {
        pinCount += 1
        press = (point, clock.now, Date(), pinCount)
        strokePoints = [StrokePoint(x: point.x, y: point.y, at: clock.now)]
        ink.addPin(pinCount, at: point)
        measure?("pin", input)
    }

    private func drag(to point: CGPoint, input: TimeInterval) {
        guard let press else { return }
        strokePoints.append(StrokePoint(x: point.x, y: point.y, at: clock.now))
        if ink.live.isEmpty {
            guard hypot(point.x - press.point.x, point.y - press.point.y) >= Self.strokeThreshold else { return }
            ink.removePin(press.pin)
            pinCount -= 1
            ink.begin(at: press.point)
        }
        ink.extend(to: point)
        measure?("stroke", input)
    }

    private func release(at point: CGPoint, input: TimeInterval) {
        guard let press else { return }
        self.press = nil
        guard !ink.live.isEmpty else {
            pin(at: press.point, number: press.pin, time: press.at, date: press.date)
            return
        }
        strokePoints.append(StrokePoint(x: point.x, y: point.y, at: clock.now))
        strokeCount += 1
        let stroke = Stroke(id: "d\(strokeCount)", points: strokePoints, color: CaptureInk.color, width: CaptureInk.width)
        strokePoints = []
        ink.finish(stroke)
        onStroke?(stroke)
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
        tap?.setAiming(true)
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
        if press != nil, !optionHeld {
            let last = strokePoints.last.map { CGPoint(x: $0.x, y: $0.y) } ?? .zero
            release(at: last, input: InteractionTimings.now)
        }
        pendingActivation?.cancel()
        pendingActivation = nil
        guard isAiming else { return }
        isAiming = false
        tap?.setAiming(false)
        onAimChanged?(false)
        hoverLoop?.cancel()
        hoverLoop = nil
        hovered = nil
        if pulses.isEmpty { hidePanels() }
    }

    private func pin(at point: CGPoint, number: Int, time: SessionTime, date pinnedAt: Date) {
        let target = hovered.flatMap { target in
            target.frame.map { Rect(x: $0.x, y: $0.y, width: $0.width, height: $0.height).contains(Point(x: point.x, y: point.y)) } == true ? target : nil
        } ?? TargetResolver.target(at: point)
        var mark = Mark(id: "pin-\(number)", at: time, point: Point(x: point.x, y: point.y), target: target)
        Task { [weak self] in
            if let enrich = self?.enrich, let richer = await enrich(mark, pinnedAt) {
                mark.target = richer.merged(withAccessibility: mark.target)
            }
            self?.onPin?(mark)
        }

        let pulse = Pulse(id: number, point: point)
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
        panel.sharingType = SimulationMode.panelSharing
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

private struct AimOverlay: View {
    let aim: AimController
    let screenOrigin: CGPoint

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if aim.isAiming, let target = aim.hovered, let frame = target.frame {
                let local = CGRect(x: frame.x - screenOrigin.x, y: frame.y - screenOrigin.y, width: frame.width, height: frame.height)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Palette.accent.opacity(0.06))
                    .strokeBorder(Palette.accent, lineWidth: 2)
                    .frame(width: local.width + 6, height: local.height + 6)
                    .offset(x: local.minX - 3, y: local.minY - 3)
                    .animation(Motion.snappy, value: local)

                Text(target.displayName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Palette.text)
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .background(Palette.ink.opacity(0.92), in: .capsule)
                    .overlay(Capsule().strokeBorder(Palette.stroke))
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
                .stroke(Palette.accent, lineWidth: 2)
                .frame(width: 44, height: 44)
                .scaleEffect(expanded ? 1.8 : 0.3)
                .opacity(expanded ? 0 : 1)
            Circle()
                .fill(Palette.accent)
                .frame(width: 16, height: 16)
                .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                .scaleEffect(expanded ? 1 : 0.3)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.9)) { expanded = true }
        }
    }
}
