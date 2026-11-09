import SwiftUI

nonisolated enum Radius {
    static let tag: CGFloat = 3
    static let key: CGFloat = 4
    static let control: CGFloat = 6
    static let card: CGFloat = 8
    static let panel: CGFloat = 10
}

extension EnvironmentValues {
    @Entry var stillRender = false
    @Entry var stillFrame: CGImage? = nil
}

struct ScoutScroll<Content: View>: View {
    var axis: Axis.Set = .vertical
    var indicators: ScrollIndicatorVisibility = .never
    @ViewBuilder var content: Content
    @Environment(\.stillRender) private var still

    var body: some View {
        if still {
            content
                .fixedSize(horizontal: axis == .horizontal, vertical: axis == .vertical)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
        } else {
            ScrollView(axis) { content }
                .scrollIndicators(indicators)
        }
    }
}

struct ScoutMenu<Items: View, Label: View>: View {
    @ViewBuilder var items: Items
    @ViewBuilder var label: Label
    @Environment(\.stillRender) private var still

    var body: some View {
        if still {
            label
        } else {
            Menu { items } label: { label }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
        }
    }
}

struct SurfaceCard: ViewModifier {
    var fill: Color = Palette.surface
    var radius: CGFloat = Radius.card
    var stroke: Color = Palette.hairline

    func body(content: Content) -> some View {
        content
            .background(fill, in: .rect(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(stroke))
    }
}

extension View {
    func surfaceCard(_ fill: Color = Palette.surface, radius: CGFloat = Radius.card, stroke: Color = Palette.hairline) -> some View {
        modifier(SurfaceCard(fill: fill, radius: radius, stroke: stroke))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var large = true

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 13.5 : 12, weight: .bold))
            .foregroundStyle(isEnabled ? Palette.onAccent : Palette.textTertiary)
            .padding(.horizontal, large ? 20 : 12)
            .frame(height: large ? 38 : 28)
            .background(isEnabled ? Palette.accent : Palette.fillRaised, in: .rect(cornerRadius: Radius.control, style: .continuous))
            .brightness(configuration.isPressed ? -0.08 : 0)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
            .contentShape(.rect(cornerRadius: Radius.control))
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isEnabled ? Palette.text : Palette.textTertiary)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(configuration.isPressed ? Palette.fillStrong : Palette.surface, in: .rect(cornerRadius: Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Palette.stroke))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
            .contentShape(.rect(cornerRadius: Radius.control))
    }
}

struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isEnabled ? Palette.textSecondary : Palette.textQuaternary)
            .padding(.horizontal, 8)
            .frame(minHeight: 26)
            .background(configuration.isPressed ? Palette.fillRaised : Color.white.opacity(0.001), in: .rect(cornerRadius: Radius.control, style: .continuous))
            .contentShape(.rect(cornerRadius: Radius.control))
    }
}

struct DangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Palette.negativeFill, in: .rect(cornerRadius: Radius.control, style: .continuous))
            .brightness(configuration.isPressed ? -0.08 : 0)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
            .contentShape(.rect(cornerRadius: Radius.control))
    }
}

struct KeyHint: View {
    let text: String
    var emphasized = false
    var large = false
    @Environment(\.isEnabled) private var isEnabled

    init(_ text: String, emphasized: Bool = false, large: Bool = false) {
        self.text = text
        self.emphasized = emphasized
        self.large = large
    }

    var body: some View {
        Text(text)
            .font(large ? .system(size: 12.5, weight: .semibold).monospacedDigit() : Typography.key)
            .tracking(large ? 1.2 : 0.6)
            .foregroundStyle(emphasized ? Color.white : large ? Palette.text : Palette.textSecondary)
            .padding(.horizontal, large ? 7 : 4)
            .frame(minWidth: large ? 24 : 17, minHeight: large ? 24 : 17)
            .background(emphasized ? Color(hex: 0x0B0B0D, opacity: 0.82) : Palette.fillRaised, in: .rect(cornerRadius: Radius.tag, style: .continuous))
            .overlay(alignment: .bottom) {
                if !emphasized {
                    RoundedRectangle(cornerRadius: Radius.tag, style: .continuous)
                        .fill(Palette.stroke)
                        .frame(height: 1)
                        .padding(.horizontal, 1)
                }
            }
            .opacity(isEnabled ? 1 : 0.35)
            .fixedSize()
    }
}

