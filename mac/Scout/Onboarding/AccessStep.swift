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
                VStack(spacing: 14) {
                    ScoutMark(level: permissions.grantedCount, pulsing: permissions.allGranted)
                        .frame(width: 150, height: 150)
                    Text("\(permissions.grantedCount)/3 on")
                        .font(.system(size: 13, weight: .heavy).monospacedDigit())
                        .textCase(.uppercase)
                        .tracking(0.8)
                        .foregroundStyle(permissions.allGranted ? Palette.positive : Palette.textSecondary)
                }
                .frame(width: 200)

                VStack(spacing: 8) {
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
        HStack(spacing: 14) {
            IconOrb(symbol: permission.symbol, size: 36, active: isNext)

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
        .padding(.leading, 17)
        .padding(.trailing, 14)
        .frame(height: 72)
        .background(Palette.surface, in: .rect(cornerRadius: Radius.card, style: .continuous))
        .overlay(alignment: .leading) {
            StateRail(color: state.isGranted ? Palette.positive : isNext ? Palette.accent : Color.clear)
        }
        .clipShape(.rect(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(isNext ? Palette.stroke : Palette.hairline, lineWidth: 1)
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
