import SwiftUI

struct ScoutingPill: View {
    @Environment(AppModel.self) private var model
    @State private var levels: [Float] = Array(repeating: 0, count: 7)

    var body: some View {
        if let session = model.session {
            HStack(spacing: 12) {
                RecordingDot(active: session.phase == .live)
                Text(Self.clock(session.elapsed))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Palette.text)

                LevelBars(levels: levels, active: session.phase == .live, tint: Palette.flare, maxHeight: 22, barWidth: 3)
                    .frame(width: 40, height: 22)

                liveText(session)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if session.closedCount > 0 {
                    Text("\(session.closedCount)")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(Palette.ink)
                        .frame(minWidth: 22, minHeight: 22)
                        .background(Palette.flareGradient, in: .circle)
                        .transition(.scale.combined(with: .opacity))
                        .help("Snippets captured")
                }

                Button {
                    session.splitNow()
                } label: {
                    Image(systemName: "scissors")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.textSecondary)
                .help("Cut here and start a new task")

                Button {
                    model.toggleScouting()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Palette.rose.opacity(0.85), in: .circle)
                }
                .buttonStyle(.plain)
                .help("Stop scouting")
            }
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .frame(width: HUDController.pillSize.width, height: HUDController.pillSize.height)
            .glassEffect(.regular.tint(Palette.ink.opacity(0.55)), in: .capsule)
            .animation(Motion.snappy, value: session.closedCount)
            .onChange(of: session.transcriber.level) { _, level in
                levels.removeFirst()
                levels.append(level)
            }
        }
    }

    @ViewBuilder
    private func liveText(_ session: ScoutingSession) -> some View {
        let transcriber = session.transcriber
        switch session.phase {
        case .starting:
            Text(startingText(transcriber.phase))
                .font(.system(size: 13))
                .foregroundStyle(Palette.textSecondary)
        case .failed(let message):
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Palette.rose)
                .lineLimit(1)
        case .live, .ended:
            let tail = Self.tail(of: transcriber.finalizedText, keeping: 44)
            if tail.isEmpty && transcriber.volatileText.isEmpty {
                Text(hint(session))
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
            } else {
                Text("\(Text(tail).foregroundStyle(Palette.textSecondary)) \(Text(transcriber.volatileText).foregroundStyle(Palette.text))")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
    }

    private func hint(_ session: ScoutingSession) -> String {
        if let target = session.hoverTarget { return "Pointing at \(target.displayName)" }
        return "Listening. Talk about what you see."
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
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !active)) { context in
            let pulse = (sin(context.date.timeIntervalSinceReferenceDate * 3.2) + 1) / 2
            Circle()
                .fill(Palette.flare)
                .frame(width: 10, height: 10)
                .shadow(color: Palette.flare.opacity(0.4 + 0.5 * pulse), radius: 4 + 5 * pulse)
                .opacity(active ? 0.75 + 0.25 * pulse : 0.4)
        }
    }
}
