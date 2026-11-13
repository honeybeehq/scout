import SwiftUI

struct VoiceStep: View {
    @Environment(AppModel.self) private var model
    @State private var levels: [Float] = Array(repeating: 0, count: 48)

    private var heardEnough: Bool { model.transcriber.wordCount >= 4 }
    private var micGranted: Bool { model.permissions.state(of: .microphone).isGranted }

    var body: some View {
        let transcriber = model.transcriber
        StepLayout(
            eyebrow: "Voice",
            title: "Say something about an app.",
            message: "Scout writes down what you say as you say it, on this Mac. Your words matter most: they become the task."
        ) {
            VStack(spacing: 24) {
                TranscriptStage(finalized: transcriber.finalizedText, volatile: transcriber.volatileText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                LevelBars(levels: levels, active: transcriber.phase == .listening, tint: Palette.accent, square: true)
                    .frame(height: 44)

                status
                    .frame(height: 26)
            }
            .padding(24)
            .surfaceCard(Palette.surface, radius: Radius.panel)
        } footer: {
            BackButton()
            Spacer()
            if !heardEnough {
                Button("Skip") { model.onboarding.next() }
                    .buttonStyle(QuietButtonStyle())
            }
            Button("Continue") { model.onboarding.next() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!heardEnough)
                .keyboardShortcut(.defaultAction)
        }
        .task(id: micGranted) {
            guard micGranted else { return }
            model.configure(model.transcriber)
            await model.transcriber.start()
        }
        .onDisappear {
            Task { await model.transcriber.stop() }
        }
        .onChange(of: transcriber.level) { _, level in
            levels.removeFirst()
            levels.append(level)
        }
    }

    @ViewBuilder
    private var status: some View {
        let transcriber = model.transcriber
        if !micGranted {
            HStack(spacing: 12) {
                Text("Scout needs the microphone for this.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                Button("Allow microphone") {
                    Task { await model.permissions.request(.microphone) }
                }
                .buttonStyle(PrimaryButtonStyle(large: false))
            }
        } else if heardEnough {
            StatusBadge(text: "Scout hears you", tone: .positive)
                .transition(.rise)
        } else {
            switch transcriber.phase {
            case .idle:
                StatusBadge(text: "Starting…", tone: .neutral)
            case .preparing(let progress):
                StatusBadge(text: progress > 0 ? "Getting the voice model ready · \(Int(progress * 100))%" : "Getting the voice model ready", tone: .caution)
            case .listening:
                StatusBadge(text: "Listening on \(transcriber.inputName ?? "your microphone")", tone: .active)
            case .failed(let message):
                HStack(spacing: 10) {
                    StatusBadge(text: message, tone: .negative)
                    Button("Try again") { Task { await model.transcriber.start() } }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }
}

private struct TranscriptStage: View {
    var finalized: String
    var volatile: String

    var body: some View {
        Group {
            if finalized.isEmpty && volatile.isEmpty {
                Text("Try: “The save button is hard to find on this page.”")
                    .foregroundStyle(Palette.textTertiary)
            } else {
                Text("\(Text(finalized).foregroundStyle(Palette.text)) \(Text(volatile).foregroundStyle(Palette.textTertiary))")
            }
        }
        .font(Typography.transcript)
        .tracking(-0.3)
        .lineSpacing(6)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 680)
        .contentTransition(.opacity)
        .animation(Motion.snappy, value: finalized)
        .animation(Motion.snappy, value: volatile)
    }
}

struct LevelBars: View {
    var levels: [Float]
    var active: Bool
    var tint: Color = Palette.text
    var maxHeight: CGFloat = 44
    var barWidth: CGFloat = 4
    var square = false

    var body: some View {
        HStack(alignment: .center, spacing: barWidth) {
            ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                let edgeFade = min(1, Double(min(index, levels.count - 1 - index)) / 8 + 0.15)
                RoundedRectangle(cornerRadius: square ? barWidth * 0.25 : barWidth / 2, style: .continuous)
                    .fill(tint.opacity(active ? (levels.count > 12 ? edgeFade : 1) : 0.18))
                    .frame(width: barWidth, height: max(barWidth, CGFloat(level) * maxHeight))
            }
        }
        .animation(.linear(duration: 0.08), value: levels)
    }
}
