import ScoutCore
import SwiftUI

struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ScoutMark(level: 3, pulsing: model.isScouting)
                    .frame(width: 22, height: 22)
                Text("Scout").font(.system(size: 15, weight: .heavy))
                Spacer()
                if model.isScouting {
                    StateTag(text: "Rec", tone: .active)
                } else {
                    StateTag(text: "Ready", tone: .neutral)
                }
            }

            Button {
                model.toggleScouting()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: model.isScouting ? "stop.fill" : "record.circle.fill")
                    Text(model.isScouting ? "Stop scouting" : "Start scouting")
                    Spacer()
                    KeyHint(model.shortcut.symbols.joined(), emphasized: true)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle(large: true))

            if let walkthrough = model.lastWalkthrough {
                LastWalkthroughRow(walkthrough: walkthrough)
            } else if let problem = model.walkthroughProblem {
                Text(problem)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
            }

            VStack(spacing: 0) {
                HStack {
                    Text("Split what you say into tasks")
                        .font(Typography.callout)
                        .foregroundStyle(Palette.textSecondary)
                    Spacer()
                    Button("Split into tasks") { model.startSplitTasks() }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(model.isScouting)
                }
                .padding(.vertical, 8)
                Rectangle().fill(Palette.hairline).frame(height: 1)
                SegmentationToggle()
                    .padding(.vertical, 8)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("Recent").eyebrowStyle(Palette.textTertiary)
                    let sent = model.dispatcher.cards.suffix(5).filter { $0.state.isFinished }.count
                    if sent > 0 {
                        Text("\(sent) sent")
                            .font(Typography.caption.monospacedDigit())
                            .foregroundStyle(Palette.positive)
                    }
                    Spacer()
                    Button("Review") { model.openLatestReview() }
                        .buttonStyle(QuietButtonStyle())
                }
                if model.review?.saveError != nil {
                    HStack(spacing: 6) {
                        StatusDot(tone: .negative, size: 5)
                        Text("Couldn't save the last session")
                    }
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                }
                let recent = model.dispatcher.cards.suffix(5).reversed()
                if recent.isEmpty {
                    Text("Tasks you capture show up here.")
                        .font(Typography.callout)
                        .foregroundStyle(Palette.textTertiary)
                        .padding(.vertical, 4)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(recent)) { card in
                            RecentTaskRow(card: card)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surfaceCard(Palette.surface)

            integrationLine

            Rectangle().fill(Palette.hairline).frame(height: 1)

            HStack(spacing: 2) {
                Button(model.onboarding.isComplete ? "Setup guide" : "Finish setup") {
                    model.onboarding.restart()
                    model.openOnboarding?()
                }
                .buttonStyle(QuietButtonStyle())
                Button("Settings") { model.openSettingsWindow?() }
                    .buttonStyle(QuietButtonStyle())
                Spacer()
                Button {
                    NSApp.terminate(nil)
                } label: {
                    HStack(spacing: 5) {
                        Text("Quit")
                        KeyHint("⌘Q")
                    }
                }
                .buttonStyle(QuietButtonStyle())
                .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(Palette.canvas)
        .scaledToUISize()
        .task { await model.integrations.refresh() }
    }

    private var integrationLine: some View {
        HStack(spacing: 6) {
            switch model.integrations.hive {
            case .connected(let count): StatusBadge(text: "hive · \(count) active", tone: .positive)
            case .checking: StatusBadge(text: "hive · checking", tone: .caution)
            case .unreachable: StatusBadge(text: "hive · not responding", tone: .negative)
            case .missing: StatusBadge(text: "hive · not installed", tone: .neutral)
            }
            if model.integrations.apiary == .running {
                StatusBadge(text: "Apiary", tone: .positive)
            }
            let apps = model.bridge.clients.filter { $0.hello != nil }
            if !apps.isEmpty {
                StatusBadge(text: apps.count == 1 ? "SDK · \(apps[0].name)" : "SDK · \(apps.count) apps", tone: .positive)
                    .help(apps.map(\.name).joined(separator: ", "))
            }
        }
    }
}

private struct SegmentationToggle: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences
        HStack(spacing: 10) {
            Text("New task on")
                .font(Typography.callout)
                .foregroundStyle(Palette.textSecondary)
            Spacer()
            SegmentedChoice(options: Segmentation.allCases, selection: $preferences.segmentation) { mode in
                mode == .automatic ? "Auto" : "\(model.breakShortcut.symbols.joined()) only"
            }
            .disabled(model.isScouting)
        }
        .help(preferences.segmentation.explanation)
    }
}

private struct RecentTaskRow: View {
    let card: SnippetCard

    var body: some View {
        HStack(spacing: 8) {
            StateRail(color: CardStateTag.color(for: card.state))
                .frame(height: 14)
            Text(card.title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(card.state.isFinished ? Palette.textSecondary : Palette.text)
                .lineLimit(1)
            Spacer(minLength: 4)
            if card.state.isFinished {
                Image(systemName: "checkmark")
                    .font(.system(size: 10.5, weight: .heavy))
                    .foregroundStyle(Palette.positive)
            } else {
                CardStateTag(state: card.state)
            }
        }
        .frame(height: 26)
    }
}

private struct LastWalkthroughRow: View {
    @Environment(AppModel.self) private var model
    let walkthrough: FinishedWalkthrough

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(walkthrough.walkthrough.title ?? "Walkthrough")
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text(summary)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary)
                if let failure = walkthrough.walkthrough.transcript.failure {
                    HStack(spacing: 5) {
                        StatusDot(tone: .caution, size: 5)
                        Text("\(TranscriptProblem.title(failure)): no transcript")
                    }
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                }
            }
            Spacer(minLength: 4)
            Button("Send…") { model.sendLastWalkthrough() }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.isScouting)
            Button("Copy") { model.copyLastWalkthrough() }
                .buttonStyle(QuietButtonStyle())
            Button {
                model.revealLastWalkthrough()
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.textSecondary)
            .help("Show in Finder")
        }
    }

    private var summary: String {
        let value = walkthrough.walkthrough
        let asks = value.asks.items.count
        return "\(WalkthroughText.clock(value.duration)) · \(asks) \(asks == 1 ? "ask" : "asks") · copied, paste with ⌘V"
    }
}
