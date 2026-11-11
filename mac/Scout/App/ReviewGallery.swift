import AppKit
import ScoutCore
import SwiftUI

enum ReviewGallery {
    static var directory: URL? {
        let prefix = "--review-gallery="
        return ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }.map { URL(fileURLWithPath: String($0.dropFirst(prefix.count)), isDirectory: true) }
    }

    static let windowSize = CGSize(width: 1260, height: 820)

    static func run(model: AppModel, into directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? await Task.sleep(for: .milliseconds(300))
        let frame = DesignGallery.mockFrame()
        let reviews = fixtures.map { ($0.name, $0.make(model.dispatcher)) }
        for scheme in DesignGallery.schemes {
            NSApp.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            try? await Task.sleep(for: .milliseconds(80))
            for size in UISize.allCases {
                for (name, review) in reviews {
                    for (suffix, window) in [("", windowSize), ("-min", ReviewWindow.minimumSize)] {
                        let view = ReviewSurface(review: review, player: ReviewPlayer())
                            .frame(width: window.width, height: window.height)
                            .scaled(by: size.scale)
                            .environment(model)
                            .environment(\.stillFrame, frame)
                        render(view, scheme: scheme, to: directory.appendingPathComponent("review-\(name)-\(scheme == .dark ? "dark" : "light")-\(size.rawValue)\(suffix).png"))
                    }
                }
            }
        }
        await captureLiveWindow(model: model, frame: frame, into: directory)
        NSApp.terminate(nil)
    }

    private static func captureLiveWindow(model: AppModel, frame: CGImage?, into directory: URL) async {
        guard let review = fixtures.first(where: { $0.name == "three" })?.make(model.dispatcher), let card = review.selectedTask else { return }
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let player = ReviewPlayer()
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: windowSize), styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ReviewSurface(review: review, player: player).environment(model).environment(\.stillFrame, frame))
        var log: [String] = []
        func capture(_ name: String, size: CGSize = windowSize) async {
            window.setContentSize(size)
            try? await Task.sleep(for: .milliseconds(400))
            guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("live-\(name).png"))
            log.append("\(name): " + review.tasks.enumerated().map { index, task in
                "\(index + 1) \(String(format: "%.1f-%.1f", task.snippet.range.start, task.snippet.range.end)) excluded=\(task.excludedTargetIDs.count) edited=\(task.transcriptOverride != nil)"
            }.joined(separator: " | "))
        }
        await capture("01-open")
        await capture("02-minimum", size: ReviewWindow.minimumSize)
        review.playhead = card.snippet.range.start + 4
        review.split(card, at: review.playhead)
        await capture("03-split")
        review.join(card)
        await capture("04-joined")
        review.delete(card)
        await capture("05-deleted")
        review.undo()
        review.select(card)
        await capture("06-undone")
        review.beginTextEdit()
        card.excludedTargetIDs = []
        card.transcriptOverride = nil
        review.edited(card)
        await capture("07-included-original")
        player.loopsTask = false
        await capture("08-loop-off")
        try? log.joined(separator: "\n").write(to: directory.appendingPathComponent("live-log.txt"), atomically: true, encoding: .utf8)
        window.close()
    }

    private static func render(_ view: some View, scheme: ColorScheme, to url: URL) {
        let renderer = ImageRenderer(content: view.environment(\.stillRender, true).environment(\.colorScheme, scheme))
        renderer.scale = 2
        guard let image = renderer.cgImage else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }

    struct Spoken {
        var start: SessionTime
        var end: SessionTime
        var text: String
    }

    struct TaskSpec {
        var title: String
        var start: SessionTime
        var end: SessionTime
        var speech: [Spoken]
        var state: SnippetCard.State
        var destination: Destination?
        var edited: String?
        var targets: [Target] = []
        var pins: [SessionTime] = []
        var excluded: Bool = false
    }

    struct Fixture {
        var name: String
        var duration: SessionTime
        var contexts: [(SessionTime, AppContext)]
        var tasks: [TaskSpec]
        var leftovers: [Spoken] = []
        var selected: Int = 0
        var empty = false

        @MainActor
        func make(_ dispatcher: Dispatcher) -> SessionReview? {
            guard !empty else { return nil }
            var signals: [Signal] = contexts.map { .context(ContextChange(at: $0.0, context: $0.1)) }
            var counter = 0
            for task in tasks {
                for spoken in task.speech {
                    counter += 1
                    signals.append(.utterance(Utterance(id: "u\(counter)", range: TimeRange(start: spoken.start, end: spoken.end), text: spoken.text)))
                }
                for target in task.targets {
                    signals.append(.focus(Focus(range: TimeRange(start: task.start + 0.4, end: min(task.end, task.start + 2.4)), target: target)))
                }
                for (index, pin) in task.pins.enumerated() {
                    signals.append(.mark(Mark(id: "m\(counter)-\(index)", at: pin, point: Point(x: 420, y: 300), target: task.targets.first)))
                }
            }
            for spoken in leftovers {
                counter += 1
                signals.append(.utterance(Utterance(id: "u\(counter)", range: TimeRange(start: spoken.start, end: spoken.end), text: spoken.text)))
            }
            var ledger = SessionLedger(replaying: signals.sorted { $0.time < $1.time })
            ledger.extend(to: duration)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("scout-review-gallery/\(name)", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let sessionID = "gallery-\(name)"
            let cards = tasks.enumerated().map { index, task -> SnippetCard in
                let card = SnippetCard(snippet: ledger.snippet(id: "task-\(index)", range: TimeRange(start: task.start, end: task.end)), sessionID: sessionID, sessionDirectory: directory)
                card.restoreTitle(task.title, custom: false)
                card.transcriptOverride = task.edited
                card.destination = task.destination
                card.state = task.state
                card.project = contexts.first?.1.project
                if task.excluded, let first = task.targets.first { card.excludedTargetIDs = [first.id] }
                return card
            }
            let record = ReviewRecord(
                sessionID: sessionID,
                startedAt: Fixture.date,
                segmentation: Segmentation.automatic.rawValue,
                duration: duration,
                video: .init(file: "session.mp4", start: 0, end: duration),
                display: nil,
                displayHops: nil,
                discarded: nil,
                tasks: []
            )
            let review = SessionReview(directory: directory, record: record, ledger: ledger, cards: cards, dispatcher: dispatcher)
            if review.tasks.indices.contains(selected) {
                review.select(review.tasks[selected])
                review.playhead = review.tasks[selected].snippet.range.start + 1.2
            }
            return review
        }

        static let date = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 18, minute: 26)) ?? Date()
    }

    private static let project = ProjectReference(rootPath: "/Users/dev/code/acme-web", name: "acme-web", gitBranch: "checkout-polish")
    private static let safari = AppContext(app: AppIdentity(bundleID: "com.apple.Safari", name: "Safari"), windowTitle: "Checkout · Acme", location: "http://localhost:3000/checkout", project: project)
    private static let simulator = AppContext(app: AppIdentity(bundleID: "com.apple.iphonesimulator", name: "Simulator"), windowTitle: "iPhone 17 Pro", location: "Acme › Cart", project: project)
    private static let terminal = AppContext(app: AppIdentity(bundleID: "com.github.wez.wezterm", name: "WezTerm"), windowTitle: "[1/3] ◐ Apiary architecture refresh and simplification", project: nil)

    private static let shop = Destination.session(id: "s1", title: "acme-web", agent: "claude")
    private static let fresh = Destination.newSession(cwd: "/Users/dev/code/acme-web", agent: "codex")

    private static func button(_ label: String, _ component: String, _ file: String, _ line: Int) -> Target {
        Target(id: "web:\(component)-\(line)", provider: .web, role: "button", label: label, ancestry: ["web:main"], component: component, source: SourceLocation(file: file, line: line))
    }

    private static let threeTasks: [TaskSpec] = [
        TaskSpec(
            title: "Make the Pay now button bigger and primary",
            start: 0.6, end: 9.4,
            speech: [Spoken(start: 1.0, end: 4.8, text: "The pay now button is way too small and it's grey, it looks disabled."), Spoken(start: 5.2, end: 9.0, text: "Make it the primary color and full width on mobile.")],
            state: .sent("acme-web · claude"), destination: shop,
            targets: [button("Pay now", "PayButton", "src/checkout/PayButton.tsx", 88)], pins: [3.1]
        ),
        TaskSpec(
            title: "Footer overlaps the cookie banner at the bottom of the page",
            start: 11.2, end: 21.0,
            speech: [Spoken(start: 11.6, end: 16.0, text: "Next thing, the footer overlaps the cookie banner when you scroll all the way down."), Spoken(start: 16.4, end: 20.6, text: "You can't reach the accept button at all.")],
            state: .held, destination: shop,
            edited: "The footer overlaps the cookie banner when you scroll to the bottom, so the accept button can't be reached. Keep the banner above the footer.",
            targets: [button("Accept", "CookieBanner", "src/legal/CookieBanner.tsx", 31), button("Footer", "SiteFooter", "src/layout/SiteFooter.tsx", 12)],
            pins: [14.2, 18.8], excluded: true
        ),
        TaskSpec(
            title: "Show the total price in bold",
            start: 23.4, end: 29.8,
            speech: [Spoken(start: 23.8, end: 29.4, text: "And the total price should be in bold, it gets lost next to the item prices.")],
            state: .needsDestination, destination: nil
        ),
    ]

    private static let eightTitles: [(String, SnippetCard.State, Destination?)] = [
        ("Make the Pay now button bigger and use the primary color, full width on narrow windows", .sent("acme-web · claude"), shop),
        ("Footer overlaps the cookie banner when the page is scrolled to the very bottom", .sent("acme-web · claude"), shop),
        ("Show the total price in bold", .sending, shop),
        ("Avatar menu opens behind the sticky header on the orders page", .failed("hive did not answer in 10 s"), shop),
        ("Rename “Workspace settings” to “Settings” everywhere in the sidebar and the command menu", .copiedInstead("session is busy"), shop),
        ("Cart badge doesn't update after removing an item in the simulator", .held, fresh),
        ("Empty state for search results needs a clear button", .held, shop),
        ("Promo code field accepts spaces and then fails silently", .needsDestination, nil),
    ]

    private static var eightTasks: [TaskSpec] {
        eightTitles.enumerated().map { index, item in
            let start = 0.8 + Double(index) * 9.5
            return TaskSpec(
                title: item.0,
                start: start, end: start + 7.6,
                speech: [Spoken(start: start + 0.4, end: start + 7.2, text: item.0 + ". It happens every time I try it, and it should match the rest of the app.")],
                state: item.1, destination: item.2,
                targets: index % 3 == 0 ? [button("Pay now", "PayButton", "src/checkout/PayButton.tsx", 88)] : [],
                pins: index % 4 == 1 ? [start + 3] : []
            )
        }
    }

    private static var walkthroughTasks: [TaskSpec] {
        let titles = [
            "Onboarding: the second step skips the email check",
            "Checkout totals don't line up with item prices",
            "Pay button too small on narrow windows",
            "Cart drawer flickers when it opens",
            "Order history shows dates in US format",
            "Settings page loses unsaved changes on back",
        ]
        return titles.enumerated().map { index, title in
            let start = 12 + Double(index) * 44
            return TaskSpec(
                title: title,
                start: start, end: start + 26 + Double(index % 3) * 6,
                speech: [Spoken(start: start + 1, end: start + 12, text: title + ". I noticed this while going through the flow from the start."), Spoken(start: start + 13, end: start + 24, text: "It should behave like the rest of the app does.")],
                state: index < 2 ? .sent("acme-web · claude") : .held, destination: shop,
                targets: [button("Continue", "StepFooter", "src/onboarding/StepFooter.tsx", 40 + index)],
                pins: [start + 6]
            )
        }
    }

    static let fixtures: [Fixture] = [
        Fixture(name: "one", duration: 14, contexts: [(0, safari)], tasks: [threeTasks[1]].map { var task = $0; task.edited = nil; task.start = 1; task.end = 11; return task }),
        Fixture(name: "three", duration: 34, contexts: [(0, safari)], tasks: threeTasks, leftovers: [Spoken(start: 31.0, end: 33.2, text: "Oh, and the coupon field is too narrow.")], selected: 1),
        Fixture(name: "eight", duration: 80, contexts: [(0, safari), (46, simulator), (66, safari)], tasks: eightTasks, selected: 3),
        Fixture(name: "sent", duration: 17, contexts: [(0, terminal)], tasks: [
            TaskSpec(title: "The pay button is too small", start: 0, end: 2.3, speech: [Spoken(start: 0.2, end: 2.0, text: "The pay button is too small.")], state: .sent("Clipboard (dry run)"), destination: .clipboard, edited: "The pay button is too small. Also make it bigger on tablets."),
            TaskSpec(title: "The footer overlaps", start: 3.6, end: 7.6, speech: [Spoken(start: 4.0, end: 7.2, text: "Next thing, the footer overlaps.")], state: .sent("Clipboard (dry run)"), destination: .clipboard),
        ]),
        Fixture(name: "walkthrough", duration: 296, contexts: [(0, safari), (140, simulator), (230, safari)], tasks: walkthroughTasks, leftovers: [Spoken(start: 280, end: 288, text: "That's mostly it, maybe look at the footer links too.")], selected: 2),
        Fixture(name: "leftover", duration: 20, contexts: [(0, safari)], tasks: [], leftovers: [Spoken(start: 2, end: 7, text: "The search field should keep focus after clearing it."), Spoken(start: 10, end: 15, text: "And the results count is hard to read.")]),
        Fixture(name: "empty", duration: 0, contexts: [], tasks: [], empty: true),
    ]
}
