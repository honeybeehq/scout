@preconcurrency import AVFoundation

nonisolated final class SessionAudioWriter: @unchecked Sendable {
    static let fileName = "audio.wav"
    static let sampleRate: Double = 16_000
    static let headerSize = 44
    static let headerRefreshFrames: Int64 = Int64(sampleRate * 2)
    static let gapTolerance: Double = 0.25

    static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!

    let url: URL
    private let clock: SessionClock
    private let queue = DispatchQueue(label: "scout.session-audio", qos: .utility)
    private var handle: FileHandle?
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private var framesWritten: Int64 = 0
    private var framesAtLastHeader: Int64 = 0
    private var closed = false

    init(url: URL, clock: SessionClock) {
        self.url = url
        self.clock = clock
        queue.async { [self] in open() }
    }

    var seconds: Double {
        queue.sync { Double(framesWritten) / Self.sampleRate }
    }

    func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        guard time.isHostTimeValid else { return }
        let start = clock.seconds(atHostTime: time.hostTime)
        queue.async { [self] in write(buffer, startingAt: start) }
    }

    func close() {
        queue.sync {
            guard !closed else { return }
            closed = true
            refreshHeader()
            try? handle?.close()
            handle = nil
        }
    }

    private func open() {
        FileManager.default.createFile(atPath: url.path, contents: Self.header(dataBytes: 0))
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    private func write(_ buffer: AVAudioPCMBuffer, startingAt start: Double) {
        guard !closed, let handle, let converted = convert(buffer) else { return }
        let target = Int64((max(0, start) * Self.sampleRate).rounded())
        let gap = target - framesWritten
        if gap > Int64(Self.gapTolerance * Self.sampleRate) {
            try? handle.write(contentsOf: Data(count: Int(gap) * 2))
            framesWritten += gap
        }
        let frames = Int(converted.frameLength)
        guard frames > 0, let samples = converted.int16ChannelData?[0] else { return }
        try? handle.write(contentsOf: Data(bytes: samples, count: frames * 2))
        framesWritten += Int64(frames)
        if framesWritten - framesAtLastHeader >= Self.headerRefreshFrames { refreshHeader() }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == Self.format { return buffer }
        if converterInput != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: Self.format)
            converterInput = buffer.format
        }
        guard let converter else { return nil }
        return MicrophoneCapture.convert(buffer, with: converter, to: Self.format)
    }

    private func refreshHeader() {
        guard let handle else { return }
        let end = (try? handle.offset()) ?? UInt64(Self.headerSize)
        try? handle.seek(toOffset: 0)
        try? handle.write(contentsOf: Self.header(dataBytes: UInt32(clamping: framesWritten * 2)))
        try? handle.seek(toOffset: end)
        try? handle.synchronize()
        framesAtLastHeader = framesWritten
    }

    static func header(dataBytes: UInt32) -> Data {
        var data = Data()
        func put(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func put(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8))
        put(UInt32(36) &+ dataBytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        put(UInt32(16))
        put(UInt16(1))
        put(UInt16(1))
        put(UInt32(sampleRate))
        put(UInt32(sampleRate) * 2)
        put(UInt16(2))
        put(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        put(dataBytes)
        return data
    }

    @discardableResult
    static func repair(_ url: URL) -> Bool {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64, size > UInt64(headerSize) else { return false }
        let dataBytes = UInt32(clamping: (size - UInt64(headerSize)) & ~1)
        guard let handle = try? FileHandle(forUpdating: url) else { return false }
        defer { try? handle.close() }
        let expected = header(dataBytes: dataBytes)
        guard (try? handle.read(upToCount: headerSize)) != expected else { return false }
        try? handle.seek(toOffset: 0)
        try? handle.write(contentsOf: expected)
        return true
    }
}
