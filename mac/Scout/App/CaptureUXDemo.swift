import AppKit
import AVFoundation
import ScoutCore
import SwiftUI
import Synchronization

enum CaptureUXDemo {
    private static func argument(_ name: String) -> String? {
        let prefix = "--\(name)="
        return ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    static var outputDirectory: URL? {
        argument("capture-ux-demo").map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static var recordsVideo: Bool {
        ProcessInfo.processInfo.arguments.contains("--capture-ux-video")
    }

    static func run(model: AppModel, output: URL) async {
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(1.5))
        let windows = TestWindows()
        windows.open()
        model.simulatedInput = argument("capture-ux-audio").map { URL(fileURLWithPath: $0) }
        model.onSessionCreated = { session in windows.register(with: session.follower.resolver) }
        let video = recordsVideo ? DemoVideo(url: output.appendingPathComponent("flow.mp4")) : nil
        video?.start()
        let pointer = DemoPointer(video: video)
        try? await Task.sleep(for: .seconds(1))

        await pointer.glide(to: windows.point(in: .page, at: CGPoint(x: 0.45, y: 0.55)), seconds: 0.6)
        try? await Task.sleep(for: .milliseconds(500))
        video?.caption = "⌃⌥S: recording starts, no picker"
        let hotkeyPath = await pressHotkey(model: model, windows: windows)
        try? await Task.sleep(for: .seconds(1.6))

        video?.caption = "Capture follows the pane under the pointer"
        await pointer.glide(to: windows.point(in: .chat, at: CGPoint(x: 0.5, y: 0.45)), seconds: 0.5)
        try? await Task.sleep(for: .seconds(1.1))
        video?.caption = "Back and forth between two panes"
        await pointer.glide(to: windows.point(in: .page, at: CGPoint(x: 0.5, y: 0.5)), seconds: 0.45)
        try? await Task.sleep(for: .seconds(0.7))
        await pointer.glide(to: windows.point(in: .chat, at: CGPoint(x: 0.45, y: 0.6)), seconds: 0.45)
        try? await Task.sleep(for: .seconds(1.4))
        video?.caption = "⌃⌥E: keep both in view"
        let suggested = model.session?.follower.suggestion != nil
        var scopeKeyPaths = [await pressScopeKey(model: model, follow: false)]
        try? await Task.sleep(for: .seconds(1.6))
        video?.caption = "⌃⌥E again: the whole window"
        scopeKeyPaths.append(await pressScopeKey(model: model, follow: false))
        try? await Task.sleep(for: .seconds(1.4))
        video?.caption = "⌃⌥E again: the whole screen"
        scopeKeyPaths.append(await pressScopeKey(model: model, follow: false))
        try? await Task.sleep(for: .seconds(1.4))
        video?.caption = "⌃⌥⇧E: follow the pointer again"
        scopeKeyPaths.append(await pressScopeKey(model: model, follow: true))
        try? await Task.sleep(for: .seconds(1.2))

        video?.caption = "Another window: capture follows it"
        await pointer.glide(to: windows.point(in: .notes, at: CGPoint(x: 0.4, y: 0.4)), seconds: 0.6)
        try? await Task.sleep(for: .seconds(1.2))

        video?.caption = "⌥-click: pin"
        let pinPoint = windows.point(in: .notes, at: CGPoint(x: 0.3, y: 0.3))
        await pointer.glide(to: pinPoint, seconds: 0.3)
        await optionClick(model: model, at: pinPoint)
        try? await Task.sleep(for: .seconds(0.9))

        video?.caption = "⌥-drag: draw"
        await pointer.glide(to: windows.point(in: .page, at: CGPoint(x: 0.5, y: 0.35)), seconds: 0.6)
        try? await Task.sleep(for: .seconds(0.6))
        await optionDraw(model: model, pointer: pointer, around: windows.point(in: .page, at: CGPoint(x: 0.5, y: 0.5)), radius: CGSize(width: 130, height: 60))
        try? await Task.sleep(for: .seconds(0.6))
        let pin2 = windows.point(in: .page, at: CGPoint(x: 0.72, y: 0.78))
        await pointer.glide(to: pin2, seconds: 0.35)
        await optionClick(model: model, at: pin2)
        try? await Task.sleep(for: .seconds(1.4))

        video?.caption = "⌃⌥S again: finish, no processing step"
        let session = model.session
        await pressHotkey(model: model, windows: windows, finishing: true)
        try? await Task.sleep(for: .seconds(2.5))
        video?.caption = nil
        try? await Task.sleep(for: .seconds(1.0))
        await video?.finish()
        writeReport(model: model, session: session, hotkeyPath: hotkeyPath, scopeKeyPaths: scopeKeyPaths, suggested: suggested, into: output)
        windows.close()
        NSApp.terminate(nil)
    }

    @discardableResult
    private static func pressHotkey(model: AppModel, windows: TestWindows, finishing: Bool = false) async -> String {
        if AXIsProcessTrusted() {
            postKey(UInt16(1), flags: [.maskControl, .maskAlternate])
            for _ in 0..<20 where model.isScouting == finishing {
                try? await Task.sleep(for: .milliseconds(10))
            }
            if model.isScouting != finishing { return "posted ⌃⌥S CGEvent, handled by the Carbon hotkey" }
        }
        model.triggerHotkey(at: InteractionTimings.now)
        return "Carbon hotkey handler called directly (posting key events needs Accessibility, which this build does not have)"
    }

    static func pressScopeKey(model: AppModel, follow: Bool) async -> String {
        guard let hotkeys = model.scopeHotkeys else { return "no scope hotkeys" }
        let hotkey = follow ? hotkeys.follow : hotkeys.widen
        let shortcut = follow ? model.followShortcut : model.widenShortcut
        let before = model.session?.capture.scopes.count ?? 0
        if CGPreflightPostEventAccess() {
            postKey(UInt16(shortcut.keyCode), flags: follow ? [.maskControl, .maskAlternate, .maskShift] : [.maskControl, .maskAlternate])
            for _ in 0..<30 where (model.session?.capture.scopes.count ?? 0) == before {
                try? await Task.sleep(for: .milliseconds(10))
            }
            if (model.session?.capture.scopes.count ?? 0) != before { return "posted \(shortcut.label) CGEvent, handled by the Carbon hotkey" }
        }
        let status = hotkey.sendPressedEvent()
        return "\(shortcut.label) sent as a Carbon hot-key event to the app's event target (status \(status)); posting key events needs Accessibility"
    }

    private static func optionClick(model: AppModel, at point: CGPoint) async {
        guard let aim = model.session?.aim else { return }
        aim.simulate(.modifiers(.maskAlternate))
        try? await Task.sleep(for: .milliseconds(260))
        aim.simulate(.press(point, InteractionTimings.now))
        try? await Task.sleep(for: .milliseconds(70))
        aim.simulate(.release(point, InteractionTimings.now))
        try? await Task.sleep(for: .milliseconds(120))
        aim.simulate(.modifiers([]))
    }

    private static func optionDraw(model: AppModel, pointer: DemoPointer, around center: CGPoint, radius: CGSize) async {
        guard let aim = model.session?.aim else { return }
        aim.simulate(.modifiers(.maskAlternate))
        try? await Task.sleep(for: .milliseconds(260))
        let duration = 1.4
        let began = InteractionTimings.now
        var pressed = false
        while true {
            let t = min(1, (InteractionTimings.now - began) / duration)
            let angle = -Double.pi / 2 + t * 2.15 * Double.pi
            let point = CGPoint(x: center.x + cos(angle) * radius.width, y: center.y + sin(angle) * radius.height)
            pointer.jump(to: point, warps: t >= 1)
            aim.simulate(pressed ? .drag(point, InteractionTimings.now) : .press(point, InteractionTimings.now))
            pressed = true
            if t >= 1 { break }
            await CaptureUXDemo.pause(milliseconds: 8)
        }
        aim.simulate(.release(pointer.location, InteractionTimings.now))
        try? await Task.sleep(for: .milliseconds(120))
        aim.simulate(.modifiers([]))
    }

    static func pause(milliseconds: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
            timer.schedule(deadline: .now() + .milliseconds(milliseconds), leeway: .milliseconds(1))
            timer.setEventHandler {
                timer.cancel()
                continuation.resume()
            }
            timer.resume()
        }
    }

