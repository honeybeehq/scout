import AppKit
import Observation
import ScoutCore
import SwiftUI

@Observable
final class CaptureInk {
    struct PinMarker: Identifiable, Equatable {
        let id: Int
        let point: CGPoint
    }

    static let color = "#FF6A3D"
    static let width = 3.5

    private(set) var pins: [PinMarker] = []
    private(set) var strokes: [Stroke] = []
    private(set) var live: [CGPoint] = []

    func addPin(_ number: Int, at point: CGPoint) {
        pins.append(PinMarker(id: number, point: point))
    }

    func removePin(_ number: Int) {
        pins.removeAll { $0.id == number }
    }

    func extend(to point: CGPoint) {
        live.append(point)
    }

    func begin(at point: CGPoint) {
        live = [point]
    }

    func finish(_ stroke: Stroke) {
        live = []
        strokes.append(stroke)
    }

    func cancelLive() {
        live = []
    }
}

final class CaptureOverlayController {
    private var panels: [(screen: CGRect, panel: NSPanel)] = []

    static let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)) - 1)

    func prepare(follower: CaptureFollower?, ink: CaptureInk?) {
        let screens = NSScreen.screens.map(\.frame)
        if panels.map(\.screen) != screens {
            panels.forEach { $0.panel.orderOut(nil) }
            panels = NSScreen.screens.map { ($0.frame, Self.makePanel(for: $0)) }
        }
        for (_, panel) in panels {
            (panel.contentView as? NSHostingView<CaptureOverlayRoot>)?.rootView.source.update(follower: follower, ink: ink)
        }
    }

    func show(follower: CaptureFollower, ink: CaptureInk) {
        prepare(follower: follower, ink: ink)
        panels.forEach { $0.panel.orderFrontRegardless() }
    }

    func hide() {
        panels.forEach { $0.panel.orderOut(nil) }
        prepare(follower: nil, ink: nil)
    }

    private static func makePanel(for screen: NSScreen) -> NSPanel {
        let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = level
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.sharingType = SimulationMode.panelSharing
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.maxY
        let frame = CGRect(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height)
        let host = NSHostingView(rootView: CaptureOverlayRoot(source: OverlaySource(), screen: frame))
        host.sizingOptions = []
        panel.contentView = host
        panel.setFrame(screen.frame, display: false)
        return panel
    }
}

@Observable
final class OverlaySource {
    private(set) var follower: CaptureFollower?
    private(set) var ink: CaptureInk?

    func update(follower: CaptureFollower?, ink: CaptureInk?) {
        if self.follower !== follower { self.follower = follower }
        if self.ink !== ink { self.ink = ink }
    }
}

struct CaptureOverlayRoot: View {
    let source: OverlaySource
    let screen: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if let follower = source.follower {
                CaptureFrame(follower: follower, screen: screen)
            }
            if let ink = source.ink {
                InkLayer(ink: ink, screen: screen)
            }
        }
        .ignoresSafeArea()
    }
}

private struct CaptureFrame: View {
    let follower: CaptureFollower
    let screen: CGRect
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let glide = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.12)

    var body: some View {
        let local = follower.bounds.map(localRect)
        let onThisScreen = local.map { CGRect(origin: .zero, size: screen.size).intersects($0) } ?? false
        ZStack(alignment: .topLeading) {
            if let local, onThisScreen {
                Cutout(hole: local.insetBy(dx: -3, dy: -3), dimsOutside: true)
                    .fill(Color.black.opacity(0.22), style: FillStyle(eoFill: true))
                Cutout(hole: local.insetBy(dx: -3, dy: -3), dimsOutside: false)
                    .stroke(Palette.accent, lineWidth: 2)
            } else if local != nil {
                Color.black.opacity(0.22)
            }
            if let suggestion = follower.suggestion.map(localRect), CGRect(origin: .zero, size: screen.size).intersects(suggestion) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Palette.accent.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .frame(width: suggestion.width + 12, height: suggestion.height + 12)
                    .offset(x: suggestion.minX - 6, y: suggestion.minY - 6)
                    .transition(.opacity)
                KeepBothBubble()
                    .position(x: suggestion.midX, y: max(24, suggestion.maxY - 30))
                    .transition(.opacity.combined(with: .offset(y: 4)))
            }
        }
        .animation(reduceMotion ? nil : Self.glide, value: local)
        .animation(.easeOut(duration: 0.1), value: follower.suggestion)
    }

    private func localRect(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: -screen.minX, dy: -screen.minY)
    }
}

nonisolated private struct Cutout: Shape {
    var hole: CGRect
    var dimsOutside: Bool

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(hole.minX, hole.minY), AnimatablePair(hole.width, hole.height)) }
        set { hole = CGRect(x: newValue.first.first, y: newValue.first.second, width: newValue.second.first, height: newValue.second.second) }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if dimsOutside { path.addRect(rect) }
        path.addRoundedRect(in: hole, cornerSize: CGSize(width: 10, height: 10), style: .continuous)
        return path
    }
}

struct KeepBothBubble: View {
    var body: some View {
        HStack(spacing: 6) {
            Text("You keep moving between these.")
                .foregroundStyle(Palette.textSecondary)
            Text("Keep both in view")
                .fontWeight(.semibold)
                .foregroundStyle(Palette.text)
            KeyHint(KeyShortcut.widenCapture.label)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Palette.ink.opacity(0.92), in: .capsule)
        .overlay(Capsule().strokeBorder(Palette.stroke))
        .fixedSize()
    }
}

struct KeyHint: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, 4)
            .frame(minHeight: 16)
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Palette.stroke))
    }
}

private struct InkLayer: View {
    let ink: CaptureInk
    let screen: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                let style = StrokeStyle(lineWidth: CaptureInk.width, lineCap: .round, lineJoin: .round)
                for stroke in ink.strokes {
                    context.stroke(path(stroke.points.map { CGPoint(x: $0.x, y: $0.y) }), with: .color(Palette.accent), style: style)
                }
                if ink.live.count > 1 {
                    context.stroke(path(ink.live), with: .color(Palette.accent), style: style)
                }
            }
            PinBadge(number: 0)
                .opacity(0)
                .accessibilityHidden(true)
            ForEach(ink.pins) { pin in
                PinBadge(number: pin.id)
                    .position(x: pin.point.x - screen.minX, y: pin.point.y - screen.minY)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.16), value: ink.pins)
    }

    private func path(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: CGPoint(x: first.x - screen.minX, y: first.y - screen.minY))
        for point in points.dropFirst() {
            path.addLine(to: CGPoint(x: point.x - screen.minX, y: point.y - screen.minY))
        }
        return path
    }
}

private struct PinBadge: View {
    let number: Int

    var body: some View {
        Text("\(number)")
            .font(.system(size: 11.5, weight: .bold))
            .foregroundStyle(Palette.ink)
            .frame(width: 22, height: 22)
            .background(Palette.accent, in: .circle)
            .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
    }
}
