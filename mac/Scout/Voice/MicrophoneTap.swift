@preconcurrency import AVFoundation
import ObjectiveC
import Synchronization

nonisolated final class MicrophoneTap: @unchecked Sendable {
    struct Delivery: Sendable {
        var peak: Float
        var mode: String
        var switches: Int
        var slowCalls: Int
        var dropped: Int
    }

    static let pollInterval: Double = 0.01
    static let window: Double = 0.5
    static let enterMargin: Double = 12
    static let leaveMargin: Double = 6
    static let floor: Double = -50

    let received = Atomic<Int>(0)
    let dropped = Atomic<Int>(0)
    let slowCalls = Atomic<Int>(0)

    private struct Entry {
        var start = 0
        var frames = 0
        var hostTime: UInt64 = 0
        var hostTimeValid = false
        var sampleTime: Int64 = 0
    }

    private struct Getters {
        typealias ChannelData = @convention(c) (AnyObject, Selector) -> UnsafePointer<UnsafeMutablePointer<Float>>?
        typealias Frames = @convention(c) (AnyObject, Selector) -> AVAudioFrameCount
        typealias HostTime = @convention(c) (AnyObject, Selector) -> UInt64
        typealias Valid = @convention(c) (AnyObject, Selector) -> Bool
        typealias SampleTime = @convention(c) (AnyObject, Selector) -> AVAudioFramePosition

        static let channelDataSelector = Selector(("floatChannelData"))
        static let framesSelector = Selector(("frameLength"))
        static let hostTimeSelector = Selector(("hostTime"))
        static let validSelector = Selector(("isHostTimeValid"))
        static let sampleTimeSelector = Selector(("sampleTime"))

        let buffer: ObjectIdentifier
        let time: ObjectIdentifier
        let channelData: ChannelData
        let frames: Frames
        let hostTime: HostTime
        let valid: Valid
        let sampleTime: SampleTime

        init?() {
            let bufferClass: AnyClass = AVAudioPCMBuffer.self
            let timeClass: AnyClass = AVAudioTime.self
            guard let channelData = class_getMethodImplementation(bufferClass, Self.channelDataSelector),
                  let frames = class_getMethodImplementation(bufferClass, Self.framesSelector),
                  let hostTime = class_getMethodImplementation(timeClass, Self.hostTimeSelector),
                  let valid = class_getMethodImplementation(timeClass, Self.validSelector),
                  let sampleTime = class_getMethodImplementation(timeClass, Self.sampleTimeSelector)
            else { return nil }
            buffer = ObjectIdentifier(bufferClass)
            time = ObjectIdentifier(timeClass)
            self.channelData = unsafeBitCast(channelData, to: ChannelData.self)
            self.frames = unsafeBitCast(frames, to: Frames.self)
            self.hostTime = unsafeBitCast(hostTime, to: HostTime.self)
            self.valid = unsafeBitCast(valid, to: Valid.self)
            self.sampleTime = unsafeBitCast(sampleTime, to: SampleTime.self)
        }
    }

    private let getters = Getters()
    private let channels: Int
    private let rate: Double
    private let capacity: Int
    private let mask: Int
    private let entryCapacity = 1024
    private let samples: UnsafeMutablePointer<Float>
    private let entries: UnsafeMutablePointer<Entry>
    private let entryWrite = Atomic<Int>(0)
    private let entryRead = Atomic<Int>(0)
    private let sampleRead = Atomic<Int>(0)
    private var sampleWrite = 0

    private let processing = DispatchQueue(label: "scout.microphone.tap", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private let mono: AVAudioFormat
    private let target: AVAudioFormat?
    private let converter: AVAudioConverter?
    private let onBuffer: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    private let onLevel: @Sendable (Float) -> Void
    private let onDelivery: @Sendable (Delivery) -> Void
    private var power: [Double]
    private var selected: Int?
    private var candidate: Int?
    private var held: Double = 0
    private var switches = 0
    private var smoothedLevel: Float = 0

    init(
        format: AVAudioFormat,
        convertingTo target: AVAudioFormat?,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void,
        onDelivery: @escaping @Sendable (Delivery) -> Void
    ) throws {
        channels = Int(format.channelCount)
        rate = format.sampleRate
        guard channels > 0, rate > 0, let mono = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else {
            throw MicrophoneCapture.CaptureError.unusableFormat
        }
        self.mono = mono
        if let target, target != mono {
            guard let made = AVAudioConverter(from: mono, to: target) else { throw MicrophoneCapture.CaptureError.converterUnavailable }
            converter = made
            self.target = target
        } else {
            converter = nil
            self.target = nil
        }
        var size = 1
        while size < Int(rate * 2) { size <<= 1 }
        capacity = size
        mask = size - 1
        samples = .allocate(capacity: channels * size)
        samples.initialize(repeating: 0, count: channels * size)
        entries = .allocate(capacity: entryCapacity)
        entries.initialize(repeating: Entry(), count: entryCapacity)
        power = Array(repeating: 0, count: channels)
        self.onBuffer = onBuffer
        self.onLevel = onLevel
        self.onDelivery = onDelivery
    }

    deinit {
        timer?.cancel()
        samples.deallocate()
        entries.deallocate()
    }

    var block: AVAudioNodeTapBlock {
        { [self] buffer, time in write(buffer, time) }
    }

    @inline(never)
    func write(_ buffer: AVAudioPCMBuffer, _ time: AVAudioTime) {
        let data: UnsafePointer<UnsafeMutablePointer<Float>>?
        let length: AVAudioFrameCount
        let hostTime: UInt64
        let valid: Bool
        let sampleTime: AVAudioFramePosition
        if let getters, object_getClass(buffer).map(ObjectIdentifier.init) == getters.buffer, object_getClass(time).map(ObjectIdentifier.init) == getters.time {
            data = getters.channelData(buffer, Getters.channelDataSelector)
            length = getters.frames(buffer, Getters.framesSelector)
            hostTime = getters.hostTime(time, Getters.hostTimeSelector)
            valid = getters.valid(time, Getters.validSelector)
            sampleTime = getters.sampleTime(time, Getters.sampleTimeSelector)
        } else {
            slowCalls.wrappingAdd(1, ordering: .relaxed)
            data = buffer.floatChannelData
            length = buffer.frameLength
            hostTime = time.hostTime
            valid = time.isHostTimeValid
            sampleTime = time.sampleTime
        }
        guard let data else {
            dropped.wrappingAdd(1, ordering: .relaxed)
            return
        }
        let frames = Int(length)
        let index = entryWrite.load(ordering: .relaxed)
        guard frames > 0, frames <= capacity,
              index - entryRead.load(ordering: .acquiring) < entryCapacity,
              sampleWrite + frames - sampleRead.load(ordering: .acquiring) <= capacity
        else {
            dropped.wrappingAdd(1, ordering: .relaxed)
            return
        }
        let offset = sampleWrite & mask
        let first = min(frames, capacity - offset)
        for channel in 0..<channels {
            let ring = samples + channel * capacity
            (ring + offset).update(from: data[channel], count: first)
            if first < frames { ring.update(from: data[channel] + first, count: frames - first) }
        }
        entries[index & (entryCapacity - 1)] = Entry(start: sampleWrite, frames: frames, hostTime: hostTime, hostTimeValid: valid, sampleTime: sampleTime)
        sampleWrite += frames
        received.wrappingAdd(1, ordering: .relaxed)
        entryWrite.store(index + 1, ordering: .releasing)
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: processing)
        timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.drain() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        processing.sync {
            timer?.cancel()
            timer = nil
            drain()
        }
    }

    private func drain() {
        var read = entryRead.load(ordering: .relaxed)
        let written = entryWrite.load(ordering: .acquiring)
        while read < written {
            let entry = entries[read & (entryCapacity - 1)]
            let delivery = deliver(entry)
            sampleRead.store(entry.start + entry.frames, ordering: .releasing)
            read += 1
            entryRead.store(read, ordering: .releasing)
            if let delivery { onDelivery(delivery) }
        }
    }

    private func deliver(_ entry: Entry) -> Delivery? {
        guard let output = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: AVAudioFrameCount(entry.frames)),
              let out = output.floatChannelData?[0]
        else { return nil }
        output.frameLength = AVAudioFrameCount(entry.frames)
        let offset = entry.start & mask
        func sample(_ channel: Int, _ frame: Int) -> Float {
            samples[channel * capacity + ((offset + frame) & mask)]
        }
        var peak: Float = 0
        let decay = exp(-Double(entry.frames) / (rate * Self.window))
        for channel in 0..<channels {
            var sum: Double = 0
            for frame in 0..<entry.frames {
                let value = sample(channel, frame)
                sum += Double(value * value)
                peak = max(peak, abs(value))
            }
            power[channel] = power[channel] * decay + (sum / Double(entry.frames)) * (1 - decay)
        }
        choose(after: Double(entry.frames) / rate)
        if let selected {
            for frame in 0..<entry.frames { out[frame] = sample(selected, frame) }
        } else {
            let scale = 1 / Float(channels)
            for frame in 0..<entry.frames {
                var sum: Float = 0
                for channel in 0..<channels { sum += sample(channel, frame) }
                out[frame] = sum * scale
            }
        }
        onLevel(measureLevel(output))
        let time = entry.hostTimeValid ? AVAudioTime(hostTime: entry.hostTime) : AVAudioTime(sampleTime: entry.sampleTime, atRate: rate)
        if let converter, let target {
            if let converted = MicrophoneCapture.convert(output, with: converter, to: target) { onBuffer(converted, time) }
        } else {
            onBuffer(output, time)
        }
        return Delivery(peak: peak, mode: mode, switches: switches, slowCalls: slowCalls.load(ordering: .relaxed), dropped: dropped.load(ordering: .relaxed))
    }

    var mode: String {
        if channels == 1 { return "mono" }
        return selected.map { "channel \($0 + 1)" } ?? "downmix"
    }

    private func choose(after seconds: Double) {
        guard channels > 1 else { return }
        let decibels = power.map { 10 * log10(max($0, 1e-12)) }
        let loudest = decibels.indices.max { decibels[$0] < decibels[$1] } ?? 0
        let margin = decibels.indices.filter { $0 != loudest }.map { decibels[loudest] - decibels[$0] }.min() ?? 0
        guard decibels[loudest] >= Self.floor else {
            candidate = nil
            held = 0
            return
        }
        if let current = selected {
            let others = decibels.indices.filter { $0 != current }.map { decibels[current] - decibels[$0] }.min() ?? 0
            if others < Self.leaveMargin {
                held += seconds
                if held >= Self.window {
                    selected = nil
                    held = 0
                    switches += 1
                }
            } else {
                held = 0
            }
        } else if margin >= Self.enterMargin {
            if candidate == loudest {
                held += seconds
            } else {
                candidate = loudest
                held = seconds
            }
            if held >= Self.window {
                selected = loudest
                candidate = nil
                held = 0
                switches += 1
            }
        } else {
            candidate = nil
            held = 0
        }
    }

    private func measureLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) {
            sum += channel[index] * channel[index]
        }
        let rms = sqrt(sum / Float(buffer.frameLength))
        let decibels = 20 * log10(max(rms, 0.000_01))
        let normalized = max(0, min(1, (decibels + 55) / 45))
        smoothedLevel = normalized > smoothedLevel ? normalized : smoothedLevel * 0.82 + normalized * 0.18
        return smoothedLevel
    }
}
