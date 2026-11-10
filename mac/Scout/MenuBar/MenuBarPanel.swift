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

    private static let edge: CGFloat = 16
    private static let quietInset: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 14)
            recordGroup
                .padding(.bottom, 14)
            divider
            recentGroup
                .padding(.vertical, 14)
            divider
            footer
                .padding(.top, 14)
        }
        .padding(Self.edge)
        .frame(width: 336)
        .background(Palette.canvas)
    }

    private var divider: some View {
        Rectangle().fill(Palette.hairline).frame(height: 1)
    }

    private var header: some View {
        HStack(spacing: 8) {
            ScoutMark(level: 3, pulsing: state.isScouting)
                .frame(width: 18, height: 18)
                .padding(.leading, -4)
            Text("Scout").font(.system(size: 15, weight: .heavy))
            Spacer()
            HStack(spacing: 6) {
                StatusDot(tone: state.isScouting ? .active : .positive)
                Text(state.isScouting ? "Recording" : "Ready")
                    .font(Typography.caption)
                    .foregroundStyle(state.isScouting ? Palette.accentText : Palette.textSecondary)
            }
        }
    }

    private var recordGroup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: actions.toggleScouting) {
                HStack(spacing: 8) {
                    Image(systemName: state.isScouting ? "stop.fill" : "record.circle.fill")
                    Text(state.isScouting ? "Finish scouting" : "Start scouting")
                    Spacer()
                    KeyHint(state.shortcut, emphasized: true)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(RecordButtonStyle(finishing: state.isScouting))

            HStack(spacing: 8) {
                Button("Record as tasks", action: actions.splitIntoTasks)
                    .buttonStyle(SecondaryButtonStyle())
                    .fixedSize()
                    .disabled(state.isScouting)
                    .help("Record, and Scout turns what you say into separate tasks for agents.")
                Spacer(minLength: 4)
                HStack(spacing: 6) {
                    Text("New task")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textTertiary)
                        .fixedSize()
                    ChoiceMenu(options: Segmentation.allCases, selection: $segmentation) { mode in
                        mode == .automatic ? "Auto" : "On \(state.breakShortcut)"
                    }
                }
                .disabled(state.isScouting)
                .opacity(state.isScouting ? 0.55 : 1)
                .help(segmentation.explanation)
            }

            if let problem = state.walkthroughProblem, state.lastWalkthrough == nil {
                HStack(spacing: 6) {
                    StatusDot(tone: .caution, size: 5)
                    Text(problem)
                }
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
            }
        }
    }

    private var recentGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Recent").eyebrowStyle(Palette.textTertiary)
                Spacer()
                Button(action: actions.openReview) {
                    HStack(spacing: 3) {
                        Text("Review")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                    }
                }
                .buttonStyle(QuietButtonStyle())
                .padding(.trailing, -Self.quietInset)
            }
            .frame(height: 20)

            if let walkthrough = state.lastWalkthrough {
                LastWalkthroughRow(walkthrough: walkthrough, isScouting: state.isScouting, actions: actions)
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
                if state.lastWalkthrough == nil {
                    Text("Nothing yet. Start scouting and talk through what you see.")
                        .font(Typography.callout)
                        .foregroundStyle(Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(state.recent) { task in
                        RecentTaskRow(task: task)
                    }
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            connections
            HStack(spacing: 2) {
                Button(state.setupComplete ? "Setup guide" : "Finish setup", action: actions.openSetup)
                    .buttonStyle(QuietButtonStyle())
                Button("Settings", action: actions.openSettings)
                    .buttonStyle(QuietButtonStyle())
                Spacer()
                Button(action: actions.quit) {
                    HStack(spacing: 6) {
                        Text("Quit")
                        KeyHint("⌘Q")
                    }
                }
                .buttonStyle(QuietButtonStyle())
                .keyboardShortcut("q")
            }
            .padding(.horizontal, -Self.quietInset)
        }
    }

    private var connections: some View {
        HStack(spacing: 14) {
            switch state.hive {
            case .connected(let count): Connection(tone: .positive, name: "hive", detail: count == 1 ? "1 session" : "\(count) sessions")
            case .checking: Connection(tone: .caution, name: "hive", detail: "checking")
            case .unreachable: Connection(tone: .negative, name: "hive", detail: "not responding")
            case .missing: Connection(tone: .neutral, name: "hive", detail: "not installed")
            }
            if state.apiaryRunning {
                Connection(tone: .positive, name: "Apiary", detail: nil)
            }
            if !state.sdkApps.isEmpty {
                Connection(tone: .positive, name: state.sdkApps.count == 1 ? state.sdkApps[0] : "\(state.sdkApps.count) apps", detail: "SDK")
                    .help(state.sdkApps.joined(separator: ", "))
            }
        }
        .frame(height: 20)
    }
}

