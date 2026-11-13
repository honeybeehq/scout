import AppKit
import FoundationModels
import ScoutCore

enum LinearDemo {
    private static func argument(_ name: String) -> String? {
        let prefix = "--\(name)="
        return ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    static var directory: URL? {
        argument("linear-demo").map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func run(model: AppModel, directory: URL) async {
        let output = URL(fileURLWithPath: argument("linear-demo-output") ?? directory.appendingPathComponent("demo").path, isDirectory: true)
        let label = argument("linear-demo-label") ?? "run"
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(1))
        let live = ProcessInfo.processInfo.arguments.contains("--linear-demo-key-stdin")
        model.linear.draftKey = live ? readLine(strippingNewline: true) ?? "" : "lin_api_SCOUTFIXTURENOTAREALKEY00003f9a"
        await model.linear.connect()
        var steps: [[String: Any]] = []
        let testTeamID = live ? ProcessInfo.processInfo.environment["SCOUT_LINEAR_TEST_TEAM"] ?? "" : ReviewGallery.testTeam.id
        guard let team = model.linear.teams.value?.first(where: { $0.id == testTeamID }) else {
            steps.append(["error": "the test team isn't in this workspace, or the key was refused"])
            finish(steps, output: output, label: label)
            return
        }
        model.linear.preferences.defaultTeam = team
        await model.linear.loadTeamDetails(team.id)
        let seeded = ReviewRecord.read(from: directory) == nil
        if seeded { seed(model: model, team: team, into: directory) }
        steps.append(["step": seeded ? "seeded review.json from the demo fixture" : "found review.json"])
        let summary = SessionSummary(id: "", directory: directory, startedAt: .now, duration: 0, taskCount: 0, unsentCount: 0, titles: [], hasVideo: false)
        model.openReview(summary)
        var waited = 0
        while waited < 40, model.review?.directory.standardizedFileURL != directory.standardizedFileURL {
            try? await Task.sleep(for: .milliseconds(250))
            waited += 1
        }
        guard let review = model.review else {
            steps.append(["error": "review did not open"])
            finish(steps, output: output, label: label)
            return
        }
        for card in review.tasks { await model.dispatcher.ensureBrief(for: card) }
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 1000 }) {
            window.setFrame(CGRect(x: 0, y: 0, width: 1260, height: 1180), display: true)
        }
        try? await Task.sleep(for: .seconds(2))
        steps.append(describe(review, model: model, step: "opened"))
        draw(review, model: model, name: "\(label)-1-opened", into: output)
        let send = argument("linear-demo-send") ?? "none"
        if send == "file-new", let card = review.tasks.first {
            await model.dispatcher.fileAsNewIssue(card)
            review.save()
        } else if send == "all" {
            await model.sendAll(in: review)
        } else if send == "first", let card = review.tasks.first {
            await model.dispatcher.send(card)
            review.save()
        }
        if send != "none" {
            try? await Task.sleep(for: .seconds(1))
            steps.append(describe(review, model: model, step: "after send=\(send)"))
            draw(review, model: model, name: "\(label)-2-after-send", into: output)
        }
        finish(steps, output: output, label: label)
    }

    private static func seed(model: AppModel, team: LinearTeam, into directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        let lines = ReviewGallery.demo.signals.compactMap { try? encoder.encode($0) }.compactMap { String(data: $0, encoding: .utf8) }
        try? (lines.joined(separator: "\n") + "\n").write(to: directory.appendingPathComponent("signals.jsonl"), atomically: true, encoding: .utf8)
        if let video = argument("linear-demo-video") {
            let target = directory.appendingPathComponent("session.mp4")
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.copyItem(at: URL(fileURLWithPath: video), to: target)
        }
        guard let review = ReviewGallery.demo.make(model.dispatcher, directory: directory) else { return }
        for card in review.tasks { card.destination = .linear(LinearTarget(team: team, project: nil, reason: .defaultTeam)) }
        review.tasks.first?.runtimeNotes = [
            "network: GET http://localhost:3000/api/cart?session=8812&token=tok_demo_should_not_leave failed with 500 (acme-web)",
            "TypeError: total is undefined — at Summary (\(NSHomeDirectory())/Code/acme-web/src/checkout/Summary.tsx:41) (acme-web)",
        ]
        review.save()
    }

    private static func describe(_ review: SessionReview, model: AppModel, step: String) -> [String: Any] {
        [
            "step": step,
            "summariser": OnDeviceSummariser.isAvailable ? "on-device (FoundationModels)" : "template (\(String(describing: SystemLanguageModel.default.availability)))",
            "tasks": review.tasks.map { card -> [String: Any] in
                [
                    "task": card.snippet.id,
                    "title": card.title,
                    "key": card.linearKey,
                    "destination": card.destination?.label ?? "none",
                    "state": String(describing: card.state),
                    "receipt": card.linearReceipt.map { String(describing: $0.status) } ?? "none",
                    "uploadedAssets": card.linearReceipt?.assets.map { "\($0.name) → \($0.url.absoluteString)" } ?? [],
                    "brief": card.brief.map { "\($0.source) kind=\($0.kind.rawValue) urgency=\($0.urgency.rawValue) summary=\($0.hasSummary)" } ?? "none",
                    "labels": card.destination?.linearTarget.map { model.dispatcher.labelIDs(for: card, team: $0.team.id) } ?? [],
                    "priority": model.dispatcher.priority(for: card),
                ]
            },
        ]
    }

    private static func draw(_ review: SessionReview, model: AppModel, name: String, into directory: URL) {
        guard let view = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 1000 })?.contentView?.superview,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
    }

    private static func finish(_ steps: [[String: Any]], output: URL, label: String) {
        if let data = try? JSONSerialization.data(withJSONObject: steps, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            try? data.write(to: output.appendingPathComponent("\(label).json"))
        }
        NSApp.terminate(nil)
    }
}
