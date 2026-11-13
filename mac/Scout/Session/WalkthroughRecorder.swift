import AppKit
import ScoutCore

final class WalkthroughRecorder {
    struct Outcome {
        let directory: URL
        let walkthrough: Walkthrough
        let timings: [String: Double]
    }

    struct Sources {
        var screen: Walkthrough.Grant?
        var microphone: Walkthrough.Grant
        var accessibility: Walkthrough.Grant
        var transcript: Walkthrough.Availability
        var transcriptFailure: Walkthrough.TranscriptFailure?
        var language: String?
        var failed: Bool
        var microphoneSummary: Walkthrough.Microphone?
    }

    let bundle: WalkthroughBundle
    private var builder: WalkthroughBuilder
    private var media: (any WalkthroughMedia)?
    private var waiting: [WalkthroughBuilder.FrameRequest] = []
    private var captures: [Task<Void, Never>] = []
    private var semanticTasks: [Task<Void, Never>] = []
    private var sealed = false
    static let pointingWait: Duration = .milliseconds(130)
    static let finishLanes = 4
    private var prepared = false
    private var finishing = false
    private(set) var failedFrames = 0
    private var transcriptEngine = "SpeechAnalyzer"

    init(startedAt: Date, root: URL = WalkthroughBundle.defaultRoot()) {
        let id = WalkthroughBundle.newID(at: startedAt)
        bundle = WalkthroughBundle(id: id, root: root)
        builder = WalkthroughBuilder(id: id, startedAt: startedAt)
        prepared = (try? bundle.prepare()) != nil
        enqueue(builder.start())
    }

    var hasMedia: Bool { media != nil }

    func attach(_ media: any WalkthroughMedia) {
        self.media = media
        if builder.scopes.isEmpty, let view = media.view(at: 0) {
            enqueue(builder.add(WalkthroughBuilder.ScopeChange(at: 0, scope: .screen, bounds: view.bbox, byUser: false)))
        }
        let pending = waiting
        waiting.removeAll()
        pending.forEach(capture)
    }

    func record(_ signal: Signal) {
        guard !finishing else { return }
        enqueue(builder.record(signal))
    }

    func replaceTranscript(with utterances: [Utterance], engine: String) {
        guard !finishing else { return }
        builder.replaceTranscript(with: utterances)
        transcriptEngine = engine
    }

    func add(_ stroke: WalkthroughBuilder.Stroke) {
        guard !finishing else { return }
        enqueue(builder.add(stroke))
    }

    func add(_ change: WalkthroughBuilder.ScopeChange) {
        guard !finishing else { return }
        enqueue(builder.add(change))
    }

    func resolve(query: @escaping @Sendable () async -> ApiaryPoint?, accept: @escaping @MainActor (ApiaryPoint?) -> SemanticHit?) {
        guard !finishing else { return }
        semanticTasks.append(Task { [weak self] in
            let answer = await query()
            guard let self, !sealed, let hit = accept(answer) else { return }
            enqueue(builder.add(hit))
        })
    }

    var semantics: [SemanticHit] { builder.semantics }

    func discard() {
        captures.forEach { $0.cancel() }
        semanticTasks.forEach { $0.cancel() }
        bundle.discard()
    }

    func finish(at end: SessionTime, sources: Sources) async throws -> Outcome {
        var timings: [String: Double] = [:]
        let started = ContinuousClock.now
        func mark(_ name: String) { timings[name] = (ContinuousClock.now - started).seconds }
        let planned = builder.finish(at: end)
        finishing = true
        if media != nil {
            for lane in 0..<Self.finishLanes {
                let requests = planned.indices.filter { $0 % Self.finishLanes == lane }.map { planned[$0] }
                captures.append(Task { for request in requests { await self.write(request) } })
            }
        }
        if !prepared { try bundle.prepare() }
        let pending = semanticTasks
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = OnceFlag()
            Task {
                for task in pending { await task.value }
                once.run { continuation.resume() }
            }
            Task {
                try? await Task.sleep(for: Self.pointingWait)
                once.run { continuation.resume() }
            }
        }
        sealed = true
        mark("pointing")
        async let clip = media?.exportClip(through: end, to: bundle.url(for: WalkthroughBundle.clipName))
        for capture in captures { await capture.value }
        mark("frames")
        let exported = await clip
        mark("clip")
        let walkthrough = builder.build(WalkthroughBuilder.Finish(
            end: end,
            recorder: Self.recorder,
            permissions: Walkthrough.Permissions(screen: sources.screen, microphone: sources.microphone, accessibility: sources.accessibility),
            displays: media?.displays ?? [],
            transcript: sources.transcript,
            transcriptFailure: sources.transcriptFailure,
            language: sources.language,
            transcriptEngine: transcriptEngine,
            clip: exported,
            sourceFailed: sources.failed || (media != nil && exported == nil),
            microphone: sources.microphoneSummary
        ))
        mark("build")
        let directory = try bundle.finish(walkthrough)
        mark("written")
        return Outcome(directory: directory, walkthrough: walkthrough, timings: timings)
    }

    private func enqueue(_ request: WalkthroughBuilder.FrameRequest?) {
        guard let request else { return }
        if media == nil {
            waiting.append(request)
        } else {
            capture(request)
        }
    }

    private func capture(_ request: WalkthroughBuilder.FrameRequest) {
        guard media != nil else { return }
        captures.append(Task { [weak self] in await self?.write(request) })
    }

    private func write(_ request: WalkthroughBuilder.FrameRequest) async {
        guard let media else { return }
        let frameURL = bundle.url(for: request.file)
        let thumbURL = bundle.url(for: request.thumb)
        let written: (width: Int, view: MediaView)? = await Task.detached(priority: .utility) {
            guard let image = await media.frame(at: request.time),
                  let view = media.view(at: request.time),
                  WalkthroughImages.write(image, frame: frameURL, thumb: thumbURL)
            else { return nil }
            return (WalkthroughImages.pixelWidth(of: image), view)
        }.value
        guard let written else {
            failedFrames += 1
            return
        }
        let bbox = written.view.bbox
        builder.captured(request, bbox: bbox, scale: bbox.width > 0 ? Double(written.width) / bbox.width : nil, display: written.view.display)
    }

    private static var recorder: Walkthrough.Recorder {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return Walkthrough.Recorder(version: version, platform: "macos", osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
    }
}

enum WalkthroughPasteboard {
    static let type = NSPasteboard.PasteboardType(WalkthroughBundle.pasteboardType)

    @discardableResult
    static func put(_ directory: URL) -> Bool {
        let item = NSPasteboardItem()
        item.setString(directory.path, forType: type)
        item.setString(directory.appendingPathComponent(WalkthroughBundle.entryName).absoluteString, forType: .fileURL)
        item.setString(directory.path, forType: .string)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }
}

extension Duration {
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
