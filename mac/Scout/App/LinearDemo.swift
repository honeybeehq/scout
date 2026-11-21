import AppKit
import AVFoundation
import FoundationModels
import ScoutCore
import SwiftUI

enum LinearDemo {
    private static func argument(_ name: String) -> String? {
        let prefix = "--\(name)="
        return ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    private static func flag(_ name: String) -> Bool {
        ProcessInfo.processInfo.arguments.contains("--\(name)")
    }

    static var directory: URL? {
        argument("linear-demo").map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func run(model: AppModel, directory: URL) async {
        let output = URL(fileURLWithPath: argument("linear-demo-output") ?? directory.appendingPathComponent("demo").path, isDirectory: true)
        let label = argument("linear-demo-label") ?? "run"
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        if let sources = argument("linear-demo-measure") {
            await measure(sources.split(separator: ",").map { URL(fileURLWithPath: String($0)) }, output: output, label: label)
            return
        }
        if let made = argument("linear-demo-make-video") {
            let began = Date()
            let seconds = argument("linear-demo-make-seconds").flatMap(Double.init) ?? 34
            do {
                try await DemoScreenVideo.make(to: URL(fileURLWithPath: made), seconds: seconds, busy: flag("linear-demo-make-busy"))
                finish([["step": "made \(made) in \(Int(Date().timeIntervalSince(began))) s"]], output: output, label: label)
            } catch {
                finish([["error": "making the demo video failed: \(error.localizedDescription)"]], output: output, label: label)
            }
            return
        }
        try? await Task.sleep(for: .seconds(1))
        let live = ProcessInfo.processInfo.arguments.contains("--linear-demo-key-stdin")
        if live, Bundle.main.bundleIdentifier == "com.trmdy.scout" {
            finish([["error": "live demo runs need a dev build (PRODUCT_BUNDLE_IDENTIFIER=com.trmdy.scout.dev.linear), not com.trmdy.scout"]], output: output, label: label)
            return
        }
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
        if let structure = argument("linear-demo-structure").flatMap(LinearStructure.init(rawValue:)) {
            review.linearStructureChoice = structure
            review.save()
        }
        if review.linearStructure == .parent { await review.loadSessionLine() }
        if let prefix = argument("linear-demo-title-prefix"), !review.parentTitle.hasPrefix(prefix) {
            review.linearParentTitle = prefix + review.parentTitle
            review.save()
        }
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 1000 }) {
            window.setFrame(CGRect(x: 0, y: 0, width: 1260, height: 1180), display: true)
        }
        try? await Task.sleep(for: .seconds(2))
        steps.append(describe(review, model: model, step: "opened"))
        draw(review, model: model, name: "\(label)-1-opened", into: output)
        if flag("linear-demo-popover") {
            review.editingParentTitle = true
            try? await Task.sleep(for: .seconds(2))
            drawPopover(name: "\(label)-1-popover", into: output)
            review.editingParentTitle = false
            try? await Task.sleep(for: .milliseconds(500))
        }
        let focus = argument("linear-demo-task").flatMap(Int.init).flatMap { review.tasks.indices.contains($0) ? review.tasks[$0] : nil } ?? review.tasks.first
        if let focus, focus !== review.tasks.first {
            review.select(focus)
            try? await Task.sleep(for: .seconds(1))
        }
        if let card = focus {
            await prepareVideo(card, review: review, model: model, label: label, output: output, steps: &steps)
        }
        if let card = focus, flag("linear-demo-duplicates") || argument("linear-demo-add-to") != nil {
            if let problem = await duplicates(card, review: review, model: model, label: label, output: output, steps: &steps) {
                steps.append(["error": problem])
                finish(steps, output: output, label: label)
                return
            }
        }
        let send = argument("linear-demo-send") ?? "none"
        if send != "none", model.dispatcher.dryRun, !SimulationMode.asksDryRun {
            steps.append(["error": "this build delivers as a dry run; pass --live-delivery (or --dry-run-delivery to ask for one)"])
            finish(steps, output: output, label: label)
            return
        }
        if let delay = argument("linear-demo-midshot").flatMap(Double.init) {
            Task {
                try? await Task.sleep(for: .seconds(delay))
                draw(review, model: model, name: "\(label)-mid-send", into: output)
            }
        }
        if send == "without-video", let card = review.tasks.first {
            await model.dispatcher.fileWithoutVideo(card)
            review.save()
        } else if send == "file-new", let card = review.tasks.first {
            await model.dispatcher.fileAsNewIssue(card)
            review.save()
        } else if send == "all" {
            await model.sendAll(in: review)
        } else if send == "all-twice" {
            async let first: Void = model.sendAll(in: review)
            async let second: Void = model.sendAll(in: review)
            _ = await (first, second)
        } else if send == "first-then-new", let card = focus {
            await model.dispatcher.send(card)
            try? await Task.sleep(for: .seconds(1))
            steps.append(describe(review, model: model, step: "after the first send"))
            draw(review, model: model, name: "\(label)-2-target-gone", into: output)
            if card.addToFailed {
                await model.dispatcher.fileAsNewIssue(card)
                await review.finishSending()
            }
        } else if send == "first", let card = focus {
            await model.dispatcher.send(card)
            await review.finishSending()
        }
        if send != "none" {
            try? await Task.sleep(for: .seconds(1))
            steps.append(describe(review, model: model, step: "after send=\(send)"))
            draw(review, model: model, name: "\(label)-2-after-send", into: output)
            if flag("linear-demo-menubar") { drawMenuBar(review, name: "\(label)-3-menubar", into: output) }
        }
        finish(steps, output: output, label: label)
    }

