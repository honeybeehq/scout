import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit
import ScoutCore
import UniformTypeIdentifiers
import VideoToolbox

nonisolated final class SegmentedScreenRecorder: NSObject, @unchecked Sendable {
    typealias FrameDifferenceHandler = @Sendable (_ at: SessionTime, _ magnitude: Double) -> Void
    typealias ErrorHandler = @Sendable (ScreenCaptureError) -> Void
    typealias FirstFrameHandler = @Sendable (_ uptime: TimeInterval) -> Void

    static let segmentInterval = 2.0
    static let framesPerSecond: Int32 = 30
    static let maxLongEdge = 1920
    static let visualSampleInterval = 0.5
    static let maximumFlushWait = 3.0
    private static let idleRepeatInterval = 0.25
    private static let idleRepeatLatencyAllowance = 0.1
    private static let snapshotTolerance = 0.25
    private static let timescale: CMTimeScale = 90_000

    private enum Phase {
        case idle, starting, recording, stopping, finished
    }

    private struct CapturedFrame: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer
        let time: SessionTime
    }

    let directory: URL
    let mediaDirectory: URL

    private let queue = DispatchQueue(label: "com.trmdy.scout.screen-recorder", qos: .userInteractive)
    private let lock = NSLock()

    private var phase = Phase.idle
    private var sessionStartHostTime = CMTime.zero
    private var captureDisplay: CaptureDisplay?
    private var currentDisplay: CaptureDisplay?
    private var displayHops: [(at: SessionTime, display: CaptureDisplay)] = []
    private var shareableContent: SCShareableContent?
    private var requestedDisplay: CGDirectDisplayID?
    private var switchingDisplay = false
    private var firstFrameHandler: FirstFrameHandler?
    private var stream: SCStream?
    private var initSegmentURL: URL?
    private var segmentList: [MediaSegment] = []
    private var firstFrameTime: SessionTime?
    private var latestFrame: CapturedFrame?
    private var frameDifferenceHandler: FrameDifferenceHandler?
    private var errorHandler: ErrorHandler?
    private var counters = CaptureStatistics()

    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var ticker: DispatchSourceTimer?
    private var lastAppendedTime = CMTime.invalid
    private var lastVisualSample: (time: SessionTime, grid: LumaGrid)?
    private var unsampledFrame: CapturedFrame?
    private var writerClosing = false
    private var writerClosed = false
    private var closeWaiters: [@Sendable () -> Void] = []

    init(directory: URL) {
        self.directory = directory
        self.mediaDirectory = directory.appending(path: "media", directoryHint: .isDirectory)
    }

    var onFrameDifference: FrameDifferenceHandler? {
        get { lock.withLock { frameDifferenceHandler } }
        set { lock.withLock { frameDifferenceHandler = newValue } }
    }

    var onError: ErrorHandler? {
        get { lock.withLock { errorHandler } }
        set { lock.withLock { errorHandler = newValue } }
    }

    var onFirstFrame: FirstFrameHandler? {
        get { lock.withLock { firstFrameHandler } }
        set { lock.withLock { firstFrameHandler = newValue } }
    }

    var display: CaptureDisplay? { lock.withLock { captureDisplay } }
    var displayChanges: [(at: SessionTime, display: CaptureDisplay)] { lock.withLock { displayHops } }
    var currentCaptureDisplay: CaptureDisplay? { lock.withLock { currentDisplay } }

    var displaysUsed: [CaptureDisplay] {
        lock.withLock {
            var seen: Set<CGDirectDisplayID> = []
            return ([captureDisplay].compactMap { $0 } + displayHops.map(\.display)).filter { seen.insert($0.displayID).inserted }
        }
    }
    var segments: [MediaSegment] { lock.withLock { segmentList } }
    var statistics: CaptureStatistics { lock.withLock { counters } }

    var sessionTimeNow: SessionTime {
        lock.withLock { (CMClockGetTime(CMClockGetHostTimeClock()) - sessionStartHostTime).seconds }
    }

    @concurrent func start(sessionStart: Date = .now) async throws {
        let claimed = lock.withLock {
            guard phase == .idle else { return false }
            phase = .starting
            return true
        }
        guard claimed else { throw ScreenCaptureError.alreadyStarted }
        do {
            guard CGPreflightScreenCaptureAccess() else { throw ScreenCaptureError.permissionDenied }
            try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
            let (target, content) = try await CaptureTarget.displayUnderPointer(maxLongEdge: Self.maxLongEdge)
            let configuration = target.streamConfiguration(framesPerSecond: Self.framesPerSecond)
            let stream = SCStream(filter: target.filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            let elapsed = CMTime(seconds: Date.now.timeIntervalSince(sessionStart), preferredTimescale: 1_000_000_000)
            let startHostTime = CMClockGetTime(CMClockGetHostTimeClock()) - elapsed
            lock.withLock {
                sessionStartHostTime = startHostTime
                captureDisplay = target.display
                currentDisplay = target.display
                shareableContent = content
                self.stream = stream
            }
            try await stream.startCapture()
            let stoppedWhileStarting = lock.withLock {
                guard phase == .starting else { return true }
                phase = .recording
                return false
            }
            if stoppedWhileStarting {
                try? await stream.stopCapture()
                return
            }
            queue.async { self.startTicker() }
        } catch {
            lock.withLock {
                if phase == .starting { phase = .idle }
                self.stream = nil
            }
            throw ScreenCaptureError.starting(error)
        }
    }

    @concurrent func show(display displayID: CGDirectDisplayID) async {
        let claimed = lock.withLock {
            requestedDisplay = displayID
            guard !switchingDisplay else { return false }
            switchingDisplay = true
            return true
        }
        guard claimed else { return }
        while true {
            let (stream, current, cached, wanted) = lock.withLock { (self.stream, currentDisplay, shareableContent, requestedDisplay) }
            guard let stream, let current, let wanted, current.displayID != wanted else { break }
            var content = cached
            if content?.displays.contains(where: { $0.displayID == wanted }) != true {
                content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            }
            guard let content, let display = content.displays.first(where: { $0.displayID == wanted }) else { break }
            let target = CaptureTarget.make(display: display, content: content, maxLongEdge: Self.maxLongEdge, videoSize: (current.videoWidth, current.videoHeight))
            do {
                try await stream.updateContentFilter(target.filter)
            } catch {
                report(.stopped(error))
                break
            }
            let at = sessionTimeNow
            lock.withLock {
                shareableContent = content
                currentDisplay = target.display
                displayHops.append((at, target.display))
            }
        }
        lock.withLock { switchingDisplay = false }
    }

    @concurrent func stop() async {
        let stream = lock.withLock {
            if phase == .starting || phase == .recording { phase = .stopping }
            defer { self.stream = nil }
            return self.stream
        }
        try? await stream?.stopCapture()
        await withCheckedContinuation { continuation in
            closeWriter { continuation.resume() }
        }
    }

    @concurrent func waitForMedia(through time: SessionTime, timeout: Double = maximumFlushWait) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while true {
            let (flushedEnd, stillRecording) = lock.withLock {
                (segmentList.last?.range.end, phase != .idle && phase != .finished)
            }
            if let flushedEnd, flushedEnd >= time { return true }
            if !stillRecording || ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @concurrent func exportClip(from start: SessionTime, to end: SessionTime, padding: Double = 1.0, into destination: URL) async throws -> ExportedClip {
        let wanted = TimeRange(start: max(0, start - padding), end: end + padding)
        _ = await waitForMedia(through: min(wanted.end, sessionTimeNow))
        let (initSegment, recorded) = lock.withLock { (initSegmentURL, segmentList) }
        let overlapping = recorded.filter { $0.overlaps(wanted) }
        guard let initSegment, let first = overlapping.first, let last = overlapping.last else {
            throw ScreenCaptureError.noMedia(from: wanted.start, to: wanted.end)
        }
        let covered = TimeRange(start: max(wanted.start, first.range.start), end: min(wanted.end, last.range.end))
        try await ClipCutter.export(covered, initSegment: initSegment, segments: overlapping, to: destination)
        return ExportedClip(url: destination, range: covered)
    }

    @concurrent func snapshot(at time: SessionTime? = nil) async -> CGImage? {
        let latest = lock.withLock { latestFrame }
        if let time, let latest, latest.time - time > Self.snapshotTolerance, let recorded = await recordedFrame(at: time) {
            return recorded
        }
        guard let latest else { return nil }
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(latest.pixelBuffer, options: nil, imageOut: &image)
        return image
    }

    private func recordedFrame(at time: SessionTime) async -> CGImage? {
        _ = await waitForMedia(through: time + 0.001)
        let (initSegment, recorded) = lock.withLock { (initSegmentURL, segmentList) }
        guard let initSegment, let segment = recorded.first(where: { $0.range.start <= time && time < $0.range.end }) else { return nil }
        return try? await ClipCutter.frame(at: time, initSegment: initSegment, segments: [segment])
    }

    private func sessionTime(ofHostTime hostTime: CMTime) -> CMTime {
        let start = lock.withLock { sessionStartHostTime }
        return CMTimeConvertScale(hostTime - start, timescale: Self.timescale, method: .roundHalfAwayFromZero)
    }

    private func report(_ error: ScreenCaptureError) {
        let handler = lock.withLock { errorHandler }
        handler?(error)
    }

    private func handle(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        let frame = CapturedFrame(pixelBuffer: pixelBuffer, time: time.seconds)
        let firstFrame = lock.withLock {
            latestFrame = frame
            counters.framesCaptured += 1
            defer { if counters.framesCaptured == 1 { firstFrameHandler = nil } }
            return counters.framesCaptured == 1 ? firstFrameHandler : nil
        }
        firstFrame?(ProcessInfo.processInfo.systemUptime)
        guard !writerClosing else { return }
        unsampledFrame = frame
        append(pixelBuffer, at: time, repeated: false)
        sampleVisualChangeIfDue(now: frame.time)
    }

    private func append(_ pixelBuffer: CVPixelBuffer, at time: CMTime, repeated: Bool) {
        guard !writerClosing else { return }
        if writer == nil, !startWriter(at: time) { return }
        guard let writer, let writerInput, let adaptor else { return }
        guard !lastAppendedTime.isValid || time > lastAppendedTime, writerInput.isReadyForMoreMediaData else {
            lock.withLock { counters.framesDropped += 1 }
            return
        }
        if adaptor.append(pixelBuffer, withPresentationTime: time) {
            lastAppendedTime = time
            lock.withLock {
                counters.framesAppended += 1
                if repeated { counters.framesRepeated += 1 }
            }
        } else if writer.status == .failed {
            failWriter(writer.error?.localizedDescription ?? "the video encoder stopped.")
        }
    }

    private func startWriter(at time: CMTime) -> Bool {
        guard let display = lock.withLock({ captureDisplay }) else { return false }
        let writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: Self.segmentInterval, preferredTimescale: Self.timescale)
        writer.initialSegmentStartTime = time
        writer.delegate = self
        let settings = Self.videoSettings(for: display)
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            failWriter("the video settings aren't supported on this Mac.")
            return false
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(input) else {
            failWriter("the video track couldn't be added.")
            return false
        }
        writer.add(input)
        guard writer.startWriting() else {
            failWriter(writer.error?.localizedDescription ?? "the writer didn't start.")
            return false
        }
        writer.startSession(atSourceTime: time)
        self.writer = writer
        self.writerInput = input
        self.adaptor = adaptor
        lock.withLock { firstFrameTime = time.seconds }
        return true
    }

    private static func videoSettings(for display: CaptureDisplay) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: display.videoWidth,
            AVVideoHeightKey: display.videoHeight,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(2_000_000, display.videoWidth * display.videoHeight * 2),
                AVVideoExpectedSourceFrameRateKey: framesPerSecond,
                AVVideoMaxKeyFrameIntervalDurationKey: segmentInterval + 1,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
    }

    private func failWriter(_ reason: String) {
        writerClosing = true
        writerClosed = true
        lock.withLock { phase = .finished }
        report(.writerFailed(reason))
        resumeCloseWaiters()
    }

    private func closeWriter(then completion: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            ticker?.cancel()
            ticker = nil
            if writerClosed {
                completion()
                return
            }
            closeWaiters.append(completion)
            guard !writerClosing else { return }
            writerClosing = true
            unsampledFrame = nil
            guard let writer, writer.status == .writing else {
                finishClosing()
                return
            }
            writerInput?.markAsFinished()
            writer.finishWriting { [self] in
                queue.async { self.finishClosing() }
            }
        }
    }

    private func finishClosing() {
        if let writer, writer.status == .failed {
            report(.writerFailed(writer.error?.localizedDescription ?? "the last segment couldn't be saved."))
        }
        writerClosed = true
        lock.withLock { phase = .finished }
        resumeCloseWaiters()
    }

    private func resumeCloseWaiters() {
        let waiters = closeWaiters
        closeWaiters = []
        waiters.forEach { $0() }
    }

    private func startTicker() {
        guard ticker == nil, !writerClosing else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100), leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        ticker = timer
    }

    private func tick() {
        guard !writerClosing, lastAppendedTime.isValid else { return }
        let now = sessionTime(ofHostTime: CMClockGetTime(CMClockGetHostTimeClock()))
        if (now - lastAppendedTime).seconds >= Self.idleRepeatInterval, let frame = lock.withLock({ latestFrame }) {
            let repeatTime = now - CMTime(seconds: Self.idleRepeatLatencyAllowance, preferredTimescale: Self.timescale)
            append(frame.pixelBuffer, at: repeatTime, repeated: true)
        }
        sampleVisualChangeIfDue(now: now.seconds)
    }

    private func sampleVisualChangeIfDue(now: SessionTime) {
        guard let frame = unsampledFrame else { return }
        if let lastVisualSample, now - lastVisualSample.time < Self.visualSampleInterval { return }
        unsampledFrame = nil
        let began = ContinuousClock.now
        guard let grid = LumaGrid(pixelBuffer: frame.pixelBuffer) else { return }
        let magnitude = lastVisualSample.map { grid.changedFraction(since: $0.grid) }
        lastVisualSample = (frame.time, grid)
        let cost = ContinuousClock.now - began
        let handler = lock.withLock {
            counters.visualSamples += 1
            counters.visualSampleMicroseconds += Double(cost.components.attoseconds) / 1e12 + Double(cost.components.seconds) * 1e6
            return frameDifferenceHandler
        }
        if let magnitude { handler?(frame.time, magnitude) }
    }

    private func storeSegment(_ data: Data, report segmentReport: AVAssetSegmentReport?) {
        let (sequence, previousEnd) = lock.withLock { (segmentList.count + 1, segmentList.last?.range.end ?? firstFrameTime ?? 0) }
        let url = mediaDirectory.appending(path: String(format: "seg-%05d.m4s", sequence))
        let range = Self.range(of: segmentReport) ?? TimeRange(start: previousEnd, end: previousEnd + Self.segmentInterval)
        do {
            try data.write(to: url)
        } catch {
            report(.writerFailed("segment \(sequence) couldn't be saved: \(error.localizedDescription)"))
            return
        }
        let segment = MediaSegment(sequence: sequence, url: url, range: range, byteCount: data.count)
        lock.withLock { segmentList.append(segment) }
    }

    private static func range(of report: AVAssetSegmentReport?) -> TimeRange? {
        guard let track = report?.trackReports.first(where: { $0.mediaType == .video }),
              track.earliestPresentationTimeStamp.isNumeric, track.duration.isNumeric
        else { return nil }
        let start = track.earliestPresentationTimeStamp.seconds
        return TimeRange(start: start, end: start + track.duration.seconds)
    }

    private static func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus)
        else { return false }
        return status == .complete
    }
}

nonisolated extension SegmentedScreenRecorder: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, Self.isComplete(sampleBuffer), let pixelBuffer = sampleBuffer.imageBuffer else { return }
        let time = sessionTime(ofHostTime: sampleBuffer.presentationTimeStamp)
        guard time.seconds >= 0 else { return }
        handle(pixelBuffer, at: time)
    }
}

nonisolated extension SegmentedScreenRecorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        lock.withLock { self.stream = nil }
        report(.stopped(error))
        closeWriter {}
    }
}

nonisolated extension SegmentedScreenRecorder: AVAssetWriterDelegate {
    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data, segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
        switch segmentType {
        case .initialization:
            let url = mediaDirectory.appending(path: "init.mp4")
            do {
                try segmentData.write(to: url)
                lock.withLock { initSegmentURL = url }
            } catch {
                report(.writerFailed("the init segment couldn't be saved: \(error.localizedDescription)"))
            }
        case .separable:
            storeSegment(segmentData, report: segmentReport)
        @unknown default:
            break
        }
    }
}
