import AppKit
import Foundation
import FoundationModels
import ScoutCore

enum SimulationMode {
    private static func argument(_ name: String) -> String? {
        let prefix = "--\(name)="
        return ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    static var audioFile: URL? {
        argument("simulate-session").map { URL(fileURLWithPath: $0) }
    }

    static var outputDirectory: URL {
        URL(fileURLWithPath: argument("simulate-output") ?? "/tmp/scout-simulation", isDirectory: true)
    }

    static var segmentation: Segmentation? {
        argument("segmentation").flatMap(Segmentation.init(rawValue:))
    }

    static var breakTimes: [Double] {
        argument("simulate-break")?.split(separator: ",").compactMap { Double($0) } ?? []
    }

    static var reviewsEdits: Bool {
        ProcessInfo.processInfo.arguments.contains("--simulate-review")
    }

    static var isRunning: Bool {
        audioFile != nil || reopensLatest || deliveryCheck != nil || walkthroughFixture != nil || CaptureUXDemo.outputDirectory != nil
    }

    static var panelSharing: NSWindow.SharingType {
        isRunning ? .readOnly : .none
    }

    static var deliveryCheck: URL? {
        argument("delivery-check").map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func runDeliveryCheck(model: AppModel, directory: URL) async {
        let output = outputDirectory
        let label = argument("delivery-label") ?? "delivery"
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(1))
        guard let record = ReviewRecord.read(from: directory) else {
            writeJSON(["error": "no review.json in \(directory.path)"], to: output.appendingPathComponent("\(label).json"))
            NSApp.terminate(nil)
            return
        }
        let summary = SessionSummary(id: record.sessionID, directory: directory, startedAt: record.startedAt, duration: record.duration, taskCount: record.tasks.count, unsentCount: 0, titles: [], hasVideo: false)
        model.openReview(summary)
        var waited = 0
        while waited < 40, model.review?.sessionID != record.sessionID {
            try? await Task.sleep(for: .milliseconds(250))
            waited += 1
        }
        try? await Task.sleep(for: .seconds(3))
        guard let review = model.review, let card = review.tasks.first else {
            writeJSON(["error": "review did not open"], to: output.appendingPathComponent("\(label).json"))
            NSApp.terminate(nil)
            return
        }
        var steps: [[String: Any]] = [describe(card, review: review, model: model, step: "opened")]
        if let path = argument("delivery-runtime"), let text = try? String(contentsOfFile: path, encoding: .utf8) {
            let decoder = JSONDecoder()
            let events = text.split(separator: "\n").compactMap { try? decoder.decode(BridgeSignalMessage.self, from: Data($0.utf8)) }
            card.runtimeNotes = events.map { Dispatcher.describe(ScoutingSession.RuntimeEvent(at: $0.at ?? card.snippet.range.start, source: "fixture-app", signal: $0)) }
            review.edited(card)
            steps.append(describe(card, review: review, model: model, step: "runtime notes added"))
        }
        if let beeID = argument("delivery-destination") {
            model.dispatcher.choose(.session(id: beeID, title: argument("delivery-destination-title") ?? beeID, agent: "claude"), for: card)
            steps.append(describe(card, review: review, model: model, step: "destination chosen"))
        }
        if ProcessInfo.processInfo.arguments.contains("--delivery-send") {
            NSPasteboard.general.clearContents()
            await model.dispatcher.send(card)
            var step = describe(card, review: review, model: model, step: "sent")
            step["pasteboard"] = NSPasteboard.general.string(forType: .string) ?? ""
            steps.append(step)
        }
        review.save()
        let readOnly = ProcessInfo.processInfo.arguments.contains("--delivery-readonly")
        if readOnly {
            try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
            review.save()
            steps.append(describe(card, review: review, model: model, step: "saved into a read-only folder"))
        }
        try? await Task.sleep(for: .seconds(1.5))
        drawWindow(named: label, into: output)
        if readOnly {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            review.save()
            steps.append(describe(card, review: review, model: model, step: "folder writable again, saved"))
        }
        let saved = (try? String(contentsOf: directory.appendingPathComponent(ReviewRecord.fileName), encoding: .utf8)) ?? ""
        writeJSON(["steps": steps, "reviewJSON": saved], to: output.appendingPathComponent("\(label).json"))
        NSApp.terminate(nil)
    }

    private static func describe(_ card: SnippetCard, review: SessionReview, model: AppModel, step: String) -> [String: Any] {
        let root = card.project?.rootPath
        let candidates = model.dispatcher.sessions.filter { session in
            guard let root, let cwd = session.cwd else { return false }
            return Dispatcher.path(cwd, isInside: root)
        }
        return [
            "step": step,
            "task": card.snippet.id,
            "location": card.snippet.primaryContext?.location ?? "",
            "project": card.project.map { "\($0.rootPath) (\($0.gitBranch ?? "no branch"))" } ?? "none",
            "sessionsInProject": candidates.map { session in
                "\(session.displayTitle) id=\(session.id) waitingForYou=\(session.isWaitingForYou) working=\(session.isWorking) lastOutputAt=\(session.lastOutputAt.map { ISO8601DateFormatter().string(from: $0) } ?? "none")"
            },
            "destination": card.destination?.label ?? "none",
            "destinationChosenByUser": card.destinationChosenByUser,
            "state": String(describing: card.state),
            "problem": card.state.problem ?? "",
            "runtimeNotes": card.runtimeNotes,
            "message": (try? model.dispatcher.compose(card).message) ?? "",
            "saveError": review.saveError ?? "",
        ]
    }

    private static func drawWindow(named name: String, into directory: URL) {
        guard let view = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 1000 })?.contentView?.superview,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
    }

    private static func writeJSON(_ object: [String: Any], to url: URL) {
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            try? data.write(to: url)
        }
    }

    static var walkthroughFixture: URL? {
        argument("simulate-walkthrough").map { URL(fileURLWithPath: $0) }
    }

    static var replaysEvents: Bool {
        walkthroughFixture != nil
    }

    static var fixtureVideo: URL? {
        walkthroughFixture.flatMap { try? WalkthroughFixture.load($0) }?.video
    }

    static func runWalkthrough(model: AppModel, fixtureURL: URL) async {
        let output = outputDirectory
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var report: [String: Any] = ["fixture": fixtureURL.path]
        defer {
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: output.appendingPathComponent("walkthrough-report.json"))
            }
            NSApp.terminate(nil)
        }
        let fixture: WalkthroughFixture
        do {
            fixture = try WalkthroughFixture.load(fixtureURL)
        } catch {
            report["error"] = "fixture: \(error)"
            return
        }
        try? await Task.sleep(for: .seconds(1))
        var finished = false
        model.startScouting(inputFile: fixture.audio, result: .walkthrough) { finished = true }
        guard let session = model.session else {
            report["error"] = "no session"
            return
        }
        let deadline = Date().addingTimeInterval(180)
        while session.transcriber.phase != .listening, Date() < deadline {
            if case .failed(let message) = session.transcriber.phase {
                report["transcriberFailed"] = message
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let offset = session.clock.now
        report["audioOffset"] = offset
        if let video = fixture.video {
            session.walkthrough?.attach(FixtureWalkthroughMedia(video: video, screen: fixture.screen, offset: offset))
        }
        for step in fixture.steps(shiftedBy: offset) {
            let wait = step.at - session.clock.now
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            switch step.action {
            case .signal(let signal): session.replay(signal)
            case .stroke(let stroke): session.walkthrough?.add(stroke)
            case .scope(let change): session.walkthrough?.add(change)
            }
        }
        while !finished, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .seconds(1.5))
        model.stopScouting()
        let stopped = Date()
        while model.lastWalkthrough == nil, model.walkthroughProblem == nil, Date().timeIntervalSince(stopped) < 30 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        report["problem"] = model.walkthroughProblem ?? ""
        guard let done = model.lastWalkthrough else { return }
        report["bundle"] = done.directory.path
        report["timings"] = done.timings
        report["status"] = done.walkthrough.status.rawValue
        report["counts"] = [
            "segments": done.walkthrough.transcript.segments.count,
            "frames": done.walkthrough.frames.count,
            "pointers": done.walkthrough.pointers.count,
            "drawings": done.walkthrough.drawings.count,
            "asks": done.walkthrough.asks.items.count,
        ]
        let item = NSPasteboard.general.pasteboardItems?.first
        report["pasteboard"] = Dictionary(uniqueKeysWithValues: (item?.types ?? []).map { ($0.rawValue, item?.string(forType: $0) ?? "") })
    }

    static var reopensLatest: Bool {
        ProcessInfo.processInfo.arguments.contains("--reopen-latest")
    }

    static func reopenLatest(model: AppModel) async {
        let output = outputDirectory
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(1.5))
        model.openLatestReview()
        try? await Task.sleep(for: .seconds(4))
        captureWindow(named: "reopened", into: output)
        let tasks = model.review?.tasks ?? []
        let report: [String: Any] = [
            "session": model.review?.sessionID ?? "none",
            "hasVideo": model.review?.video != nil,
            "leftover": model.review?.leftoverSpeech.map(\.text) ?? [],
            "tasks": tasks.map { "\($0.snippet.id) \(String(format: "%.1f-%.1f", $0.snippet.range.start, $0.snippet.range.end)) state=\($0.state) destination=\($0.destination?.label ?? "none") title=\($0.title) edited=\($0.transcriptOverride != nil)" },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appendingPathComponent("reopen.json"))
        }
        NSApp.terminate(nil)
    }

    static var isQuickStop: Bool {
        ProcessInfo.processInfo.arguments.contains("--simulate-quick-stop")
    }

    static func runQuickStop(model: AppModel, audio: URL) async {
        let output = outputDirectory
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(1))
        model.startScouting(inputFile: audio, result: .tasks)
        try? await Task.sleep(for: .milliseconds(250))
        model.stopScouting()
        try? await Task.sleep(for: .seconds(3))
        let framesEarly = model.session?.recorder?.statistics.framesCaptured ?? -1
        try? await Task.sleep(for: .seconds(3))
        let framesLate = model.session?.recorder?.statistics.framesCaptured ?? -1
        let report: [String: Any] = [
            "sessionPhase": String(describing: model.session?.phase),
            "transcriberPhase": String(describing: model.session?.transcriber.phase),
            "transcriberLevel": Double(model.session?.transcriber.level ?? -1),
            "framesAfter3s": framesEarly,
            "framesAfter6s": framesLate,
            "isScouting": model.isScouting,
            "aimActiveTap": model.session?.aim.isAiming ?? false,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appendingPathComponent("quick-stop.json"))
        }
        NSApp.terminate(nil)
    }

    static var isDryRun: Bool {
        ProcessInfo.processInfo.arguments.contains("--dry-run-delivery")
    }

    static func run(model: AppModel, audio: URL) async {
        let output = outputDirectory
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(1))

        var finished = false
        model.startScouting(inputFile: audio, segmentation: segmentation, result: .tasks) { finished = true }
        let started = Date()
        for time in breakTimes {
            Task {
                try? await Task.sleep(for: .seconds(time))
                postBreakShortcut()
            }
        }
        var snapped = false
        if ProcessInfo.processInfo.arguments.contains("--simulate-pin") {
            Task {
                try? await Task.sleep(for: .seconds(4))
                await postPin()
            }
        }
        while !finished, Date().timeIntervalSince(started) < 600 {
            try? await Task.sleep(for: .milliseconds(250))
            if !snapped, (model.session?.closedCount ?? 0) >= 1 {
                snapped = true
                try? await Task.sleep(for: .milliseconds(600))
                snapshotPanels(into: output, suffix: "live")
            }
        }
        try? await Task.sleep(for: .seconds(10))
        snapshotPanels(into: output, suffix: "before-stop")
        model.stopScouting()
        try? await Task.sleep(for: .seconds(4))
        var reviewReport: [String: Any] = [:]
        if reviewsEdits, let review = model.review {
            reviewReport = await exerciseReview(review, model: model, output: output)
        }
        for card in (model.review?.tasks ?? model.dispatcher.cards) where card.state == .needsDestination || card.state == .held {
            model.dispatcher.choose(.clipboard, for: card)
            await model.dispatcher.send(card)
        }
        try? await Task.sleep(for: .seconds(4))
        let tasksBeforeClear = model.review?.tasks.count ?? -1
        model.dispatcher.dismissDelivered()
        reviewReport["tasksBeforeClearSent"] = tasksBeforeClear
        reviewReport["tasksAfterClearSent"] = model.review?.tasks.count ?? -1
        model.review?.save()
        try? await Task.sleep(for: .seconds(1))
        snapshotPanels(into: output, suffix: "after-stop")
        writeReport(model: model, into: output, elapsed: Date().timeIntervalSince(started), extra: ["review": reviewReport])
        NSApp.terminate(nil)
    }

    private static func postPin() async {
        let source = CGEventSource(stateID: .hidSystemState)
        let location = CGEvent(source: nil)?.location ?? .zero
        let optionDown = CGEvent(keyboardEventSource: source, virtualKey: 58, keyDown: true)
        optionDown?.flags = .maskAlternate
        optionDown?.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(450))
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: location, mouseButton: .left).map { $0.flags = .maskAlternate; $0.post(tap: .cghidEventTap) }
        try? await Task.sleep(for: .milliseconds(60))
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: location, mouseButton: .left).map { $0.flags = .maskAlternate; $0.post(tap: .cghidEventTap) }
        try? await Task.sleep(for: .milliseconds(200))
        let optionUp = CGEvent(keyboardEventSource: source, virtualKey: 58, keyDown: false)
        optionUp?.flags = []
        optionUp?.post(tap: .cghidEventTap)
    }

    private static func snapshotPanels(into directory: URL, suffix: String) {
        for (index, panel) in NSApp.windows.enumerated() where panel is NSPanel && panel.isVisible {
            guard let image = SnapshotMode.windowImage(CGWindowID(panel.windowNumber)) else { continue }
            let name = panel.frame.height < 80 ? "pill" : "stack-\(index)"
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: directory.appendingPathComponent("\(name)-\(suffix).png"))
        }
    }

    private static func describeTasks(_ review: SessionReview) -> [String] {
        review.tasks.map { card in
            String(format: "%@ %.1f-%.1f %@ | %@", card.snippet.id, card.snippet.range.start, card.snippet.range.end, card.title, card.transcript)
        }
    }

    private static func exerciseReview(_ review: SessionReview, model: AppModel, output: URL) async -> [String: Any] {
        var steps: [[String: Any]] = []
        func step(_ name: String) {
            steps.append(["step": name, "tasks": describeTasks(review), "leftover": review.leftoverSpeech.map(\.text), "canUndo": review.canUndo])
        }
        try? await Task.sleep(for: .seconds(2))
        captureWindow(named: "review-initial", into: output)
        step("initial")
        if let first = review.tasks.first {
            let range = first.snippet.range
            review.split(first, at: range.start + range.duration * 0.55)
            step("split first task")
            review.join(first)
            step("join it back")
            review.beginBoundaryDrag()
            review.moveBoundary(of: first, edge: .end, to: range.end - 2, snap: true)
            step("trim first task end by 2 s (snapped)")
            review.undo()
            step("undo trim")
        }
        if let last = review.tasks.last {
            review.delete(last)
            step("delete last task")
            if let leftover = review.leftoverSpeech.first {
                review.makeTask(from: leftover)
                step("make task from leftover speech")
            }
            if let leftover = review.leftoverSpeech.first, let neighbor = review.neighbor(for: leftover) {
                review.attach(leftover, to: neighbor)
                step("attach next leftover to its neighbor")
            }
            if let card = review.tasks.first {
                review.beginTextEdit()
                card.transcriptOverride = card.transcript + " Also make it bigger on tablets."
                review.edited(card)
                step("edit first transcript")
            }
        }
        if let first = review.tasks.first { review.select(first) }
        try? await Task.sleep(for: .seconds(1.5))
        captureWindow(named: "review-edited", into: output)
        review.save()
        return ["steps": steps, "reviewFile": review.directory.appendingPathComponent(ReviewRecord.fileName).path]
    }

    private static func captureWindow(named name: String, into directory: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 1000 }),
              let image = SnapshotMode.windowImage(CGWindowID(window.windowNumber))
        else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
            .write(to: directory.appendingPathComponent("\(name).png"))
    }

    private static func postBreakShortcut() {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 11, keyDown: true)
        down?.flags = [.maskControl, .maskAlternate]
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 11, keyDown: false)
        up?.flags = [.maskControl, .maskAlternate]
        up?.post(tap: .cghidEventTap)
    }

    private static func writeReport(model: AppModel, into directory: URL, elapsed: TimeInterval, extra: [String: Any] = [:]) {
        let cards: [[String: Any]] = (model.review?.tasks ?? model.dispatcher.cards).map { card in
            [
                "id": card.snippet.id,
                "range": [card.snippet.range.start, card.snippet.range.end],
                "title": card.title,
                "transcript": card.snippet.transcript,
                "state": String(describing: card.state),
                "destination": card.destination?.label ?? "none",
                "context": card.snippet.primaryContext.map { "\($0.app.name) \($0.location ?? $0.windowTitle ?? "")" } ?? "none",
                "targets": card.snippet.targets.map(\.displayName),
                "marks": card.snippet.marks.map { "\($0.id) at \($0.at) \($0.target?.displayName ?? "no target")" },
                "breakpoint": card.snippet.closedBy.map { ["score": $0.score, "hard": $0.isHard, "reasons": $0.reasons.map { "\($0.kind.rawValue) \($0.weight)" }] } ?? [:],
            ]
        }
        var report: [String: Any] = [
            "elapsed": elapsed,
            "session": model.session?.directory.path ?? "",
            "transcript": model.session?.transcriber.finalizedText ?? "",
            "onDeviceTitles": String(describing: SystemLanguageModel.default.availability),
            "aimAvailable": model.session?.aim.isAvailable ?? false,
            "bridgePort": model.bridge.port.map(Int.init) ?? 0,
            "bridgeFailure": model.bridge.failure ?? "",
            "captureProblem": model.session?.captureProblem ?? "",
            "attachments": (model.review?.tasks ?? model.dispatcher.cards).flatMap { $0.attachments.map(\.line) },
            "cards": cards,
        ]
        report.merge(extra) { $1 }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("report.json"))
        }
    }
}

