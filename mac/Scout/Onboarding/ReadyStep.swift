import ServiceManagement
import SwiftUI

struct ReadyStep: View {
    @Environment(AppModel.self) private var model
    var onFinish: () -> Void

    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled
    @State private var celebrate = false
    @Environment(\.stillRender) private var still

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)

            ZStack {
                ScoutMark(level: 3, pulsing: true)
                    .frame(width: 150, height: 150)
            }
            .frame(height: 220)

            Text("Scout is ready.")
                .font(.system(size: 44, weight: .heavy))
                .tracking(-1.2)
                .padding(.top, 8)

            Text("Open any app, press the shortcut, and start talking.")
                .font(.system(size: 16))
                .foregroundStyle(Palette.textSecondary)
                .padding(.top, 10)

            KeyCombo(symbols: model.shortcut.symbols, size: 48)
                .padding(.top, 28)

            Spacer(minLength: 20)

            HStack(spacing: 14) {
                Toggle(isOn: $opensAtLogin) {
                    Text("Open Scout at login")
                        .font(Typography.body)
                        .foregroundStyle(Palette.textSecondary)
                }
                .toggleStyle(SignalToggleStyle())
                .onChange(of: opensAtLogin) { _, enabled in
                    model.opensAtLogin = enabled
                }

                Spacer()

                Button("Back") { model.onboarding.back() }
                    .buttonStyle(QuietButtonStyle())
                Button("Start using Scout") { onFinish() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 56)
            .padding(.bottom, 34)
        }
        .frame(maxWidth: .infinity)
        .onAppear { celebrate = true }
    }
}
