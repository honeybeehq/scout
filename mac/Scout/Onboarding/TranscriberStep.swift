import SwiftUI

struct TranscriberStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TranscriberStepContent(
            engine: model.preferences.transcriptionEngine,
            whisper: model.whisperModels.snapshot,
            useApple: {
                model.useAppleTranscriber()
                model.onboarding.next()
            },
            useWhisper: model.useWhisperTranscriber,
            actions: WhisperModelActions(download: model.installWhisper, cancel: model.whisperModels.cancel),
            onContinue: model.onboarding.next
        )
        .onAppear(perform: model.whisperModels.refresh)
    }
}

struct TranscriberStepContent: View {
    var engine: TranscriptionEngineChoice
    var whisper: WhisperModelSnapshot
    var useApple: () -> Void
    var useWhisper: () -> Void
    var actions: WhisperModelActions
    var onContinue: () -> Void

    var body: some View {
        StepLayout(
            eyebrow: "Transcriber",
            title: "Choose how Scout writes down your words.",
            message: "Both run on this Mac. You can change this later in Settings."
        ) {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 16) {
                    EngineCard(
                        symbol: "waveform",
                        title: "Built-in Apple transcriber",
                        subtitle: "Ready now · nothing to download",
                        message: "Writes down your words live while you talk.",
                        selected: engine == .apple
                    ) {
                        Button("Use Apple", action: useApple)
                            .buttonStyle(SecondaryButtonStyle())
                    }
                    EngineCard(
                        symbol: "text.magnifyingglass",
                        title: "\(WhisperModelStore.displayName), on device",
                        subtitle: "\(whisper.downloadSize) download",
                        message: "Writes the whole transcript again after you stop. Apple still shows your words live.",
                        selected: engine == .whisper
                    ) {
                        WhisperCardAction(engine: engine, whisper: whisper, useWhisper: useWhisper, actions: actions)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        } footer: {
            BackButton()
            Spacer()
            if engine == .whisper && whisper.state.isBusy {
                Text("Whisper keeps installing if you continue.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .transition(.opacity)
            }
            Button("Continue", action: onContinue)
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
        .animation(Motion.smooth, value: whisper)
        .animation(Motion.smooth, value: engine)
    }
}

private struct EngineCard<Action: View>: View {
    var symbol: String
    var title: String
    var subtitle: String
    var message: String
    var selected: Bool
    @ViewBuilder var action: Action

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                IconOrb(symbol: symbol, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(Typography.headline)
                        .foregroundStyle(Palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .font(Typography.caption.monospacedDigit())
                        .foregroundStyle(Palette.textSecondary)
                }
                Spacer(minLength: 8)
                if selected {
                    StateTag(text: "Selected", tone: .neutral)
                        .transition(.opacity)
                }
            }
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            action
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .bottomLeading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .surfaceCard(Palette.surface, radius: Radius.panel, stroke: selected ? Palette.strokeStrong : Palette.hairline)
    }
}

private struct WhisperCardAction: View {
    var engine: TranscriptionEngineChoice
    var whisper: WhisperModelSnapshot
    var useWhisper: () -> Void
    var actions: WhisperModelActions

    var body: some View {
        switch whisper.state {
        case .notInstalled:
            VStack(alignment: .leading, spacing: 8) {
                if whisper.isPaused {
                    Text(whisper.pausedLine)
                        .font(Typography.caption.monospacedDigit())
                        .foregroundStyle(Palette.textSecondary)
                }
                Button(whisper.isPaused ? "Resume download" : "Download and install", action: actions.download)
                    .buttonStyle(SecondaryButtonStyle())
            }
        case .downloading, .verifying:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text(whisper.state.isDownloading ? whisper.downloadingLine : whisper.verifyingLine)
                        .font(Typography.caption.monospacedDigit())
                        .foregroundStyle(Palette.text)
                        .contentTransition(.numericText())
                    Spacer(minLength: 8)
                    Button("Cancel", action: actions.cancel)
                        .buttonStyle(QuietButtonStyle())
                }
                DownloadMeter(progress: whisper.progress ?? 0)
            }
        case .preparing:
            VStack(alignment: .leading, spacing: 4) {
                PreparingLine(since: whisper.preparingSince)
                Text(PreparingLine.expectation)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
        case .installed, .ready:
            if engine == .whisper {
                HStack(spacing: 8) {
                    Checkmark(size: 20)
                    Text(whisper.state == .ready ? "Ready" : "Installed")
                        .font(Typography.headline)
                        .foregroundStyle(Palette.text)
                }
            } else {
                Button("Use Whisper", action: useWhisper)
                    .buttonStyle(SecondaryButtonStyle())
            }
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        StatusDot(tone: .negative)
                        Text("Scout couldn't set up Whisper.")
                            .font(Typography.headline)
                            .foregroundStyle(Palette.negative)
                    }
                    Text(reason)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Try again", action: actions.download)
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
    }
}
