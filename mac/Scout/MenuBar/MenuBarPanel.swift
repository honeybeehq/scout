import ScoutCore
import SwiftUI

struct MenuBarPanelState {
    struct RecentTask: Identifiable {
        let id: String
        let title: String
        let state: SnippetCard.State
    }

    struct WalkthroughSummary {
        let title: String
        let summary: String
        let transcriptProblem: String?
    }

    var isScouting = false
    var shortcut = "⌃⌥S"
    var breakShortcut = "⌃⌥B"
    var recent: [RecentTask] = []
    var lastSessionSaveFailed = false
    var lastWalkthrough: WalkthroughSummary?
    var walkthroughProblem: String?
    var hive: Integrations.HiveStatus = .checking
    var apiaryRunning = false
    var sdkApps: [String] = []
    var setupComplete = true
}

struct MenuBarPanelActions {
    var toggleScouting: () -> Void = {}
    var splitIntoTasks: () -> Void = {}
    var openReview: () -> Void = {}
    var sendWalkthrough: () -> Void = {}
    var copyWalkthrough: () -> Void = {}
    var revealWalkthrough: () -> Void = {}
    var openSetup: () -> Void = {}
    var openSettings: () -> Void = {}
    var quit: () -> Void = {}
}

struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var preferences = model.preferences
        MenuBarPanelContent(state: state, segmentation: $preferences.segmentation, actions: actions)
            .scaledToUISize()
            .task { await model.integrations.refresh() }
    }

    private var state: MenuBarPanelState {
        MenuBarPanelState(
            isScouting: model.isScouting,
            shortcut: model.shortcut.symbols.joined(),
            breakShortcut: model.breakShortcut.symbols.joined(),
            recent: model.dispatcher.cards.suffix(5).reversed().map { .init(id: $0.id, title: $0.title, state: $0.state) },
            lastSessionSaveFailed: model.review?.saveError != nil,
            lastWalkthrough: model.lastWalkthrough.map(Self.summary),
            walkthroughProblem: model.walkthroughProblem,
            hive: model.integrations.hive,
            apiaryRunning: model.integrations.apiary == .running,
            sdkApps: model.bridge.clients.filter { $0.hello != nil }.map(\.name),
            setupComplete: model.onboarding.isComplete
        )
    }

    private var actions: MenuBarPanelActions {
        MenuBarPanelActions(
            toggleScouting: { model.toggleScouting() },
            splitIntoTasks: { model.startSplitTasks() },
            openReview: { model.openLatestReview() },
            sendWalkthrough: { model.sendLastWalkthrough() },
            copyWalkthrough: { model.copyLastWalkthrough() },
            revealWalkthrough: { model.revealLastWalkthrough() },
            openSetup: {
                model.onboarding.restart()
                model.openOnboarding?()
            },
            openSettings: { model.openSettingsWindow?() },
            quit: { NSApp.terminate(nil) }
        )
    }

    private static func summary(_ finished: FinishedWalkthrough) -> MenuBarPanelState.WalkthroughSummary {
        let value = finished.walkthrough
        let asks = value.asks.items.count
        return .init(
            title: value.title ?? "Walkthrough",
            summary: "\(WalkthroughText.clock(value.duration)) · \(asks) \(asks == 1 ? "ask" : "asks") · copied, paste with ⌘V",
            transcriptProblem: value.transcript.failure.map { "\(TranscriptProblem.title($0)): no transcript" }
        )
    }
}

