@preconcurrency import AVFoundation
import Speech
import Synchronization

nonisolated protocol MicrophoneDevice: AnyObject, Sendable {
    var name: String? { get }
    var hasInput: Bool { get }
    func hardwareFormat() throws -> AVAudioFormat
    func installTap(bufferSize: AVAudioFrameCount, format: AVAudioFormat, block: @escaping AVAudioNodeTapBlock) throws
    func start() throws
    func stop()
    func observeConfigurationChanges(_ handler: @escaping @Sendable () -> Void)
}

nonisolated final class MicrophoneCapture: @unchecked Sendable {
    enum CaptureError: LocalizedError {
        case noInputDevice
        case unusableFormat
        case converterUnavailable
        case audioEngine(String)
        case stopped(String)
        case silentTap
        case noAudio(String)

        var errorDescription: String? {
            switch self {
            case .noInputDevice: "No microphone is available."
            case .unusableFormat: "The microphone couldn't start (its input format isn't usable)."
            case .converterUnavailable: "The microphone format isn't supported."
            case .audioEngine(let reason): "The microphone couldn't start: \(reason)"
            case .stopped(let reason): "The microphone stopped after an audio device change: \(reason)"
            case .silentTap: "The microphone started but sent no audio."
            case .noAudio(let reason): "No audio captured: \(reason)"
            }
        }

        var reason: String {
            switch self {
            case .stopped(let reason), .noAudio(let reason): reason
            default: errorDescription ?? "unknown error"
            }
        }
    }

    struct Summary: Sendable, Equatable {
        var device: String?
        var sampleRate: Double?
        var channels: Int?
        var buffers = 0
        var peakDecibels: Double?
        var restarts = 0
        var retries = 0
        var channelMode: String?
        var channelSwitches = 0
        var tapSlowCalls = 0
        var tapDropped = 0
    }

    static let retryDelays: [Double] = [0.1, 0.2, 0.4, 0.6, 0.7]
    static let firstBufferWait: Double = 1.0
    static let bufferSize: AVAudioFrameCount = 2048

    private let makeDevice: @Sendable () -> any MicrophoneDevice
    private let queue = DispatchQueue(label: "scout.microphone")
    private let lock = NSLock()
    private var device: (any MicrophoneDevice)?
    private var tap: MicrophoneTap?
    private var generation = 0
    private var running = false
    private var failedTries = 0
    private var lastError: Error?
    private var stats = Summary()
    private var peak: Float = 0
    private var flowing = false
    private var deliveredSwitches = 0
    private var targetFormat: AVAudioFormat?
    private var onBuffer: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
    private var onLevel: (@Sendable (Float) -> Void)?
    private var onFailure: (@Sendable (Error) -> Void)?

    let isSimulated: Bool

    init(simulated: Bool = false, device makeDevice: @escaping @Sendable () -> any MicrophoneDevice = { EngineMicrophone() }) {
        self.makeDevice = makeDevice
        isSimulated = simulated
    }

    var inputName: String? {
        AVCaptureDevice.default(for: .audio)?.localizedName
    }

    var summary: Summary {
        lock.withLock {
            var summary = stats
            summary.peakDecibels = stats.buffers > 0 ? Double(20 * log10(max(peak, 0.000_01))).rounded() : nil
            return summary
        }
    }

    func start(
        convertingTo targetFormat: AVAudioFormat?,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void,
        onFailure: @escaping @Sendable (Error) -> Void
    ) throws {
        try queue.sync {
            self.targetFormat = targetFormat
            self.onBuffer = onBuffer
            self.onLevel = onLevel
            self.onFailure = onFailure
            running = true
            failedTries = 0
            lock.withLock {
                stats = Summary()
                peak = 0
            }
            do {
                try install()
            } catch CaptureError.noInputDevice {
                running = false
                teardown()
                throw CaptureError.noInputDevice
            } catch {
                retry(after: error)
            }
        }
    }

    func stop() {
        queue.sync {
            running = false
            advance()
            teardown()
            onBuffer = nil
            onLevel = nil
            onFailure = nil
        }
    }

    private func install() throws {
        teardown()
        let current = advance()
        let device = makeDevice()
        self.device = device
        device.observeConfigurationChanges { [weak self] in
            guard let self else { return }
            queue.async { self.configurationChanged(current) }
        }
        lock.withLock { stats.device = device.name ?? stats.device }
        guard device.hasInput else { throw CaptureError.noInputDevice }
        let hardware = try device.hardwareFormat()
        guard hardware.sampleRate > 0, hardware.channelCount > 0, let format = Self.floatFormat(sampleRate: hardware.sampleRate, channels: hardware.channelCount) else { throw CaptureError.unusableFormat }
        lock.withLock {
            stats.sampleRate = hardware.sampleRate
            stats.channels = Int(hardware.channelCount)
        }
        guard let onBuffer, let onLevel else { return }
        let tap = try MicrophoneTap(format: format, convertingTo: targetFormat, onBuffer: onBuffer, onLevel: onLevel) { [weak self] delivery in
            self?.delivered(delivery, generation: current)
        }
        self.tap = tap
        try device.installTap(bufferSize: Self.bufferSize, format: format, block: tap.block)
        try device.start()
        tap.start()
        queue.asyncAfter(deadline: .now() + Self.firstBufferWait) { [weak self] in
            guard let self, running, current == generation, tap.received.load(ordering: .relaxed) == 0 else { return }
            retry(after: CaptureError.silentTap)
        }
    }

    static func floatFormat(sampleRate: Double, channels: AVAudioChannelCount) -> AVAudioFormat? {
        if let standard = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels) { return standard }
        guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)) else { return nil }
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, interleaved: false, channelLayout: layout)
    }

    private func delivered(_ delivery: MicrophoneTap.Delivery, generation current: Int) {
        let first = lock.withLock {
            stats.buffers += 1
            peak = max(peak, delivery.peak)
            stats.tapSlowCalls = max(stats.tapSlowCalls, delivery.slowCalls)
            stats.tapDropped = max(stats.tapDropped, delivery.dropped)
            guard current == generation else { return false }
            stats.channelMode = delivery.mode
            stats.channelSwitches += delivery.switches - deliveredSwitches
            deliveredSwitches = delivery.switches
            guard !flowing else { return false }
            flowing = true
            return true
        }
        if first {
            queue.async { [weak self] in
                guard let self, current == generation else { return }
                failedTries = 0
            }
        }
    }

    private func configurationChanged(_ current: Int) {
        guard running, current == generation else { return }
        lock.withLock { stats.restarts += 1 }
        let silent = (tap?.received.load(ordering: .relaxed) ?? 0) == 0
        if silent {
            retry(after: lastError ?? CaptureError.silentTap)
        } else {
            failedTries = 0
            reinstall(after: Self.retryDelays[0])
        }
    }

    private func retry(after error: Error) {
        guard running else { return }
        lastError = error
        teardown()
        guard failedTries < Self.retryDelays.count else {
            give(up: error)
            return
        }
        let delay = Self.retryDelays[failedTries]
        failedTries += 1
        lock.withLock { stats.retries += 1 }
        reinstall(after: delay)
    }

    @discardableResult
    private func advance() -> Int {
        lock.withLock {
            generation += 1
            flowing = false
            deliveredSwitches = 0
            return generation
        }
    }

    private func reinstall(after delay: Double) {
        teardown()
        let current = advance()
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, running, current == generation else { return }
            do {
                try install()
            } catch {
                retry(after: error)
            }
        }
    }

    private func give(up error: Error) {
        running = false
        advance()
        let summary = summary
        let reason = Self.describe(error, tries: Self.retryDelays.count + 1, device: summary.device)
        let failure: CaptureError = summary.buffers == 0 ? .noAudio(reason) : .stopped(reason)
        let onFailure = onFailure
        self.onFailure = nil
        onFailure?(failure)
    }

    private static func describe(_ error: Error, tries: Int, device: String?) -> String {
        let source = device ?? "the microphone"
        let why: String = switch error {
        case CaptureError.silentTap: "\(source) sent no sound"
        case CaptureError.noInputDevice: "no microphone is available"
        case CaptureError.unusableFormat: "\(source) couldn't start (its input format isn't usable)"
        case CaptureError.converterUnavailable: "\(source) couldn't start (its format isn't supported)"
        case CaptureError.audioEngine(let reason): "\(source) couldn't start (\(reason))"
        default: "\(source) couldn't start (\(error.localizedDescription))"
        }
        return "\(why), after \(tries) tries"
    }

    private func teardown() {
        device?.stop()
        device = nil
        tap?.stop()
        tap = nil
    }

    static func guarding(_ body: () throws -> Void) throws {
        var error: NSError?
        var thrown: Error?
        guard ScoutCatchObjCException({
            do { try body() } catch { thrown = error }
        }, &error) else {
            throw CaptureError.audioEngine(error?.localizedDescription ?? "unknown error")
        }
        if let thrown { throw thrown }
    }

    static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }
}

nonisolated final class EngineMicrophone: MicrophoneDevice, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var observer: NSObjectProtocol?

    var name: String? {
        AVCaptureDevice.default(for: .audio)?.localizedName
    }

    var hasInput: Bool {
        AVCaptureDevice.default(for: .audio) != nil
    }

    func hardwareFormat() throws -> AVAudioFormat {
        var format: AVAudioFormat?
        try MicrophoneCapture.guarding { format = engine.inputNode.inputFormat(forBus: 0) }
        guard let format else { throw MicrophoneCapture.CaptureError.unusableFormat }
        return format
    }

    func installTap(bufferSize: AVAudioFrameCount, format: AVAudioFormat, block: @escaping AVAudioNodeTapBlock) throws {
        try MicrophoneCapture.guarding {
            engine.inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format, block: block)
            engine.prepare()
        }
    }

    func start() throws {
        try MicrophoneCapture.guarding { try engine.start() }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        try? MicrophoneCapture.guarding {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }

    func observeConfigurationChanges(_ handler: @escaping @Sendable () -> Void) {
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in handler() }
    }
}