    static func postKey(_ key: UInt16, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)
    }

    private struct Summary: Encodable {
        var count: Int
        var handledP95: Double
        var committedP50: Double
        var committedP95: Double
        var committedMax: Double
        var onScreenP50: Double
        var onScreenP95: Double
        var onScreenMax: Double
        var budget: Double
    }

    private struct Report: Encodable {
        var hotkeyPath: String
        var scopeKeyPaths: [String]
        var keepBothSuggestedBeforeE: Bool
        var screens: [String]
        var accessibilityTrusted: Bool
        var screenRecordingGranted: Bool
        var eventTapAvailable: Bool
        var captureProblem: String
        var sessionDirectory: String
        var timingClockSkewMs: Double
        var summary: [String: Summary]
        var samples: [InteractionSample]
        var capture: CaptureTimeline?
        var pins: [Mark]
        var reviewOpened: Bool
    }

    private static func writeReport(model: AppModel, session: ScoutingSession?, hotkeyPath: String, scopeKeyPaths: [String], suggested: Bool, into output: URL) {
        let samples = InteractionTimings.shared.samples
        var summary: [String: Summary] = [:]
        for name in Set(samples.map(\.name)) {
            let named = samples.filter { $0.name == name }
            let handled = named.map(\.handledMs).sorted()
            let committed = named.map { $0.committedMs ?? $0.handledMs }.sorted()
            let onScreen = named.map { $0.paintedMs ?? $0.handledMs }.sorted()
            summary[name] = Summary(
                count: named.count,
                handledP95: percentile(handled, 0.95),
                committedP50: percentile(committed, 0.5),
                committedP95: percentile(committed, 0.95),
                committedMax: committed.last ?? 0,
                onScreenP50: percentile(onScreen, 0.5),
                onScreenP95: percentile(onScreen, 0.95),
                onScreenMax: onScreen.last ?? 0,
                budget: named.first?.budgetMs ?? 0
            )
        }
        let report = Report(
            hotkeyPath: hotkeyPath,
            scopeKeyPaths: scopeKeyPaths,
            keepBothSuggestedBeforeE: suggested,
            screens: NSScreen.screens.map { NSStringFromRect($0.frame) },
            accessibilityTrusted: AXIsProcessTrusted(),
            screenRecordingGranted: CGPreflightScreenCaptureAccess(),
            eventTapAvailable: session?.aim.isAvailable ?? false,
            captureProblem: session?.captureProblem ?? "",
            sessionDirectory: session?.directory.path ?? "",
            timingClockSkewMs: (CACurrentMediaTime() - ProcessInfo.processInfo.systemUptime) * 1000,
            summary: summary,
            samples: samples,
            capture: session?.capture,
            pins: session?.ledger.marks ?? [],
            reviewOpened: model.review.map { $0.sessionID == session?.id } ?? false
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try encoder.encode(report).write(to: output.appendingPathComponent("report.json"))
        } catch {
            NSLog("S2 demo report failed: %@", String(describing: error))
        }
    }

    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded()))]
    }
}