struct Keycap: View {
    var symbol: String
    var size: CGFloat = 34
    var pressed = false

    var body: some View {
        Text(symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(pressed ? Palette.onAccent : Palette.text)
            .frame(minWidth: size, minHeight: size)
            .padding(.horizontal, symbol.count > 1 ? size * 0.22 : 0)
            .background {
                RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                    .fill(pressed ? Palette.accent : Palette.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                            .strokeBorder(pressed ? Palette.accent : Palette.stroke, lineWidth: 1)
                    )
                    .shadow(color: pressed ? .clear : Palette.stroke, radius: 0, y: 2)
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
        HStack(spacing: size * 0.12) {
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
        RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
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
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(Palette.fill, in: .rect(cornerRadius: Radius.tag, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.tag, style: .continuous).strokeBorder(Palette.hairline))
    }
}

struct StateTag: View {
    var text: String
    var tone: Tone

    var body: some View {
        Text(text)
            .font(Typography.label)
            .tracking(0.7)
            .textCase(.uppercase)
            .foregroundStyle(tone == .neutral ? Palette.textSecondary : tone == .active ? Palette.accentText : tone.color)
            .padding(.horizontal, 5)
            .frame(height: 16)
            .overlay(RoundedRectangle(cornerRadius: Radius.tag, style: .continuous).strokeBorder(tone == .neutral ? Palette.stroke : tone.color.opacity(0.6)))
            .fixedSize()
    }
}

struct IconOrb: View {
    var symbol: String
    var size: CGFloat = 40
    var active = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.4, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(active ? Palette.onAccent : Palette.textSecondary)
            .frame(width: size, height: size)
            .background(active ? Palette.accent : Palette.raised, in: .rect(cornerRadius: size * 0.22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).strokeBorder(active ? Color.clear : Palette.hairline))
    }
}

struct Checkmark: View {
    var size: CGFloat = 24

    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: size * 0.46, weight: .heavy))
            .foregroundStyle(Color.white)
            .frame(width: size, height: size)
            .background(Palette.positive, in: .rect(cornerRadius: size * 0.22, style: .continuous))
            .transition(.iconSwap)
    }
}

struct SignalToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(Motion.snappy) { configuration.isOn.toggle() }
        } label: {
            HStack(spacing: 8) {
                configuration.label
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(configuration.isOn ? Palette.positive : Palette.fillStrong)
                        .frame(width: 34, height: 20)
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .fill(Color.white)
                        .frame(width: 14, height: 14)
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                        .padding(3)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

struct SegmentedChoice<Value: Hashable>: View {
    var options: [Value]
    @Binding var selection: Value
    var title: (Value) -> String
    var fill = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    withAnimation(Motion.snappy) { selection = option }
                } label: {
                    Text(title(option))
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(selected ? (isEnabled ? Palette.onInk : Palette.text) : isEnabled ? Palette.textSecondary : Palette.textTertiary)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: fill ? .infinity : nil)
                        .frame(height: 24)
                        .background(selected ? (isEnabled ? Palette.ink : Palette.fillStrong) : Color.clear, in: .rect(cornerRadius: 4, style: .continuous))
                        .contentShape(.rect(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Palette.raised, in: .rect(cornerRadius: Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Palette.hairline))
        .fixedSize(horizontal: !fill, vertical: true)
    }
}

struct ChoiceMenu<Value: Hashable>: View {
    var options: [Value]
    @Binding var selection: Value
    var title: (Value) -> String

    var body: some View {
        ScoutMenu {
            ForEach(options, id: \.self) { option in
                Button(title(option)) { selection = option }
            }
        } label: {
            HStack(spacing: 6) {
                Text(title(selection))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Palette.textTertiary)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Palette.surface, in: .rect(cornerRadius: Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Palette.stroke))
            .fixedSize()
        }
        .fixedSize()
    }
}

