import AppKit
import AVFoundation
import ImageIO
@preconcurrency import ScreenCaptureKit
import ScoutCore
import UniformTypeIdentifiers

enum CaptureSelfTest {
    private static let argumentPrefix = "--capture-self-test="
    private static let directory = URL(fileURLWithPath: "/tmp/scout-capture-test", isDirectory: true)

    static func startIfRequested() {
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(argumentPrefix) }),
              let seconds = Double(argument.dropFirst(argumentPrefix.count)), seconds >= 8
        else { return }
        Task {
            await run(seconds: seconds)
            NSApp.terminate(nil)
        }
    }

    private static func run(seconds: Double) async {
        try? await Task.sleep(for: .seconds(1))
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let recorder = SegmentedScreenRecorder(directory: directory)
        let log = SelfTestLog()
        recorder.onFrameDifference = { at, magnitude in log.add(VisualChange(at: at, magnitude: magnitude)) }
        recorder.onError = { error in log.add(error: error.localizedDescription) }
        let heartbeat = MainThreadHeartbeat()
        heartbeat.start()

        var report = Report(requestedSeconds: seconds)
        report.syntheticVisualChange = syntheticVisualChange()
        report.scoutListedForExclusion = await scoutIsShareable()
        let sessionStart = Date.now
        do {
            try await recorder.start(sessionStart: sessionStart)
        } catch {
            report.errors.append(error.localizedDescription)
            finish(report, heartbeat: heartbeat)
            return
        }
        report.display = recorder.display

        await sleep(until: seconds - 3, since: sessionStart)
        report.snapshots.append(await snapshot(recorder, at: nil, named: "snapshot.png"))
        report.clips.append(await clip(recorder, from: 1, to: seconds - 4, named: "clip-live.mp4"))

        await sleep(until: seconds, since: sessionStart)
        let stopBegan = ContinuousClock.now
        await recorder.stop()
        report.stopMilliseconds = milliseconds(since: stopBegan)

        report.snapshots.append(await snapshot(recorder, at: 2, named: "snapshot-at-2s.png"))
        report.snapshots.append(await snapshot(recorder, at: seconds - 5, named: "snapshot-at-\(Int(seconds - 5))s.png"))
        report.clips.append(await clip(recorder, from: seconds / 2 - 1, to: seconds - 0.5, named: "clip-final.mp4"))

        report.segments = recorder.segments.map { SegmentEntry(file: $0.url.lastPathComponent, start: $0.range.start, end: $0.range.end, bytes: $0.byteCount) }
        report.segmentCount = report.segments.count
        report.statistics = recorder.statistics
        report.averageVisualSampleMicroseconds = recorder.statistics.averageVisualSampleMicroseconds
        report.visualChanges = log.visualChanges
        report.visualChangeSampleCount = report.visualChanges.count
        report.errors += log.errors
        finish(report, heartbeat: heartbeat)
    }

    private static func clip(_ recorder: SegmentedScreenRecorder, from start: Double, to end: Double, named name: String) async -> ClipEntry {
        var entry = ClipEntry(file: name, requestedStart: start, requestedEnd: end, requestedAt: recorder.sessionTimeNow)
        let waitBegan = ContinuousClock.now
        entry.waitSatisfied = await recorder.waitForMedia(through: min(end + 1, entry.requestedAt))
        entry.waitMilliseconds = milliseconds(since: waitBegan)
        entry.flushedEnd = recorder.segments.last?.range.end
        let cutBegan = ContinuousClock.now
        do {
            let exported = try await recorder.exportClip(from: start, to: end, into: directory.appending(path: name))
            entry.cutMilliseconds = milliseconds(since: cutBegan)
            entry.coveredStart = exported.range.start
            entry.coveredEnd = exported.range.end
            let asset = AVURLAsset(url: exported.url)
            entry.duration = try await asset.load(.duration).seconds
            if let track = try await asset.loadTracks(withMediaType: .video).first {
                let size = try await track.load(.naturalSize)
                entry.width = Int(size.width)
                entry.height = Int(size.height)
                let formats = try await track.load(.formatDescriptions)
                entry.codec = formats.first.map { fourCharacterCode(CMFormatDescriptionGetMediaSubType($0)) }
            }
            entry.bytes = (try? FileManager.default.attributesOfItem(atPath: exported.url.path)[.size] as? Int) ?? nil
        } catch {
            entry.cutMilliseconds = milliseconds(since: cutBegan)
            entry.error = error.localizedDescription
        }
        return entry
    }

    private static func snapshot(_ recorder: SegmentedScreenRecorder, at time: Double?, named name: String) async -> SnapshotEntry {
        let began = ContinuousClock.now
        let image = await recorder.snapshot(at: time)
        var entry = SnapshotEntry(file: name, requestedAt: time, milliseconds: milliseconds(since: began), returnedImage: image != nil)
        if let image {
            await writePNG(image, to: directory.appending(path: name))
            entry.width = image.width
            entry.height = image.height
        }
        return entry
    }

    @concurrent private static func writePNG(_ image: CGImage, to url: URL) async {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    private static func syntheticVisualChange() -> SyntheticCheck {
        let width = 1920, height = 800
        guard let before = lumaBuffer(width: width, height: height, topHalf: 40, bottomHalf: 40),
              let after = lumaBuffer(width: width, height: height, topHalf: 200, bottomHalf: 40)
        else { return SyntheticCheck(expected: 0.5, measured: nil, microseconds: nil) }
        let began = ContinuousClock.now
        let first = LumaGrid(pixelBuffer: before)
        let elapsed = ContinuousClock.now - began
        guard let first, let second = LumaGrid(pixelBuffer: after) else { return SyntheticCheck(expected: 0.5, measured: nil, microseconds: nil) }
        let microseconds = Double(elapsed.components.seconds) * 1e6 + Double(elapsed.components.attoseconds) / 1e12
        return SyntheticCheck(expected: 0.5, measured: second.changedFraction(since: first), microseconds: microseconds)
    }

    private static func lumaBuffer(width: Int, height: Int, topHalf: UInt8, bottomHalf: UInt8) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for row in 0..<height {
            memset(base + row * rowBytes, Int32(row < height / 2 ? topHalf : bottomHalf), rowBytes)
        }
        return buffer
    }

    @concurrent private static func scoutIsShareable() async -> Bool {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return false }
        let ownProcess = ProcessInfo.processInfo.processIdentifier
        return content.applications.contains { $0.processID == ownProcess }
    }

    private static func finish(_ report: Report, heartbeat: MainThreadHeartbeat) {
        var report = report
        report.mainThreadLongestStallMilliseconds = heartbeat.longestStallMilliseconds
        report.mainThreadStalls = heartbeat.stalls
        heartbeat.stop()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(report) {
            try? data.write(to: directory.appending(path: "report.json"))
        }
    }

    private static func sleep(until sessionSeconds: Double, since start: Date) async {
        let remaining = sessionSeconds - Date.now.timeIntervalSince(start)
        if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return (Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15).rounded(toPlaces: 1)
    }

    private static func fourCharacterCode(_ code: FourCharCode) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .ascii) ?? "\(code)"
    }

    private struct Report: Encodable {
        var requestedSeconds: Double
        var display: CaptureDisplay?
        var segmentCount = 0
        var segments: [SegmentEntry] = []
        var clips: [ClipEntry] = []
        var snapshots: [SnapshotEntry] = []
        var visualChangeSampleCount = 0
        var averageVisualSampleMicroseconds = 0.0
        var visualChanges: [VisualChange] = []
        var statistics: CaptureStatistics?
        var stopMilliseconds: Double?
        var mainThreadLongestStallMilliseconds: Double?
        var mainThreadStalls: [MainThreadHeartbeat.Stall] = []
        var syntheticVisualChange: SyntheticCheck?
        var scoutListedForExclusion: Bool?
        var errors: [String] = []
    }

    private struct SyntheticCheck: Encodable {
        let expected: Double
        let measured: Double?
        let microseconds: Double?
    }

    private struct SegmentEntry: Encodable {
        let file: String
        let start: Double
        let end: Double
        let bytes: Int
    }

    private struct ClipEntry: Encodable {
        let file: String
        let requestedStart: Double
        let requestedEnd: Double
        let requestedAt: Double
        var waitSatisfied: Bool?
        var waitMilliseconds: Double?
        var flushedEnd: Double?
        var cutMilliseconds: Double?
        var coveredStart: Double?
        var coveredEnd: Double?
        var duration: Double?
        var width: Int?
        var height: Int?
        var codec: String?
        var bytes: Int?
        var error: String?
    }

    private struct SnapshotEntry: Encodable {
        let file: String
        let requestedAt: Double?
        let milliseconds: Double
        let returnedImage: Bool
        var width: Int?
        var height: Int?
    }
}

