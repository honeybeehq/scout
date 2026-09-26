import AppKit
import SwiftUI

final class HUDController {
    private var pill: NSPanel?
    private var stack: NSPanel?
    private var screen: NSScreen?

    static let pillSize = CGSize(width: 480, height: 52)
    static let stackWidth: CGFloat = 360

    func show(model: AppModel) {
        screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame

        let pill = self.pill ?? makePanel(content: ScoutingPill().environment(model))
        pill.setFrame(
            CGRect(x: visible.midX - Self.pillSize.width / 2, y: visible.maxY - Self.pillSize.height - 10, width: Self.pillSize.width, height: Self.pillSize.height),
            display: true
        )
        pill.orderFrontRegardless()
        self.pill = pill

        let stack = self.stack ?? makePanel(content: SnippetStack().environment(model))
        stack.setFrame(
            CGRect(x: visible.maxX - Self.stackWidth - 14, y: visible.minY + 14, width: Self.stackWidth, height: visible.height - 28 - Self.pillSize.height),
            display: true
        )
        stack.orderFrontRegardless()
        self.stack = stack
    }

    func hidePill() {
        pill?.orderOut(nil)
    }

    func hideAll() {
        pill?.orderOut(nil)
        stack?.orderOut(nil)
    }

    private func makePanel(content: some View) -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.sharingType = SimulationMode.audioFile == nil ? .none : .readOnly
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: content.environment(\.colorScheme, .dark))
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }
}
