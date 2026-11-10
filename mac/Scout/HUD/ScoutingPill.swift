import SwiftUI

struct ScoutingPill: View {
    @Environment(AppModel.self) private var model
    @State private var levels: [Float] = Array(repeating: 0, count: 7)

    enum Slot {
        static let clock: CGFloat = 76
        static let levels: CGFloat = 26
        static let transcript: CGFloat = 280
        static let task: CGFloat = 128
        static let capture: CGFloat = 220
        static let discard: CGFloat = 104
        static let finish: CGFloat = 96
        static let spacing: CGFloat = 8
        static let inset: CGFloat = 8
    }

    static let barHeight: CGFloat = 36
    static let barWidth: CGFloat = Slot.inset * 2 + Slot.clock + Slot.levels + Slot.transcript + Slot.task + Slot.capture + Slot.discard + Slot.finish + Slot.spacing * 6
    static let windowSize = CGSize(width: barWidth, height: barHeight + 8)
    static let cornerRadius: CGFloat = 12

    var body: some View {
        let session = model.session
        let live = session?.phase == .live
        let confirming = model.confirmingDiscard
        let hearing: Bool = if case .failed = session?.transcriber.phase { false } else { live }
        let manual = session?.segmentation == .manual
        HStack(spacing: Slot.spacing) {
            HStack(spacing: 6) {
                RecordingDot(active: live && !confirming)
                Text(Self.clock(session?.elapsed ?? 0))
                    .font(.system(size: 12.5, weight: .bold).monospacedDigit())
                    .lineLimit(1)
            }
            .foregroundStyle(live && !confirming ? Palette.onAccent : Palette.textSecondary)
            .frame(width: Slot.clock, height: 28)
            .background(live && !confirming ? Palette.recording : Palette.raised, in: .rect(cornerRadius: Radius.control, style: .continuous))
            .barSlot("clock")

            LevelBars(levels: hearing ? levels : Array(repeating: 0, count: levels.count), active: hearing, tint: Palette.accent, maxHeight: 16, barWidth: 2, square: true)
                .frame(width: Slot.levels, height: 16)
                .barSlot("levels")

            ZStack(alignment: .leading) {
                HStack(spacing: Slot.spacing) {
                    transcript(session)
                        .frame(width: Slot.transcript + (manual ? 0 : Slot.task + Slot.spacing), alignment: .leading)
                        .mask(FadeEdge())
                        .barSlot("transcript")
                    if manual, let session {
                        taskButton(session)
                    }
                    captureButton(session)
                }
                .opacity(confirming ? 0 : 1)
                .allowsHitTesting(!confirming)
                if confirming {
                    DiscardQuestion(model: model)
                        .barSlot("question")
                        .transition(.opacity)
                }
            }
            .frame(width: Slot.transcript + Slot.task + Slot.capture + Slot.spacing * 2, alignment: .leading)

            discardButton

            Button {
                model.finishScouting(input: InteractionTimings.now)
            } label: {
                HStack(spacing: 6) {
                    Text("Finish")
                    KeyHint(model.shortcut.symbols.joined(), emphasized: true)
                }
                .frame(width: Slot.finish, height: 28)
            }
            .buttonStyle(BarButtonStyle(fill: Palette.ink, foreground: Palette.onInk, bold: true))
            .barSlot("finish")
            .help("Finish and review")
        }
        .padding(.horizontal, Slot.inset)
        .frame(width: Self.barWidth, height: Self.barHeight)
        .barSlot("bar")
        .background(Palette.hud, in: NotchShape(radius: Self.cornerRadius))
        .overlay(NotchShape(radius: Self.cornerRadius).strokeBorder(Palette.stroke).padding(.top, -2).clipped())
        .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
        .frame(width: Self.windowSize.width, height: Self.windowSize.height, alignment: .top)
        .coordinateSpace(.named(BarLayoutProbe.space))
        .scaledToUISize()
        .animation(Motion.snappy, value: confirming)
        .animation(Motion.snappy, value: session?.confirmingBreak)
        .task(id: confirming) {
            guard confirming else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { model.confirmingDiscard = false }
        }
        .onChange(of: session?.transcriber.level) { _, level in
            levels.removeFirst()
            levels.append(level ?? 0)
        }
    }

