import AppKit
import AVFoundation
import Carbon.HIToolbox
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

    static var uiSizeChange: (size: UISize, at: Double)? {
        guard let parts = argument("simulate-ui-size")?.split(separator: "@"), parts.count == 2,
              let size = UISize(rawValue: String(parts[0])), let time = Double(parts[1])
        else { return nil }
        return (size, time)
    }

    static var discardAt: Double? {
        argument("simulate-discard").flatMap(Double.init)
    }

    static var discardsByHotkey: Bool {
        ProcessInfo.processInfo.arguments.contains("--simulate-discard-hotkey")
    }

    static var sendsBeforeDiscard: Bool {
        ProcessInfo.processInfo.arguments.contains("--simulate-discard-after-send")
    }

    static var result: SessionResult {
        argument("simulate-result") == "walkthrough" ? .walkthrough : .tasks
    }

    static var analyzerFaultAfter: Double? {
        argument("simulate-analyzer-fault").flatMap(Double.init)
    }

    static var microphoneScenario: SimulatedRoute.Scenario? {
        argument("simulate-mic").flatMap(SimulatedRoute.Scenario.init(rawValue:))
    }

    static var secondPassFails: Bool {
        ProcessInfo.processInfo.arguments.contains("--simulate-second-pass-failure")
    }

    static var whisperFails: Bool {
        ProcessInfo.processInfo.arguments.contains("--simulate-whisper-failure")
    }

    static var whisperDrill: [String]? {
        argument("whisper-drill")?.split(separator: ",").map(String.init)
    }

    static func runWhisperDrill(store: WhisperModelStore, steps: [String]) async {
        func wait(upTo seconds: Double = 600, until condition: () -> Bool) async {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition(), Date() < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        func downloaded(atLeast fraction: Double) -> Bool {
            if case .downloading(let progress) = store.state { return progress >= fraction }
            return false
        }
        for step in steps {
            let parts = step.split(separator: "@")
            let value = parts.count > 1 ? Double(parts[1]) ?? 0 : 0
            switch parts.first.map(String.init) {
            case "cancel":
                await wait { downloaded(atLeast: value) }
                NSLog("[scout-whisper] drill: cancel at %@", store.state.summary)
                store.cancel()
                await wait(upTo: 60) { !store.state.isBusy }
            case "verify-cancel":
                await wait { if case .verifying = store.state { return true } else { return false } }
                NSLog("[scout-whisper] drill: cancel at %@", store.state.summary)
                store.cancel()
                await wait(upTo: 60) { !store.state.isBusy }
            case "resume":
                try? await Task.sleep(for: .seconds(value))
                NSLog("[scout-whisper] drill: resume from %@", store.state.summary)
                store.download()
            case "remove":
                await wait { downloaded(atLeast: value) }
                NSLog("[scout-whisper] drill: remove at %@", store.state.summary)
                store.remove()
                await wait(upTo: 120) { store.state == .notInstalled && !FileManager.default.fileExists(atPath: store.folder.path) && !FileManager.default.fileExists(atPath: store.partialFolder.path) }
            case "wait-ready":
                await wait { store.state == .ready }
            default:
                NSLog("[scout-whisper] drill: unknown step %@", step)
            }
            store.refresh()
            NSLog("[scout-whisper] drill %@ done: state %@, partial %lld bytes (%@), installed %lld bytes (%@)", step, store.state.summary, store.partialBytes, FileManager.default.fileExists(atPath: store.partialFolder.path) ? "exists" : "absent", store.installedBytes, FileManager.default.fileExists(atPath: store.folder.path) ? "exists" : "absent")
        }
        try? await Task.sleep(for: .seconds(2))
        NSApp.terminate(nil)
    }

    static var whisperWaitsReady: Bool {
        ProcessInfo.processInfo.arguments.contains("--whisper-wait-ready")
    }

    static var whisperDownloads: Bool {
        ProcessInfo.processInfo.arguments.contains("--whisper-download")
    }

    static var whisperModelFolder: URL? {
        argument("whisper-model").map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static var whisperTokenizerFolder: URL? {
        argument("whisper-tokenizer").map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func secondPassReport(of session: ScoutingSession?) -> [String: Any] {
        let audio = session?.transcriber.recordedAudio
        var report: [String: Any] = ["audioSeconds": audio?.seconds ?? 0, "audioFile": audio?.url.lastPathComponent ?? ""]
        switch session?.transcriptPass {
        case .refined(let final):
            report["outcome"] = "refined"
            report["engine"] = final.engine
            report["locale"] = final.locale ?? ""
            report["elapsed"] = final.elapsedSeconds
            report["utterances"] = final.utterances.count
            report["words"] = final.utterances.reduce(0) { $0 + $1.words.count }
            report["wordsWithinAudio"] = final.utterances.flatMap(\.words).allSatisfy { $0.range.start >= 0 && $0.range.end <= (audio?.seconds ?? 0) + 0.05 }
        case .keptLive(let reason):
            report["outcome"] = "keptLive"
            report["reason"] = reason
        case nil:
            report["outcome"] = "none"
        }
        report["enginesTried"] = session?.secondPassFailures ?? []
        report["ledgerUtterances"] = session?.ledger.utterances.map(\.id) ?? []
        return report
    }

    static var reviewsEdits: Bool {
        ProcessInfo.processInfo.arguments.contains("--simulate-review")
    }

    static var isRunning: Bool {
        audioFile != nil || reopensLatest || deliveryCheck != nil || walkthroughFixture != nil || CaptureUXDemo.outputDirectory != nil || ExpandKeyCheck.outputDirectory != nil || HeroDemo.outputDirectory != nil
    }

    static var panelSharing: NSWindow.SharingType {
        isRunning ? .readOnly : .none
    }

    static var deliveryCheck: URL? {
        argument("delivery-check").map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static var openSettingsOutput: URL? {
        argument("simulate-open-settings").map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private static var windowStates = 0

    static func listenForOpenSettings(output: URL) {
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        DistributedNotificationCenter.default().addObserver(forName: .init("com.trmdy.scout.simulate-open-settings"), object: nil, queue: .main) { note in
            let command = note.object as? String ?? "state-settings"
            Task { await recordWindow(command, output: output) }
        }
    }

    private static func recordWindow(_ command: String, output: URL) async {
        let kind = command.replacingOccurrences(of: "minimize-", with: "").replacingOccurrences(of: "state-", with: "")
        let match = kind == "settings" ? "Settings" : kind == "review" ? ScoutApp.reviewWindowID : ScoutApp.onboardingWindowID
        let window = NSApp.windows.first { $0.identifier?.rawValue.contains(match) == true }
        if command.hasPrefix("minimize-") {
            window?.miniaturize(nil)
            return
        }
        windowStates += 1
        writeJSON([
            "step": windowStates,
            "window": kind,
            "appActive": NSApp.isActive,
            "activationPolicy": NSApp.activationPolicy().rawValue,
            "keyWindow": NSApp.keyWindow?.title ?? "",
            "windowVisible": window?.isVisible ?? false,
            "windowKey": window?.isKeyWindow ?? false,
            "windowMiniaturized": window?.isMiniaturized ?? false,
            "windowLevel": window?.level.rawValue ?? -1,
            "windowNumber": window?.windowNumber ?? 0,
        ], to: output.appendingPathComponent("open-\(windowStates).json"))
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
        if awaitsRecordURL {
            model.simulatedInput = fixture.audio
            model.onSessionCreated = { session in session.transcriber.onInputFinished = { finished = true } }
            try? "waiting".write(to: output.appendingPathComponent("awaiting-url"), atomically: true, encoding: .utf8)
            if let url = recordURL, let request = RecordRequest.parse(url) { model.record(request) }
            await waitFor(300) { model.session != nil }
            report["recordURL"] = model.boundTarget.map { "\($0.kind):\($0.id)" } ?? ""
        } else {
            model.startScouting(inputFile: fixture.audio, result: .walkthrough) { finished = true }
        }
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
        var hops: CaptureDisplays?
        if let video = fixture.video {
            let size = (try? await AVURLAsset(url: video).loadTracks(withMediaType: .video).first?.load(.naturalSize)) ?? .zero
            hops = fixture.captureDisplays(videoSize: size, shiftedBy: offset)
            session.walkthrough?.attach(FixtureWalkthroughMedia(video: video, screen: fixture.screen, offset: offset, hops: hops))
        }
        for step in fixture.steps(shiftedBy: offset) {
            let wait = step.at - session.clock.now
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            switch step.action {
            case .signal(let signal): session.replay(signal)
            case .stroke(let stroke): session.walkthrough?.add(stroke)
            case .scope(let change): session.walkthrough?.add(change)
            case .dwell(let point): session.pointing?.dwell(at: point, time: step.at)
            }
        }
        var pillText = ""
        while !finished, Date() < deadline {
            if pillText.isEmpty, case .failed(let message) = session.transcriber.phase {
                pillText = message
                ViewShot.write(ScoutingPill().environment(model), to: output.appendingPathComponent("pill.png"), padding: 12)
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .seconds(1.5))
        if pillText.isEmpty, microphoneScenario != nil {
            ViewShot.write(ScoutingPill().environment(model), to: output.appendingPathComponent("pill.png"), padding: 12)
        }
        let bound = model.boundTarget != nil
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
        report["transcription"] = transcriptionReport(session.transcriber.run)
        report["transcript"] = [
            "status": done.walkthrough.transcript.status.rawValue,
            "engine": done.walkthrough.transcript.engine ?? "",
            "language": done.walkthrough.transcript.language ?? "",
            "failure": done.walkthrough.transcript.failure.map { ["reason": $0.reason.rawValue, "message": $0.message ?? "", "t": $0.t ?? -1] } ?? [:],
            "soundSeconds": session.transcriber.sound.seconds,
            "events": (try? JSONEncoder().encode(session.transcriber.events)).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? [],
        ]
        if let microphone = done.walkthrough.capture.microphone, let data = try? JSONEncoder().encode(microphone) {
            report["microphone"] = try? JSONSerialization.jsonObject(with: data)
        }
        report["transcriptText"] = (try? String(contentsOf: done.directory.appendingPathComponent(WalkthroughBundle.textName), encoding: .utf8)) ?? ""
        report["pillDuringRecording"] = pillText
        report["secondPass"] = secondPassReport(of: session)
        report["transcriptEngine"] = done.walkthrough.transcript.engine ?? ""
        report["displays"] = done.walkthrough.capture.displays?.map { ["id": $0.id, "bounds": [$0.bounds.x, $0.bounds.y, $0.bounds.w, $0.bounds.h]] } ?? []
        report["counts"] = [
            "segments": done.walkthrough.transcript.segments.count,
            "frames": done.walkthrough.frames.count,
            "pointers": done.walkthrough.pointers.count,
            "drawings": done.walkthrough.drawings.count,
            "asks": done.walkthrough.asks.items.count,
        ]
        let item = NSPasteboard.general.pasteboardItems?.first
        report["pasteboard"] = Dictionary(uniqueKeysWithValues: (item?.types ?? []).map { ($0.rawValue, item?.string(forType: $0) ?? "") })
        report["pointing"] = ["calls": session.pointing?.calls ?? 0, "skipped": session.pointing?.skipped ?? 0]
        report["apiaryPointers"] = done.walkthrough.pointers.filter { $0.source == .apiary }.map { "\($0.id) \($0.via.rawValue) \($0.label ?? "")" }
        report["uuidv5Check"] = ScoutUUID.v5("scout:probe:send1")
        if let hops, let video = fixture.video {
            let size = (try? await AVURLAsset(url: video).loadTracks(withMediaType: .video).first?.load(.naturalSize)) ?? .zero
            report["pinShots"] = await pinShots(fixture: fixture, video: video, displays: fixture.captureDisplays(videoSize: size) ?? hops, output: output)
        }
        report["picker"] = bound ? await boundReport(model: model, output: output) : await drivePicker(model: model, output: output)
        report["bridgeLog"] = await model.apiary.log
    }

    private static func pinShots(fixture: WalkthroughFixture, video: URL, displays: CaptureDisplays, output: URL) async -> [String: Any] {
        let ledger = SessionLedger(replaying: fixture.signals)
        let duration = (try? await AVURLAsset(url: video).load(.duration).seconds) ?? ledger.end
        let directory = output.appendingPathComponent("pin-shots", isDirectory: true)
        let record = ReviewRecord(sessionID: "s7-hop", startedAt: Date(), segmentation: "manual", duration: duration, video: nil, display: displays.start, displayHops: displays.hops, discarded: nil, tasks: [])
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? ReviewRecord.write(record, to: directory)
        let restored = ReviewRecord.read(from: directory)?.displays
        let snippet = ledger.snippet(id: "t1", range: TimeRange(start: 0, end: duration))
        let attachments = await SnippetMedia.attachments(for: snippet, video: ExportedClip(url: video, range: TimeRange(start: 0, end: duration)), displays: restored, into: directory)
        let marks: [[String: Any]] = snippet.marks.map { mark in
            let display = restored?.display(at: mark.at)
            let video = display?.videoPoint(forScreenPoint: CGPoint(x: mark.point.x, y: mark.point.y))
            return [
                "mark": mark.id,
                "at": mark.at,
                "point": [mark.point.x, mark.point.y],
                "display": display.map { Int($0.displayID) } ?? -1,
                "displayBounds": display.map { [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height] } ?? [],
                "videoPoint": video.map { [$0.x, $0.y] } ?? [],
                "contentRect": display.map { [$0.contentRect.minX, $0.contentRect.minY, $0.contentRect.width, $0.contentRect.height] } ?? [],
            ]
        }
        return ["reviewRecordHops": restored?.hops.count ?? -1, "marks": marks, "files": attachments.map(\.url.path)]
    }

    private static func pickerSnapshot(_ model: AppModel, _ name: String, into output: URL) {
        try? model.picker.snapshot()?.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("picker-\(name).png"))
        if name == "1-open" {
            ViewShot.write(MenuBarPanel().environment(model), to: output.appendingPathComponent("menu-bar.png"))
        }
    }

    private static func debugDataReport(model: AppModel, output: URL) async -> [String: Any] {
        await model.debugFinish?.value
        var report: [String: Any] = ["keepsDebugData": model.preferences.keepsDebugData]
        guard let directory = model.lastDebugDirectory else { return report }
        report["directory"] = directory.path
        let manager = FileManager.default
        report["files"] = ((try? manager.contentsOfDirectory(atPath: directory.path)) ?? []).sorted().map { name -> [String: Any] in
            let url = directory.appendingPathComponent(name)
            let attributes = (try? manager.attributesOfItem(atPath: url.path)) ?? [:]
            return ["name": name, "bytes": (attributes[.size] as? Int) ?? 0, "links": (attributes[.referenceCount] as? Int) ?? 0, "inode": (attributes[.systemFileNumber] as? Int) ?? 0]
        }
        let audio = model.session?.directory.appendingPathComponent(SessionAudioWriter.fileName)
        report["sessionAudioInode"] = audio.flatMap { (try? manager.attributesOfItem(atPath: $0.path))?[.systemFileNumber] as? Int } ?? 0
        ViewShot.write(MenuBarPanel().environment(model), to: output.appendingPathComponent("menu-bar-debug.png"))
        let folder = directory.deletingLastPathComponent()
        report["retention"] = [6.0, 8.0, 15.0].map { days -> [String: Any] in
            var wouldTrash: [String] = []
            DebugRun.prune(sessionFolder: folder, now: Date().addingTimeInterval(days * 86_400)) { url, _ in wouldTrash.append(url.lastPathComponent) }
            return ["days": days, "wouldTrash": wouldTrash]
        }
        report["releasePruning"] = ScoutPaths.allowsPruning
        if ProcessInfo.processInfo.arguments.contains("--simulate-reveal-debug") {
            report["revealed"] = model.revealDebugData()?.path ?? ""
        }
        return report
    }

    private static func waitFor(_ seconds: Double, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private static func drivePicker(model: AppModel, output: URL) async -> [String: Any] {
        var result: [String: Any] = [:]
        let picker = model.picker
        func state() -> [String: Any] {
            [
                "source": String(describing: picker.model.source),
                "phase": String(describing: picker.model.phase),
                "query": picker.model.query,
                "rows": picker.model.filtered.prefix(8).map { "\($0.kind):\($0.title)\($0.focused ? " (focused)" : "")" },
                "selected": picker.model.selected.map { "\($0.kind):\($0.id):\($0.title)" } ?? "",
            ]
        }
        await waitFor(3) { picker.model.source != .loading }
        result["opened"] = state()
        pickerSnapshot(model, "1-open", into: output)
        guard let key = argument("pick-key") else {
            result["timings"] = model.pickerTimings
            return result
        }
        for character in argument("pick") ?? "" {
            picker.post(.character(character))
            try? await Task.sleep(for: .milliseconds(40))
        }
        for _ in 0..<(Int(argument("pick-down") ?? "0") ?? 0) {
            picker.post(.down)
            try? await Task.sleep(for: .milliseconds(40))
        }
        try? await Task.sleep(for: .milliseconds(150))
        result["filtered"] = state()
        pickerSnapshot(model, "2-filtered", into: output)
        switch key {
        case "send": picker.post(.commandEnter)
        case "escape": picker.post(.escape)
        default: picker.post(.enter)
        }
        await waitFor(10) { picker.model.confirmation != nil || picker.model.problem != nil }
        result["confirmation"] = picker.model.confirmation ?? ""
        result["problem"] = picker.model.problem ?? ""
        pickerSnapshot(model, "3-confirmed", into: output)
        result["delivery"] = deliveryReport(model.lastDelivery)
        result["timings"] = model.pickerTimings
        if ProcessInfo.processInfo.arguments.contains("--pick-repeat") {
            await waitFor(3) { !picker.isOpen }
            if let gate = argument("repeat-gate") {
                let first = try? JSONSerialization.data(withJSONObject: deliveryReport(model.lastDelivery))
                try? first?.write(to: output.appendingPathComponent("first-delivery.json"))
                await waitFor(180) { FileManager.default.fileExists(atPath: gate) }
            }
            let first = model.lastDelivery?.deliveryID
            model.sendLastWalkthrough()
            await waitFor(3) { picker.model.source != .loading }
            for character in argument("pick") ?? "" {
                picker.post(.character(character))
                try? await Task.sleep(for: .milliseconds(40))
            }
            try? await Task.sleep(for: .milliseconds(150))
            picker.post(key == "send" ? .commandEnter : .enter)
            await waitFor(10) { (picker.model.confirmation != nil && model.lastDelivery?.deliveryID == first) || picker.model.problem != nil }
            try? await Task.sleep(for: .milliseconds(100))
            result["repeat"] = ["delivery": deliveryReport(model.lastDelivery), "confirmation": picker.model.confirmation ?? "", "problem": picker.model.problem ?? "", "timings": model.pickerTimings]
            pickerSnapshot(model, "4-repeat", into: output)
        }
        try? await Task.sleep(for: .milliseconds(1800))
        return result
    }

    static var recordURL: URL? {
        argument("record-url").flatMap(URL.init(string:))
    }

    static var awaitsRecordURL: Bool {
        ProcessInfo.processInfo.arguments.contains("--await-record-url")
    }

    private static func boundReport(model: AppModel, output: URL) async -> [String: Any] {
        await waitFor(15) { model.lastDeliveryLine != nil }
        try? await Task.sleep(for: .milliseconds(300))
        pickerSnapshot(model, "bound", into: output)
        let result: [String: Any] = [
            "line": model.lastDeliveryLine ?? "",
            "delivery": deliveryReport(model.lastDelivery),
            "timings": model.pickerTimings,
            "pasteboardTypes": NSPasteboard.general.pasteboardItems?.first?.types.map(\.rawValue) ?? [],
        ]
        try? await Task.sleep(for: .milliseconds(1800))
        return result
    }

    private static func deliveryReport(_ outcome: DeliveryOutcome?) -> [String: Any] {
        guard let outcome else { return [:] }
        return [
            "route": outcome.route.rawValue,
            "mode": outcome.mode.rawValue,
            "title": outcome.title,
            "deliveryId": outcome.deliveryID,
            "messageId": outcome.messageID,
            "deduped": outcome.deduped,
            "fallbackReason": outcome.fallbackReason ?? "",
            "roundTripMs": outcome.roundTripMs,
        ]
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
        var report: [String: Any] = [
            "session": model.review?.sessionID ?? "none",
            "hasVideo": model.review?.video != nil,
            "leftover": model.review?.leftoverSpeech.map(\.text) ?? [],
            "transcripts": tasks.map(\.transcript),
            "utterances": model.review?.ledger.utterances.map { ["id": $0.id, "start": $0.range.start, "end": $0.range.end, "words": $0.words.count] } ?? [],
            "tasks": tasks.map { "\($0.snippet.id) \(String(format: "%.1f-%.1f", $0.snippet.range.start, $0.snippet.range.end)) state=\($0.state) destination=\($0.destination?.label ?? "none") title=\($0.title) edited=\($0.transcriptOverride != nil)" },
        ]
        if discardAt != nil, let review = model.review {
            report["discard"] = await discard(review, model: model, output: output)
        }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
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

    static var asksDryRun: Bool {
        ProcessInfo.processInfo.arguments.contains("--dry-run-delivery")
    }

    static var asksLiveDelivery: Bool {
        ProcessInfo.processInfo.arguments.contains("--live-delivery")
    }

    static var isDryRun: Bool {
        asksDryRun || !(ScoutDataRoot.current.isRelease || asksLiveDelivery)
    }

    static var writesPasteboard: Bool {
        ScoutDataRoot.current.isRelease || asksLiveDelivery
    }

    static var deliveryReason: String {
        if asksDryRun { return "--dry-run-delivery" }
        if ScoutDataRoot.current.isRelease { return "release" }
        return asksLiveDelivery ? "non-release, --live-delivery" : "non-release"
    }

    static func run(model: AppModel, audio: URL) async {
        let output = outputDirectory
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(1))

        if whisperWaitsReady {
            let waiting = Date()
            while model.whisperModels.state != .ready, Date().timeIntervalSince(waiting) < 600 {
                try? await Task.sleep(for: .milliseconds(250))
            }
            NSLog("[scout-whisper] simulation waited %.1f s for the model: %@", Date().timeIntervalSince(waiting), model.whisperModels.state.summary)
        }
        var finished = false
        let pasteboardBefore = (NSPasteboard.general.changeCount, NSPasteboard.general.string(forType: .string))
        model.startScouting(inputFile: audio, segmentation: segmentation, result: result) { finished = true }
        let started = Date()
        for time in breakTimes {
            Task {
                try? await Task.sleep(for: .seconds(time))
                let pillBefore = describe(model.hud.pillWindow?.frame)
                let pressesBefore = GlobalHotkey.lastPressTime
                postBreakShortcut()
                try? await Task.sleep(for: .milliseconds(400))
                let name = String(format: "break-%.1fs", time)
                snapshotPanels(into: output, suffix: name)
                breakLog.append([
                    "at": time,
                    "caughtByHotkey": GlobalHotkey.lastPressTime != pressesBefore,
                    "barConfirming": model.session?.confirmingBreak ?? false,
                    "pillBefore": pillBefore,
                    "pillAfter": describe(model.hud.pillWindow?.frame),
                    "snapshot": "pill-\(name).png",
                ])
            }
        }
        var uiSizeReport: [String: Any] = [:]
        var snapped = false
        var stallShot = false
        var pillText = ""
        if ProcessInfo.processInfo.arguments.contains("--simulate-pin") {
            Task {
                try? await Task.sleep(for: .seconds(4))
                await postPin()
            }
        }
        while !finished || discardAt != nil, Date().timeIntervalSince(started) < 600 {
            try? await Task.sleep(for: .milliseconds(250))
            if let change = uiSizeChange, uiSizeReport.isEmpty, Date().timeIntervalSince(started) >= change.at {
                uiSizeReport = await changeUISize(to: change.size, model: model, output: output)
            }
            if let at = discardAt, Date().timeIntervalSince(started) >= at {
                await discard(model: model, output: output, pasteboardBefore: pasteboardBefore)
                return
            }
            if !stallShot, model.session?.transcriber.stalledSince != nil {
                stallShot = true
                ViewShot.write(ScoutingPill().environment(model), to: output.appendingPathComponent("pill-stalled.png"), padding: 12)
            }
            if let transcriber = model.session?.transcriber {
                let live = [transcriber.finalizedText, transcriber.volatileText].filter { !$0.isEmpty }.joined(separator: " ")
                if !live.isEmpty { pillText = live }
                if pillText.isEmpty, case .failed(let message) = transcriber.phase { pillText = message }
            }
            if !snapped, (model.session?.closedCount ?? 0) >= 1 {
                snapped = true
                try? await Task.sleep(for: .milliseconds(600))
                snapshotPanels(into: output, suffix: "live")
                await DesignGallery.captureLive(model: model)
            }
        }
        try? await Task.sleep(for: .seconds(10))
        snapshotPanels(into: output, suffix: "before-stop")
        model.stopScouting()
        let stopped = Date()
        while let session = model.session, session.phase != .ended, Date().timeIntervalSince(stopped) < 300 {
            try? await Task.sleep(for: .milliseconds(250))
        }
        try? await Task.sleep(for: .seconds(4))
        if result == .walkthrough {
            await waitFor(30) { model.lastWalkthrough != nil || model.walkthroughProblem != nil }
            try? await Task.sleep(for: .milliseconds(300))
            pickerSnapshot(model, "debug", into: output)
        }
        if DesignGallery.directory != nil {
            await DesignGallery.captureReview(model: model)
        }
        var reviewReport: [String: Any] = [:]
        if reviewsEdits, let review = model.review {
            reviewReport = await exerciseReview(review, model: model, output: output)
        }
        let waiting = (model.review?.tasks ?? model.dispatcher.cards).filter { $0.state == .needsDestination || $0.state == .held }
        for card in waiting where card.destination == nil {
            model.dispatcher.choose(.clipboard, for: card)
        }
        if let review = model.review {
            captureWindow(named: "review-before-send", into: output)
            await model.sendAll(in: review)
            try? await Task.sleep(for: .seconds(1))
            captureWindow(named: "review-after-send", into: output)
        } else {
            await model.dispatcher.sendAll(waiting)
        }
        reviewReport["clipboard"] = NSPasteboard.general.string(forType: .string) ?? ""
        reviewReport["clipboardFolders"] = (NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL])?.map(\.path) ?? []
        try? await Task.sleep(for: .seconds(4))
        if DesignGallery.directory != nil {
            await DesignGallery.captureDelivered(model: model)
        }
        let tasksBeforeClear = model.review?.tasks.count ?? -1
        model.dispatcher.dismissDelivered()
        reviewReport["tasksBeforeClearSent"] = tasksBeforeClear
        reviewReport["tasksAfterClearSent"] = model.review?.tasks.count ?? -1
        model.review?.save()
        try? await Task.sleep(for: .seconds(1))
        snapshotPanels(into: output, suffix: "after-stop")
        let debugReport = await debugDataReport(model: model, output: output)
        writeReport(model: model, into: output, elapsed: Date().timeIntervalSince(started), extra: ["review": reviewReport, "uiSizeChange": uiSizeReport, "debugData": debugReport, "pillDuringRecording": pillText])
        if DesignGallery.directory != nil {
            await DesignGallery.captureFinished(model: model)
        }
        NSApp.terminate(nil)
    }

    private static func discard(model: AppModel, output: URL, pasteboardBefore: (Int, String?)) async {
        guard let session = model.session else { return }
        let walkthroughID = session.walkthrough?.bundle.id
        let cardsBefore = model.dispatcher.cards.filter { $0.sessionID == session.id }.map { "\($0.snippet.id) \(String(describing: $0.state))" }
        let filesBefore = sessionFiles(session.directory, walkthroughID: walkthroughID)
        snapshotPanels(into: output, suffix: "discard-1-button")
        ViewShot.write(ScoutingPill().environment(model), to: output.appendingPathComponent("pill-discard-1-button-rendered.png"), padding: 12)
        var sentFirst = false
        if sendsBeforeDiscard, let card = session.cards.first {
            model.dispatcher.choose(.clipboard, for: card)
            await model.dispatcher.send(card)
            sentFirst = true
            try? await Task.sleep(for: .milliseconds(700))
            snapshotPanels(into: output, suffix: "discard-1-sent")
        }
        var keys: [[String: Any]] = []
        func press(_ shortcut: KeyShortcut, _ hotkey: GlobalHotkey?) async {
            let path = await pressKey(shortcut, hotkey: hotkey)
            try? await Task.sleep(for: .milliseconds(700))
            keys.append(["key": shortcut.label, "path": path, "confirming": model.confirmingDiscard, "recording": model.isScouting, "escapeRegistered": model.discardHotkeys?.cancel.isRegistered ?? false])
        }
        let pressed = Date()
        if discardsByHotkey {
            await press(model.discardShortcut, model.discardHotkeys?.discard)
            snapshotPanels(into: output, suffix: "discard-2-confirm")
            ViewShot.write(ScoutingPill().environment(model), to: output.appendingPathComponent("pill-discard-2-confirm-rendered.png"), padding: 12)
            if model.confirmingDiscard {
                await press(.escape, model.discardHotkeys?.cancel)
                snapshotPanels(into: output, suffix: "discard-3-kept")
                await press(model.discardShortcut, model.discardHotkeys?.discard)
                await press(model.discardShortcut, model.discardHotkeys?.discard)
            }
            await waitFor(15) { !model.isScouting && session.phase == .ended }
        } else {
            model.confirmingDiscard = true
            try? await Task.sleep(for: .milliseconds(700))
            snapshotPanels(into: output, suffix: "discard-2-confirm")
            ViewShot.write(ScoutingPill().environment(model), to: output.appendingPathComponent("pill-discard-2-confirm-rendered.png"), padding: 12)
            await model.discardScouting()
        }
        let discardSeconds = Date().timeIntervalSince(pressed)
        try? await Task.sleep(for: .seconds(8))
        let cards = session.cards + model.dispatcher.cards.filter { card in card.sessionID == session.id && !session.cards.contains { $0 === card } }
        let delivered = cards.filter { card in
            switch card.state {
            case .sent, .sending, .copiedInstead: true
            default: false
            }
        }
        let report: [String: Any] = [
            "session": session.directory.path,
            "walkthroughID": walkthroughID ?? "",
            "discardSeconds": discardSeconds,
            "filesBeforeDiscard": filesBefore,
            "filesAfterDiscard": sessionFiles(session.directory, walkthroughID: walkthroughID),
            "cardsBeforeDiscard": cardsBefore,
            "cardStatesAfter": cards.map { "\($0.snippet.id) \(String(describing: $0.state))" },
            "delivered": delivered.count,
            "stackCards": model.dispatcher.cards.filter { $0.sessionID == session.id }.count,
            "reviewOpened": model.review?.sessionID == session.id,
            "pickerOpen": model.picker.isOpen,
            "lastWalkthrough": model.lastWalkthrough?.directory.path ?? "",
            "isScouting": model.isScouting,
            "visiblePanels": NSApp.windows.filter { $0 is NSPanel && $0.isVisible }.count,
            "pasteboardChangeCountBefore": pasteboardBefore.0,
            "pasteboardChangeCountAfter": NSPasteboard.general.changeCount,
            "pasteboardUnchanged": pasteboardBefore.0 == NSPasteboard.general.changeCount && pasteboardBefore.1 == NSPasteboard.general.string(forType: .string),
            "uiSize": model.preferences.uiSize.rawValue,
            "keys": keys,
            "sentBeforeDiscard": sentFirst,
            "discardHotkeyRegisteredAfter": model.discardHotkeys?.discard.isRegistered ?? false,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            try? data.write(to: output.appendingPathComponent("discard.json"))
        }
        NSApp.terminate(nil)
    }

    private static func discard(_ review: SessionReview, model: AppModel, output: URL) async -> [String: Any] {
        let pasteboard = (NSPasteboard.general.changeCount, NSPasteboard.general.string(forType: .string))
        let filesBefore = sessionFiles(review.directory, walkthroughID: nil)
        let canDiscard = review.canDiscard
        review.confirmingDiscard = canDiscard
        try? await Task.sleep(for: .milliseconds(700))
        captureWindow(named: "review-discard-confirm", into: output)
        model.discard(review)
        try? await Task.sleep(for: .seconds(3))
        captureWindow(named: "review-discarded", into: output)
        return [
            "canDiscard": canDiscard,
            "taskStates": review.tasks.map { "\($0.snippet.id) \(String(describing: $0.state))" },
            "filesBeforeDiscard": filesBefore,
            "filesAfterDiscard": sessionFiles(review.directory, walkthroughID: nil),
            "reviewStillOpen": model.review === review,
            "listedInSessions": SessionLibrary.recent().contains { $0.id == review.sessionID },
            "pasteboardUnchanged": pasteboard.0 == NSPasteboard.general.changeCount && pasteboard.1 == NSPasteboard.general.string(forType: .string),
        ]
    }

    private static func pressKey(_ shortcut: KeyShortcut, hotkey: GlobalHotkey?) async -> String {
        let before = GlobalHotkey.lastPressTime
        if CGPreflightPostEventAccess() {
            var flags: CGEventFlags = []
            if shortcut.carbonModifiers & UInt32(controlKey) != 0 { flags.insert(.maskControl) }
            if shortcut.carbonModifiers & UInt32(optionKey) != 0 { flags.insert(.maskAlternate) }
            CaptureUXDemo.postKey(UInt16(shortcut.keyCode), flags: flags)
            for _ in 0..<30 where GlobalHotkey.lastPressTime == before {
                try? await Task.sleep(for: .milliseconds(10))
            }
            if GlobalHotkey.lastPressTime != before { return "posted \(shortcut.label) key event, handled by the Carbon hotkey" }
        }
        guard let hotkey, hotkey.isRegistered else { return "\(shortcut.label) not registered" }
        let status = hotkey.sendPressedEvent()
        return "\(shortcut.label) sent as a Carbon hot-key event to the registered hotkey (status \(status)); posting key events needs Accessibility"
    }

    private static func sessionFiles(_ directory: URL, walkthroughID: String?) -> [String] {
        let manager = FileManager.default
        var roots = [directory]
        if let walkthroughID {
            let bundle = WalkthroughBundle(id: walkthroughID)
            roots += [bundle.partialDirectory, bundle.directory]
        }
        return roots.flatMap { root -> [String] in
            guard manager.fileExists(atPath: root.path) else { return [] }
            let children = manager.enumerator(atPath: root.path)?.compactMap { $0 as? String } ?? []
            return [root.path] + children.map { root.appendingPathComponent($0).path }
        }
    }

    private static func changeUISize(to size: UISize, model: AppModel, output: URL) async -> [String: Any] {
        model.openSettingsWindow?()
        try? await Task.sleep(for: .seconds(1.5))
        let before = panelFrames()
        snapshotPanels(into: output, suffix: "size-before")
        captureSettingsWindow(named: "settings-size-before", into: output)
        let from = model.preferences.uiSize
        model.preferences.uiSize = size
        try? await Task.sleep(for: .seconds(1.5))
        snapshotPanels(into: output, suffix: "size-after")
        captureSettingsWindow(named: "settings-size-after", into: output)
        return ["from": from.rawValue, "to": size.rawValue, "scale": size.scale, "before": before, "after": panelFrames()]
    }

    private static func panelFrames() -> [String: Any] {
        var frames: [String: Any] = [:]
        for panel in NSApp.windows where panel is NSPanel && panel.isVisible {
            frames[panel.frame.height < 80 ? "pill" : panel.frame == panel.screen?.frame ? "overlay" : "stack"] = ["x": panel.frame.minX, "y": panel.frame.minY, "width": panel.frame.width, "height": panel.frame.height]
        }
        return frames
    }

    private static func captureSettingsWindow(named name: String, into directory: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue.contains("Settings") == true }),
              let image = SnapshotMode.windowImage(CGWindowID(window.windowNumber))
        else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
            .write(to: directory.appendingPathComponent("\(name).png"))
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
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue.hasPrefix(ScoutApp.reviewWindowID) == true }),
              let image = SnapshotMode.windowImage(CGWindowID(window.windowNumber))
        else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
            .write(to: directory.appendingPathComponent("\(name).png"))
    }

    private static var breakLog: [[String: Any]] = []

    private static func describe(_ rect: CGRect?) -> String {
        guard let rect else { return "none" }
        return String(format: "x %.1f y %.1f w %.1f h %.1f", rect.minX, rect.minY, rect.width, rect.height)
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

    private static func transcriptionReport(_ run: TranscriptionRun?) -> Any {
        guard let run, let data = try? JSONEncoder().encode(run), let object = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        return object
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
            "transcript": model.session?.ledger.utterances.map(\.text).joined(separator: " ") ?? "",
            "liveTranscript": model.session?.transcriber.finalizedText ?? "",
            "transcription": transcriptionReport(model.session?.transcriber.run),
            "onDeviceTitles": String(describing: SystemLanguageModel.default.availability),
            "aimAvailable": model.session?.aim.isAvailable ?? false,
            "bridgePort": model.bridge.port.map(Int.init) ?? 0,
            "bridgeFailure": model.bridge.failure ?? "",
            "captureProblem": model.session?.captureProblem ?? "",
            "attachments": (model.review?.tasks ?? model.dispatcher.cards).flatMap { $0.attachments.map(\.line) },
            "cards": cards,
        ]
        report["breaks"] = breakLog
        report["walkthrough"] = model.lastWalkthrough?.directory.path ?? ""
        report["secondPass"] = secondPassReport(of: model.session)
        if let session = model.session {
            let transcriber = session.transcriber
            report["soundSeconds"] = transcriber.sound.seconds
            report["transcriberFailure"] = transcriber.failure.map { ["message": $0.message, "t": $0.at.map(Walkthrough.milliseconds) ?? -1, "microphone": $0.microphone ?? ""] } ?? [:]
            if let microphone = transcriber.microphoneSummary, let data = try? JSONEncoder().encode(MicrophoneCapture.walkthroughMicrophone(microphone)) {
                report["microphone"] = try? JSONSerialization.jsonObject(with: data)
            }
            report["counts"] = [
                "cards": cards.count,
                "utterances": session.ledger.utterances.count,
                "words": session.ledger.utterances.reduce(0) { $0 + $1.words.count },
                "discarded": session.discardedRanges.count,
            ]
        }
        if let events = model.session?.transcriber.events, let data = try? JSONEncoder().encode(events) {
            report["transcriptEvents"] = try? JSONSerialization.jsonObject(with: data)
        }
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

    struct PointerInput: Decodable {
        var at: Double
        var x: Double
        var y: Double
    }

    struct DisplayInput: Decodable {
        var id: UInt32
        var bounds: Rect
    }

    struct HopInput: Decodable {
        var at: Double
        var display: UInt32
    }

    enum Action {
        case dwell(Point)
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
    var pointers: [PointerInput]?
    var displays: [DisplayInput]?
    var hops: [HopInput]?
    var base: URL = URL(fileURLWithPath: "/")

    private enum CodingKeys: String, CodingKey {
        case audioPath = "audio"
        case videoPath = "video"
        case screen, signals, strokes, scopes, pointers, displays, hops
    }

    var audio: URL { URL(fileURLWithPath: audioPath, relativeTo: base).standardizedFileURL }
    var video: URL? { videoPath.map { URL(fileURLWithPath: $0, relativeTo: base).standardizedFileURL } }

    func captureDisplays(videoSize: CGSize, shiftedBy offset: Double = 0) -> CaptureDisplays? {
        guard let displays, let first = displays.first else { return nil }
        func display(_ input: DisplayInput) -> CaptureDisplay {
            CaptureDisplay(
                displayID: input.id,
                frame: CGRect(x: input.bounds.x, y: input.bounds.y, width: input.bounds.width, height: input.bounds.height),
                pointPixelScale: 1,
                videoWidth: Int(videoSize.width),
                videoHeight: Int(videoSize.height)
            )
        }
        let hops = (hops ?? []).compactMap { hop in
            displays.first { $0.id == hop.display }.map { CaptureDisplays.Hop(at: hop.at + offset, display: display($0)) }
        }
        return CaptureDisplays(start: display(first), hops: hops)
    }

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
        steps += (pointers ?? []).map { Step(at: $0.at + offset, action: .dwell(Point(x: $0.x, y: $0.y))) }
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

nonisolated struct FailingTranscriptionEngine: TranscriptionEngine {
    struct Failure: LocalizedError {
        var errorDescription: String? { "simulated second-pass failure" }
    }

    var name = "simulated-failure"

    func transcribe(_ request: TranscriptionRequest) async throws -> EngineTranscript {
        throw Failure()
    }
}
