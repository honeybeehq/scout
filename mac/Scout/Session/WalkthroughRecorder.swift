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
        var language: String?
        var failed: Bool
    }

    let bundle: WalkthroughBundle
    private var builder: WalkthroughBuilder
    private var media: (any WalkthroughMedia)?
    private var waiting: [WalkthroughBuilder.FrameRequest] = []
    private var captures: [Task<Void, Never>] = []
    private var prepared = false
    private var finishing = false
    private(set) var failedFrames = 0

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
        if builder.scopes.isEmpty, let bounds = media.bounds {
            enqueue(builder.add(WalkthroughBuilder.ScopeChange(at: 0, scope: .screen, bounds: bounds, byUser: false)))
        }
        let pending = waiting
        waiting.removeAll()
        pending.forEach(capture)
    }

    func record(_ signal: Signal) {
        guard !finishing else { return }
        enqueue(builder.record(signal))
    }

    func add(_ stroke: WalkthroughBuilder.Stroke) {
        guard !finishing else { return }
        enqueue(builder.add(stroke))
    }

    func add(_ change: WalkthroughBuilder.ScopeChange) {
        guard !finishing else { return }
        enqueue(builder.add(change))
    }

    func discard() {
        captures.forEach { $0.cancel() }
        bundle.discard()
    }

    func finish(at end: SessionTime, sources: Sources) async throws -> Outcome {
        var timings: [String: Double] = [:]
        let started = ContinuousClock.now
        func mark(_ name: String) { timings[name] = (ContinuousClock.now - started).seconds }
        enqueue(builder.finish(at: end))
        finishing = true
        if !prepared { try bundle.prepare() }
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
            language: sources.language,
            transcriptEngine: "SpeechAnalyzer",
            clip: exported,
            sourceFailed: sources.failed || (media != nil && exported == nil)
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
        guard let media, let bounds = media.bounds else { return }
        let frameURL = bundle.url(for: request.file)
        let thumbURL = bundle.url(for: request.thumb)
        captures.append(Task { [weak self] in
            let written: Int? = await Task.detached(priority: .utility) {
                guard let image = await media.frame(at: request.time),
                      WalkthroughImages.write(image, frame: frameURL, thumb: thumbURL)
                else { return nil }
                return WalkthroughImages.pixelWidth(of: image)
            }.value
            guard let self else { return }
            guard let written else {
                failedFrames += 1
                return
            }
            builder.captured(request, bbox: bounds, scale: bounds.width > 0 ? Double(written) / bounds.width : nil)
        })
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
