import AppKit
import ScoutCore
import SwiftUI

enum OptimiseGallery {
    static var fixtures: URL? {
        let prefix = "--optimise-states="
        return ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }.map { URL(fileURLWithPath: String($0.dropFirst(prefix.count)), isDirectory: true) }
    }

    struct Shot {
        var name: String
        var fixture: String
        var select: String
        var prepare: (SessionReview, URL) async throws -> Void
    }

    static func run(model: AppModel, fixtures: URL, into directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let frame = DesignGallery.mockFrame()
        let eight = fixtures.appendingPathComponent("eight.optimise.v1.json")
        let walkthrough = fixtures.appendingPathComponent("review-walkthrough.optimise.v1.json")
        let shots: [Shot] = [
            Shot(name: "1-idle", fixture: "eight", select: "task-5") { _, _ in },
            Shot(name: "1-waiting-for-titles", fixture: "eight", select: "task-5") { review, _ in
                review.tasks.last?.state = .preparing
            },
            Shot(name: "2-running", fixture: "eight", select: "task-5") { review, _ in
                await run(review, socket: argument("--optimise-hang-socket="), until: { $0 == .running })
            },
            Shot(name: "3-proposals-merge", fixture: "eight", select: "task-5") { review, _ in try review.optimise.loadProposals(from: eight) },
            Shot(name: "3-proposals-split-flag", fixture: "eight", select: "task-7") { review, _ in try review.optimise.loadProposals(from: eight) },
            Shot(name: "3-proposals-crosses-cut", fixture: "eight", select: "task-3") { review, _ in try review.optimise.loadProposals(from: eight) },
            Shot(name: "4-partly-accepted", fixture: "eight", select: "task-3") { review, _ in
                try review.optimise.loadProposals(from: eight)
                review.optimise.accept("p2")
                review.optimise.reject("p3")
            },
            Shot(name: "4-partly-accepted-merged", fixture: "eight", select: "task-5") { review, _ in
                try review.optimise.loadProposals(from: eight)
                review.optimise.accept("p1")
                review.optimise.accept("p2")
            },
            Shot(name: "4-all-decided", fixture: "eight", select: "task-5") { review, _ in
                try review.optimise.loadProposals(from: eight)
                review.optimise.acceptAll()
                review.optimise.reject("p6")
            },
            Shot(name: "5-boot-failure", fixture: "eight", select: "task-5") { review, _ in
                await run(review, socket: argument("--optimise-boot-socket="), until: { if case .failed = $0 { true } else { false } })
            },
            Shot(name: "7-stopping-after-cancel", fixture: "eight", select: "task-5") { review, _ in
                await run(review, socket: argument("--optimise-hang-socket="), until: { $0 == .running })
                review.optimise.cancel()
            },
            Shot(name: "8-cleanup-error-after-accept-undo", fixture: "eight", select: "task-3") { review, _ in
                await run(review, socket: argument("--optimise-cleanup-socket="), until: { $0 == .ready })
                for _ in 0..<300 where review.optimise.cleanupError == nil {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                review.optimise.accept("p2")
                review.optimise.accept("p3")
                review.undo()
            },
            Shot(name: "5-failure", fixture: "eight", select: "task-5") { review, _ in
                await run(review, socket: "/tmp/scout-optimise-gallery-no-hive.sock", until: { if case .failed = $0 { true } else { false } })
            },
            Shot(name: "6-walkthrough-proposals", fixture: "walkthrough", select: "task-2") { review, _ in try review.optimise.loadProposals(from: walkthrough) },
            Shot(name: "6-walkthrough-split", fixture: "walkthrough", select: "task-4") { review, _ in try review.optimise.loadProposals(from: walkthrough) },
            Shot(name: "6-walkthrough-drop", fixture: "walkthrough", select: "task-5") { review, _ in try review.optimise.loadProposals(from: walkthrough) },
        ]
        var log: [String] = []
        for scheme in DesignGallery.schemes {
            NSApp.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            try? await Task.sleep(for: .milliseconds(80))
            for shot in shots {
                guard let review = ReviewGallery.fixtures.first(where: { $0.name == shot.fixture })?.make(model.dispatcher) else { continue }
                do {
                    try await shot.prepare(review, directory)
                } catch {
                    log.append("\(shot.name): \(error)")
                }
                if let card = review.tasks.first(where: { $0.snippet.id == shot.select }) { review.select(card) }
                for (suffix, window) in [("", ReviewGallery.windowSize), ("-min", ReviewWindow.minimumSize)] {
                    let view = ReviewSurface(review: review, player: ReviewPlayer())
                        .frame(width: window.width, height: window.height)
                        .environment(model)
                        .environment(\.stillFrame, frame)
                    ReviewGallery.render(view, scheme: scheme, to: directory.appendingPathComponent("optimise-\(shot.name)-\(scheme == .dark ? "dark" : "light")\(suffix).png"))
                }
                if scheme == .light {
                    log.append("\(shot.name): state=\(review.optimise.state) undo=\(review.undoDepth) tasks=" + review.tasks.map { "\($0.snippet.id)[\(String(format: "%.1f-%.1f", $0.snippet.range.start, $0.snippet.range.end))] \($0.title)" }.joined(separator: " | "))
                    log.append("   stopping=\(review.optimise.isStopping) cleanupError=\(review.optimise.cleanupError ?? "none")")
                    log.append("   proposals: " + review.optimise.proposals.map { "\($0.id)=\(review.optimise.status(for: $0))" + (review.optimise.validationMessage(for: $0).map { "(\($0))" } ?? "") }.joined(separator: " ") + (review.optimise.error.map { " error=\($0)" } ?? ""))
                }
                if review.optimise.state == .running { review.optimise.cancel() }
            }
        }
        try? log.joined(separator: "\n").write(to: directory.appendingPathComponent("optimise-log.txt"), atomically: true, encoding: .utf8)
        await recordLive(model: model, fixture: eight, frame: frame, into: directory)
    }

    static func argument(_ prefix: String) -> String? {
        ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    static func run(_ review: SessionReview, socket: String?, until done: (OptimiseReview.State) -> Bool) async {
        if let socket { setenv("HIVE_V2_SOCKET_PATH", socket, 1) }
        review.optimise.start()
        for _ in 0..<100 where !done(review.optimise.state) {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func recordLive(model: AppModel, fixture: URL, frame: CGImage?, into directory: URL) async {
        guard let review = ReviewGallery.fixtures.first(where: { $0.name == "eight" })?.make(model.dispatcher) else { return }
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let frames = directory.appendingPathComponent("live-frames", isDirectory: true)
        try? FileManager.default.removeItem(at: frames)
        try? FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        let player = ReviewPlayer()
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: 80, y: 80), size: ReviewGallery.windowSize), styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ReviewSurface(review: review, player: player).environment(model).environment(\.stillFrame, frame))
        window.orderFrontRegardless()
        var index = 0
        var log: [String] = []
        func hold(_ seconds: Double, _ caption: String) async {
            log.append(String(format: "%05d %@ undo=%d tasks=%d pending=%d", index, caption, review.undoDepth, review.tasks.count, review.optimise.proposals.filter { review.optimise.status(for: $0) == .pending }.count))
            let count = Int(seconds * 15)
            for _ in 0..<count {
                try? await Task.sleep(for: .milliseconds(66))
                guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: frames.appendingPathComponent(String(format: "f%05d.png", index)))
                index += 1
            }
        }
        func select(_ id: String) {
            if let card = review.tasks.first(where: { $0.snippet.id == id }) { review.select(card) }
        }
        select("task-5")
        await hold(1.2, "idle")
        if let socket = argument("--optimise-hang-socket=") { setenv("HIVE_V2_SOCKET_PATH", socket, 1) }
        review.optimise.start()
        await hold(2.4, "running (agent never answers): \(review.optimise.state)")
        review.optimise.cancel()
        await hold(1.2, "cancelled: \(review.optimise.state) stopping=\(review.optimise.isStopping) tasks unchanged")
        if let socket = argument("--optimise-success-socket=") { setenv("HIVE_V2_SOCKET_PATH", socket, 1) }
        review.optimise.start()
        await hold(0.6, "start pressed: \(review.optimise.state)")
        await hold(2.4, "after run: \(review.optimise.state) \(review.optimise.error ?? "")")
        await hold(2.0, "proposals on task 6")
        withAnimation(Motion.smooth) { review.optimise.accept("p1") }
        await hold(2.0, "accepted merge p1")
        select("task-3")
        await hold(1.6, "task 4 suggestions")
        withAnimation(Motion.smooth) { review.optimise.accept("p2") }
        await hold(1.6, "accepted title p2")
        withAnimation(Motion.smooth) { review.optimise.acceptAll() }
        await hold(2.0, "accept all (skips the cut-crossing merge)")
        withAnimation(Motion.smooth) { review.undo() }
        await hold(1.6, "undo: accept all")
        withAnimation(Motion.smooth) { review.undo() }
        await hold(1.6, "undo: title")
        select("task-5")
        withAnimation(Motion.smooth) { review.undo() }
        await hold(2.2, "undo: merge")
        if let socket = argument("--optimise-cleanup-socket=") {
            setenv("HIVE_V2_SOCKET_PATH", socket, 1)
            select("task-3")
            review.optimise.start()
            await hold(1.0, "optimise again (agent will not confirm stop): \(review.optimise.state)")
            var waited = 0.0
            while review.optimise.cleanupError == nil && waited < 26 {
                await hold(1.0, "waiting for stop confirmation: \(review.optimise.state) stopping=\(review.optimise.isStopping)")
                waited += 1
            }
            await hold(2.0, "cleanup error shown: \(review.optimise.cleanupError ?? "none")")
            withAnimation(Motion.smooth) { review.optimise.accept("p2") }
            await hold(1.6, "accepted title p2 with cleanup error: \(review.optimise.cleanupError != nil)")
            withAnimation(Motion.smooth) { review.undo() }
            await hold(2.0, "undo: title, cleanup error still shown: \(review.optimise.cleanupError != nil)")
        }
        try? log.joined(separator: "\n").write(to: directory.appendingPathComponent("live-log.txt"), atomically: true, encoding: .utf8)
        window.close()
    }
}
