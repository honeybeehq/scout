import SwiftUI

struct ScoutingPill: View {
    @Environment(AppModel.self) private var model
    @State private var levels: [Float] = Array(repeating: 0, count: 7)

    var body: some View {
        let session = model.session
        let live = session?.phase == .live
        let hearing: Bool = if case .failed = session?.transcriber.phase { false } else { live }
        let follower = session?.follower
        HStack(spacing: 10) {
            RecordingDot(active: live)
            Text(Self.clock(session?.elapsed ?? 0))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Palette.text)
                .frame(minWidth: 34, alignment: .leading)

            LevelBars(levels: hearing ? levels : Array(repeating: 0, count: levels.count), active: hearing, tint: .white, maxHeight: 16, barWidth: 2)
                .frame(width: 26, height: 16)

            Group {
                if let session {
                    liveText(session)
                } else {
                    Text("Starting…")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            .frame(maxWidth: model.confirmingDiscard ? 120 : 260, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)

            if !model.confirmingDiscard {
                if let session, session.segmentation == .manual {
                    Button {
                        session.splitNow()
                    } label: {
                        HStack(spacing: 5) {
                            Text("Task \(session.closedCount + 1) · Next")
                                .contentTransition(.numericText())
                            KeyHint(model.breakShortcut.symbols.joined())
                        }
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Palette.text)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .overlay(Capsule().strokeBorder(Palette.stroke))
                    }
                    .buttonStyle(.plain)
                    .help("End this task and start the next one")
                }

                let following = (follower?.scope ?? .follow) == .follow
                Button {
                    let input = InteractionTimings.now
                    if NSEvent.modifierFlags.contains(.shift) {
                        follower?.follow(input: input)
                    } else {
                        follower?.expand(input: input)
                    }
                } label: {
                    HStack(spacing: 5) {
                        if session?.captureProblem != nil {
                            Circle()
                                .fill(Palette.caution)
                                .frame(width: 6, height: 6)
                        }
                        Image(systemName: following ? "arrow.up.left.and.arrow.down.right" : "lock.fill")
                            .font(.system(size: 9.5, weight: .semibold))
                        Text(follower?.scopeTitle ?? "Following")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 190, alignment: .leading)
                            .fixedSize(horizontal: true, vertical: false)
                        KeyHint(following ? model.widenShortcut.label : model.followShortcut.label)
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Palette.text)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .overlay(Capsule().strokeBorder(Palette.stroke))
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .help(session?.captureProblem ?? (following ? "Widen the captured area (\(model.widenShortcut.label)). \(model.followShortcut.label) follows the pointer again." : "Widen further (\(model.widenShortcut.label)), or follow the pointer again (\(model.followShortcut.label))"))
            }

            let discardable = model.canDiscardScouting
            DiscardControl(question: "Discard this recording?", help: discardable ? "Stop and delete this recording (\(model.discardShortcut.label), then \(model.discardShortcut.label) again). Nothing is sent or copied." : "A task from this recording was already sent, so it can't be discarded. Finish keeps it.", shortcut: model.discardShortcut.label, asking: Bindable(model).confirmingDiscard) {
                Task { await model.discardScouting() }
            }
            .disabled(!discardable)
            .opacity(discardable ? 1 : 0.5)

            Button {
                model.finishScouting(input: InteractionTimings.now)
            } label: {
                HStack(spacing: 6) {
                    Text("Finish")
                    KeyHint(model.shortcut.symbols.joined())
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.text)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Palette.fillStrong, in: .capsule)
            }
            .buttonStyle(.plain)
            .help("Finish and review")
        }
        .padding(.leading, 12)
        .padding(.trailing, 5)
        .frame(height: HUDController.pillHeight)
        .glassEffect(.regular.tint(Palette.ink.opacity(0.55)), in: .capsule)
        .overlay(Capsule().strokeBorder(Palette.hairline))
        .fixedSize()
        .frame(width: HUDController.pillSize.width, height: HUDController.pillSize.height, alignment: .leading)
        .scaledToUISize()
        .animation(Motion.snappy, value: session?.closedCount)
        .animation(Motion.snappy, value: follower?.scopeTitle)
        .onChange(of: session?.transcriber.level) { _, level in
            levels.removeFirst()
            levels.append(level ?? 0)
        }
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
                .fill(Palette.accent)
                .frame(width: 9, height: 9)
                .opacity(active ? 0.55 + 0.45 * pulse : 0.35)
        }
    }
}
