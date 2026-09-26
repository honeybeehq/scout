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
                        .foregroundStyle(model.isScouting ? Palette.flareSoft : Palette.textSecondary)
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
            .buttonStyle(FlareButtonStyle(large: false))

            VStack(alignment: .leading, spacing: 8) {
                Text("Recent").eyebrowStyle(Palette.textTertiary)
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
            case .connected(let count): StatusBadge(text: "hive · \(count) active", tone: .success)
            case .checking: StatusBadge(text: "hive · checking", tone: .waiting)
            case .unreachable: StatusBadge(text: "hive · not responding", tone: .warning)
            case .missing: StatusBadge(text: "hive · not installed", tone: .neutral)
            }
            if model.integrations.apiary == .running {
                StatusBadge(text: "Apiary", tone: .success)
            }
            let apps = model.bridge.clients.filter { $0.hello != nil }
            if !apps.isEmpty {
                StatusBadge(text: apps.count == 1 ? "SDK · \(apps[0].name)" : "SDK · \(apps.count) apps", tone: .success)
                    .help(apps.map(\.name).joined(separator: ", "))
            }
        }
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
        case .needsDestination, .held: "pause.circle.fill"
        default: "arrow.up.circle"
        }
    }

    private var tint: Color {
        switch card.state {
        case .sent: Palette.mint
        case .failed: Palette.rose
        case .needsDestination, .held: Palette.amber
        default: Palette.textSecondary
        }
    }
}