struct WalkthroughFixture: Decodable {
    struct StrokeInput: Decodable {
        var start: Double
        var end: Double
        var points: [[Double]]
        var color: String?
        var width: Double?
    }

    struct ScopeInput: Decodable {
        var at: Double
        var scope: String
        var bounds: Rect
        var byUser: Bool?
    }

    enum Action {
        case signal(Signal)
        case stroke(WalkthroughBuilder.Stroke)
        case scope(WalkthroughBuilder.ScopeChange)
    }

    struct Step {
        var at: Double
        var action: Action
    }

    var audioPath: String
    var videoPath: String?
    var screen: Rect
    var signals: [Signal]
    var strokes: [StrokeInput]?
    var scopes: [ScopeInput]?
    var base: URL = URL(fileURLWithPath: "/")

    private enum CodingKeys: String, CodingKey {
        case audioPath = "audio"
        case videoPath = "video"
        case screen, signals, strokes, scopes
    }

    var audio: URL { URL(fileURLWithPath: audioPath, relativeTo: base).standardizedFileURL }
    var video: URL? { videoPath.map { URL(fileURLWithPath: $0, relativeTo: base).standardizedFileURL } }

    static func load(_ url: URL) throws -> WalkthroughFixture {
        var fixture = try JSONDecoder().decode(WalkthroughFixture.self, from: Data(contentsOf: url))
        fixture.base = url.deletingLastPathComponent()
        return fixture
    }