@MainActor
private final class DemoPointer {
    private(set) var location: CGPoint
    private weak var video: DemoVideo?

    init(video: DemoVideo?) {
        self.video = video
        location = CaptureFollower.pointer()
    }

    func jump(to point: CGPoint, warps: Bool = true) {
        location = point
        if warps { CGWarpMouseCursorPosition(point) }
        video?.pointer = point
    }

    func glide(to target: CGPoint, seconds: Double) async {
        let start = location
        let began = InteractionTimings.now
        while true {
            let t = min(1, (InteractionTimings.now - began) / seconds)
            let eased = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
            jump(to: CGPoint(x: start.x + (target.x - start.x) * eased, y: start.y + (target.y - start.y) * eased))
            if t >= 1 { return }
            await CaptureUXDemo.pause(milliseconds: 8)
        }
    }
}

@MainActor
private final class TestWindows {
    enum Area { case page, chat, notes }

    private var main: NSWindow?
    private var notes: NSWindow?
    static let split: CGFloat = 0.56

    func open() {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 1080
        main = makeWindow(title: "Checkout (S2 test window)", frame: CGRect(x: 70, y: 90, width: 1010, height: 660), primaryHeight: primaryHeight, content: AnyView(SplitTestContent()))
        notes = makeWindow(title: "Notes (S2 test window)", frame: CGRect(x: 1140, y: 170, width: 700, height: 520), primaryHeight: primaryHeight, content: AnyView(NotesTestContent()))
    }

    func close() {
        main?.close()
        notes?.close()
    }

