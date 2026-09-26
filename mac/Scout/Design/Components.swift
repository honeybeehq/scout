import SwiftUI

struct FlareButtonStyle: ButtonStyle {
    var large = true

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(large ? .system(size: 15, weight: .semibold) : .system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, large ? 26 : 16)
            .frame(height: large ? 46 : 32)
            .background {
                Capsule()
                    .fill(isEnabled ? AnyShapeStyle(Palette.flareGradient) : AnyShapeStyle(Color.white.opacity(0.12)))
                    .overlay(Capsule().strokeBorder(.white.opacity(isEnabled ? 0.28 : 0.08), lineWidth: 1).blendMode(.plusLighter))
                    .shadow(color: isEnabled ? Palette.flare.opacity(configuration.isPressed ? 0.25 : 0.45) : .clear, radius: 18, y: 6)
            }
            .opacity(isEnabled ? 1 : 0.6)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
            .contentShape(.capsule)
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.10 : 0.001)))
            .contentShape(.capsule)
    }
}

struct GlassPillButtonStyle: ButtonStyle {
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 32)
            .glassEffect(.regular.tint(tint).interactive(), in: .capsule)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}

struct Keycap: View {
    var symbol: String
    var size: CGFloat = 34
    var pressed = false

    var body: some View {
        Text(symbol)
            .font(.system(size: size * 0.44, weight: .semibold, design: .rounded))
            .foregroundStyle(pressed ? Palette.ink : .white)
            .frame(minWidth: size, minHeight: size)
            .padding(.horizontal, symbol.count > 1 ? size * 0.22 : 0)
            .background {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(pressed ? AnyShapeStyle(Palette.flareGradient) : AnyShapeStyle(Color.white.opacity(0.08)))
                    .overlay(
                        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                            .strokeBorder(.white.opacity(0.16), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.4), radius: 0, y: pressed ? 0 : 2)
            }
            .offset(y: pressed ? 2 : 0)
            .animation(Motion.snappy, value: pressed)
    }
}

struct KeyCombo: View {
    var symbols: [String]
    var size: CGFloat = 34
    var pressed = false

    var body: some View {
        HStack(spacing: size * 0.18) {
            ForEach(Array(symbols.enumerated()), id: \.offset) { _, symbol in
                Keycap(symbol: symbol, size: size, pressed: pressed)
            }
        }
    }
}

struct StatusBadge: View {
    enum Tone {
        case neutral, waiting, success, warning

        var color: Color {
            switch self {
            case .neutral: Palette.textTertiary
            case .waiting: Palette.amber
            case .success: Palette.mint
            case .warning: Palette.rose
            }
        }
    }

    var text: String
    var tone: Tone

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tone.color)
                .frame(width: 6, height: 6)
                .shadow(color: tone.color.opacity(0.8), radius: 4)
            Text(text)
                .font(Typography.caption)
                .foregroundStyle(tone == .neutral ? Palette.textSecondary : tone.color)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Capsule().fill(tone.color.opacity(0.12)))
    }
}

struct IconOrb: View {
    var symbol: String
    var tint: Color
    var size: CGFloat = 44
    var active = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(active ? tint : .white.opacity(0.85))
            .frame(width: size, height: size)
            .background {
                Circle()
                    .fill(tint.opacity(active ? 0.2 : 0.08))
                    .overlay(Circle().strokeBorder(tint.opacity(active ? 0.55 : 0.12), lineWidth: 1))
            }
            .shadow(color: active ? tint.opacity(0.45) : .clear, radius: 12)
    }
}

struct Checkmark: View {
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: size * 0.46, weight: .heavy))
            .foregroundStyle(Palette.ink)
            .frame(width: size, height: size)
            .background(Palette.mint, in: .circle)
            .shadow(color: Palette.mint.opacity(0.5), radius: 8)
            .transition(.scale(scale: 0.4).combined(with: .opacity))
    }
}
