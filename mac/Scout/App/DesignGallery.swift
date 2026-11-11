import AppKit
import SwiftUI

enum DesignGallery {
    static var directory: URL? {
        let prefix = "--design-gallery="
        return ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }.map { URL(fileURLWithPath: String($0.dropFirst(prefix.count)), isDirectory: true) }
    }

    static let schemes: [ColorScheme] = [.light, .dark]

    private static func each(model: AppModel, _ body: (ColorScheme, UISize) async -> Void) async {
        let original = model.preferences.uiSize
        for scheme in schemes {
            NSApp.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            for size in UISize.allCases {
                model.preferences.uiSize = size
                try? await Task.sleep(for: .milliseconds(80))
                await body(scheme, size)
            }
        }
        model.preferences.uiSize = original
        NSApp.appearance = model.preferences.colorMode.appearance
    }

    private static func name(_ surface: String, _ scheme: ColorScheme, _ size: UISize) -> String {
        "\(surface)-\(scheme == .dark ? "dark" : "light")-\(size.rawValue)"
    }

    static func captureLive(model: AppModel) async {
        guard directory != nil else { return }
        await each(model: model) { scheme, size in
            render(ScoutingPill().environment(model), scheme: scheme, name: name("pill", scheme, size))
            render(SnippetStack().environment(model).frame(width: HUDController.stackWidth * size.scale, height: 640 * size.scale), scheme: scheme, name: name("stack-live", scheme, size))
            model.confirmingDiscard = true
            render(ScoutingPill().environment(model), scheme: scheme, name: name("pill-discard", scheme, size))
            model.confirmingDiscard = false
            model.session?.confirmBreak()
            render(ScoutingPill().environment(model), scheme: scheme, name: name("pill-new-ask", scheme, size))
        }
        await captureBarSequence(model: model)
    }

    static func captureBarSequence(model: AppModel) async {
        guard let directory, let session = model.session else { return }
        let follower = session.follower
        let original = model.preferences.uiSize
        var log: [[String: Any]] = []
        let steps: [(String, Bool, () -> Void)] = [
            ("listening", false, {}),
            ("hover", true, {}),
            ("discard-confirm", false, { model.confirmingDiscard = true }),
            ("discard-confirm-hover", true, {}),
            ("discard-kept", false, { model.confirmingDiscard = false }),
            ("widen", false, { follower.expand(input: InteractionTimings.now) }),
            ("widen-again", false, { follower.expand(input: InteractionTimings.now) }),
            ("follow", false, { follower.follow(input: InteractionTimings.now) }),
            ("new-ask", false, { session.confirmBreak() }),
            ("transcript-1", false, {}),
            ("transcript-2", false, {}),
            ("transcript-3", false, {}),
        ]
        for size in [UISize.standard, .extraLarge] {
            model.preferences.uiSize = size
            for scheme in schemes {
                NSApp.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                for (index, step) in steps.enumerated() {
                    step.2()
                    try? await Task.sleep(for: .milliseconds(step.0.hasPrefix("transcript") ? 900 : 250))
                    let name = "bar-\(size.rawValue)-\(scheme == .dark ? "dark" : "light")-\(String(format: "%02d", index))-\(step.0)"
                    render(ScoutingPill().environment(model).environment(\.barHoverPreview, step.1), scheme: scheme, name: name)
                    var entry: [String: Any] = ["frame": name, "step": step.0, "size": size.rawValue, "appearance": scheme == .dark ? "dark" : "light"]
                    entry["window"] = describe(model.hud.pillWindow?.frame)
                    entry["windowVisible"] = model.hud.pillWindow?.isVisible ?? false
                    entry["display"] = describe(model.hud.pillWindow?.screen?.frame)
                    entry["captured"] = describe(follower.bounds)
                    entry["scope"] = follower.scopeTitle
                    entry["transcript"] = String(session.transcriber.finalizedText.suffix(60))
                    entry["controls"] = controlFrames(ScoutingPill().environment(model).environment(\.barHoverPreview, step.1), scheme: scheme, size: size)
                    log.append(entry)
                }
                model.confirmingDiscard = false
            }
        }
        model.preferences.uiSize = original
        NSApp.appearance = model.preferences.colorMode.appearance
        if let data = try? JSONSerialization.data(withJSONObject: log, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("bar-frames.json"))
        }
    }

    private static func describe(_ rect: CGRect?) -> String {
        guard let rect else { return "none" }
        return String(format: "x %.1f y %.1f w %.1f h %.1f", rect.minX, rect.minY, rect.width, rect.height)
    }

    private static func controlFrames(_ view: some View, scheme: ColorScheme, size: UISize) -> [String: String] {
        let probe = BarLayoutProbe()
        let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme).environment(\.barLayoutProbe, probe))
        host.frame = CGRect(origin: .zero, size: CGSize(width: ScoutingPill.windowSize.width * size.scale, height: ScoutingPill.windowSize.height * size.scale))
        host.layoutSubtreeIfNeeded()
        _ = host.bitmapImageRepForCachingDisplay(in: host.bounds).map { host.cacheDisplay(in: host.bounds, to: $0) }
        return probe.frames.mapValues { String(format: "x %.1f w %.1f", $0.minX, $0.width) }
    }

    static func captureReview(model: AppModel) async {
        guard let review = model.review else { return }
        if review.selectedTaskID == nil, let first = review.tasks.first { review.select(first) }
        let frame = mockFrame()
        await each(model: model) { scheme, size in
            render(
                ReviewWindow().environment(model).environment(\.stillFrame, frame).frame(width: 1260 * size.scale, height: 820 * size.scale),
                scheme: scheme,
                name: name("review", scheme, size),
                background: true
            )
        }
    }

    static func captureDelivered(model: AppModel) async {
        await each(model: model) { scheme, size in
            render(SnippetStack().environment(model).frame(width: HUDController.stackWidth * size.scale, height: 640 * size.scale), scheme: scheme, name: name("stack-done", scheme, size))
            render(MenuBarPanel().environment(model), scheme: scheme, name: name("panel", scheme, size), background: true)
        }
    }

    static func captureFinished(model: AppModel) async {
        await each(model: model) { scheme, size in
            for pane in SettingsView.Pane.allCases {
                render(SettingsView(pane: pane).environment(model), scheme: scheme, name: name("settings-\(pane.rawValue)", scheme, size), background: true)
            }
            render(CaptureScene().frame(width: 960 * size.scale, height: 560 * size.scale).scaledToUISize().environment(model), scheme: scheme, name: name("capture", scheme, size))
            render(GuidingCard(permission: .microphone).frame(width: 320, height: 236), scheme: scheme, name: name("settings-guide", scheme, size), background: true)
        }
        for scheme in schemes {
            let glyphs = HStack(spacing: 24) {
                if scheme == .dark { MenuBarGlyph(scouting: false).colorInvert() } else { MenuBarGlyph(scouting: false) }
                MenuBarGlyph(scouting: true)
                ScoutMark(level: 1).frame(width: 64, height: 64)
                ScoutMark(level: 3).frame(width: 64, height: 64)
            }
            .padding(16)
            .background(scheme == .dark ? Color(hex: 0x2A2A2E) : Color(hex: 0xECECEA))
            render(glyphs.scaleEffect(2).frame(width: 2 * 296, height: 2 * 96), scheme: scheme, name: "mark-\(scheme == .dark ? "dark" : "light")")
        }
        let step = model.onboarding.step
        for onboardingStep in OnboardingModel.Step.allCases {
            model.onboarding.go(to: onboardingStep)
            try? await Task.sleep(for: .milliseconds(200))
            await each(model: model) { scheme, size in
                render(OnboardingView().environment(model), scheme: scheme, name: name("onboarding-\(onboardingStep.rawValue)", scheme, size), background: true)
            }
        }
        model.onboarding.go(to: step)
    }

    static func render(_ view: some View, scheme: ColorScheme, name: String, background: Bool = false) {
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let content = view
            .environment(\.stillRender, true)
            .environment(\.colorScheme, scheme)
            .background(background ? Palette.canvas : Color.clear)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
            .write(to: directory.appendingPathComponent("\(name).png"))
    }

    static func mockFrame() -> CGImage? {
        let renderer = ImageRenderer(content: MockPage().frame(width: 960, height: 600).environment(\.colorScheme, .light))
        renderer.scale = 1
        return renderer.cgImage
    }
}

