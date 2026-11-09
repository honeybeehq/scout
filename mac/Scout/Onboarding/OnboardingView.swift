import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow

    static let size = CGSize(width: 940, height: 640)

    var body: some View {
        let onboarding = model.onboarding
        ZStack {
            SignalBackdrop(intensity: onboarding.step.glowIntensity)
                .animation(Motion.smooth, value: onboarding.step)

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
        .scaledToUISize()
        .onAppear {
            model.windowOpened()
            model.permissions.startMonitoring()
        }
        .onDisappear {
            model.permissions.stopMonitoring()
            model.permissions.guide.hide()
            model.windowClosed()
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
        HStack(spacing: 4) {
            ForEach(Array(steps.enumerated()), id: \.element) { index, step in
                let isCurrent = step == current
                let isDone = step.rawValue < current.rawValue
                VStack(alignment: .leading, spacing: 5) {
                    Rectangle()
                        .fill(isCurrent ? Palette.accent : isDone ? Palette.text : Palette.fillStrong)
                        .frame(height: 3)
                    HStack(spacing: 5) {
                        Text(String(format: "%02d", index + 1))
                            .monospacedDigit()
                            .foregroundStyle(isCurrent ? Palette.accentText : Palette.textTertiary)
                        Text(step.title)
                            .foregroundStyle(isCurrent ? Palette.text : isDone ? Palette.textSecondary : Palette.textTertiary)
                    }
                    .font(.system(size: 10.5, weight: .bold))
                    .textCase(.uppercase)
                    .tracking(0.6)
                }
                .frame(width: 112, alignment: .leading)
            }
        }
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
                Text(eyebrow).eyebrowStyle(Palette.textTertiary)
                Text(title)
                    .font(.system(size: 30, weight: .heavy))
                    .tracking(-0.6)
                    .foregroundStyle(Palette.text)
                Text(message)
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 560, alignment: .leading)
            }
            .padding(.top, 30)
            .staggeredEntrance(0)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 22)
                .staggeredEntrance(1)

            HStack(spacing: 12) {
                footer
            }
            .frame(height: 50)
            .staggeredEntrance(2)
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
