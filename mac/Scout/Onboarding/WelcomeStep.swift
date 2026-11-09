import SwiftUI

struct WelcomeStep: View {
    @Environment(AppModel.self) private var model
    @State private var litLevel = 0
    @State private var revealed = false
    @Environment(\.stillRender) private var still

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 40)

            ZStack {
                ScoutMark(level: still ? 3 : litLevel, pulsing: litLevel == 3)
                    .frame(width: 170, height: 170)
            }
            .frame(height: 210)

            Text("Scout")
                .font(.system(size: 60, weight: .heavy))
                .tracking(-1.8)
                .foregroundStyle(Palette.text)
                .padding(.top, 6)
                .staggeredEntrance(1)

            Text("Talk through your app. Point at what's off.\nScout turns it into tasks your agents can fix.")
                .font(.system(size: 16, weight: .regular))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .foregroundStyle(Palette.textSecondary)
                .padding(.top, 14)
                .staggeredEntrance(2)

            Spacer(minLength: 30)

            VStack(spacing: 14) {
                Button("Set up Scout") {
                    model.onboarding.next()
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)

                HStack(spacing: 6) {
                    KeyHint("↩")
                    Label("About a minute. Nothing leaves this Mac until you send it.", systemImage: "lock.fill")
                }
                .font(Typography.caption)
                .foregroundStyle(Palette.textTertiary)
            }
            .staggeredEntrance(3)
            .padding(.bottom, 56)
        }
        .frame(maxWidth: .infinity)
        .task {
            withAnimation(Motion.smooth.delay(0.1)) { revealed = true }
            for arc in 1...3 {
                try? await Task.sleep(for: .milliseconds(arc == 1 ? 450 : 260))
                litLevel = arc
            }
        }
    }
}
