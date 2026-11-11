import AppKit
import SwiftUI

final class HUDController {
    private var pill: NSPanel?
    private var stack: NSPanel?
    private let overlay = CaptureOverlayController()
    private weak var model: AppModel?
    private var barScreen: NSScreen?

    static let stackWidth: CGFloat = 360

    private var scale: CGFloat { model?.preferences.uiSize.scale ?? 1 }
    private var scaledPillSize: CGSize { CGSize(width: ScoutingPill.windowSize.width * scale, height: ScoutingPill.windowSize.height * scale) }

    func prepare(model: AppModel) {
        if self.model == nil {
            self.model = model
            trackUISize(model.preferences)
        }
        if pill == nil {
            let pill = makePanel(content: ScoutingPill().environment(model), level: CaptureOverlayController.level + 2, movable: false)
            pill.setFrame(CGRect(origin: .zero, size: scaledPillSize), display: false)
            warm(pill)
            self.pill = pill
        }
        if stack == nil { stack = makePanel(content: SnippetStack().environment(model), level: CaptureOverlayController.level + 1) }
        overlay.prepare(follower: nil, ink: nil)
    }

    private func warm(_ panel: NSPanel) {
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        DispatchQueue.main.async {
            panel.orderOut(nil)
            panel.alphaValue = 1
            panel.ignoresMouseEvents = false
        }
    }

    func showPill(model: AppModel) {
        prepare(model: model)
        guard let pill else { return }
        let cursor = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(cursor, $0.frame, false) }) ?? NSScreen.main else { return }
        place(pill, on: screen)
        pill.orderFrontRegardless()
        CATransaction.flush()
    }

    var pillWindow: NSWindow? { pill }

    private func place(_ pill: NSPanel, on screen: NSScreen) {
        barScreen = screen
        let frame = NotchGeometry(screen).barFrame(size: scaledPillSize)
        guard pill.frame != frame else { return }
        pill.setFrame(frame, display: true)
    }

    func attach(_ session: ScoutingSession, model: AppModel) {
        overlay.show(follower: session.follower, ink: session.aim.ink)
        track(session.follower)
        dock(to: session.follower.bounds)
        guard let stack else { return }
        Task {
            await InteractionTimings.afterCommit()
            guard model.isScouting, let frame = self.stackFrame() else { return }
            stack.setFrame(frame, display: false)
            stack.orderFrontRegardless()
        }
    }

    private func stackFrame() -> CGRect? {
        guard let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return nil }
        let width = Self.stackWidth * scale
        return CGRect(x: visible.maxX - width - 14, y: visible.minY + 14, width: width, height: visible.height - 28 - scaledPillSize.height)
    }

    private func trackUISize(_ preferences: Preferences) {
        withObservationTracking {
            _ = preferences.uiSize
        } onChange: { [weak self, weak preferences] in
            Task { @MainActor in
                guard let self, let preferences else { return }
                self.resizePanels()
                self.trackUISize(preferences)
            }
        }
    }

    private func resizePanels() {
        if let pill, pill.isVisible, let screen = barScreen ?? pill.screen ?? NSScreen.main {
            place(pill, on: screen)
        }
        if let stack, stack.isVisible, let frame = stackFrame() {
            stack.setFrame(frame, display: true)
        }
    }

    func hidePill() {
        barScreen = nil
        pill?.orderOut(nil)
        overlay.hide()
    }

    func hideAll() {
        hidePill()
        stack?.orderOut(nil)
    }

    private func track(_ follower: CaptureFollower) {
        withObservationTracking {
            _ = follower.bounds
        } onChange: { [weak self, weak follower] in
            Task { @MainActor in
                guard let self, let follower, follower.isRunning else { return }
                self.dock(to: follower.bounds)
                self.track(follower)
            }
        }
    }

    private func dock(to region: CGRect?) {
        guard let region, let pill, pill.isVisible else { return }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let center = CGPoint(x: region.midX, y: primaryHeight - region.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }), screen.frame != barScreen?.frame else { return }
        place(pill, on: screen)
    }

    private func makePanel(content: some View, level: NSWindow.Level, movable: Bool = true) -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = level
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovableByWindowBackground = movable
        panel.becomesKeyOnlyIfNeeded = true
        panel.sharingType = SimulationMode.panelSharing
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: content)
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }
}

extension NotchGeometry {
    init(_ screen: NSScreen) {
        self.init(
            frame: screen.frame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryTopLeft: screen.auxiliaryTopLeftArea,
            auxiliaryTopRight: screen.auxiliaryTopRightArea
        )
    }
}

extension NSWindow.Level {
    static func + (level: NSWindow.Level, offset: Int) -> NSWindow.Level {
        NSWindow.Level(rawValue: level.rawValue + offset)
    }
}
