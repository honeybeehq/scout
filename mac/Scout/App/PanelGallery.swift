import AppKit
import SwiftUI

enum PanelGallery {
    static var directory: URL? {
        let prefix = "--panel-gallery="
        return ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }.map { URL(fileURLWithPath: String($0.dropFirst(prefix.count)), isDirectory: true) }
    }

    static func run(into directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? await Task.sleep(for: .milliseconds(300))
        for scheme in DesignGallery.schemes {
            NSApp.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            try? await Task.sleep(for: .milliseconds(80))
            for size in UISize.allCases {
                for (name, state, segmentation) in fixtures {
                    let view = MenuBarPanelContent(state: state, segmentation: .constant(segmentation), actions: MenuBarPanelActions())
                        .scaled(by: size.scale)
                    render(view, scheme: scheme, to: directory.appendingPathComponent("panel-\(name)-\(scheme == .dark ? "dark" : "light")-\(size.rawValue).png"))
                }
            }
        }
        NSApp.terminate(nil)
    }

    private static func render(_ view: some View, scheme: ColorScheme, to url: URL) {
        let renderer = ImageRenderer(content: view.environment(\.stillRender, true).environment(\.colorScheme, scheme))
        renderer.scale = 2
        guard let image = renderer.cgImage else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }

    private static let longTasks: [MenuBarPanelState.RecentTask] = [
        .init(id: "1", title: "The total on the checkout summary should be bold and line up with the item prices above it", state: .needsDestination),
        .init(id: "2", title: "Pay button is too small on narrow windows and the label wraps onto two lines", state: .countdown(until: .distantFuture)),
        .init(id: "3", title: "Footer overlaps the cookie banner when the page is scrolled to the very bottom", state: .sent("hive")),
        .init(id: "4", title: "Avatar menu opens behind the sticky header", state: .failed("hive did not answer")),
        .init(id: "5", title: "Rename “Workspace settings” to “Settings” everywhere in the sidebar", state: .sent("hive")),
    ]

    private static let fixtures: [(String, MenuBarPanelState, Segmentation)] = [
        ("empty", MenuBarPanelState(hive: .unreachable("timed out"), apiaryRunning: true), .automatic),
        ("content", MenuBarPanelState(
            recent: longTasks,
            lastWalkthrough: .init(title: "Checkout totals and the pay button on narrow windows", summary: "1:42 · 3 asks · copied, paste with ⌘V", transcriptProblem: nil),
            hive: .connected(activeSessions: 4),
            apiaryRunning: true,
            sdkApps: ["checkout-web"]
        ), .manual),
        ("recording", MenuBarPanelState(
            isScouting: true,
            recent: Array(longTasks.prefix(3)),
            hive: .connected(activeSessions: 2),
            apiaryRunning: true
        ), .automatic),
    ]
}
