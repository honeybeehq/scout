import AppKit
import SwiftUI

final class HUDController {
    private var pill: NSPanel?
    private var stack: NSPanel?
    private let overlay = CaptureOverlayController()
    private var shownAt: TimeInterval = 0
    private var dockTask: Task<Void, Never>?
    private weak var model: AppModel?

    static let pillSize = CGSize(width: 660, height: 44)
    static let pillHeight: CGFloat = 36
    static let stackWidth: CGFloat = 360
    static let cursorOffset = CGPoint(x: 14, y: 14)
    static let dockDelay: TimeInterval = 0.12

    private var scale: CGFloat { model?.preferences.uiSize.scale ?? 1 }
    private var scaledPillSize: CGSize { CGSize(width: Self.pillSize.width * scale, height: Self.pillSize.height * scale) }

    func prepare(model: AppModel) {
        if self.model == nil {
            self.model = model
            trackUISize(model.preferences)
        }
        if pill == nil {
            let pill = makePanel(content: ScoutingPill().environment(model), level: CaptureOverlayController.level + 2)
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
        let screen = NSScreen.screens.first { NSMouseInRect(cursor, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        pill.setFrame(clamped(CGRect(x: cursor.x + Self.cursorOffset.x, y: cursor.y - Self.cursorOffset.y - scaledPillSize.height, width: scaledPillSize.width, height: scaledPillSize.height), to: screen.visibleFrame), display: false)
        pill.orderFrontRegardless()
        CATransaction.flush()
        shownAt = InteractionTimings.now
    }

    func attach(_ session: ScoutingSession, model: AppModel) {
        overlay.show(follower: session.follower, ink: session.aim.ink)
        track(session.follower)
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
        if let pill, pill.isVisible {
            let screen = pill.screen ?? NSScreen.main
            let top = CGRect(x: pill.frame.minX, y: pill.frame.maxY - scaledPillSize.height, width: scaledPillSize.width, height: scaledPillSize.height)
            pill.setFrame(screen.map { clamped(top, to: $0.visibleFrame) } ?? top, display: true)
        }
        if let stack, stack.isVisible, let frame = stackFrame() {
            stack.setFrame(frame, display: true)
        }
    }

    func hidePill() {
        dockTask?.cancel()
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
        let wait = Self.dockDelay - (InteractionTimings.now - shownAt)
        dockTask?.cancel()
        dockTask = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled, let self else { return }
            self.move(pill, to: self.dockFrame(for: region))
        }
    }

    private func dockFrame(for region: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let regionTop = primaryHeight - region.minY
        let cocoaRegion = CGRect(x: region.minX, y: primaryHeight - region.maxY, width: region.width, height: region.height)
        let screen = NSScreen.screens.first { $0.frame.intersects(cocoaRegion) && $0.frame.contains(CGPoint(x: cocoaRegion.midX, y: cocoaRegion.midY)) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? cocoaRegion
        let inset = (Self.pillSize.height - Self.pillHeight) / 2 * scale
        var origin = CGPoint(x: region.minX + 8 - inset, y: regionTop + 6 - inset)
        if origin.y + scaledPillSize.height > visible.maxY {
            origin.y = min(regionTop, visible.maxY) - scaledPillSize.height - 6 + inset
        }
        return clamped(CGRect(origin: origin, size: scaledPillSize), to: visible)
    }

    private func clamped(_ frame: CGRect, to visible: CGRect) -> CGRect {
        var frame = frame
        frame.origin.x = min(max(frame.minX, visible.minX + 4), visible.maxX - 220)
        frame.origin.y = min(max(frame.minY, visible.minY + 4), visible.maxY - frame.height)
        return frame
    }

    private func move(_ panel: NSPanel, to frame: CGRect) {
        guard panel.frame != frame else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func makePanel(content: some View, level: NSWindow.Level) -> NSPanel {
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
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.sharingType = SimulationMode.panelSharing
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: content.environment(\.colorScheme, .dark))
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }
}

extension NSWindow.Level {
    static func + (level: NSWindow.Level, offset: Int) -> NSWindow.Level {
        NSWindow.Level(rawValue: level.rawValue + offset)
    }
}
