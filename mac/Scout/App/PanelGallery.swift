import AppKit
import SwiftUI

enum PanelGallery {
    static var directory: URL? {
        let prefix = "--panel-gallery="
        return ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }.map { URL(fileURLWithPath: String($0.dropFirst(prefix.count)), isDirectory: true) }
    }

    static func run(model: AppModel, into directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--picker-query=") }) {
            let loadStarted = ContinuousClock.now
            await model.loadTargets(pressedAt: loadStarted)
            let loadMs = ApiaryBridge.milliseconds(.now - loadStarted)
            let picker = model.picker.model
            picker.query = String(argument.dropFirst("--picker-query=".count))
            let query = picker.query
            let started = ContinuousClock.now
            for index in 0..<1000 { picker.query = index.isMultiple(of: 2) ? query : query.uppercased() }
            let elapsed = ApiaryBridge.milliseconds(.now - started)
            picker.query = query
            let matches = picker.filtered
            let queries = Set([query, query.uppercased(), String(query.prefix(3))] + matches.flatMap { target in
                [target.name, target.displayName, target.subtitle, target.sessionTitle, target.championName, target.championID, target.id, target.sessionID, target.handle, target.workspaceID, target.workspaceName].compactMap { $0 }
            })
            var searches: [String: [String]] = [:]
            for query in queries.sorted() {
                picker.query = query
                searches[query] = picker.filtered.map(\.key)
            }
            picker.query = query
            let report: [String: Any] = [
                "query": picker.query,
                "total": picker.targets.count,
                "loadMs": loadMs,
                "searches": searches,
                "uniqueKeys": Set(picker.targets.map(\.key)).count,
                "canPaste": picker.canPaste,
                "filter1000Ms": elapsed,
                "matches": picker.filtered.map { ["kind": $0.kind, "id": $0.id, "title": $0.title, "sessionId": $0.sessionID ?? "", "workspace": $0.workspaceLabel ?? "", "viaApiary": $0.viaApiary] },
            ]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: directory.appendingPathComponent("picker-report.json"))
            }
            for scheme in DesignGallery.schemes {
                NSApp.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                let host = NSHostingView(rootView: TargetPickerView().environment(picker).environment(\.colorScheme, scheme))
                host.frame = CGRect(origin: .zero, size: TargetPickerController.size)
                let panel = PickerPanel(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                panel.contentView = host
                panel.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
                panel.orderFrontRegardless()
                host.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(200))
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("picker-\(scheme == .dark ? "dark" : "light").png"))
                }
                panel.orderOut(nil)
            }
            NSApp.terminate(nil)
            return
        }
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
