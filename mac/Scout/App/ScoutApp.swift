import SwiftUI

@main
struct ScoutApp: App {
    static let onboardingWindowID = "onboarding"

    @State private var model = AppModel()


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
            }
    }
}