    private static func prepareVideo(_ card: SnippetCard, review: SessionReview, model: AppModel, label: String, output: URL, steps: inout [[String: Any]]) async {
        if flag("linear-demo-include-video") {
            card.linearOptions.includeVideo = true
            review.edited(card)
        }
        if flag("linear-demo-redact") {
            card.linearOptions.redaction = DemoScreenVideo.redaction
            review.edited(card)
        }
        guard flag("linear-demo-include-video") || flag("linear-demo-redact") else { return }
        let media = await model.dispatcher.preparedVideo(for: card)
        try? await Task.sleep(for: .seconds(1.5))
        draw(review, model: model, name: "\(label)-2-video", into: output)
        var step: [String: Any] = ["step": "video prepared", "includeVideo": model.dispatcher.includesVideo(card)]
        if let media {
            step["upload"] = await describeMedia(media.url)
            step["uploadFile"] = media.url.lastPathComponent
            step["redacted"] = media.isRedacted
            let original = card.sessionDirectory.appendingPathComponent("snippets/\(card.snippet.id)/clip.mp4")
            step["originalClip"] = await describeMedia(original)
            if media.isRedacted {
                try? FileManager.default.removeItem(at: output.appendingPathComponent("\(label)-redacted-clip.mp4"))
                try? FileManager.default.copyItem(at: media.url, to: output.appendingPathComponent("\(label)-redacted-clip.mp4"))
                await exportFrames(original: original, media: media, label: label, output: output)
            }
        }
        steps.append(step)
        if let target = card.destination?.linearTarget {
            let preview = IssuePreview(draft: model.dispatcher.previewIssue(for: card), target: target, outgoing: LinearSection.outgoing(card, dispatcher: model.dispatcher)) {}
            let renderer = ImageRenderer(content: preview.environment(model).environment(\.stillRender, true))
            renderer.scale = 2
            if let image = renderer.cgImage { write(image, to: output.appendingPathComponent("\(label)-issue-preview.png")) }
        }
        if let sheet = argument("linear-demo-sheet") {
            card.redactionSheet = .edit
            try? await Task.sleep(for: .seconds(5))
            drawSheet(name: "\(label)-3-sheet-edit", into: output)
            if sheet == "preview" {
                card.redactionSheet = .preview
                try? await Task.sleep(for: .seconds(4))
                drawSheet(name: "\(label)-4-sheet-preview", into: output)
                await recordSheet(seconds: 12, to: output.appendingPathComponent("\(label)-sheet-preview.mp4"))
            }
            card.redactionSheet = nil
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private static func duplicates(_ card: SnippetCard, review: SessionReview, model: AppModel, label: String, output: URL, steps: inout [[String: Any]]) async -> String? {
        guard let target = card.destination?.linearTarget else { return "the task has no Linear destination" }
        let wanted = argument("linear-demo-add-to")
        var waited = 0.0
        while true {
            card.duplicates = .idle
            await model.dispatcher.checkDuplicates(for: card, in: target, excluding: review.ownLinearIssueIDs, debounce: false)
            let ids = card.duplicates.candidates.map(\.id)
            if wanted == nil || wanted == "first" ? !ids.isEmpty : ids.contains(wanted ?? "") { break }
            if waited >= 45 { break }
            try? await Task.sleep(for: .seconds(5))
            waited += 5
        }
        let candidates = card.duplicates.candidates
        steps.append([
            "step": "duplicate check",
            "term": Dispatcher.duplicateTerm(for: card),
            "titleTerm": Dispatcher.duplicateTitle(for: card),
            "result": String(describing: card.duplicates).prefix(60).description,
            "waitedSeconds": waited,
            "candidates": candidates.map { candidate -> [String: Any] in ["marker": candidate.marker ?? "", "identifier": candidate.identifier, "id": candidate.id, "renderedTitle": RemoteText.clean(candidate.title), "renderedLength": RemoteText.clean(candidate.title).count, "state": candidate.state ?? ""] },
        ])
        try? await Task.sleep(for: .seconds(1.5))
        draw(review, model: model, name: "\(label)-1-candidate", into: output)
        renderRow(card, review: review, target: target, name: "\(label)-1-candidate-row", into: output)
        guard let wanted else { return nil }
        var picked = wanted == "first" ? candidates.first : candidates.first(where: { $0.id == wanted })
        if picked == nil, let identifier = argument("linear-demo-add-to-identifier"), let url = argument("linear-demo-add-to-url").flatMap(RemoteURL.issue) {
            picked = LinearCandidate(id: wanted, identifier: identifier, title: "(chosen by the live check: search had not returned it)", url: url, state: nil)
            steps.append(["step": "search did not return \(identifier); the live check chose it by id"])
        }
        guard let chosen = picked else {
            return "the duplicate check did not return the wanted issue \(wanted) (got \(candidates.map(\.identifier)))"
        }
        card.linearOptions.addTo = chosen
        card.linearOptions.fileNew = nil
        review.edited(card)
        try? await Task.sleep(for: .seconds(1.5))
        draw(review, model: model, name: "\(label)-1-add-to", into: output)
        renderRow(card, review: review, target: target, name: "\(label)-1-add-to-row", into: output)
        steps.append(["step": "chose Add to it", "addTo": chosen.identifier])
        return nil
    }

    private static func renderRow(_ card: SnippetCard, review: SessionReview, target: LinearTarget, name: String, into directory: URL) {
        let row = DuplicateRow(review: review, card: card, target: target)
            .frame(width: 300)
            .padding(16)
            .background(Palette.surface)
        let renderer = ImageRenderer(content: row.environment(\.stillRender, true))
        renderer.scale = 2
        if let image = renderer.cgImage { write(image, to: directory.appendingPathComponent("\(name).png")) }
    }

    private static func drawMenuBar(_ review: SessionReview, name: String, into directory: URL) {
        let state = MenuBarPanelState(recent: review.tasks.suffix(5).reversed().map(MenuBarPanelState.RecentTask.init), version: "T6 demo")
        let panel = MenuBarPanelContent(state: state, segmentation: .constant(review.segmentation), actions: MenuBarPanelActions())
        let renderer = ImageRenderer(content: panel.environment(\.stillRender, true))
        renderer.scale = 2
        if let image = renderer.cgImage { write(image, to: directory.appendingPathComponent("\(name).png")) }
    }

    private static func measure(_ sources: [URL], output: URL, label: String) async {
        var rows: [[String: Any]] = []
        for source in sources {
            let length = (try? await AVURLAsset(url: source).load(.duration).seconds) ?? 0
            let video = ExportedClip(url: source, range: TimeRange(start: 0, end: length))
            for seconds in [10.0, 30.0, 60.0] where seconds + 1 <= length {
                let snippet = Snippet(id: "measure-\(Int(seconds))", range: TimeRange(start: 1, end: seconds - 1))
                let directory = output.appendingPathComponent("measure/\(source.deletingPathExtension().lastPathComponent)-\(Int(seconds))s", isDirectory: true)
                try? FileManager.default.removeItem(at: directory)
                guard let clip = await SnippetMedia.clip(for: snippet, video: video, into: directory) else { continue }
                var row: [String: Any] = ["source": source.lastPathComponent, "clipSeconds": seconds, "passthrough": await describeMedia(clip.url)]
                let began = Date()
                if let hidden = try? await ClipRedactor.render(clip, redaction: ClipRedaction(regions: [RedactedRegion(rect: DemoScreenVideo.secretPanel)])) {
                    var info = await describeMedia(hidden.url)
                    info["renderSeconds"] = (Date().timeIntervalSince(began) * 10).rounded() / 10
                    row["redactedOneArea"] = info
                }
                rows.append(row)
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            try? data.write(to: output.appendingPathComponent("\(label).json"))
        }
        NSApp.terminate(nil)
    }

    private static func describeMedia(_ url: URL) async -> [String: Any] {
        let asset = AVURLAsset(url: url)
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? 0
        var info: [String: Any] = ["bytes": bytes]
        if let duration = try? await asset.load(.duration) { info["seconds"] = (duration.seconds * 100).rounded() / 100 }
        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            if let size = try? await track.load(.naturalSize) { info["size"] = "\(Int(size.width))x\(Int(size.height))" }
            if let formats = try? await track.load(.formatDescriptions), let format = formats.first {
                let code = CMFormatDescriptionGetMediaSubType(format)
                info["codec"] = String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .ascii) ?? "?"
            }
            if let rate = try? await track.load(.estimatedDataRate) { info["kbps"] = Int(rate / 1000) }
        }
        return info
    }

    private static func exportFrames(original: URL, media: RenderedMedia, label: String, output: URL) async {
        let clipStart = media.range.start
        let kept = media.redaction?.kept(in: media.range) ?? [media.range]
        func compositionTime(_ session: Double) -> Double? {
            var offset = 0.0
            for range in kept {
                if range.contains(session) { return offset + session - range.start }
                offset += range.duration
            }
            return nil
        }
        let moments: [(String, Double)] = [("toast-and-secret", 3.1), ("password-popup", 6.8), ("secret-only", 9.0)]
        for (name, session) in moments {
            if let before = await image(original, at: session - clipStart) { write(before, to: output.appendingPathComponent("\(label)-frame-\(name)-before.png")) }
            let after = compositionTime(session) ?? compositionTime(DemoScreenVideo.popupRange.end + 0.05) ?? 0
            if let image = await image(media.url, at: after) { write(image, to: output.appendingPathComponent("\(label)-frame-\(name)-after.png")) }
        }
    }

    private static func image(_ url: URL, at seconds: Double) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
        return try? await generator.image(at: CMTime(seconds: max(0, seconds), preferredTimescale: 600)).image
    }