nonisolated private final class SelfTestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var changes: [VisualChange] = []
    private var messages: [String] = []

    var visualChanges: [VisualChange] { lock.withLock { changes } }
    var errors: [String] { lock.withLock { messages } }

    func add(_ change: VisualChange) {
        lock.withLock { changes.append(change) }
    }

    func add(error: String) {
        lock.withLock { messages.append(error) }
    }
}

private final class MainThreadHeartbeat {
    struct Stall: Encodable {
        let at: Double
        let milliseconds: Double
    }

    private var task: Task<Void, Never>?
    private(set) var longestStallMilliseconds = 0.0
    private(set) var stalls: [Stall] = []

    func start() {
        let began = ContinuousClock.now
        task = Task { [weak self] in
            var previous = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
                let now = ContinuousClock.now
                let gap = now - previous
                previous = now
                let stall = Double(gap.components.seconds) * 1000 + Double(gap.components.attoseconds) / 1e15 - 10
                guard let self else { return }
                self.longestStallMilliseconds = max(self.longestStallMilliseconds, stall)
                if stall > 25 {
                    let at = now - began
                    self.stalls.append(Stall(at: Double(at.components.seconds) + Double(at.components.attoseconds) / 1e18, milliseconds: stall))
                }
            }
        }
    }

    func stop() {
        task?.cancel()
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10, Double(places))
        return (self * factor).rounded() / factor
    }
}
