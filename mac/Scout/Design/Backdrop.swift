import SwiftUI

struct Aurora: View {
    var glow: Color = Palette.accent
    var intensity: Double = 1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            MeshGradient(
                width: 3,
                height: 3,
                points: points(at: t),
                colors: colors
            )
        }
        .ignoresSafeArea()
    }

    private var colors: [Color] {
        [
            Palette.ink, Palette.night, Palette.ink,
            Palette.indigo.opacity(0.9), Palette.plum.opacity(0.75), Palette.night,
            glow.opacity(0.55 * intensity), Palette.plum.opacity(0.6), Palette.indigo.opacity(0.85),
        ]
    }

    private func points(at t: TimeInterval) -> [SIMD2<Float>] {
        func drift(_ speed: Double, _ amount: Double, _ offset: Double) -> Float {
            Float(sin(t * speed + offset) * amount)
        }
        return [
            [0, 0], [0.5 + drift(0.21, 0.08, 0), 0], [1, 0],
            [0, 0.5 + drift(0.17, 0.10, 1)], [0.5 + drift(0.23, 0.12, 2), 0.5 + drift(0.19, 0.10, 3)], [1, 0.5 + drift(0.13, 0.12, 4)],
            [0, 1], [0.5 + drift(0.15, 0.14, 5), 1], [1, 1],
        ]
    }
}

struct Grain: View {
    var body: some View {
        Canvas { context, size in
            var generator = SeededGenerator(seed: 7)
            let count = Int(size.width * size.height / 90)
            for _ in 0..<count {
                let x = Double.random(in: 0..<size.width, using: &generator)
                let y = Double.random(in: 0..<size.height, using: &generator)
                let alpha = Double.random(in: 0.015..<0.05, using: &generator)
                context.fill(Path(CGRect(x: x, y: y, width: 1, height: 1)), with: .color(.white.opacity(alpha)))
            }
        }
        .allowsHitTesting(false)
        .blendMode(.plusLighter)
    }
}

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &* 0x9E3779B97F4A7C15
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }
}