struct NumberStepper: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var unit: String

    var body: some View {
        HStack(spacing: 0) {
            stepButton("minus", enabled: value > range.lowerBound) { value = max(range.lowerBound, value - 1) }
            Text("\(Int(value)) \(unit)")
                .font(Typography.numeric)
                .foregroundStyle(Palette.text)
                .frame(minWidth: 44)
                .contentTransition(.numericText(value: value))
            stepButton("plus", enabled: value < range.upperBound) { value = min(range.upperBound, value + 1) }
        }
        .frame(height: 26)
        .background(Palette.surface, in: .rect(cornerRadius: Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Palette.stroke))
        .fixedSize()
    }

    private func stepButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(Motion.snappy) { action() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .bold))
                .frame(width: 26, height: 26)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Palette.text : Palette.textQuaternary)
        .disabled(!enabled)
    }
}

struct DiscardControl: View {
    var question: String
    var help: String
    var compact = false
    var shortcut: String?
    @Binding var asking: Bool
    var onDiscard: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if asking {
                Text(question)
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(Palette.negative)
                    .padding(.horizontal, 2)
                    .fixedSize()
                Button {
                    asking = false
                } label: {
                    HStack(spacing: 5) {
                        Text("Keep")
                        if shortcut != nil { KeyHint("esc") }
                    }
                }
                .buttonStyle(DiscardOutlineStyle())
                .help("Keep going. Nothing is deleted.")
                Button {
                    asking = false
                    onDiscard()
                } label: {
                    HStack(spacing: 5) {
                        Text("Discard")
                        if let shortcut { DangerKeyHint(text: shortcut) }
                    }
                }
                .buttonStyle(DangerButtonStyle())
                .help(help)
            } else {
                Button {
                    asking = true
                } label: {
                    if compact {
                        Image(systemName: "trash")
                            .accessibilityLabel("Discard")
                    } else {
                        HStack(spacing: 5) {
                            Image(systemName: "trash")
                            if let shortcut { KeyHint(shortcut) }
                        }
                        .accessibilityLabel("Discard")
                    }
                }
                .buttonStyle(DiscardOutlineStyle())
                .help(help)
            }
        }
        .font(.system(size: 11.5, weight: .semibold))
        .fixedSize()
        .animation(Motion.snappy, value: asking)
        .task(id: asking) {
            guard asking else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { asking = false }
        }
    }
}

private struct DangerKeyHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Typography.key)
            .tracking(0.6)
            .foregroundStyle(Color.white)
            .padding(.horizontal, 4)
            .frame(minHeight: 17)
            .overlay(RoundedRectangle(cornerRadius: Radius.tag, style: .continuous).strokeBorder(Color.white.opacity(0.7), lineWidth: 1))
            .fixedSize()
    }
}

private struct DiscardOutlineStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(configuration.isPressed ? Palette.fillStrong : Palette.fillRaised, in: .rect(cornerRadius: Radius.control, style: .continuous))
            .contentShape(.rect(cornerRadius: Radius.control))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}

struct AimChip: View {
    var role: String?
    var label: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "scope")
                .font(.system(size: 10, weight: .heavy))
            if let role {
                Text(role.uppercased())
                    .font(.system(size: 9.5, weight: .heavy))
                    .tracking(0.6)
                    .opacity(0.7)
            }
            Text(label)
                .font(.system(size: 11.5, weight: .bold))
                .lineLimit(1)
        }
        .foregroundStyle(Palette.onAccent)
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(Palette.accent, in: .rect(cornerRadius: Radius.tag + 1, style: .continuous))
        .fixedSize()
    }
}

struct AimOutline: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Palette.accent.opacity(0.08))
            .strokeBorder(Palette.accent, lineWidth: 2)
    }
}

struct PinBadge: View {
    let number: Int

    var body: some View {
        Text("\(number)")
            .font(.system(size: 11.5, weight: .heavy).monospacedDigit())
            .foregroundStyle(Palette.onAccent)
            .frame(width: 22, height: 22)
            .background(Palette.accent, in: .rect(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.white, lineWidth: 1.5))
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
    }
}
