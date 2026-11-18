import AppKit
import ApplicationServices
import ScoutCore

enum HeroDemo {
    private static func argument(_ name: String) -> String? {
        let prefix = "--\(name)="
        return ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    static var outputDirectory: URL? {
        argument("hero-demo").map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private struct Plan {
        var audio: URL
        var site: URL
        var lead: Double
        var first: Double
        var gap: Double
        var second: Double
        var safariFrame: CGRect
        var button: String
        var headline: String
        var patchTimeout: Double
    }

    private struct Event: Encodable {
        var name: String
        var at: Double
        var detail: String?
    }

    private struct Report: Encodable {
        var events: [Event]
        var problems: [String]
        var buttonFrame: String?
        var headlineFrame: String?
        var copyFrame: String?
        var taskTitles: [String]
        var taskStates: [String]
        var pins: [Mark]
        var accessibilityTrusted: Bool
        var screenRecordingGranted: Bool
        var screens: [String]
    }

    private static var events: [Event] = []
    private static var problems: [String] = []

    private static func note(_ name: String, _ detail: String? = nil) {
        events.append(Event(name: name, at: Date().timeIntervalSince1970, detail: detail))
        NSLog("[scout-hero] %@ %@", name, detail ?? "")
    }

    private static func plan() -> Plan? {
        guard let audio = argument("hero-audio"), let site = argument("hero-site"),
              let timing = argument("hero-timing")?.split(separator: ",").compactMap({ Double($0) }), timing.count == 4
        else { return nil }
        let frame = argument("hero-safari-frame")?.split(separator: ",").compactMap { Double($0) } ?? []
        return Plan(
            audio: URL(fileURLWithPath: audio),
            site: URL(fileURLWithPath: site, isDirectory: true),
            lead: timing[0], first: timing[1], gap: timing[2], second: timing[3],
            safariFrame: frame.count == 4 ? CGRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3]) : CGRect(x: 0, y: 25, width: 1920, height: 1055),
            button: argument("hero-button") ?? "Choose Household",
            headline: argument("hero-headline") ?? "Plan every meal",
            patchTimeout: argument("hero-patch-timeout").flatMap(Double.init) ?? 2700
        )
    }

