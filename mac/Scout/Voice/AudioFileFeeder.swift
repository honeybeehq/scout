@preconcurrency import AVFoundation

nonisolated final class AudioFileFeeder: @unchecked Sendable {
    private var task: Task<Void, Never>?

    func start(
        url: URL,
        convertingTo targetFormat: AVAudioFormat?,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void,
        onFinish: @escaping @Sendable () -> Void
    ) throws {
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        let format = targetFormat ?? sourceFormat
        guard let converter = AVAudioConverter(from: sourceFormat, to: format) else { throw MicrophoneCapture.CaptureError.converterUnavailable }
        let chunkFrames = AVAudioFrameCount(sourceFormat.sampleRate / 10)

        task = Task.detached(priority: .userInitiated) {
            let started = mach_absolute_time()
            var framesRead: AVAudioFramePosition = 0
            while !Task.isCancelled, framesRead < file.length {
                guard let chunk = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: chunkFrames) else { break }
                do { try file.read(into: chunk, frameCount: chunkFrames) } catch { break }
                guard chunk.frameLength > 0 else { break }
                let chunkStart = Double(framesRead) / sourceFormat.sampleRate
                framesRead += AVAudioFramePosition(chunk.frameLength)

                let hostTime = started + AVAudioTime.hostTime(forSeconds: chunkStart)
                let wait = AVAudioTime.seconds(forHostTime: hostTime) - AVAudioTime.seconds(forHostTime: mach_absolute_time())
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }

                onLevel(Self.level(of: chunk))
                if let converted = MicrophoneCapture.convert(chunk, with: converter, to: format) {
                    onBuffer(converted, AVAudioTime(hostTime: hostTime))
                }
            }
            onLevel(0)
            onFinish()
            let silenceFrames = chunkFrames
            var silenceStart = Double(framesRead) / sourceFormat.sampleRate
            while !Task.isCancelled, let silence = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: silenceFrames) {
                silence.frameLength = silenceFrames
                let hostTime = started + AVAudioTime.hostTime(forSeconds: silenceStart)
                let wait = AVAudioTime.seconds(forHostTime: hostTime) - AVAudioTime.seconds(forHostTime: mach_absolute_time())
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                if let converted = MicrophoneCapture.convert(silence, with: converter, to: format) {
                    onBuffer(converted, AVAudioTime(hostTime: hostTime))
                }
                silenceStart += Double(silenceFrames) / sourceFormat.sampleRate
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += channel[index] * channel[index] }
        let decibels = 20 * log10(max(sqrt(sum / Float(buffer.frameLength)), 0.000_01))
        return max(0, min(1, (decibels + 55) / 45))
    }
}
