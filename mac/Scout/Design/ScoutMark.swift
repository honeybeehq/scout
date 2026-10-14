import SwiftUI

nonisolated struct PointerShape: Shape {
    func path(in rect: CGRect) -> Path {
        let tip = CGPoint(x: rect.minX, y: rect.minY)
        let rightWing = CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.40)
        let notch = CGPoint(x: rect.minX + rect.width * 0.47, y: rect.minY + rect.height * 0.47)
        let bottomWing = CGPoint(x: rect.minX + rect.width * 0.40, y: rect.maxY)
        let corners = [tip, rightWing, notch, bottomWing]
        let radius = rect.width * 0.09

        var path = Path()
        for index in corners.indices {
            let current = corners[index]
            let next = corners[(index + 1) % corners.count]
            let previous = corners[(index + corners.count - 1) % corners.count]
            let entry = current.moved(toward: previous, by: radius)
            let exit = current.moved(toward: next, by: radius)
            if index == 0 { path.move(to: entry) } else { path.addLine(to: entry) }
            path.addQuadCurve(to: exit, control: current)
        }
        path.closeSubpath()
        return path
    }
}

nonisolated struct SignalArc: Shape {
    var radiusFraction: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.minX + rect.width * ScoutMark.tipFraction, y: rect.minY + rect.height * ScoutMark.tipFraction),
            radius: rect.width * radiusFraction,
            startAngle: .degrees(192),
            endAngle: .degrees(258),
            clockwise: false
        )
        return path
    }
}

struct ScoutMark: View {
    nonisolated static let tipFraction = 0.40
    static let arcRadii: [Double] = [0.15, 0.25, 0.35]

    var litArcs = 3
    var pulsing = false
    var arcColor: Color = Palette.accent
    var pointerStyle: AnyShapeStyle = AnyShapeStyle(Color.white)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack(alignment: .topLeading) {
                ForEach(Self.arcRadii.indices, id: \.self) { index in
                    arc(index: index, side: side)
                }
                PointerShape()
                    .fill(pointerStyle)
                    .frame(width: side * 0.52, height: side * 0.52)
                    .offset(x: side * Self.tipFraction, y: side * Self.tipFraction)
                    .shadow(color: .black.opacity(0.35), radius: side * 0.03, y: side * 0.015)
            }
            .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func arc(index: Int, side: Double) -> some View {
        let lit = index < litArcs
        return SignalArc(radiusFraction: Self.arcRadii[index])
            .stroke(
                lit ? arcColor : Color.white.opacity(0.16),
                style: StrokeStyle(lineWidth: side * 0.062, lineCap: .round)
            )
            .shadow(color: lit ? arcColor.opacity(0.25) : .clear, radius: side * 0.04)
            .modifier(ArcPulse(active: pulsing && lit && !reduceMotion, index: index))
            .animation(Motion.bouncy.delay(Double(index) * 0.08), value: lit)
    }
}

private struct ArcPulse: ViewModifier {
    var active: Bool
    var index: Int

    func body(content: Content) -> some View {
        if active {
            TimelineView(.animation) { context in
                let period = 2.4
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                let wave = max(0, sin((phase - Double(index) * 0.12) * .pi * 2))
                content.opacity(0.55 + 0.45 * wave)
            }
        } else {
            content
        }
    }
}

nonisolated private extension CGPoint {
    func moved(toward other: CGPoint, by distance: CGFloat) -> CGPoint {
        let dx = other.x - x
        let dy = other.y - y
        let length = max(sqrt(dx * dx + dy * dy), 0.0001)
        let clamped = min(distance, length / 2)
        return CGPoint(x: x + dx / length * clamped, y: y + dy / length * clamped)
    }
}
