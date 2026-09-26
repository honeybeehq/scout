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
                Text("Tasks you capture show up here.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.textTertiary)
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
        }
    }
}
