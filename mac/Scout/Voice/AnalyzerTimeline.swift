@preconcurrency import AVFoundation
import Speech

nonisolated final class AnalyzerTimeline: @unchecked Sendable {
    static let gapTolerance: Double = 0.25
    static let longestFill: Double = 30

    private let clock: SessionClock
    private let lock = NSLock()
    private var nextSample: Int64?

    init(clock: SessionClock) {
        self.clock = clock
    }

    func inputs(for buffer: AVAudioPCMBuffer, at time: AVAudioTime) -> [AnalyzerInput] {
        let rate = buffer.format.sampleRate
        let stamped = max(0, Int64((clock.seconds(atHostTime: time.hostTime) * rate).rounded()))
        lock.lock()
        defer { lock.unlock() }
        var inputs: [AnalyzerInput] = []
        var start = stamped
        if let nextSample {
            let gap = stamped - nextSample
            if gap < Int64(Self.gapTolerance * rate) {
                start = nextSample
            } else if gap <= Int64(Self.longestFill * rate), let silence = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(gap)) {
                silence.frameLength = silence.frameCapacity
                for channel in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
                    if let data = channel.mData { memset(data, 0, Int(channel.mDataByteSize)) }
                }
                inputs.append(AnalyzerInput(buffer: silence, bufferStartTime: Self.time(nextSample, rate)))
            }
        }
        inputs.append(AnalyzerInput(buffer: buffer, bufferStartTime: Self.time(start, rate)))
        nextSample = start + Int64(buffer.frameLength)
        return inputs
    }

    private static func time(_ sample: Int64, _ rate: Double) -> CMTime {
        CMTime(value: sample, timescale: CMTimeScale(rate))
    }
}

nonisolated final class AnalyzerFault: @unchecked Sendable {
    private let after: Double
    private let lock = NSLock()
    private var delivered: Double = 0
    private var fired = false

    init(after: Double) {
        self.after = after
    }

    func input(after buffer: AVAudioPCMBuffer) -> AnalyzerInput? {
        lock.lock()
        defer { lock.unlock() }
        delivered += Double(buffer.frameLength) / buffer.format.sampleRate
        guard !fired, delivered >= after else { return nil }
        fired = true
        return AnalyzerInput(buffer: buffer, bufferStartTime: .zero)
    }
}

nonisolated final class SoundMeter: @unchecked Sendable {
    static let window: Double = 0.02
    static let threshold: Float = -37
    static let shortestRun: Double = 0.2
    static let needed: Double = 1.0

    private let lock = NSLock()
    private var run: Double = 0
    private var sustained: Double = 0

    var heardSound: Bool { lock.withLock { sustained + (run >= Self.shortestRun ? run : 0) >= Self.needed } }
    var seconds: Double { lock.withLock { sustained + (run >= Self.shortestRun ? run : 0) } }

    func measure(_ buffer: AVAudioPCMBuffer) {
        let rate = buffer.format.sampleRate
        let frames = Int(buffer.frameLength)
        let size = max(1, Int(rate * Self.window))
        guard frames > 0, rate > 0 else { return }
        var loud: [Bool] = []
        var start = 0
        while start < frames {
            let count = min(size, frames - start)
            var sum: Float = 0
            if let channel = buffer.floatChannelData?[0] {
                for index in start..<(start + count) { sum += channel[index] * channel[index] }
            } else if let channel = buffer.int16ChannelData?[0] {
                for index in start..<(start + count) {
                    let value = Float(channel[index]) / Float(Int16.max)
                    sum += value * value
                }
            }
            loud.append(20 * log10(max(sqrt(sum / Float(count)), 0.000_01)) >= Self.threshold)
            start += count
        }
        let step = Double(size) / rate
        lock.withLock {
            for isLoud in loud {
                if isLoud {
                    run += step
                } else {
                    if run >= Self.shortestRun { sustained += run }
                    run = 0
                }
            }
        }
    }
}