    static func run(model: AppModel, output: URL) async {
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        guard let plan = plan() else {
            problems.append("missing --hero-audio, --hero-site or --hero-timing")
            finish(model: model, output: output, frames: [:])
            return
        }
        model.preferences.autoSend = false
        model.preferences.reviewOpening = .always
        try? await Task.sleep(for: .seconds(1.5))

        guard let safari = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first else {
            problems.append("Safari is not running")
            finish(model: model, output: output, frames: [:])
            return
        }
        let pid = safari.processIdentifier
        if !(await placeWindow(pid: pid, frame: plan.safariFrame)) { problems.append("could not place the Safari window") }
        note("safari.banner", await dismissBanner(pid: pid))
        try? await Task.sleep(for: .seconds(1.2))
        let button = await findFrame(pid: pid, text: plan.button, roles: ["AXLink", "AXButton"], prefix: false)
        let headline = await findFrame(pid: pid, text: plan.headline, roles: ["AXHeading", "AXStaticText"], prefix: true)
        var frames: [String: CGRect] = [:]
        frames["button"] = button
        frames["headline"] = headline
        guard let button, let headline else {
            problems.append("could not find the button or the headline in Safari")
            finish(model: model, output: output, frames: frames)
            return
        }
        let buttonPoint = CGPoint(x: button.midX, y: button.midY)
        let headlinePoint = CGPoint(x: headline.minX + min(240, headline.width * 0.3), y: headline.minY + min(30, headline.height * 0.2))
        let pointer = HeroPointer(start: CGPoint(x: plan.safariFrame.minX + plan.safariFrame.width * 0.62, y: plan.safariFrame.maxY - 90))

        let spoken = plan.lead + plan.first + plan.gap + plan.second + 1.4
        let partA = HeroRecording(url: output.appendingPathComponent("part-a.mov"), seconds: Int((2.0 + spoken + 16).rounded(.up)), log: output.appendingPathComponent("part-a.log"))
        note("partA.launched", partA.problem)
        try? await Task.sleep(for: .seconds(2.0))

        let forcing = Task { @MainActor in
            while !Task.isCancelled {
                for card in model.dispatcher.cards where !card.isLocked && card.destination != .clipboard {
                    model.dispatcher.choose(.clipboard, for: card)
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        model.startScouting(inputFile: plan.audio, result: .tasks)
        let start = Date()
        note("session.start")
        func at(_ seconds: Double) async {
            let wait = seconds - Date().timeIntervalSince(start)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        }

        await at(0.4)
        note("glide.button")
        await pointer.glide(to: buttonPoint, seconds: 1.0)
        let firstPin = plan.lead + 0.4
        await at(firstPin - 0.9)
        await pin(model: model, at: buttonPoint, log: "pin.button")
        await at(plan.lead + plan.first + 0.5)
        note("glide.headline")
        await pointer.glide(to: headlinePoint, seconds: 0.9)
        let secondPin = plan.lead + plan.first + plan.gap + 0.4
        await at(secondPin - 0.9)
        await pin(model: model, at: headlinePoint, log: "pin.headline")
        await at(spoken)
        let session = model.session
        model.finishScouting(input: InteractionTimings.now)
        note("session.finish")

        var review: SessionReview?
        for _ in 0..<300 {
            if let current = model.review, current.sessionID == session?.id, !current.tasks.isEmpty, !current.isPreparing {
                review = current
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let review else {
            problems.append("the review did not open with tasks")
            forcing.cancel()
            await partA.finish()
            finish(model: model, output: output, frames: frames, session: session)
            return
        }
        for card in review.tasks where !card.isLocked && card.destination != .clipboard {
            model.dispatcher.choose(.clipboard, for: card)
        }
        let window = reviewWindow()
        window?.orderFrontRegardless()
        note("review.shown", "\(review.tasks.count) tasks")
        await pointer.glide(to: CGPoint(x: buttonPoint.x, y: buttonPoint.y + 40), seconds: 0.6)
        try? await Task.sleep(for: .seconds(2.2))
        if review.tasks.count > 1 {
            review.select(review.tasks[1])
            note("review.select", "task 2")
            try? await Task.sleep(for: .seconds(2.2))
            review.select(review.tasks[0])
            note("review.select", "task 1")
            try? await Task.sleep(for: .seconds(0.8))
        }
        let copy = await findFrame(pid: ProcessInfo.processInfo.processIdentifier, text: "Copy all", roles: ["AXButton"], prefix: true) ?? fallbackCopyFrame(window)
        frames["copy"] = copy
        if let copy {
            await pointer.glide(to: CGPoint(x: copy.midX, y: copy.midY), seconds: 0.8)
            try? await Task.sleep(for: .milliseconds(350))
        } else {
            problems.append("could not find Copy all")
        }
        note("copy.click")
        await model.sendAll(in: review)
        note("copy.done", review.tasks.map { String(describing: $0.state) }.joined(separator: "; "))
        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        try? copied.write(to: output.appendingPathComponent("tasks.txt"), atomically: true, encoding: .utf8)
        await partA.finish()
        note("partA.stopped", partA.problem)
        forcing.cancel()

        let ready = output.appendingPathComponent("patch/ready")
        try? Data().write(to: output.appendingPathComponent("waiting-for-patch"))
        note("patch.waiting")
        let waited = Date()
        while !FileManager.default.fileExists(atPath: ready.path), Date().timeIntervalSince(waited) < plan.patchTimeout {
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard FileManager.default.fileExists(atPath: ready.path) else {
            problems.append("no patch arrived")
            finish(model: model, output: output, frames: frames, session: session, review: review)
            return
        }
        note("patch.ready")

        let partB = HeroRecording(url: output.appendingPathComponent("part-b.mov"), seconds: 14, log: output.appendingPathComponent("part-b.log"))
        note("partB.launched", partB.problem)
        try? await Task.sleep(for: .seconds(2.5))
        let pagePoint = CGPoint(x: headlinePoint.x + 120, y: headlinePoint.y + 230)
        await pointer.glide(to: pagePoint, seconds: 0.8)
        await raiseWindow(pid: pid)
        window?.orderBack(nil)
        note("safari.front")
        try? await Task.sleep(for: .seconds(1.6))
        let applied = apply(patch: output.appendingPathComponent("patch/files", isDirectory: true), to: plan.site)
        note("patch.applied", applied.joined(separator: ", "))
        await partB.finish()
        note("partB.stopped", partB.problem)
        finish(model: model, output: output, frames: frames, session: session, review: review)
    }

    private static func pin(model: AppModel, at point: CGPoint, log name: String) async {
        guard let aim = model.session?.aim else {
            problems.append("no aim for \(name)")
            return
        }
        aim.simulate(.modifiers(.maskAlternate))
        note(name + ".aim")
        try? await Task.sleep(for: .milliseconds(900))
        aim.simulate(.press(point, InteractionTimings.now))
        try? await Task.sleep(for: .milliseconds(80))
        aim.simulate(.release(point, InteractionTimings.now))
        note(name)
        try? await Task.sleep(for: .milliseconds(450))
        aim.simulate(.modifiers([]))
    }

    private static func reviewWindow() -> NSWindow? {
        NSApp.windows.first { $0.title == "Scout Review" && $0.isVisible }
    }

    private static func fallbackCopyFrame(_ window: NSWindow?) -> CGRect? {
        guard let window else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 1080
        let top = primaryHeight - window.frame.maxY
        return CGRect(x: window.frame.maxX - 16 - 150, y: top + 11, width: 150, height: 32)
    }

    private static func apply(patch: URL, to site: URL) -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: patch, includingPropertiesForKeys: nil)) ?? []
        var applied: [String] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where !file.lastPathComponent.hasPrefix(".") {
            guard let data = try? Data(contentsOf: file) else { continue }
            do {
                try data.write(to: site.appendingPathComponent(file.lastPathComponent), options: .atomic)
                applied.append(file.lastPathComponent)
            } catch {
                problems.append("could not write \(file.lastPathComponent): \(error)")
            }
        }
        return applied
    }

    @concurrent
    nonisolated private static func placeWindow(pid: pid_t, frame: CGRect) async -> Bool {
        guard let window = mainWindow(pid: pid) else { return false }
        var origin = frame.origin
        var size = frame.size
        guard let position = AXValueCreate(.cgPoint, &origin), let extent = AXValueCreate(.cgSize, &size) else { return false }
        let moved = AXUIElementSetAttributeValue(window.element, kAXPositionAttribute as CFString, position)
        let sized = AXUIElementSetAttributeValue(window.element, kAXSizeAttribute as CFString, extent)
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        return moved == .success && sized == .success
    }

    @concurrent
    nonisolated private static func dismissBanner(pid: pid_t) async -> String {
        guard let window = mainWindow(pid: pid) else { return "no window" }
        guard let text = window.firstDescendant(maxDepth: 30, maxVisited: 3000, where: { ($0.label ?? "").hasPrefix("Make Safari your default browser") }) else { return "no banner" }
        var container = text.parent
        for _ in 0..<4 {
            guard let current = container else { break }
            if let close = current.firstDescendant(maxDepth: 4, maxVisited: 200, where: { $0.role == "AXButton" && $0.label != "Make Safari Default" }) {
                let result = AXUIElementPerformAction(close.element, kAXPressAction as CFString)
                return "pressed \(close.label ?? "unlabeled button"): \(result.rawValue)"
            }
            container = current.parent
        }
        return "no close button"
    }

    @concurrent
    nonisolated private static func raiseWindow(pid: pid_t) async {
        guard let window = mainWindow(pid: pid) else { return }
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
    }

    nonisolated private static func mainWindow(pid: pid_t) -> AXElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 2)
        let root = AXElement(element: app)
        return root.child(kAXMainWindowAttribute) ?? root.child(kAXFocusedWindowAttribute) ?? root.children.first { $0.role == kAXWindowRole }
    }

    @concurrent
    nonisolated private static func findFrame(pid: pid_t, text: String, roles: Set<String>, prefix: Bool) async -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 2)
        let root = AXElement(element: app)
        let match = root.firstDescendant(maxDepth: 40, maxVisited: 6000) { element in
            guard let role = element.role, roles.contains(role), let label = element.label else { return false }
            return prefix ? label.hasPrefix(text) : label == text
        }
        return match?.frame
    }

    private static func finish(model: AppModel, output: URL, frames: [String: CGRect], session: ScoutingSession? = nil, review: SessionReview? = nil) {
        note("end")
        let report = Report(
            events: events,
            problems: problems,
            buttonFrame: frames["button"].map(NSStringFromRect),
            headlineFrame: frames["headline"].map(NSStringFromRect),
            copyFrame: frames["copy"].map(NSStringFromRect),
            taskTitles: review?.tasks.map(\.title) ?? [],
            taskStates: review?.tasks.map { String(describing: $0.state) } ?? [],
            pins: session?.ledger.marks ?? [],
            accessibilityTrusted: AXIsProcessTrusted(),
            screenRecordingGranted: CGPreflightScreenCaptureAccess(),
            screens: NSScreen.screens.map { NSStringFromRect($0.frame) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? encoder.encode(report).write(to: output.appendingPathComponent("hero-report.json"))
        NSApp.terminate(nil)
    }
}

@MainActor
private final class HeroPointer {
    private(set) var location: CGPoint

    init(start: CGPoint) {
        location = start
        CGWarpMouseCursorPosition(start)
    }

    func glide(to target: CGPoint, seconds: Double) async {
        let from = location
        let began = Date()
        while true {
            let t = min(1, Date().timeIntervalSince(began) / seconds)
            let eased = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
            location = CGPoint(x: from.x + (target.x - from.x) * eased, y: from.y + (target.y - from.y) * eased)
            CGWarpMouseCursorPosition(location)
            if t >= 1 { return }
            await CaptureUXDemo.pause(milliseconds: 8)
        }
    }
}

@MainActor
private final class HeroRecording {
    private let process = Process()
    private let seconds: Int
    private(set) var problem: String?

    init(url: URL, seconds: Int, log: URL) {
        self.seconds = seconds
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-v", "-C", "-x", "-V", String(seconds), url.path]
        process.standardInput = FileHandle.nullDevice
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try? FileHandle(forWritingTo: log)
        process.standardOutput = handle
        process.standardError = handle
        do {
            try process.run()
        } catch {
            problem = "screencapture did not start: \(error)"
        }
    }

    func finish() async {
        let deadline = Date().addingTimeInterval(Double(seconds) + 30)
        while process.isRunning, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning {
            problem = "still running after \(seconds + 30) s"
        } else if process.terminationStatus != 0 {
            problem = "screencapture exited with \(process.terminationStatus)"
        }
    }
}
