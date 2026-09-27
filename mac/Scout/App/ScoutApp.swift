import SwiftUI

@main
struct ScoutApp: App {
    static let onboardingWindowID = "onboarding"
    static let reviewWindowID = "review"

    @State private var model = AppModel()

    init() { CaptureSelfTest.startIfRequested() }

    var body: some Scene {
        Window("Welcome to Scout", id: Self.onboardingWindowID) {
            OnboardingView()
                .environment(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .windowBackgroundDragBehavior(.enabled)
        .defaultLaunchBehavior(model.onboarding.isComplete ? .suppressed : .presented)
        .restorationBehavior(.disabled)
        .defaultPosition(.center)

        Window("Scout Review", id: Self.reviewWindowID) {
            ReviewWindow()
                .environment(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1260, height: 840)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        MenuBarExtra {
            MenuBarPanel()
                .environment(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

private struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Image(nsImage: MenuBarIcon.image(scouting: model.isScouting))
            .onAppear {
                model.openOnboarding = {
                    openWindow(id: ScoutApp.onboardingWindowID)
                    NSApp.activate()
                }
                model.openSettingsWindow = {
                    openSettings()
                    NSApp.activate()
                }
                model.openReviewWindow = {
                    openWindow(id: ScoutApp.reviewWindowID)
                    if SimulationMode.audioFile == nil { NSApp.activate() }
                }
            }
    }
}
