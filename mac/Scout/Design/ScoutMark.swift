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
            ZStack {
                Capsule()
                    .fill(color)
                    .frame(width: side * 0.34, height: side * 0.86)
                    .blur(radius: side * 0.12)
                    .opacity(0.55 * strength)
                Capsule()
                    .fill(BeamFill(color: color))
                    .frame(width: side * 0.24, height: side * 0.74)
                    .opacity(strength)
                Capsule()
                    .fill(.white.opacity(0.55))
                    .frame(width: side * 0.07, height: side * 0.38)
                    .blur(radius: side * 0.03)
                    .opacity(strength)
            }
            .modifier(BeamPulse(active: pulsing && level > 0 && !reduceMotion))
            .animation(Motion.bouncy, value: level)
            .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

struct BeamFill: ShapeStyle {
    var color: Color

    func resolve(in environment: EnvironmentValues) -> LinearGradient {
        LinearGradient(
            stops: [
                .init(color: color.opacity(0.35), location: 0),
                .init(color: color, location: 0.22),
                .init(color: color.mix(with: .white, by: 0.28), location: 0.5),
                .init(color: color, location: 0.78),
                .init(color: color.opacity(0.35), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

private struct BeamPulse: ViewModifier {
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
