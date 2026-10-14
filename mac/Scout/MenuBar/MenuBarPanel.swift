import ScoutCore
import SwiftUI

struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ScoutMark(litArcs: 3, pulsing: model.isScouting)
                    .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Scout").font(Typography.headline)
                    Text(model.isScouting ? "Scouting. Talk and point." : "Ready when you are.")
                        .font(Typography.caption)
                        .foregroundStyle(model.isScouting ? Palette.text : Palette.textSecondary)
                }
                Spacer()
            }

            Button {
                model.toggleScouting()
            } label: {
                HStack {
                    Image(systemName: model.isScouting ? "stop.fill" : "record.circle")
                    Text(model.isScouting ? "Stop scouting" : "Start scouting")
                    Spacer()
                    Text(model.shortcut.symbols.joined())
                        .font(Typography.mono)
                        .opacity(0.8)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle(large: false))

            if let walkthrough = model.lastWalkthrough {
                LastWalkthroughRow(walkthrough: walkthrough)
            } else if let problem = model.walkthroughProblem {
                Text(problem)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
            }

            HStack {
                Text("Or split what you say into tasks")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                Spacer()
                Button("Split into tasks") { model.startSplitTasks() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                    .disabled(model.isScouting)
            }

            SegmentationToggle()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Recent").eyebrowStyle(Palette.textTertiary)
                    Spacer()
                    Button("Review") { model.openLatestReview() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Palette.textSecondary)
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
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.textTertiary)
                } else {
                    ForEach(Array(recent)) { card in
                        RecentTaskRow(card: card)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.05), in: .rect(cornerRadius: 12))

            integrationLine

            Divider().overlay(Palette.hairline)

            HStack {
                Button(model.onboarding.isComplete ? "Setup guide" : "Finish setup") {
                    model.onboarding.restart()
                    openWindow(id: ScoutApp.onboardingWindowID)
                    NSApp.activate()
                }
                .buttonStyle(QuietButtonStyle())
                SettingsLink {
                    Text("Settings")
                }
                .buttonStyle(QuietButtonStyle())
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut("q")
            }
        }
        .padding(16)
        .frame(width: 320)
        .environment(\.colorScheme, .dark)
        .task { await model.integrations.refresh() }
    }

    private var integrationLine: some View {
        HStack(spacing: 8) {
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
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
            Spacer()
            HStack(spacing: 2) {
                ForEach(Segmentation.allCases) { mode in
                    Button {
                        withAnimation(Motion.snappy) { preferences.segmentation = mode }
                    } label: {
                        Text(mode == .automatic ? "Auto" : "\(model.breakShortcut.symbols.joined()) only")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(preferences.segmentation == mode ? Palette.ink : Palette.textSecondary)
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .background {
                                if preferences.segmentation == mode { Capsule().fill(.white) }
                            }
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(Color.white.opacity(0.07), in: .capsule)
            .disabled(model.isScouting)
        }
        .help(preferences.segmentation.explanation)
    }
}

private struct RecentTaskRow: View {
    let card: SnippetCard

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 14)
            Text(card.title)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 4)
        }
    }

    private var icon: String {
        switch card.state {
        case .sent: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .copiedInstead: "doc.on.clipboard.fill"
        case .needsDestination, .held: "pause.circle.fill"
        default: "arrow.up.circle"
        }
    }

    private var tint: Color {
        switch card.state {
        case .sent: Palette.textTertiary
        case .failed, .copiedInstead: Palette.negative
        case .needsDestination, .held: Palette.textSecondary
        default: Palette.textSecondary
        }
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
            }
            Spacer(minLength: 4)
            Button("Send…") { model.sendLastWalkthrough() }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
                .disabled(model.isScouting)
            Button("Copy") { model.copyLastWalkthrough() }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
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
