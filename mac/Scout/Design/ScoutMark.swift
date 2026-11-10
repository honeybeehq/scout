import SwiftUI

struct ScoutMark: View {
    static let steps = 3

    var level = 3
    var pulsing = false
    var color: Color = Palette.accent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let strength = 0.28 + 0.72 * Double(min(max(level, 0), Self.steps)) / Double(Self.steps)
            let rim = side * 0.84
            let lens = rim * 0.54
            let lean = CGSize(width: -side * 0.035, height: side * 0.045)
            let line = max(1.6, side * 0.055)
            ZStack {
                Circle()
                    .fill(color)
                    .frame(width: rim, height: rim)
                    .blur(radius: side * 0.1)
                    .opacity(0.45 * strength)
                Circle()
                    .strokeBorder(RimLight(color: color), lineWidth: line)
                    .frame(width: rim, height: rim)
                    .blur(radius: side * 0.012)
                    .opacity(strength)
                if side >= 40 {
                    Circle()
                        .strokeBorder(color.opacity(0.5), lineWidth: side * 0.022)
                        .frame(width: rim * 0.76, height: rim * 0.76)
                        .offset(x: lean.width * 0.5, y: lean.height * 0.5)
                        .blur(radius: side * 0.006)
                        .opacity(strength)
                }
                Circle()
                    .fill(LensFill(color: color))
                    .frame(width: lens, height: lens)
                    .offset(lean)
                    .opacity(strength)
            }
            .modifier(MarkPulse(active: pulsing && level > 0 && !reduceMotion))
            .animation(Motion.bouncy, value: level)
            .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

private struct RimLight: ShapeStyle {
    static let ember = Color(red: 1, green: 0.62, blue: 0.42)
    var color: Color

    func resolve(in environment: EnvironmentValues) -> LinearGradient {
        LinearGradient(
            colors: [color.mix(with: Self.ember, by: 0.25), color.opacity(0.8)],
            startPoint: .bottomLeading,
            endPoint: .topTrailing
        )
    }
}

private struct LensFill: ShapeStyle {
    static let core = Color(red: 1, green: 0.8, blue: 0.6)
    var color: Color

    func resolve(in environment: EnvironmentValues) -> EllipticalGradient {
        EllipticalGradient(
            stops: [
                .init(color: color.mix(with: Self.core, by: 0.85), location: 0),
                .init(color: color.mix(with: Self.core, by: 0.4), location: 0.5),
                .init(color: color, location: 1),
            ],
            center: UnitPoint(x: 0.42, y: 0.4),
            startRadiusFraction: 0,
            endRadiusFraction: 0.62
        )
    }
}

private struct MarkPulse: ViewModifier {
    var active: Bool
    @State private var bright = false

    func body(content: Content) -> some View {
        content
            .opacity(active ? (bright ? 1 : 0.7) : 1)
            .onAppear { pulse(active) }
            .onDisappear { bright = false }
            .onChange(of: active) { _, now in pulse(now) }
    }

    private func pulse(_ active: Bool) {
        guard active else {
            bright = false
            return
        }
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
            bright = true
        }
    }
}