    @ViewBuilder
    private func transcript(_ session: ScoutingSession?) -> some View {
        if let session, session.confirmingBreak {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(Palette.accentText)
                Text(session.walkthrough == nil ? "New task" : "New ask")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Palette.text)
                Text("Keep talking.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textTertiary)
            }
            .lineLimit(1)
            .transition(.opacity)
            .barSlot("break")
        } else if let session {
            liveText(session)
        } else {
            Text("Starting…")
                .font(.system(size: 12))
                .foregroundStyle(Palette.textSecondary)
        }
    }

    private func taskButton(_ session: ScoutingSession) -> some View {
        Button {
            session.splitNow()
        } label: {
            HStack(spacing: 5) {
                Text("Task \(session.closedCount + 1)")
                    .monospacedDigit()
                    .lineLimit(1)
                Text("Next")
                Spacer(minLength: 0)
                KeyHint(model.breakShortcut.symbols.joined())
            }
            .padding(.horizontal, 8)
            .frame(width: Slot.task, height: 28)
        }
        .buttonStyle(BarButtonStyle())
        .barSlot("task")
        .help("End this task and start the next one")
    }

    private func captureButton(_ session: ScoutingSession?) -> some View {
        let follower = session?.follower
        let following = (follower?.scope ?? .follow) == .follow
        return Button {
            let input = InteractionTimings.now
            if NSEvent.modifierFlags.contains(.shift) {
                follower?.follow(input: input)
            } else {
                follower?.expand(input: input)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: following ? "viewfinder" : "lock.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Palette.accentText)
                    .frame(width: 12)
                Text(follower?.scopeTitle ?? "Following")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                StatusDot(tone: .caution, size: 6)
                    .opacity(session?.captureProblem != nil ? 1 : 0)
                KeyHint(following ? model.widenShortcut.label : model.followShortcut.label)
            }
            .padding(.horizontal, 8)
            .frame(width: Slot.capture, height: 28)
        }
        .buttonStyle(BarButtonStyle())
        .barSlot("capture")
        .help(session?.captureProblem ?? (following ? "Widen the captured area (\(model.widenShortcut.label)). \(model.followShortcut.label) follows the pointer again." : "Widen further (\(model.widenShortcut.label)), or follow the pointer again (\(model.followShortcut.label))"))
    }

    private var discardButton: some View {
        let discardable = model.canDiscardScouting
        let confirming = model.confirmingDiscard
        let shortcut = model.discardShortcut.label
        return Button {
            if confirming {
                model.confirmingDiscard = false
                Task { await model.discardScouting() }
            } else {
                model.confirmingDiscard = true
            }
        } label: {
            HStack(spacing: 5) {
                Text("Discard")
                KeyHint(shortcut, emphasized: confirming)
            }
            .frame(width: Slot.discard, height: 28)
        }
        .buttonStyle(BarButtonStyle(fill: confirming ? Palette.negativeFill : Palette.fillRaised, foreground: confirming ? .white : Palette.text, bold: confirming))
        .disabled(!discardable)
        .opacity(discardable ? 1 : 0.5)
        .barSlot("discard")
        .help(discardable ? "Stop and delete this recording (\(shortcut), then \(shortcut) again). Nothing is sent or copied." : "A task from this recording was already sent, so it can't be discarded. Finish keeps it.")
    }

    @ViewBuilder
    private func liveText(_ session: ScoutingSession) -> some View {
        let transcriber = session.transcriber
        switch session.phase {
        case .starting:
            Text(startingText(transcriber.phase))
                .font(.system(size: 12))
                .foregroundStyle(Palette.textSecondary)
        case .failed(let message):
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
        case .live, .ended:
            let tail = Self.tail(of: transcriber.finalizedText, keeping: 36)
            if case .failed(let message) = transcriber.phase {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Palette.caution)
                        .frame(width: 6, height: 6)
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .help(message)
            } else if session.aim.isAiming || (tail.isEmpty && transcriber.volatileText.isEmpty) {
                Text(hint(session))
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
            } else {
                Text("\(Text(tail).foregroundStyle(Palette.textSecondary)) \(Text(transcriber.volatileText).foregroundStyle(Palette.text))")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
    }

    private func hint(_ session: ScoutingSession) -> String {
        if session.aim.isAiming { return "Click to pin · drag to draw" }
        if let target = session.hoverTarget { return "Pointing at \(target.displayName)" }
        return "Listening…"
    }

    private func startingText(_ phase: LiveTranscriber.Phase) -> String {
        if case .preparing(let progress) = phase, progress > 0 {
            return "Getting the voice model ready · \(Int(progress * 100))%"
        }
        return "Starting…"
    }

    static func tail(of text: String, keeping count: Int) -> String {
        guard text.count > count else { return text }
        let suffix = text.suffix(count)
        guard let space = suffix.firstIndex(of: " ") else { return "…" + suffix }
        return "…" + suffix[suffix.index(after: space)...]
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct RecordingDot: View {
    var active: Bool

    var body: some View {
        let active = active
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !active)) { @Sendable context in
            let pulse = (sin(context.date.timeIntervalSinceReferenceDate * 3.2) + 1) / 2
            Circle()
                .fill(active ? Palette.onAccent : Palette.textTertiary)
                .frame(width: 8, height: 8)
                .opacity(active ? 0.45 + 0.55 * pulse : 1)
        }
    }
}

