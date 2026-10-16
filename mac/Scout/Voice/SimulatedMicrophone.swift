@preconcurrency import AVFoundation

nonisolated final class SimulatedRoute: @unchecked Sendable {
    enum Scenario: String, CaseIterable, Sendable {
        case steady
        case bluetooth
        case dead
        case fails
        case silent
        case stops
        case interface
        case quad
        case duo
    }

    let scenario: Scenario
    var name: String {
        switch scenario {
        case .interface: "MOTU 8-channel (simulated)"
        case .quad, .duo: "RODE 4-channel (simulated)"
        default: "AirPods Max (simulated)"
        }
    }

    var channels: AVAudioChannelCount {
        switch scenario {
        case .interface: 8
        case .quad, .duo: 4
        default: 1
        }
    }

    var speechGains: [Int: Float] {
        switch scenario {
        case .quad: [2: 1]
        case .duo: [0: 1, 2: 0.7]
        default: [0: 1]
        }
    }
    private let lock = NSLock()
    private let speech: [Double: AVAudioPCMBuffer]
    private let duration: Double
    private var rate: Double
    private var origin: UInt64?
    private var installs = 0
    private var finished = false
    private let onFinish: @Sendable () -> Void
    private(set) var log: [String] = []

    init(scenario: Scenario, audio: URL, onFinish: @escaping @Sendable () -> Void = {}) throws {
        self.scenario = scenario
        self.onFinish = onFinish
        let file = try AVAudioFile(forReading: audio)
        var speech: [Double: AVAudioPCMBuffer] = [:]
        for rate in [24_000.0, 48_000.0] {
            speech[rate] = try Self.read(file, at: rate)
        }
        self.speech = speech
        duration = Double(file.length) / file.processingFormat.sampleRate
        rate = [.bluetooth, .interface, .quad, .duo].contains(scenario) ? 48_000 : 24_000
    }

    func makeDevice() -> any MicrophoneDevice {
        SimulatedMicrophone(route: self)
    }

    var hardwareRate: Double { lock.withLock { rate } }

    func note(_ line: String) {
        let at = lock.withLock { origin.map { AVAudioTime.seconds(forHostTime: mach_absolute_time() - $0) } ?? 0 }
        lock.withLock { log.append(String(format: "%6.3f %@", at, line)) }
    }

    fileprivate func installed() -> Int {
        lock.withLock {
            installs += 1
            return installs
        }
    }

    fileprivate func started() {
        let first = lock.withLock {
            guard origin == nil else { return false }
            origin = mach_absolute_time()
            return true
        }
        guard first else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self else { return }
            let call = lock.withLock {
                guard !finished else { return false }
                finished = true
                return true
            }
            if call { onFinish() }
        }
    }

    fileprivate func switchRoute(to newRate: Double) {
        lock.withLock { rate = newRate }
    }

    fileprivate func chunk(from start: AVAudioFramePosition, frames: AVAudioFrameCount, rate: Double) -> (AVAudioPCMBuffer, AVAudioTime)? {
        guard let origin = lock.withLock({ origin }),
              let source = speech[rate],
              let format = MicrophoneCapture.floatFormat(sampleRate: rate, channels: channels),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { return nil }
        buffer.frameLength = frames
        let input = source.floatChannelData![0]
        let gains = speechGains
        for channel in 0..<Int(channels) {
            let output = buffer.floatChannelData![channel]
            let gain = gains[channel]
            for index in 0..<Int(frames) {
                let position = Int(start) + index
                let quiet = Float.random(in: -0.000_3...0.000_3)
                if let gain, scenario != .silent, position < Int(source.frameLength) {
                    output[index] = input[position] * gain
                } else {
                    output[index] = quiet
                }
            }
        }
        let hostTime = origin + AVAudioTime.hostTime(forSeconds: Double(start) / rate)
        return (buffer, AVAudioTime(hostTime: hostTime, sampleTime: start, atRate: rate))
    }

    fileprivate func position(rate: Double) -> AVAudioFramePosition {
        guard let origin = lock.withLock({ origin }) else { return 0 }
        return AVAudioFramePosition(AVAudioTime.seconds(forHostTime: mach_absolute_time() - origin) * rate)
    }

    private static func read(_ file: AVAudioFile, at rate: Double) throws -> AVAudioPCMBuffer {
        file.framePosition = 0
        let source = file.processingFormat
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(file.length)),
              let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let converter = AVAudioConverter(from: source, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(file.length) * rate / source.sampleRate) + 1024)
        else { throw MicrophoneCapture.CaptureError.converterUnavailable }
        try file.read(into: input)
        nonisolated(unsafe) var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return output
    }
}