    private static func write(_ image: CGImage, to url: URL) {
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }

    private static var sheetView: NSView? {
        NSApp.windows.first { $0.isVisible && $0.sheetParent != nil }?.contentView?.superview
    }

    private static func drawPopover(name: String, into directory: URL) {
        guard let popover = NSApp.windows.first(where: { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }),
              let content = popover.contentView,
              let main = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 1000 }),
              let frame = main.contentView?.superview,
              let base = frame.bitmapImageRepForCachingDisplay(in: frame.bounds),
              let card = content.bitmapImageRepForCachingDisplay(in: content.bounds)
        else { return }
        frame.cacheDisplay(in: frame.bounds, to: base)
        content.cacheDisplay(in: content.bounds, to: card)
        try? card.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
        let origin = content.convert(content.bounds, to: nil).origin
        let screen = popover.convertToScreen(CGRect(origin: origin, size: content.bounds.size))
        let local = main.convertFromScreen(screen)
        let image = NSImage(size: frame.bounds.size)
        image.lockFocus()
        base.draw(in: frame.bounds)
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 18
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.set()
        NSBezierPath(roundedRect: local, xRadius: 10, yRadius: 10).addClip()
        card.draw(in: local)
        image.unlockFocus()
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name)-in-window.png"))
        }
    }

    private static func drawSheet(name: String, into directory: URL) {
        guard let view = sheetView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
    }

    private static func recordSheet(seconds: Double, to url: URL) async {
        guard let view = sheetView, let first = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        let width = first.pixelsWide / 2 * 2
        let height = first.pixelsHigh / 2 * 2
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let rate = 10
        for index in 0..<Int(seconds * Double(rate)) {
            let began = ContinuousClock.now
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { break }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let image = bitmap.cgImage, let pool = adaptor.pixelBufferPool {
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                if let buffer {
                    CVPixelBufferLockBaseAddress(buffer, [])
                    if let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                    }
                    CVPixelBufferUnlockBaseAddress(buffer, [])
                    while !input.isReadyForMoreMediaData { try? await Task.sleep(for: .milliseconds(5)) }
                    adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(rate)))
                }
            }
            let spent = (ContinuousClock.now - began) / .seconds(1)
            try? await Task.sleep(for: .seconds(max(0.01, 1.0 / Double(rate) - spent)))
        }
        input.markAsFinished()
        await writer.finishWriting()
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
        guard let review = ReviewGallery.demo.make(model.dispatcher, directory: directory, sessionID: argument("linear-demo-session"), segmentation: flag("linear-demo-manual") ? .manual : .automatic) else { return }
        for card in review.tasks {
            card.destination = .linear(LinearTarget(team: team, project: nil, reason: .defaultTeam))
            if let prefix = argument("linear-demo-title-prefix"), !card.title.hasPrefix(prefix) { card.restoreTitle(prefix + card.title, custom: true) }
        }
        if let key = argument("linear-demo-other-team"), let other = model.linear.teams.value?.first(where: { $0.key == key }), let last = review.tasks.last {
            last.destination = .linear(LinearTarget(team: other, project: nil, reason: .defaultTeam))
        }
        review.tasks.first?.runtimeNotes = [
            "network: GET http://localhost:3000/api/cart?session=8812&token=tok_demo_should_not_leave failed with 500 (acme-web)",
            "TypeError: total is undefined — at Summary (\(NSHomeDirectory())/Code/acme-web/src/checkout/Summary.tsx:41) (acme-web)",
        ]
        review.save()
    }

    private static func describe(_ review: SessionReview, model: AppModel, step: String) -> [String: Any] {
        let plan = review.linearPlan
        return [
            "step": step,
            "segmentation": review.segmentation.rawValue,
            "structure": review.linearStructure.rawValue,
            "structureChosenInReview": review.linearStructureChoice?.rawValue ?? "none (Settings default)",
            "parentTitle": review.parentTitle,
            "parent": review.linearParent.map { "\($0.issue.identifier) in \($0.target.team.key)" } ?? "none",
            "parentIssueID": review.linearParent?.issue.id ?? "",
            "plannedChildren": plan?.children.map(\.snippet.id) ?? [],
            "standalone": plan?.elsewhere.map(\.snippet.id) ?? [],
            "caution": plan?.cautionText ?? "none",
            "summariser": OnDeviceSummariser.isAvailable ? "on-device (FoundationModels)" : "template (\(String(describing: SystemLanguageModel.default.availability)))",
            "tasks": review.tasks.map { card -> [String: Any] in
                [
                    "task": card.snippet.id,
                    "issueID": card.linearReceipt?.issue?.id ?? "",
                    "identifier": card.linearReceipt?.issue?.identifier ?? "",
                    "title": card.title,
                    "key": card.linearKey,
                    "destination": card.destination?.label ?? "none",
                    "state": String(describing: card.state),
                    "receipt": card.linearReceipt.map { String(describing: $0.status) } ?? "none",
                    "subIssueOf": card.linearReceipt?.parent?.identifier ?? "none",
                    "addedTo": card.linearReceipt?.addedTo?.identifier ?? "none",
                    "addedToIssueID": card.linearReceipt?.addedTo?.id ?? "",
                    "commentID": card.linearReceipt?.comment?.id ?? "",
                    "addToChoice": card.linearOptions.addTo?.identifier ?? "none",
                    "addToFailed": card.addToFailed,
                    "sentText": card.linearReceipt?.sentText ?? "",
                    "uploadedAssets": card.linearReceipt?.assets.map { "\($0.name) \($0.kind?.rawValue ?? "image") \($0.byteCount.map { "\($0) bytes" } ?? "") → \($0.url.absoluteString)" } ?? [],
                    "clipAttachment": card.linearReceipt?.clipAttachmentID ?? "none",
                    "unlinkedClip": card.linearReceipt?.unlinkedClip ?? false,
                    "includeVideo": model.dispatcher.includesVideo(card),
                    "redaction": card.linearOptions.redaction.map { "\($0.regions.count) areas, \($0.excluded.count) cuts" } ?? "none",
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