    func register(with resolver: RegionResolver) {
        [main, notes].compactMap { $0 }.forEach { resolver.include(CGWindowID($0.windowNumber)) }
        let page = rect(of: .page), chat = rect(of: .chat)
        let mainID = main.map { CGWindowID($0.windowNumber) }
        resolver.paneProvider = { point, window in
            guard window.id == mainID else { return nil }
            if page.contains(point) { return RegionResolver.Pane(id: "page", bounds: page, label: "Page pane") }
            if chat.contains(point) { return RegionResolver.Pane(id: "chat", bounds: chat, label: "Chat pane") }
            return nil
        }
    }

    func point(in area: Area, at fraction: CGPoint) -> CGPoint {
        let rect = rect(of: area)
        return CGPoint(x: rect.minX + rect.width * fraction.x, y: rect.minY + rect.height * fraction.y)
    }

    private func rect(of area: Area) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 1080
        let window = area == .notes ? notes : main
        guard let window else { return .zero }
        let content = window.contentLayoutRect
        let frame = window.frame
        let top = primaryHeight - frame.maxY + (frame.height - content.height)
        let full = CGRect(x: frame.minX, y: top, width: frame.width, height: content.height)
        switch area {
        case .notes: return full
        case .page: return CGRect(x: full.minX, y: full.minY, width: full.width * Self.split, height: full.height)
        case .chat: return CGRect(x: full.minX + full.width * Self.split, y: full.minY, width: full.width * (1 - Self.split), height: full.height)
        }
    }

    private func makeWindow(title: String, frame: CGRect, primaryHeight: CGFloat, content: AnyView) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content.environment(\.colorScheme, .light))
        window.setFrame(CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height), display: true)
        window.orderFrontRegardless()
        return window
    }
}

private struct SplitTestContent: View {
    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Checkout").font(.system(size: 22, weight: .bold))
                    Text("Throwaway test page for Scout S2").font(.system(size: 12)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 8) {
                        row("Subtotal", "36.00 €")
                        row("Shipping", "4.90 €")
                        Divider()
                        row("Total", "40.90 €").fontWeight(.semibold)
                    }
                    .padding(14)
                    .background(.white, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(white: 0.88)))
                    Text("Pay now")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color(white: 0.15), in: RoundedRectangle(cornerRadius: 6))
                    Spacer()
                }
                .padding(24)
                .frame(width: proxy.size.width * TestWindows.split, alignment: .leading)
                .frame(maxHeight: .infinity)
                .background(Color(white: 0.96))
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("Chat").font(.system(size: 15, weight: .semibold))
                    bubble("Shipping is free over 40 €.", agent: true)
                    bubble("The page still charges 4.90 €.", agent: false)
                    bubble("I'll check the rule in checkout.ts.", agent: true)
                    Spacer()
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Color(white: 0.8)).frame(height: 34)
                        .overlay(Text("Message").foregroundStyle(.tertiary).padding(.leading, 10), alignment: .leading)
                }
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(white: 0.99))
            }
        }
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack { Text(name); Spacer(); Text(value) }.font(.system(size: 13)).frame(width: 300)
    }

    private func bubble(_ text: String, agent: Bool) -> some View {
        Text(text)
            .font(.system(size: 13))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(agent ? Color(white: 0.93) : Color(red: 0.86, green: 0.9, blue: 1), in: RoundedRectangle(cornerRadius: 9))
            .frame(maxWidth: .infinity, alignment: agent ? .leading : .trailing)
    }
}

private struct NotesTestContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Notes").font(.system(size: 20, weight: .bold))
            Text("A second throwaway window, to show capture following another window.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            ForEach(["Pay button too small", "Card errors only after submit", "Shipping rule mismatch"], id: \.self) { item in
                HStack(spacing: 8) {
                    Circle().fill(Color(white: 0.75)).frame(width: 7, height: 7)
                    Text(item).font(.system(size: 13))
                }
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 0.99, green: 0.98, blue: 0.94))
    }
}

@MainActor
private final class DemoVideo {
    var pointer: CGPoint = CaptureFollower.pointer() {
        didSet { renderer.state.withLock { $0.pointer = pointer } }
    }
    var caption: String? {
        didSet { renderer.state.withLock { $0.caption = caption } }
    }

    private let renderer: DemoRenderer

    init(url: URL) {
        renderer = DemoRenderer(url: url)
    }

    func start() {
        renderer.state.withLock { $0.pointer = pointer }
        renderer.start()
    }

