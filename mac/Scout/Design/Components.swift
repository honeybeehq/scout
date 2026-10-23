import SwiftUI

struct PrimaryButtonStyle: ButtonStyle {
    var large = true

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(large ? .system(size: 14, weight: .semibold) : .system(size: 12.5, weight: .semibold))
            .foregroundStyle(isEnabled ? Color.white : Palette.textTertiary)
            .padding(.horizontal, large ? 24 : 14)
            .frame(height: large ? 42 : 30)
            .background {
                Capsule()
                    .fill(isEnabled ? AnyShapeStyle(Palette.accentGradient) : AnyShapeStyle(Palette.fillRaised))
                    .overlay(alignment: .top) {
                        Capsule()
                            .strokeBorder(Color.white.opacity(isEnabled ? 0.22 : 0), lineWidth: 1)
                            .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center))
                    }
            }
            .brightness(configuration.isPressed ? -0.06 : 0)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
            .contentShape(.capsule)
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Capsule().fill(configuration.isPressed ? Palette.fillRaised : Color.white.opacity(0.001)))
            .contentShape(.capsule)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .glassEffect(.regular.interactive(), in: .capsule)
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
            .font(.system(size: size * 0.42, weight: .medium, design: .rounded))
            .foregroundStyle(pressed ? Palette.ink : Palette.text)
            .frame(minWidth: size, minHeight: size)
            .padding(.horizontal, symbol.count > 1 ? size * 0.22 : 0)
            .background {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(pressed ? Color.white : Palette.fillRaised)
                    .overlay(
                        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                            .strokeBorder(Palette.stroke, lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.35), radius: 0, y: pressed ? 0 : 1.5)
            }
            .offset(y: pressed ? 1.5 : 0)
            .animation(Motion.snappy, value: pressed)
    }
}

struct KeyCombo: View {
    var symbols: [String]
    var size: CGFloat = 34
    var pressed = false

    var body: some View {
        HStack(spacing: size * 0.16) {
            ForEach(Array(symbols.enumerated()), id: \.offset) { _, symbol in
                Keycap(symbol: symbol, size: size, pressed: pressed)
            }
        }
    }
}

enum Tone {
    case neutral, active, positive, caution, negative

    var color: Color {
        switch self {
        case .neutral: Palette.textQuaternary
        case .active: Palette.accent
        case .positive: Palette.positive
        case .caution: Palette.caution
        case .negative: Palette.negative
        }
    }
}

struct StatusDot: View {
    var tone: Tone
    var size: CGFloat = 6

    var body: some View {
        Circle()
            .fill(tone.color)
            .frame(width: size, height: size)
    }
}

struct StatusBadge: View {
    var text: String
    var tone: Tone

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(tone: tone)
            Text(text)
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Capsule().fill(Palette.fill))
        .overlay(Capsule().strokeBorder(Palette.hairline))
    }
}

struct IconOrb: View {
    var symbol: String
    var size: CGFloat = 40
    var active = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.4, weight: .medium))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(active ? Palette.text : Palette.textSecondary)
            .frame(width: size, height: size)
            .background(Circle().fill(active ? Palette.fillStrong : Palette.fill))
            .overlay(Circle().strokeBorder(Palette.hairline))
    }
}

struct Checkmark: View {
    var size: CGFloat = 24

    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: size * 0.44, weight: .bold))
            .foregroundStyle(Palette.ink)
            .frame(width: size, height: size)
            .background(Color.white.opacity(0.92), in: .circle)
            .transition(.iconSwap)
    }
}

struct DiscardControl: View {
    var question: String
    var help: String
    var compact = false
    @Binding var asking: Bool
    var onDiscard: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if asking {
                Text(question)
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, 4)
                    .fixedSize()
                Button("Keep") { asking = false }
                    .buttonStyle(DiscardCapsuleStyle(filled: false))
                    .help("Keep going. Nothing is deleted.")
                Button("Discard") {
                    asking = false
                    onDiscard()
                }
                .buttonStyle(DiscardCapsuleStyle(filled: true))
                .help(help)
            } else {
                Button {
                    asking = true
                } label: {
                    if compact {
                        Image(systemName: "trash")
                            .accessibilityLabel("Discard")
                    } else {
                        Label("Discard", systemImage: "trash")
                    }
                }
                .buttonStyle(DiscardCapsuleStyle(filled: false))
                .help(help)
            }
        }
        .font(.system(size: 11.5, weight: .medium))
        .fixedSize()
        .animation(Motion.snappy, value: asking)
        .task(id: asking) {
            guard asking else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { asking = false }
        }
    }
}

private struct DiscardCapsuleStyle: ButtonStyle {
    var filled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(filled ? Palette.fillStrong : Color.white.opacity(configuration.isPressed ? 0.09 : 0.001), in: .capsule)
            .overlay(Capsule().strokeBorder(filled ? Color.clear : Palette.stroke))
            .contentShape(.capsule)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}
