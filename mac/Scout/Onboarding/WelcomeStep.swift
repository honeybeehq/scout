import SwiftUI

struct WelcomeStep: View {
    @Environment(AppModel.self) private var model
    @State private var litArcs = 0
    @State private var revealed = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 40)

            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Palette.flare.opacity(0.35), .clear], center: .center, startRadius: 4, endRadius: 150))
                    .frame(width: 300, height: 300)
                    .blur(radius: 10)
                    .opacity(revealed ? 1 : 0)
                ScoutMark(litArcs: litArcs, pulsing: litArcs == 3)
                    .frame(width: 150, height: 150)
                    .offset(x: -8, y: -8)
            }
            .frame(height: 210)

            Text("Scout")
                .font(Typography.hero)
                .tracking(-1.5)
                .foregroundStyle(
                    LinearGradient(colors: [.white, .white.opacity(0.72)], startPoint: .top, endPoint: .bottom)
                )
                .padding(.top, 6)
                .opacity(revealed ? 1 : 0)
                .offset(y: revealed ? 0 : 12)

            Text("Talk through your app. Point at what's off.\nScout turns it into tasks your agents can fix.")
                .font(.system(size: 17, weight: .regular))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .foregroundStyle(Palette.textSecondary)
                .padding(.top, 14)
                .opacity(revealed ? 1 : 0)
                .offset(y: revealed ? 0 : 12)

            Spacer(minLength: 30)

            VStack(spacing: 14) {
                Button("Set up Scout") {
                    model.onboarding.next()
                }
                .buttonStyle(FlareButtonStyle())
                .keyboardShortcut(.defaultAction)

                Label("About a minute. Nothing leaves this Mac until you send it.", systemImage: "lock.fill")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary)
            }
            .opacity(revealed ? 1 : 0)
            .offset(y: revealed ? 0 : 16)
            .padding(.bottom, 56)
        }
        .frame(maxWidth: .infinity)
        .task {
            withAnimation(Motion.smooth.delay(0.1)) { revealed = true }
            for arc in 1...3 {
                try? await Task.sleep(for: .milliseconds(arc == 1 ? 450 : 260))
                litArcs = arc
            }
        }
    }
}
