import SwiftUI

struct AccessStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let permissions = model.permissions
        StepLayout(
            eyebrow: "Access",
            title: "Let Scout see, hear and point.",
            message: "macOS asks you to switch on three things. Scout checks each one as you go and brings you back when it's done."
        ) {
            HStack(alignment: .center, spacing: 44) {
                ZStack {
                    Circle()
                        .fill(RadialGradient(colors: [Color.white.opacity(0.06), .clear], center: .center, startRadius: 2, endRadius: 120))
                        .frame(width: 240, height: 240)
                    ScoutMark(litArcs: permissions.grantedCount, pulsing: permissions.allGranted)
                        .frame(width: 128, height: 128)
                        .offset(x: -6, y: -6)
                }
                .frame(width: 220)

                VStack(spacing: 12) {
                    ForEach(Permission.allCases) { permission in
                        PermissionRow(
                            permission: permission,
                            state: permissions.state(of: permission),
                            isNext: permissions.nextNeeded == permission
                        )
                    }
                }
                .frame(maxWidth: .infinity)
            }
        } footer: {
            BackButton()
            Spacer()
            if !permissions.allGranted {
                Button("Skip for now") { model.onboarding.next() }
                    .buttonStyle(QuietButtonStyle())
            }
            Button("Continue") { model.onboarding.next() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!permissions.allGranted)
                .keyboardShortcut(.defaultAction)
        }
    }
}

private struct PermissionRow: View {
    @Environment(AppModel.self) private var model
    let permission: Permission
    let state: PermissionState
    let isNext: Bool

    var body: some View {
        HStack(spacing: 16) {
            IconOrb(symbol: permission.symbol, active: isNext)

            VStack(alignment: .leading, spacing: 3) {
                Text(permission.title)
                    .font(Typography.headline)
                    .foregroundStyle(Palette.text)
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.textSecondary)
                    .contentTransition(.opacity)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            ZStack {
                trailing
                    .id(state)
                    .transition(.iconSwap)
            }
            .animation(Motion.iconSwap, value: state)
        }
        .padding(.horizontal, 18)
        .frame(height: 78)
        .glassEffect(.regular.tint(Palette.night.opacity(isNext ? 0.1 : 0.3)), in: .rect(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(isNext ? Palette.stroke : .clear, lineWidth: 1)
        }
        .opacity(state.isGranted ? 0.85 : 1)
        .animation(Motion.smooth, value: isNext)
        .animation(Motion.smooth, value: state)
    }

    private var detail: String {
        switch state {
        case .notRequested, .granted: permission.purpose
        case .waiting: "Switch Scout on in System Settings."
        case .needsRelaunch: "Switched it on? Relaunch Scout to finish."
        case .denied: "Turned off for Scout. Switch it on in System Settings."
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch state {
        case .granted:
            Checkmark()
        case .notRequested:
            if isNext {
                Button("Allow") { request() }
                    .buttonStyle(PrimaryButtonStyle(large: false))
            } else {
                Button("Allow") { request() }
                    .buttonStyle(SecondaryButtonStyle())
            }
        case .waiting:
            HStack(spacing: 10) {
                WaitingDots()
                Button("Open Settings") { model.permissions.openSettings(for: permission) }
                    .buttonStyle(SecondaryButtonStyle())
            }
        case .needsRelaunch:
            HStack(spacing: 8) {
                Button("Settings") { model.permissions.openSettings(for: permission) }
                    .buttonStyle(QuietButtonStyle())
                Button("Relaunch") { Relauncher.relaunch() }
                    .buttonStyle(PrimaryButtonStyle(large: false))
            }
        case .denied:
            Button("Open Settings") { model.permissions.openSettings(for: permission) }
                .buttonStyle(SecondaryButtonStyle())
        }
    }

    private func request() {
        Task { await model.permissions.request(permission) }
    }
}
