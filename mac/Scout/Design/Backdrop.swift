import SwiftUI

struct SignalBackdrop: View {
    var intensity: Double = 1

    var body: some View {
        ZStack {
            Palette.canvas
            GridLines()
                .stroke(Palette.hairline.opacity(0.7), lineWidth: 1)
            Grain()
        }
        .ignoresSafeArea()
    }
}

nonisolated private struct GridLines: Shape {
    var spacing: CGFloat = 48

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX + spacing
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            x += spacing
        }
        var y = rect.minY + spacing
        while y < rect.maxY {
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
            y += spacing
        }
        return path
    }
}

struct Grain: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        Canvas { @Sendable context, size in
            var generator = SeededGenerator(seed: 7)
            let count = Int(size.width * size.height / 90)
            for _ in 0..<count {
                let x = Double.random(in: 0..<size.width, using: &generator)
                let y = Double.random(in: 0..<size.height, using: &generator)
                let alpha = Double.random(in: 0.015..<0.05, using: &generator)
                context.fill(Path(CGRect(x: x, y: y, width: 1, height: 1)), with: .color((dark ? Color.white : Color.black).opacity(alpha * (dark ? 1 : 0.6))))
            }
        }
        .allowsHitTesting(false)
    }
}

nonisolated struct SeededGenerator: RandomNumberGenerator {
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