nonisolated final class SimulatedMicrophone: MicrophoneDevice, @unchecked Sendable {
    private let route: SimulatedRoute
    private let lock = NSLock()
    private var install = 0
    private var tap: (format: AVAudioFormat, frames: AVAudioFrameCount, block: AVAudioNodeTapBlock)?
    private var feeder: Task<Void, Never>?
    private var onChange: (@Sendable () -> Void)?

    init(route: SimulatedRoute) {
        self.route = route
    }

    var name: String? { route.name }
    var hasInput: Bool { true }

    func hardwareFormat() throws -> AVAudioFormat {
        MicrophoneCapture.floatFormat(sampleRate: route.hardwareRate, channels: route.channels)!
    }

    func installTap(bufferSize: AVAudioFrameCount, format: AVAudioFormat, block: @escaping AVAudioNodeTapBlock) throws {
        route.started()
        let install = route.installed()
        lock.withLock { self.install = install }
        let scenario = route.scenario
        let pending = (scenario == .bluetooth && install == 2) || scenario == .fails || (scenario == .stops && install > 1)
        try MicrophoneCapture.guarding {
            if pending {
                route.note("install \(install): tap at \(Int(format.sampleRate)) Hz raises: config change pending")
                NSException(name: .internalInconsistencyException, reason: "Failed to create tap, config change pending!", userInfo: nil).raise()
            }
            if format.sampleRate != route.hardwareRate {
                NSException(name: .internalInconsistencyException, reason: "Format mismatch: input hw \(Int(route.hardwareRate)) Hz, client format \(Int(format.sampleRate)) Hz", userInfo: nil).raise()
            }
        }
        route.note("install \(install): tap at \(Int(format.sampleRate)) Hz, \(format.channelCount) ch")
        lock.withLock { tap = (format, bufferSize, block) }
    }

    func start() throws {
        route.started()
        let (install, tap) = lock.withLock { (self.install, self.tap) }
        guard let tap else { return }
        let scenario = route.scenario
        route.note("install \(install): engine started")
        if scenario == .dead || (scenario == .bluetooth && install == 1) {
            if scenario == .bluetooth {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { [weak self, route] in
                    route.switchRoute(to: 24_000)
                    route.note("route switched to HFP: hardware now 24000 Hz mono; configuration change posted")
                    self?.lock.withLock { self?.onChange }?()
                }
            }
            return
        }
        if scenario == .stops {
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) { [weak self, route] in
                route.note("device unplugged: configuration change posted")
                self?.lock.withLock { self?.onChange }?()
            }
        }
        let rate = tap.format.sampleRate
        let frames = tap.frames
        feeder = Task.detached(priority: .userInitiated) { [route] in
            var next = route.position(rate: rate)
            while !Task.isCancelled {
                let due = Double(Int64(next) + Int64(frames) - Int64(route.position(rate: rate))) / rate
                if due > 0 { try? await Task.sleep(for: .seconds(due)) }
                guard !Task.isCancelled, let (buffer, time) = route.chunk(from: next, frames: frames, rate: rate) else { break }
                tap.block(buffer, time)
                next += AVAudioFramePosition(frames)
            }
        }
    }

    func stop() {
        feeder?.cancel()
        feeder = nil
        lock.withLock {
            tap = nil
            onChange = nil
        }
    }

    func observeConfigurationChanges(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { onChange = handler }
    }
}