private struct DiscardQuestion: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Text("Discard this recording?")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Palette.negative)
                .lineLimit(1)
            Text("Recording carries on.")
                .font(.system(size: 12))
                .foregroundStyle(Palette.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button {
                model.confirmingDiscard = false
            } label: {
                HStack(spacing: 5) {
                    Text("Keep")
                    KeyHint("esc")
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
            }
            .buttonStyle(BarButtonStyle())
            .barSlot("keep")
            .help("Keep going. Nothing is deleted.")
        }
        .padding(.leading, 4)
    }
}

struct NotchShape: InsettableShape {
    var radius: CGFloat
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: inset, dy: inset)
        return UnevenRoundedRectangle(bottomLeadingRadius: max(radius - inset, 0), bottomTrailingRadius: max(radius - inset, 0), style: .continuous).path(in: rect)
    }

    func inset(by amount: CGFloat) -> NotchShape {
        NotchShape(radius: radius, inset: inset + amount)
    }
}

private struct FadeEdge: View {
    var body: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: 14)
            Color.black
        }
    }
}

struct BarButtonStyle: ButtonStyle {
    var fill: Color = Palette.fillRaised
    var foreground: Color = Palette.text
    var bold = false

    func makeBody(configuration: Configuration) -> some View {
        BarButtonBody(label: configuration.label, pressed: configuration.isPressed, style: self)
    }
}

private struct BarButtonBody<Label: View>: View {
    let label: Label
    let pressed: Bool
    let style: BarButtonStyle
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.barHoverPreview) private var hoverPreview

    var body: some View {
        let hovered = (hovering || hoverPreview) && isEnabled
        label
            .font(.system(size: style.bold ? 12 : 11.5, weight: style.bold ? .bold : .semibold))
            .foregroundStyle(style.foreground)
            .background(style.fill, in: .rect(cornerRadius: Radius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(Palette.text.opacity(pressed ? 0.14 : hovered ? 0.08 : 0))
            }
            .contentShape(.rect(cornerRadius: Radius.control))
            .onHover { hovering = $0 }
            .animation(Motion.snappy, value: hovered)
            .animation(Motion.snappy, value: pressed)
    }
}

@MainActor
final class BarLayoutProbe {
    nonisolated static let space = "scout-bar"
    var frames: [String: CGRect] = [:]
}

extension EnvironmentValues {
    @Entry var barHoverPreview = false
    @Entry var barLayoutProbe: BarLayoutProbe? = nil
}

private struct BarSlot: ViewModifier {
    let name: String
    @Environment(\.barLayoutProbe) private var probe

    func body(content: Content) -> some View {
        if let probe {
            content.onGeometryChange(for: CGRect.self) { $0.frame(in: .named(BarLayoutProbe.space)) } action: { probe.frames[name] = $0 }
        } else {
            content
        }
    }
}

private extension View {
    func barSlot(_ name: String) -> some View {
        modifier(BarSlot(name: name))
    }
}