    func finish() async {
        await renderer.finish()
    }
}

nonisolated private final class DemoRenderer: @unchecked Sendable {
    struct State {
        var pointer: CGPoint = .zero
        var caption: String?
    }

    let state = Mutex(State())
    private let url: URL
    private let queue = DispatchQueue(label: "scout.demo-video", qos: .utility)
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var timer: DispatchSourceTimer?
    private var started: TimeInterval = 0
    private let size = CGSize(width: 1920, height: 1080)
    private let cursor: CGImage?
    private let cursorSize: CGSize
    private let hotSpot: CGPoint

    private typealias WindowImageFunction = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    init(url: URL) {
        self.url = url
        let arrow = MainActor.assumeIsolated { (NSCursor.arrow.image, NSCursor.arrow.hotSpot) }
        cursor = arrow.0.cgImage(forProposedRect: nil, context: nil, hints: nil)
        cursorSize = arrow.0.size
        hotSpot = arrow.1
    }

    func start() {
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        started = ProcessInfo.processInfo.systemUptime
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.frame() }
        timer.resume()
        self.timer = timer
    }

    func finish() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                timer?.cancel()
                input?.markAsFinished()
                guard let writer else { return continuation.resume() }
                writer.finishWriting { continuation.resume() }
            }
        }
    }

    private func frame() {
        guard let adaptor, let input, input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return }
        let time = CMTime(seconds: ProcessInfo.processInfo.systemUptime - started, preferredTimescale: 600)
        CVPixelBufferLockBaseAddress(buffer, [])
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            CVPixelBufferUnlockBaseAddress(buffer, [])
            return
        }
        draw(into: context, state: state.withLock { $0 })
        CVPixelBufferUnlockBaseAddress(buffer, [])
        adaptor.append(buffer, withPresentationTime: time)
    }

    private func draw(into context: CGContext, state: State) {
        let height = size.height
        context.setFillColor(CGColor(red: 0.11, green: 0.13, blue: 0.17, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let ownProcess = ProcessInfo.processInfo.processIdentifier
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        let mine = list.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == ownProcess }
        for entry in mine.reversed() {
            guard let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let boundsInfo = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo),
                  bounds.width > 1, bounds.height > 1,
                  let image = windowImage(id)
            else { continue }
            context.draw(image, in: CGRect(x: bounds.minX, y: height - bounds.maxY, width: bounds.width, height: bounds.height))
        }
        if let cursor {
            let origin = CGPoint(x: state.pointer.x - hotSpot.x, y: height - state.pointer.y - cursorSize.height + hotSpot.y)
            context.draw(cursor, in: CGRect(origin: origin, size: cursorSize))
        }
        drawBanner(into: context, caption: state.caption)
    }

    private func windowImage(_ id: CGWindowID) -> CGImage? {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let symbol = dlsym(handle, "CGWindowListCreateImage")
        else { return nil }
        let function = unsafeBitCast(symbol, to: WindowImageFunction.self)
        let imageOptions = CGWindowImageOption([.boundsIgnoreFraming, .nominalResolution]).rawValue
        return function(.null, CGWindowListOption.optionIncludingWindow.rawValue, id, imageOptions)?.takeRetainedValue()
    }

    private func drawBanner(into context: CGContext, caption: String?) {
        let note = "Rendered from Scout's own windows without Screen Recording permission. Test windows are temporary."
        let small = NSAttributedString(string: note, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.7)])
        draw(small, at: CGPoint(x: 24, y: 18), in: context)
        guard let caption else { return }
        let text = NSAttributedString(string: caption, attributes: [.font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: NSColor.white])
        let width = text.size().width + 36
        let box = CGRect(x: (size.width - width) / 2, y: 46, width: width, height: 42)
        context.setFillColor(CGColor(gray: 0, alpha: 0.72))
        context.addPath(CGPath(roundedRect: box, cornerWidth: 21, cornerHeight: 21, transform: nil))
        context.fillPath()
        draw(text, at: CGPoint(x: box.minX + 18, y: box.minY + 9), in: context)
    }

    private func draw(_ text: NSAttributedString, at point: CGPoint, in context: CGContext) {
        let line = CTLineCreateWithAttributedString(text)
        context.textPosition = CGPoint(x: point.x, y: point.y + 6)
        CTLineDraw(line, context)
    }
}