struct MenuBarPanelContent: View {
    let state: MenuBarPanelState
    @Binding var segmentation: Segmentation
    let actions: MenuBarPanelActions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ScoutMark(level: 3, pulsing: state.isScouting)
                    .frame(width: 22, height: 22)
                Text("Scout").font(.system(size: 15, weight: .heavy))
                Spacer()
                if state.isScouting {
                    StateTag(text: "Rec", tone: .active)
                } else {
                    StateTag(text: "Ready", tone: .neutral)
                }
            }

            Button(action: actions.toggleScouting) {
                HStack(spacing: 8) {
                    Image(systemName: state.isScouting ? "stop.fill" : "record.circle.fill")
                    Text(state.isScouting ? "Stop scouting" : "Start scouting")
                    Spacer()
                    KeyHint(state.shortcut, emphasized: true)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle(large: true))

            if let walkthrough = state.lastWalkthrough {
                LastWalkthroughRow(walkthrough: walkthrough, isScouting: state.isScouting, actions: actions)
            } else if let problem = state.walkthroughProblem {
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
                    Button("Split into tasks", action: actions.splitIntoTasks)
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(state.isScouting)
                }
                .padding(.vertical, 8)
                Rectangle().fill(Palette.hairline).frame(height: 1)
                HStack(spacing: 10) {
                    Text("New task on")
                        .font(Typography.callout)
                        .foregroundStyle(Palette.textSecondary)
                    Spacer()
                    SegmentedChoice(options: Segmentation.allCases, selection: $segmentation) { mode in
                        mode == .automatic ? "Auto" : "\(state.breakShortcut) only"
                    }
                    .disabled(state.isScouting)
                }
                .help(segmentation.explanation)
                .padding(.vertical, 8)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("Recent").eyebrowStyle(Palette.textTertiary)
                    let sent = state.recent.filter { $0.state.isFinished }.count
                    if sent > 0 {
                        Text("\(sent) sent")
                            .font(Typography.caption.monospacedDigit())
                            .foregroundStyle(Palette.positive)
                    }
                    Spacer()
                    Button("Review", action: actions.openReview)
                        .buttonStyle(QuietButtonStyle())
                }
                if state.lastSessionSaveFailed {
                    HStack(spacing: 6) {
                        StatusDot(tone: .negative, size: 5)
                        Text("Couldn't save the last session")
                    }
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                }
                if state.recent.isEmpty {
                    Text("Tasks you capture show up here.")
                        .font(Typography.callout)
                        .foregroundStyle(Palette.textTertiary)
                        .padding(.vertical, 4)
                } else {
                    VStack(spacing: 0) {
                        ForEach(state.recent) { task in
                            RecentTaskRow(task: task)
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
                Button(state.setupComplete ? "Setup guide" : "Finish setup", action: actions.openSetup)
                    .buttonStyle(QuietButtonStyle())
                Button("Settings", action: actions.openSettings)
                    .buttonStyle(QuietButtonStyle())
                Spacer()
                Button(action: actions.quit) {
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
    }

    private var integrationLine: some View {
        HStack(spacing: 6) {
            switch state.hive {
            case .connected(let count): StatusBadge(text: "hive · \(count) active", tone: .positive)
            case .checking: StatusBadge(text: "hive · checking", tone: .caution)
            case .unreachable: StatusBadge(text: "hive · not responding", tone: .negative)
            case .missing: StatusBadge(text: "hive · not installed", tone: .neutral)
            }
            if state.apiaryRunning {
                StatusBadge(text: "Apiary", tone: .positive)
            }
            if !state.sdkApps.isEmpty {
                StatusBadge(text: state.sdkApps.count == 1 ? "SDK · \(state.sdkApps[0])" : "SDK · \(state.sdkApps.count) apps", tone: .positive)
                    .help(state.sdkApps.joined(separator: ", "))
            }
        }
    }
}

private struct RecentTaskRow: View {
    let task: MenuBarPanelState.RecentTask

    var body: some View {
        HStack(spacing: 8) {
            StateRail(color: CardStateTag.color(for: task.state))
                .frame(height: 14)
            Text(task.title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(task.state.isFinished ? Palette.textSecondary : Palette.text)
                .lineLimit(1)
            Spacer(minLength: 4)
            if task.state.isFinished {
                Image(systemName: "checkmark")
                    .font(.system(size: 10.5, weight: .heavy))
                    .foregroundStyle(Palette.positive)
            } else {
                CardStateTag(state: task.state)
            }
        }
        .frame(height: 26)
    }
}

private struct LastWalkthroughRow: View {
    let walkthrough: MenuBarPanelState.WalkthroughSummary
    let isScouting: Bool
    let actions: MenuBarPanelActions

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(walkthrough.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text(walkthrough.summary)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary)
                if let problem = walkthrough.transcriptProblem {
                    HStack(spacing: 5) {
                        StatusDot(tone: .caution, size: 5)
                        Text(problem)
                    }
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                }
            }
            Spacer(minLength: 4)
            Button("Send…", action: actions.sendWalkthrough)
                .buttonStyle(SecondaryButtonStyle())
                .disabled(isScouting)
            Button("Copy", action: actions.copyWalkthrough)
                .buttonStyle(QuietButtonStyle())
            Button(action: actions.revealWalkthrough) {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.textSecondary)
            .help("Show in Finder")
        }
    }
}