private struct MockPage: View {
    var showsPay = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ForEach([0xFF5F57, 0xFEBC2E, 0x28C840] as [UInt32], id: \.self) { Circle().fill(Color(hex: $0)).frame(width: 11, height: 11) }
                Spacer()
                Text(verbatim: "localhost:3000/checkout").font(.system(size: 13, design: .monospaced)).foregroundStyle(Color(hex: 0x6B7280))
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
            .background(Color(hex: 0xEDEFF3))
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Checkout").font(.system(size: 30, weight: .bold)).foregroundStyle(Color(hex: 0x111827))
                    RoundedRectangle(cornerRadius: 8).fill(Color(hex: 0xF3F4F6)).frame(height: 44)
                    RoundedRectangle(cornerRadius: 8).fill(Color(hex: 0xF3F4F6)).frame(height: 44)
                    HStack {
                        if showsPay {
                        Text("Pay now").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 12).frame(height: 26)
                            .background(Color(hex: 0x4F46E5), in: .rect(cornerRadius: 6))
                        }
                        Spacer()
                    }
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Order summary").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(hex: 0x111827))
                    ForEach(0..<4) { _ in RoundedRectangle(cornerRadius: 4).fill(Color(hex: 0xE5E7EB)).frame(height: 12) }
                    Spacer()
                }
                .padding(18)
                .frame(width: 280)
                .background(Color(hex: 0xF9FAFB), in: .rect(cornerRadius: 12))
            }
            .padding(32)
        }
        .background(Color.white)
    }
}

private struct CaptureScene: View {
    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let window = CGRect(x: 40, y: 40, width: size.width - 300, height: size.height - 80)
            let button = CGRect(x: window.minX + 40, y: window.minY + 300, width: 92, height: 30)
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(hex: 0x3A4A6B), Color(hex: 0x1D2333)], startPoint: .topLeading, endPoint: .bottomTrailing)
                MockPage(showsPay: false)
                    .frame(width: window.width, height: window.height)
                    .clipShape(.rect(cornerRadius: 10))
                    .offset(x: window.minX, y: window.minY)
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(hex: 0x2B2F3A))
                    .frame(width: 200, height: window.height * 0.6)
                    .offset(x: window.maxX + 30, y: window.minY + 40)
                CaptureOutline(hole: window)
                Text("Pay now").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: button.width, height: button.height)
                    .background(Color(hex: 0x4F46E5), in: .rect(cornerRadius: 6))
                    .offset(x: button.minX, y: button.minY)
                AimOutline()
                    .frame(width: button.width + 6, height: button.height + 6)
                    .offset(x: button.minX - 3, y: button.minY - 3)
                AimChip(role: "Button", label: "Pay now")
                    .offset(x: button.minX - 3, y: button.minY - 30)
                PinBadge(number: 1)
                    .position(x: window.minX + 300, y: window.minY + 120)
                KeepBothBubble()
                    .position(x: window.maxX - 220, y: window.maxY - 30)
            }
        }
    }
}
