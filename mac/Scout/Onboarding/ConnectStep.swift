import SwiftUI

struct ConnectStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var integrations = model.integrations
        StepLayout(
            eyebrow: "Agents",
            title: "Send tasks straight to your agents.",
            message: "Scout hands each task to a hive session, including the ones open in Apiary, with the transcript, clip and pinned elements attached."
        ) {
            VStack(spacing: 18) {
                HStack(alignment: .top, spacing: 16) {
                    HiveCard(status: integrations.hive, sessions: integrations.recentSessions)
                    ApiaryCard(status: integrations.apiary)
                        .frame(width: 250)
                }
                .fixedSize(horizontal: false, vertical: true)

                RoutePicker(route: $integrations.route, hiveAvailable: hiveAvailable)
                Spacer(minLength: 0)
            }
        } footer: {
            BackButton()
            Spacer()
            Button("Continue") { model.onboarding.next() }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
        .task {
            await model.integrations.refresh()
        }
    }

    private var hiveAvailable: Bool {
        if case .connected = model.integrations.hive { return true }
        return false
    }
}

private struct HiveCard: View {
    var status: Integrations.HiveStatus
    var sessions: [HiveSession]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                IconOrb(symbol: "hexagon", size: 36, active: isConnected)
                VStack(alignment: .leading, spacing: 2) {
                    Text("hive").font(Typography.headline)
                    Text("Agent sessions on this Mac").font(Typography.caption).foregroundStyle(Palette.textSecondary)
                }
                Spacer()
                badge
            }

            if sessions.isEmpty {
                Text(emptyMessage)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 6) {
                    ForEach(sessions) { session in
                        SessionRow(session: session)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .surfaceCard(Palette.surface, radius: Radius.panel)
    }

    private var isConnected: Bool {
        if case .connected = status { return true }
        return false
    }

    @ViewBuilder
    private var badge: some View {
        switch status {
        case .checking: StatusBadge(text: "Looking…", tone: .caution)
        case .connected(let count): StatusBadge(text: "\(count) active", tone: .positive)
        case .unreachable: StatusBadge(text: "Not responding", tone: .negative)
        case .missing: StatusBadge(text: "Not installed", tone: .neutral)
        }
    }

    private var emptyMessage: String {
        switch status {
        case .checking: "Checking for hive…"
        case .connected: "No active sessions yet. Scout can start one for each task."
        case .unreachable(let reason): "hive is installed, but Scout couldn't talk to it (\(reason))."
        case .missing: "Without hive, Scout copies tasks to your clipboard and saves them to a folder."
        }
    }
}

private struct SessionRow: View {
    let session: HiveSession

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(tone: session.isWorking ? .positive : .neutral, size: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.displayTitle)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                if let project = session.projectName {
                    Text(project)
                        .font(Typography.mono)
                        .foregroundStyle(Palette.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(session.agent)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background(Palette.fillRaised, in: .rect(cornerRadius: Radius.tag))
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(Palette.fill, in: .rect(cornerRadius: Radius.control))
    }
}

private struct ApiaryCard: View {
    var status: ApiaryStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                IconOrb(symbol: "square.grid.2x2", size: 36, active: status == .running)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apiary").font(Typography.headline)
                    Text("Agent workspace").font(Typography.caption).foregroundStyle(Palette.textSecondary)
                }
            }
            switch status {
            case .running: StatusBadge(text: "Running", tone: .positive)
            case .installed: StatusBadge(text: "Installed", tone: .neutral)
            case .missing: StatusBadge(text: "Not installed", tone: .neutral)
            }
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .surfaceCard(Palette.surface, radius: Radius.panel)
    }

    private var message: String {
        switch status {
        case .running: "Tasks sent to Apiary panes appear right in the conversation."
        case .installed: "Open Apiary and Scout will send to its panes too."
        case .missing: "Optional. Scout works fine without it."
        }
    }
}

private struct RoutePicker: View {
    @Binding var route: DeliveryRoute
    var hiveAvailable: Bool

    var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Where tasks go").font(Typography.headline)
                Text(hiveAvailable ? route.explanation : "Scout copies tasks to the clipboard until hive is available.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .contentTransition(.opacity)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if hiveAvailable {
                SegmentedChoice(options: DeliveryRoute.allCases, selection: $route, title: \.title)
            } else {
                StateTag(text: "Clipboard", tone: .neutral)
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 14)
        .frame(height: 66)
        .surfaceCard(Palette.surface, radius: Radius.panel)
    }
}
