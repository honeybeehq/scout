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
                .frame(maxHeight: .infinity)

                RoutePicker(route: $integrations.route, hiveAvailable: hiveAvailable)
            }
        } footer: {
            BackButton()
            Spacer()
            Button("Continue") { model.onboarding.next() }
                .buttonStyle(FlareButtonStyle())
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
                IconOrb(symbol: "hexagon.fill", tint: Palette.amber, size: 38, active: isConnected)
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
                Spacer(minLength: 0)
            } else {
                VStack(spacing: 6) {
                    ForEach(sessions) { session in
                        SessionRow(session: session)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassEffect(.regular.tint(Palette.night.opacity(0.25)), in: .rect(cornerRadius: 22))
    }

    private var isConnected: Bool {
        if case .connected = status { return true }
        return false
    }

    @ViewBuilder
    private var badge: some View {
        switch status {
        case .checking: StatusBadge(text: "Looking…", tone: .waiting)
        case .connected(let count): StatusBadge(text: "\(count) active", tone: .success)
        case .unreachable: StatusBadge(text: "Not responding", tone: .warning)
        case .missing: StatusBadge(text: "Not installed", tone: .neutral)
        }
    }

    private var emptyMessage: String {
        switch status {
        case .checking: "Checking for hive…"
        case .connected: "No active sessions yet. Scout can start one for each task."
        case .unreachable(let reason): "hive didn't answer: \(reason)"
        case .missing: "Without hive, Scout copies tasks to your clipboard and saves them to a folder."
        }
    }
}

private struct SessionRow: View {
    let session: HiveSession

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(session.isWorking ? Palette.mint : Color.white.opacity(0.25))
                .frame(width: 7, height: 7)
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
                .padding(.horizontal, 7)
                .frame(height: 18)
                .background(Color.white.opacity(0.08), in: .capsule)
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(Color.white.opacity(0.04), in: .rect(cornerRadius: 8))
    }
}

private struct ApiaryCard: View {
    var status: ApiaryStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                IconOrb(symbol: "square.grid.3x3.square", tint: Palette.beam, size: 38, active: status == .running)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apiary").font(Typography.headline)
                    Text("Agent workspace").font(Typography.caption).foregroundStyle(Palette.textSecondary)
                }
            }
            switch status {
            case .running: StatusBadge(text: "Running", tone: .success)
            case .installed: StatusBadge(text: "Installed", tone: .neutral)
            case .missing: StatusBadge(text: "Not installed", tone: .neutral)
            }
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassEffect(.regular.tint(Palette.night.opacity(0.25)), in: .rect(cornerRadius: 22))
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
            GlassEffectContainer(spacing: 4) {
                HStack(spacing: 4) {
                    ForEach(DeliveryRoute.allCases) { option in
                        Button {
                            withAnimation(Motion.snappy) { route = option }
                        } label: {
                            Text(option.title)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(route == option ? Palette.ink : Palette.textSecondary)
                                .padding(.horizontal, 14)
                                .frame(height: 30)
                                .background {
                                    if route == option {
                                        Capsule().fill(.white)
                                    }
                                }
                                .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
                .glassEffect(.regular, in: .capsule)
            }
            .disabled(!hiveAvailable)
            .opacity(hiveAvailable ? 1 : 0.5)
        }
        .padding(.leading, 28)
        .padding(.trailing, 16)
        .frame(height: 70)
        .glassEffect(.regular.tint(Palette.night.opacity(0.25)), in: .capsule)
    }
}
