import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow

    static let size = CGSize(width: 940, height: 640)

    var body: some View {
        let onboarding = model.onboarding
        ZStack {
            Aurora(glow: onboarding.step.glow)
                .animation(Motion.smooth, value: onboarding.step)
            Grain()

            VStack(spacing: 0) {
                StepRail(current: onboarding.step)
                    .padding(.top, 22)
                    .opacity(onboarding.step == .welcome ? 0 : 1)
                    .animation(Motion.smooth, value: onboarding.step)

                ZStack {
                    stepView(onboarding.step)
                        .id(onboarding.step)
                        .transition(onboarding.movingForward ? .stepForward : .stepBackward)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .environment(\.colorScheme, .dark)
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
            model.permissions.startMonitoring()
        }
        .onDisappear {
            model.permissions.stopMonitoring()
            model.permissions.guide.hide()
            NSApp.setActivationPolicy(.accessory)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.permissions.noteAppBecameActive()
        }
        .task {
            if let directory = SnapshotMode.directory, SettingsView.requestedPane == nil {
                await SnapshotMode.run(model: model, into: directory)
            }
        }
    }

    @ViewBuilder
    private func stepView(_ step: OnboardingModel.Step) -> some View {
        switch step {
        case .welcome: WelcomeStep()
        case .access: AccessStep()
        case .voice: VoiceStep()
        case .point: PointStep()
        case .connect: ConnectStep()
        case .ready: ReadyStep(onFinish: finish)
        }
    }

    private func finish() {
        model.onboarding.finish()
        dismissWindow(id: ScoutApp.onboardingWindowID)
    }
}

struct StepRail: View {
    var current: OnboardingModel.Step

    private var steps: [OnboardingModel.Step] {
        OnboardingModel.Step.allCases.filter { $0 != .welcome }
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(steps) { step in
                let isCurrent = step == current
                let isDone = step.rawValue < current.rawValue
                HStack(spacing: 6) {
                    Capsule()
                        .fill(isCurrent ? AnyShapeStyle(Palette.flareGradient) : AnyShapeStyle(isDone ? Palette.mint.opacity(0.8) : Color.white.opacity(0.18)))
                        .frame(width: isCurrent ? 22 : 6, height: 6)
                    if isCurrent {
                        Text(step.title)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.text)
                            .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .glassEffect(.regular.tint(Palette.night.opacity(0.3)), in: .capsule)
        .animation(Motion.snappy, value: current)
    }
}

struct StepLayout<Content: View, Footer: View>: View {
    var eyebrow: String
    var title: String
    var message: String
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(eyebrow).eyebrowStyle()
                Text(title)
                    .font(Typography.title)
                    .tracking(-0.4)
                    .foregroundStyle(Palette.text)
                Text(message)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 560, alignment: .leading)
            }
            .padding(.top, 30)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 22)

            HStack(spacing: 12) {
                footer
            }
            .frame(height: 50)
        }
        .padding(.horizontal, 56)
        .padding(.bottom, 34)
    }
}

struct BackButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.onboarding.back()
        } label: {
            Label("Back", systemImage: "chevron.left")
        }
        .buttonStyle(QuietButtonStyle())
        .keyboardShortcut(.leftArrow, modifiers: [.command])
    }
}
