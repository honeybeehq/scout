import SwiftUI

struct VoiceSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences
        let store = model.whisperModels
        ScoutScroll {
            TranscriberSettingsContent(
                engine: $preferences.transcriptionEngine,
                whisper: store.snapshot,
                actions: WhisperModelActions(
                    download: {
                        preferences.transcriptionEngine = .whisper
                        store.download()
                    },
                    cancel: store.cancel,
                    remove: {
                        if preferences.transcriptionEngine == .whisper { preferences.transcriptionEngine = .apple }
                        store.remove()
                    }
                )
            )
            .padding(20)
        }
        .onAppear(perform: store.refresh)
    }
}

struct TranscriberSettingsContent: View {
    @Binding var engine: TranscriptionEngineChoice
    var whisper: WhisperModelSnapshot
    var actions: WhisperModelActions
    var confirmingRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSection(title: "Transcriber") {
                SettingRow(title: "Transcribe with", detail: nil, divider: false) {
                    SegmentedChoice(options: TranscriptionEngineChoice.allCases, selection: $engine, title: \.shortTitle)
                }
                SettingNote(text: engine.settingsNote)
                if engine == .whisper && !whisper.isInstalled {
                    HStack(spacing: 6) {
                        StatusDot(tone: .caution)
                        Text("Scout uses Apple until the Whisper model is installed.")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.caution)
                    }
                    .padding(.bottom, 10)
                    .transition(.opacity)
                }
            }
            WhisperModelSection(whisper: whisper, actions: actions, confirmingRemove: confirmingRemove)
        }
        .animation(Motion.smooth, value: whisper)
        .animation(Motion.smooth, value: engine)
    }
}

private struct WhisperModelSection: View {
    var whisper: WhisperModelSnapshot
    var actions: WhisperModelActions
    @State private var confirmingRemove: Bool

    init(whisper: WhisperModelSnapshot, actions: WhisperModelActions, confirmingRemove: Bool) {
        self.whisper = whisper
        self.actions = actions
        _confirmingRemove = State(initialValue: confirmingRemove)
    }

    var body: some View {
        SettingsSection(title: "Whisper model") {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(WhisperModelStore.displayName)
                        .font(Typography.headline)
                        .foregroundStyle(Palette.text)
                    status
                }
                Spacer(minLength: 12)
                trailing
            }
            .padding(.vertical, 10)
            if let progress = whisper.progress {
                DownloadMeter(progress: progress)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
            SettingNote(text: note)
        }
        .onChange(of: whisper.state) { _, state in
            if state != .ready { confirmingRemove = false }
        }
        .task(id: confirmingRemove) {
            guard confirmingRemove else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { confirmingRemove = false }
        }
    }

    private var note: String {
        switch whisper.state {
        case .preparing: "Scout prepares the model for this Mac's Neural Engine. \(PreparingLine.expectation) You can close Settings."
        default: "Downloaded once, checked before use, and kept on this Mac. Your audio never leaves it."
        }
    }

    @ViewBuilder
    private var status: some View {
        if case .preparing = whisper.state, let since = whisper.preparingSince {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                statusText(Text("Preparing model… \(PreparingLine.elapsed(from: since, to: context.date))"))
            }
        } else {
            statusText(statusLine)
        }
    }

    private var statusLine: Text {
        switch whisper.state {
        case .notInstalled where whisper.isPaused: Text(whisper.pausedLine)
        case .notInstalled: Text("Not installed · \(whisper.downloadSize) download")
        case .downloading: Text(whisper.downloadingLine)
        case .verifying: Text(whisper.verifyingLine)
        case .preparing: Text("Preparing model…")
        case .ready: Text(whisper.installedLine)
        case .failed(let reason): Text("\(Text("Scout couldn't set up Whisper.").foregroundStyle(Palette.negative)) \(reason)")
        }
    }

    private func statusText(_ line: Text) -> some View {
        line
            .font(Typography.caption.monospacedDigit())
            .foregroundStyle(Palette.textSecondary)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .contentTransition(.numericText())
    }

    @ViewBuilder
    private var trailing: some View {
        HStack(spacing: 8) {
            switch whisper.state {
            case .notInstalled where whisper.isPaused:
                Button("Remove", action: actions.remove)
                    .buttonStyle(QuietButtonStyle())
                Button("Resume", action: actions.download)
                    .buttonStyle(SecondaryButtonStyle())
            case .notInstalled:
                Button("Download", action: actions.download)
                    .buttonStyle(SecondaryButtonStyle())
            case .downloading, .verifying:
                Button("Cancel", action: actions.cancel)
                    .buttonStyle(SecondaryButtonStyle())
            case .preparing:
                WaitingDots()
            case .ready where confirmingRemove:
                Text("Remove the model?")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(Palette.negative)
                Button("Keep") { confirmingRemove = false }
                    .buttonStyle(QuietButtonStyle())
                Button("Remove") {
                    confirmingRemove = false
                    actions.remove()
                }
                .buttonStyle(DangerButtonStyle())
            case .ready:
                Button("Remove") { confirmingRemove = true }
                    .buttonStyle(SecondaryButtonStyle())
            case .failed:
                if whisper.partialBytes > 0 {
                    Button("Remove", action: actions.remove)
                        .buttonStyle(QuietButtonStyle())
                }
                Button("Try again", action: actions.download)
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .fixedSize()
    }
}

extension TranscriptionEngineChoice {
    var shortTitle: String {
        switch self {
        case .apple: "Apple"
        case .whisper: "Whisper"
        }
    }

    var settingsNote: String {
        switch self {
        case .apple: "Apple's built-in transcriber writes down your words live, on this Mac."
        case .whisper: "Apple still shows your words live. After you stop, Whisper writes the whole transcript again on this Mac."
        }
    }
}