private struct Connection: View {
    let tone: Tone
    let name: String
    let detail: String?

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(tone: tone)
            HStack(spacing: 4) {
                Text(name).foregroundStyle(Palette.textSecondary)
                if let detail {
                    Text(detail).foregroundStyle(tone == .negative ? Palette.negative : Palette.textTertiary)
                }
            }
            .lineLimit(1)
        }
        .font(Typography.caption)
        .accessibilityElement(children: .combine)
    }
}

private struct RecordButtonStyle: ButtonStyle {
    let finishing: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .bold))
            .foregroundStyle(finishing ? Palette.onInk : Palette.onAccent)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(finishing ? Palette.ink : Palette.accent, in: .rect(cornerRadius: Radius.control, style: .continuous))
            .brightness(configuration.isPressed ? -0.08 : 0)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
            .contentShape(.rect(cornerRadius: Radius.control))
    }
}

private struct RecentTaskRow: View {
    let task: MenuBarPanelState.RecentTask

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            marker
                .frame(width: 12)
            if task.state.isFinished {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(task.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Text(label)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.positive)
                        .fixedSize()
                }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(task.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Palette.text)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(label)
                        .font(Typography.caption)
                        .foregroundStyle(tone == .neutral ? Palette.textSecondary : tone.color)
                }
            }
        }
        .padding(.vertical, 3)
        .help(task.title)
    }

    @ViewBuilder
    private var marker: some View {
        if task.state.isFinished {
            Image(systemName: "checkmark")
                .font(.system(size: 9.5, weight: .heavy))
                .foregroundStyle(Palette.positive)
                .accessibilityLabel("Sent")
        } else if case .sending = task.state {
            SendingMark()
        } else if case .countdown = task.state {
            SendingMark()
        } else {
            StatusDot(tone: tone)
        }
    }

    private var tone: Tone {
        switch task.state {
        case .needsDestination, .copiedInstead: .caution
        case .countdown, .sending: .neutral
        case .sent: .positive
        case .failed: .negative
        case .withdrawn, .held, .preparing: .neutral
        }
    }

    private var label: String {
        switch task.state {
        case .needsDestination: "Needs a destination"
        case .countdown, .sending: "Sending"
        case .sent: "Sent"
        case .failed: "Failed"
        case .copiedInstead: "Copied instead"
        case .withdrawn: "Withdrawn"
        case .held: "Held"
        case .preparing: "Preparing"
        }
    }
}

private struct LastWalkthroughRow: View {
    let walkthrough: MenuBarPanelState.WalkthroughSummary
    let isScouting: Bool
    let actions: MenuBarPanelActions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(walkthrough.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(walkthrough.summary)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
                if let problem = walkthrough.transcriptProblem {
                    HStack(spacing: 5) {
                        StatusDot(tone: .caution, size: 5)
                        Text(problem)
                    }
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                }
                HStack(spacing: 4) {
                    Button("Send…", action: actions.sendWalkthrough)
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(isScouting)
                    Button("Copy", action: actions.copyWalkthrough)
                        .buttonStyle(QuietButtonStyle())
                    Button("Show in Finder", action: actions.revealWalkthrough)
                        .buttonStyle(QuietButtonStyle())
                }
                .padding(.top, 4)
            }
        }
    }
}

private struct SendingMark: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .strokeBorder(Palette.textSecondary, lineWidth: 1.5)
            .frame(width: 7, height: 7)
    }
}
