import SwiftUI

struct PointStep: View {
    @Environment(AppModel.self) private var model
    @State private var pins: [PracticePin] = []

    var body: some View {
        StepLayout(
            eyebrow: "Point",
            title: "Point instead of describing.",
            message: "While you scout, hold ⌥ and click anything to pin it. Scout records what it is and, with the SDK, where it lives in your code."
        ) {
            VStack(spacing: 16) {
                PracticeArea(pins: $pins)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                ShortcutRow()
            }
        } footer: {
            BackButton()
            Spacer()
            if pins.isEmpty {
                Button("Skip") { model.onboarding.next() }
                    .buttonStyle(QuietButtonStyle())
            }
            Button("Continue") { model.onboarding.next() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(pins.isEmpty)
                .keyboardShortcut(.defaultAction)
        }
    }
}

struct PracticePin: Identifiable, Equatable {
    let id = UUID()
    let element: PracticeElement
    let point: CGPoint
}

struct PracticeElement: Identifiable, Equatable, Hashable {
    let id: String
    let role: String
    let label: String
    let source: String

    static let payNow = PracticeElement(id: "pay", role: "Button", label: "Pay now", source: "Checkout.tsx:88")
    static let cancel = PracticeElement(id: "cancel", role: "Button", label: "Cancel", source: "Checkout.tsx:84")
    static let email = PracticeElement(id: "email", role: "TextField", label: "Email", source: "EmailField.tsx:12")
    static let summary = PracticeElement(id: "summary", role: "Card", label: "Order summary", source: "OrderSummary.tsx:5")
    static let promo = PracticeElement(id: "promo", role: "Link", label: "Add promo code", source: "PromoCode.tsx:21")
}

private struct PracticeArea: View {
    @Binding var pins: [PracticePin]
    @State private var aiming = false
    @State private var hoverPoint: CGPoint?
    @State private var frames: [PracticeElement: CGRect] = [:]

    private static let space = "practice"

    private var hovered: PracticeElement? {
        guard aiming, let hoverPoint else { return nil }
        return frames
            .filter { $0.value.contains(hoverPoint) }
            .min { $0.value.width * $0.value.height < $1.value.width * $1.value.height }?
            .key
    }

    var body: some View {
        HStack(spacing: 18) {
            ZStack(alignment: .topLeading) {
                MockCheckout()
                    .onPreferenceChange(ElementFramesKey.self) { frames = $0 }

                if let hovered, let frame = frames[hovered] {
                    AimHighlight(element: hovered, frame: frame)
                }

                ForEach(pins) { pin in
                    PinMarker()
                        .position(pin.point)
                }
            }
            .coordinateSpace(.named(Self.space))
            .onContinuousHover(coordinateSpace: .named(Self.space)) { phase in
                if case .active(let location) = phase { hoverPoint = location } else { hoverPoint = nil }
            }
            .gesture(
                SpatialTapGesture(coordinateSpace: .named(Self.space)).onEnded { value in
                    guard aiming, let element = hovered else { return }
                    withAnimation(Motion.bouncy) {
                        pins.removeAll { $0.element == element }
                        pins.append(PracticePin(element: element, point: value.location))
                    }
                }
            )
            .onModifierKeysChanged(mask: .option, initial: true) { _, keys in
                withAnimation(Motion.snappy) { aiming = keys.contains(.option) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            PinTray(pins: pins, aiming: aiming)
                .frame(width: 250)
        }
    }
}

private struct ElementFramesKey: PreferenceKey {
    static let defaultValue: [PracticeElement: CGRect] = [:]

    static func reduce(value: inout [PracticeElement: CGRect], nextValue: () -> [PracticeElement: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private extension View {
    func practiceElement(_ element: PracticeElement) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: ElementFramesKey.self, value: [element: proxy.frame(in: .named("practice"))])
            }
        }
    }
}

private struct MockCheckout: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ForEach([Color(hex: 0xFF5F57), Color(hex: 0xFEBC2E), Color(hex: 0x28C840)], id: \.self) { color in
                    Circle().fill(color.opacity(0.85)).frame(width: 9, height: 9)
                }
                Spacer()
                Text(verbatim: "localhost:3000/checkout")
                    .font(Typography.mono)
                    .foregroundStyle(Palette.textTertiary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(Color.white.opacity(0.04))

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Checkout")
                        .font(.system(size: 20, weight: .bold))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Email").font(Typography.caption).foregroundStyle(Palette.textSecondary)
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.06))
                            .overlay(alignment: .leading) {
                                Text(verbatim: "you@studio.dev").font(.system(size: 13)).foregroundStyle(Palette.textTertiary).padding(.leading, 10)
                            }
                            .frame(height: 32)
                            .practiceElement(.email)
                    }
                    Text("Add promo code")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.textSecondary)
                        .underline()
                        .practiceElement(.promo)
                    Spacer(minLength: 0)
                    HStack(spacing: 10) {
                        Text("Cancel")
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 14).frame(height: 32)
                            .background(Color.white.opacity(0.08), in: .rect(cornerRadius: 8))
                            .practiceElement(.cancel)
                        Text("Pay now")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                            .padding(.horizontal, 10).frame(height: 24)
                            .background(Color(hex: 0xB9C1D9), in: .rect(cornerRadius: 6))
                            .practiceElement(.payNow)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Order summary").font(.system(size: 12, weight: .semibold))
                    ForEach(["Pro plan · $24", "Seats × 3 · $36", "Tax · $6"], id: \.self) { line in
                        Text(line).font(.system(size: 11.5)).foregroundStyle(Palette.textSecondary)
                    }
                    Divider().overlay(Palette.hairline)
                    Text("Total $66").font(.system(size: 13, weight: .semibold))
                }
                .padding(14)
                .frame(width: 170)
                .background(Color.white.opacity(0.05), in: .rect(cornerRadius: 12))
                .practiceElement(.summary)
            }
            .padding(20)
        }
        .foregroundStyle(Palette.text)
        .background(Palette.ink.opacity(0.55), in: .rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Palette.hairline))
    }
}

