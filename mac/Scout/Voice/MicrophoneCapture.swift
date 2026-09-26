@preconcurrency import AVFoundation
import Speech

nonisolated final class MicrophoneCapture: @unchecked Sendable {
    enum CaptureError: LocalizedError {
        case noInputDevice
        case converterUnavailable

        var errorDescription: String? {
            switch self {
            case .noInputDevice: "No microphone is available."
            case .converterUnavailable: "The microphone format isn't supported."
            }
        }
    }

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var smoothedLevel: Float = 0
    private var configurationObserver: NSObjectProtocol?
    private var restart: (() -> Void)?

    var inputName: String? {
        AVCaptureDevice.default(for: .audio)?.localizedName
    }

    func start(
        convertingTo targetFormat: AVAudioFormat?,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void
    ) throws {
        try install(convertingTo: targetFormat, onBuffer: onBuffer, onLevel: onLevel)
        restart = { [weak self] in
            guard let self else { return }
            self.engine.inputNode.removeTap(onBus: 0)
            try? self.install(convertingTo: targetFormat, onBuffer: onBuffer, onLevel: onLevel)
        }
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.restart?()
        }
    }

    private func install(
        convertingTo targetFormat: AVAudioFormat?,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void
    ) throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw CaptureError.noInputDevice }

        let converter: AVAudioConverter?
        if let targetFormat, targetFormat != inputFormat {
            guard let made = AVAudioConverter(from: inputFormat, to: targetFormat) else { throw CaptureError.converterUnavailable }
            converter = made
        } else {
            converter = nil
        }

        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, time in
            guard let self else { return }
            onLevel(self.measureLevel(buffer))
            if let converter, let targetFormat {
                if let converted = Self.convert(buffer, with: converter, to: targetFormat) {
                    onBuffer(converted, time)
                }
            } else {
                onBuffer(buffer, time)
            }
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        restart = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
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
        lock.lock()
        smoothedLevel = normalized > smoothedLevel ? normalized : smoothedLevel * 0.82 + normalized * 0.18
        let level = smoothedLevel
        lock.unlock()
        return level
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
