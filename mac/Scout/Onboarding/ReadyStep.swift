import ServiceManagement
import SwiftUI

struct ReadyStep: View {
    @Environment(AppModel.self) private var model
    var onFinish: () -> Void

    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled
    @State private var celebrate = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)

            ZStack {
                ForEach(0..<3) { ring in
                    Circle()
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                        .frame(width: 150, height: 150)
                        .scaleEffect(celebrate ? 2.2 : 0.6)
                        .opacity(celebrate ? 0 : 0.8)
                        .animation(.easeOut(duration: 2.2).repeatForever(autoreverses: false).delay(Double(ring) * 0.7), value: celebrate)
                }
                ScoutMark(litArcs: 3, pulsing: true)
                    .frame(width: 136, height: 136)
                    .offset(x: -6, y: -6)
            }
            .frame(height: 220)

            Text("Scout is ready.")
                .font(.system(size: 40, weight: .bold).width(.expanded))
                .tracking(-1)
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
                .toggleStyle(.switch)
                .tint(Palette.accent)
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
