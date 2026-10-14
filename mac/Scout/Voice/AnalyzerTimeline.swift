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
