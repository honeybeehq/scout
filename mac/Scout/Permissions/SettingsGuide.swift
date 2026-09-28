import AppKit
import Observation
import SwiftUI

@Observable
final class SettingsGuide {
    enum Phase: Equatable {
        case hidden
        case guiding(Permission)
        case done(Permission)
    }

    private(set) var phase: Phase = .hidden
    private var panel: NSPanel?
    private var tracking: Task<Void, Never>?

    private static let settingsBundleID = "com.apple.systempreferences"
    private static let panelSize = CGSize(width: 320, height: 236)
    private static let gap: CGFloat = 14

    func show(for permission: Permission) {
        phase = .guiding(permission)
        ensurePanel()
        startTracking()
    }

    func complete(_ permission: Permission) {
        guard phase == .guiding(permission) else { return }
        withAnimation(Motion.bouncy) { phase = .done(permission) }
        Task {
            try? await Task.sleep(for: .milliseconds(1100))
            guard phase == .done(permission) else { return }
            hide()
            NSApp.activate()
        }
    }

    func hideIfIdle() {
        if case .done = phase { hide() }
    }

    func hide() {
        tracking?.cancel()
        tracking = nil
        panel?.orderOut(nil)
        phase = .hidden
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: Self.panelSize),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let host = NSHostingView(rootView: SettingsGuideView(guide: self))
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
    }

    private func startTracking() {
        tracking?.cancel()
        tracking = Task { [weak self] in
            while !Task.isCancelled {
                self?.reposition()
                try? await Task.sleep(for: .milliseconds(160))
            }
        }
    }

    private func reposition() {
        guard let panel, phase != .hidden else { return }
        guard let settingsFrame = Self.frontSettingsWindowFrame() else {
            if case .guiding = phase { panel.orderOut(nil) }
            return
        }
        let origin = Self.placement(beside: settingsFrame, size: Self.panelSize)
        if panel.frame.origin != origin || !panel.isVisible {
            panel.setFrame(CGRect(origin: origin, size: Self.panelSize), display: true)
            panel.orderFrontRegardless()
        }
    }

    private static func frontSettingsWindowFrame() -> CGRect? {
        guard let settings = NSRunningApplication.runningApplications(withBundleIdentifier: settingsBundleID).first,
              !settings.isHidden
        else { return nil }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let match = windows.first { info in
            (info[kCGWindowOwnerPID as String] as? pid_t) == settings.processIdentifier
                && (info[kCGWindowLayer as String] as? Int) == 0
        }
        guard let bounds = match?[kCGWindowBounds as String] as? [String: CGFloat],
              let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"],
              width > 200, height > 200
        else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: x, y: primaryHeight - y - height, width: width, height: height)
    }

    private static func placement(beside window: CGRect, size: CGSize) -> CGPoint {
        let screen = NSScreen.screens.first { $0.frame.intersects(window) }?.visibleFrame ?? window
        let top = window.maxY - 64 - size.height
        let y = min(max(top, screen.minY + gap), screen.maxY - size.height - gap)
        if window.maxX + gap + size.width <= screen.maxX {
            return CGPoint(x: window.maxX + gap, y: y)
        }
        if window.minX - gap - size.width >= screen.minX {
            return CGPoint(x: window.minX - gap - size.width, y: y)
        }
        return CGPoint(x: window.maxX - size.width - gap, y: window.minY + gap)
    }
}

struct SettingsGuideView: View {
    let guide: SettingsGuide

    var body: some View {
        ZStack {
            switch guide.phase {
            case .guiding(let permission):
                GuidingCard(permission: permission)
                    .transition(.blurReplace)
            case .done(let permission):
                DoneCard(permission: permission)
                    .transition(.blurReplace)
            case .hidden:
                Color.clear
            }
        }
        .frame(width: 320, height: 236)
        .environment(\.colorScheme, .dark)
    }
}

private struct GuidingCard: View {
    let permission: Permission

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ScoutMark(litArcs: 3, pulsing: true)
                    .frame(width: 22, height: 22)
                Text("Switch on Scout")
                    .font(Typography.headline)
                Spacer()
                Text(permission.title)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary)
            }

            HStack(spacing: 14) {
                AppIconDragTile()
                VStack(alignment: .leading, spacing: 6) {
                    Text(instruction)
                        .font(Typography.body)
                        .foregroundStyle(Palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                    TogglePreview()
                }
            }

            HStack(spacing: 8) {
                WaitingDots()
                Text(footnote)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassEffect(.regular.tint(Palette.night.opacity(0.55)), in: .rect(cornerRadius: 24))
    }

    private var instruction: String {
        "Find Scout in the list and turn it on. Not listed? Drag the icon in."
    }

    private var footnote: String {
        switch permission {
        case .screenRecording: "If macOS asks, pick Quit & Reopen. Scout resumes right here."
        default: "Scout will notice as soon as it's on."
        }
    }
}

private struct DoneCard: View {
    let permission: Permission

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Palette.ink)
                .frame(width: 58, height: 58)
                .background(Color.white.opacity(0.92), in: .circle)
            Text("\(permission.title) is on")
                .font(Typography.headline)
            Text("Taking you back to Scout")
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassEffect(.regular.tint(Palette.night.opacity(0.55)), in: .rect(cornerRadius: 24))
    }
}

private struct AppIconDragTile: View {
    @State private var hovering = false

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: 64, height: 64)
            .scaleEffect(hovering ? 1.06 : 1)
            .animation(Motion.snappy, value: hovering)
            .onHover { hovering = $0 }
            .draggable(Bundle.main.bundleURL)
            .help("Drag Scout into the list")
    }
}

private struct TogglePreview: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let on = reduceMotion || context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) > 1.0
            HStack(spacing: 8) {
                Text("Scout")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                Capsule()
                    .fill(on ? Color.accentColor : Color.white.opacity(0.18))
                    .frame(width: 34, height: 20)
                    .overlay(alignment: on ? .trailing : .leading) {
                        Circle().fill(.white).padding(2)
                    }
                    .animation(Motion.snappy, value: on)
            }
        }
    }
}

struct WaitingDots: View {
    var color: Color = Palette.textSecondary

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(color)
                        .frame(width: 5, height: 5)
                        .opacity(0.35 + 0.65 * max(0, sin(t * 4 - Double(index) * 0.7)))
                }
            }
        }
    }
}