    func steps(shiftedBy offset: Double) -> [Step] {
        var steps = signals.map { Step(at: $0.time + offset, action: .signal($0.shifted(by: offset))) }
        steps += (strokes ?? []).map { input in
            let samples = input.points.compactMap { point -> WalkthroughBuilder.StrokeSample? in
                guard point.count >= 3 else { return nil }
                return WalkthroughBuilder.StrokeSample(point: Point(x: point[0], y: point[1]), at: point[2] + offset)
            }
            let stroke = WalkthroughBuilder.Stroke(range: TimeRange(start: input.start + offset, end: input.end + offset), samples: samples, color: input.color, width: input.width)
            return Step(at: input.end + offset, action: .stroke(stroke))
        }
        steps += (scopes ?? []).compactMap { input in
            guard let scope = Walkthrough.Scope(rawValue: input.scope) else { return nil }
            return Step(at: input.at + offset, action: .scope(WalkthroughBuilder.ScopeChange(at: input.at + offset, scope: scope, bounds: input.bounds, byUser: input.byUser ?? false)))
        }
        return steps.sorted { $0.at < $1.at }
    }
}

private extension Signal {
    func shifted(by offset: Double) -> Signal {
        func range(_ value: TimeRange) -> TimeRange { TimeRange(start: value.start + offset, end: value.end + offset) }
        switch self {
        case .utterance(var value):
            value.range = range(value.range)
            value.words = value.words.map { var word = $0; word.range = range(word.range); return word }
            return .utterance(value)
        case .context(var value):
            value.at += offset
            return .context(value)
        case .focus(var value):
            value.range = range(value.range)
            return .focus(value)
        case .mark(var value):
            value.at += offset
            return .mark(value)
        case .visualChange(var value):
            value.at += offset
            return .visualChange(value)
        case .command(var value):
            value.at += offset
            return .command(value)
        case .clock(let time):
            return .clock(time + offset)
        }
    }
}