private struct AimHighlight: View {
    let element: PracticeElement
    let frame: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Palette.accent.opacity(0.08))
                .strokeBorder(Palette.accent, lineWidth: 1.5)
                .frame(width: frame.width + 8, height: frame.height + 8)
                .offset(x: frame.minX - 4, y: frame.minY - 4)

            Text("\(element.role) “\(element.label)”")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.text)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Palette.ink.opacity(0.9), in: .capsule)
                .overlay(Capsule().strokeBorder(Palette.stroke))
                .fixedSize()
                .offset(x: frame.minX - 4, y: frame.minY - 30)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
        .animation(Motion.snappy, value: frame)
    }
}

private struct PinMarker: View {
    @State private var ripple = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Palette.accent, lineWidth: 1.5)
                .frame(width: 34, height: 34)
                .scaleEffect(ripple ? 1.6 : 0.4)
                .opacity(ripple ? 0 : 0.9)
            Circle()
                .fill(Palette.accent)
                .frame(width: 14, height: 14)
                .overlay(Circle().strokeBorder(.white, lineWidth: 2))
        }
        .allowsHitTesting(false)
        .transition(.scale(scale: 0.2).combined(with: .opacity))
        .onAppear {
            withAnimation(.easeOut(duration: 0.9)) { ripple = true }
        }
    }
}

private struct PinTray: View {
    var pins: [PracticePin]
    var aiming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Keycap(symbol: "⌥", size: 30, pressed: aiming)
                Text(aiming ? "Aiming. Click to pin." : "Hold ⌥ over the page")
                    .font(Typography.caption)
                    .foregroundStyle(aiming ? Palette.text : Palette.textSecondary)
                    .contentTransition(.opacity)
            }

            if pins.isEmpty {
                Text("Try pinning the tiny “Pay now” button.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(pins.reversed()) { pin in
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(pin.element.role) “\(pin.element.label)”")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(pin.element.source)
                        .font(Typography.mono)
                        .foregroundStyle(Palette.textTertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.06), in: .rect(cornerRadius: 8))
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular.tint(Palette.night.opacity(0.25)), in: .rect(cornerRadius: 20))
    }
}

private struct ShortcutRow: View {
    @Environment(AppModel.self) private var model
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "record.circle")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Start scouting from anywhere")
                    .font(Typography.headline)
                Text(recording ? "Press the new shortcut. Esc cancels." : "Press it in any app to start or stop scouting.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer()
            KeyCombo(symbols: model.shortcut.symbols, size: 30, pressed: recording)
                .opacity(recording ? 0.5 : 1)
            Button(recording ? "Cancel" : "Change") { recording ? stopRecording() : startRecording() }
                .buttonStyle(SecondaryButtonStyle())
        }
        .padding(.leading, 26)
        .padding(.trailing, 16)
        .frame(height: 64)
        .glassEffect(.regular.tint(Palette.night.opacity(0.25)), in: .capsule)
        .onDisappear(perform: stopRecording)
    }

    private func startRecording() {
        recording = true
        model.suspendShortcut()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }
            guard let shortcut = KeyShortcut(event: event) else {
                NSSound.beep()
                return nil
            }
            model.updateShortcut(shortcut)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { model.resumeShortcut() }
        recording = false
    }
}
