@preconcurrency import AVFoundation
import Darwin
import Foundation
import Speech

struct Arguments {
    var audio: URL?
    var out: URL?
    var preset = "progressive"
    var locale = "current"
    var context: URL?
    var paced = false
    var installAssets = false
    var contextMode = "init"
    var module = "speech"

    init(_ argv: [String]) {
        var i = 1
        func next() -> String { i += 1; return argv[i] }
        while i < argv.count {
            switch argv[i] {
            case "--audio": audio = URL(fileURLWithPath: next())
            case "--out": out = URL(fileURLWithPath: next())
            case "--preset": preset = next()
            case "--locale": locale = next()
            case "--context": context = URL(fileURLWithPath: next())
            case "--paced": paced = true
            case "--install-assets": installAssets = true
            case "--context-mode": contextMode = next()
            case "--module": module = next()
            default: fail("unknown argument \(argv[i])")
            }
            i += 1
        }
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

struct WordOut: Codable {
    var text: String
    var start: Double
    var end: Double
    var confidence: Double?
}

struct SegmentOut: Codable {
    var text: String
    var start: Double
    var end: Double
    var finalizedAt: Double
}

struct Metrics: Codable {
    var machine: String
    var chip: String
    var osVersion: String
    var engine: String
    var preset: String
    var requestedLocale: String
    var resolvedLocale: String?
    var contextualStrings: Int
    var paced: Bool
    var audioSeconds: Double
    var loadSeconds: Double
    var analysisSeconds: Double
    var finalizeLagSeconds: Double
    var totalSeconds: Double
    var realTimeFactor: Double
    var peakFootprintMB: Double
    var maxRSSMB: Double
    var assetStatus: String?
}

struct Output: Codable {
    var text: String
    var segments: [SegmentOut]
    var words: [WordOut]
    var metrics: Metrics
}

func sysctlString(_ name: String) -> String {
    var size = 0
    sysctlbyname(name, nil, &size, nil, 0)
    var buffer = [CChar](repeating: 0, count: size)
    sysctlbyname(name, &buffer, &size, nil, 0)
    return String(cString: buffer)
}

func peakFootprintMB() -> Double {
    var info = rusage_info_current()
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { pointer in
            proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, pointer)
        }
    }
    guard result == 0 else { return 0 }
    return Double(info.ri_lifetime_max_phys_footprint) / 1_048_576
}

func maxRSSMB() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_maxrss) / 1_048_576
}

func readContext(_ url: URL?) -> [String] {
    guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    var seen = Set<String>()
    return text.split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") && seen.insert($0.lowercased()).inserted }
}

final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var segments: [SegmentOut] = []
    private(set) var words: [WordOut] = []
    private let started: Date

    init(started: Date) { self.started = started }

    func add(text attributed: AttributedString, range: CMTimeRange, isFinal: Bool) {
        guard isFinal else { return }
        let text = String(attributed.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var words: [WordOut] = []
        for run in attributed.runs {
            let word = String(attributed[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, let timeRange = run.audioTimeRange else { continue }
            words.append(WordOut(text: word, start: timeRange.start.seconds, end: timeRange.end.seconds, confidence: run.transcriptionConfidence))
        }
        lock.lock()
        segments.append(SegmentOut(text: text, start: range.start.seconds, end: range.end.seconds, finalizedAt: Date().timeIntervalSince(started)))
        self.words.append(contentsOf: words)
        lock.unlock()
    }
}

enum Module {
    case speech(SpeechTranscriber)
    case dictation(DictationTranscriber)

    var speechModule: any SpeechModule {
        switch self {
        case .speech(let m): m
        case .dictation(let m): m
        }
    }

    func consume(into collector: Collector) -> Task<Void, any Error> {
        switch self {
        case .speech(let m):
            Task { for try await result in m.results { collector.add(text: result.text, range: result.range, isFinal: result.isFinal) } }
        case .dictation(let m):
            Task { for try await result in m.results { collector.add(text: result.text, range: result.range, isFinal: result.isFinal) } }
        }
    }
}

func makeTranscriber(module: String, preset: String, locale requested: String) async throws -> (Module, Locale) {
    let wanted = requested == "current" ? Locale.current : Locale(identifier: requested)
    switch module {
    case "speech":
        let preferred = await SpeechTranscriber.supportedLocale(equivalentTo: wanted)
        let fallback = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
        guard let locale = preferred ?? fallback else { fail("no supported locale") }
        switch preset {
        case "progressive":
            return (.speech(SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)), locale)
        case "whole":
            return (.speech(SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange, .transcriptionConfidence])), locale)
        default:
            fail("preset must be progressive or whole")
        }
    case "dictation":
        let preferred = await DictationTranscriber.supportedLocale(equivalentTo: wanted)
        let fallback = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
        guard let locale = preferred ?? fallback else { fail("no supported locale") }
        switch preset {
        case "progressive":
            return (.dictation(DictationTranscriber(locale: locale, preset: .progressiveLongDictation)), locale)
        case "whole":
            return (.dictation(DictationTranscriber(locale: locale, preset: .longDictation)), locale)
        default:
            fail("preset must be progressive or whole")
        }
    default:
        fail("module must be speech or dictation")
    }
}

func runApple(_ args: Arguments, audio: URL) async throws -> Output {
    let started = Date()
    let (module, locale) = try await makeTranscriber(module: args.module, preset: args.preset, locale: args.locale)
    let transcriber = module.speechModule
    let status = await AssetInventory.status(forModules: [transcriber])
    if args.installAssets, let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        log("installing speech assets for \(locale.identifier(.bcp47))")
        try await request.downloadAndInstall()
    }
    let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
    let strings = readContext(args.context)
    let context = AnalysisContext()
    if !strings.isEmpty { context.contextualStrings[.general] = strings }
    let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
    let analyzer: SpeechAnalyzer
    switch args.contextMode {
    case "init":
        analyzer = SpeechAnalyzer(inputSequence: stream, modules: [transcriber], analysisContext: context)
    case "set":
        analyzer = SpeechAnalyzer(modules: [transcriber])
        if !strings.isEmpty { try await analyzer.setContext(context) }
    case "late":
        analyzer = SpeechAnalyzer(modules: [transcriber])
    default:
        fail("context-mode must be init, set or late")
    }
    try await analyzer.prepareToAnalyze(in: format)
    let loadSeconds = Date().timeIntervalSince(started)

    let file = try AVAudioFile(forReading: audio)
    let sourceFormat = file.processingFormat
    let audioSeconds = Double(file.length) / sourceFormat.sampleRate
    let target = format ?? sourceFormat
    guard let converter = AVAudioConverter(from: sourceFormat, to: target) else { fail("no converter") }

    let collector = Collector(started: started)
    let resultsTask = module.consume(into: collector)
    if args.contextMode != "init" { try await analyzer.start(inputSequence: stream) }
    if args.contextMode == "late", !strings.isEmpty { try await analyzer.setContext(context) }

    let analysisStart = Date()
    let chunkFrames = AVAudioFrameCount(sourceFormat.sampleRate / 10)
    var framesRead: AVAudioFramePosition = 0
    var stamped: Int64 = 0
    while framesRead < file.length {
        guard let chunk = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: chunkFrames) else { break }
        try file.read(into: chunk, frameCount: chunkFrames)
        guard chunk.frameLength > 0 else { break }
        let chunkStart = Double(framesRead) / sourceFormat.sampleRate
        framesRead += AVAudioFramePosition(chunk.frameLength)
        if args.paced {
            let wait = chunkStart - Date().timeIntervalSince(analysisStart)
            if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
        }
        guard let converted = convert(chunk, with: converter, to: target) else { continue }
        continuation.yield(AnalyzerInput(buffer: converted, bufferStartTime: CMTime(value: stamped, timescale: CMTimeScale(target.sampleRate))))
        stamped += Int64(converted.frameLength)
    }
    let inputEnd = Date()
    continuation.finish()
    try await analyzer.finalizeAndFinishThroughEndOfInput()
    try await resultsTask.value
    let finished = Date()

    let metrics = Metrics(
        machine: sysctlString("hw.model"),
        chip: sysctlString("machdep.cpu.brand_string"),
        osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
        engine: "apple-" + args.module,
        preset: args.preset,
        requestedLocale: args.locale == "current" ? "current(\(Locale.current.identifier))" : args.locale,
        resolvedLocale: locale.identifier(.bcp47),
        contextualStrings: strings.count,
        paced: args.paced,
        audioSeconds: audioSeconds,
        loadSeconds: loadSeconds,
        analysisSeconds: finished.timeIntervalSince(analysisStart),
        finalizeLagSeconds: finished.timeIntervalSince(inputEnd),
        totalSeconds: finished.timeIntervalSince(started),
        realTimeFactor: finished.timeIntervalSince(analysisStart) / audioSeconds,
        peakFootprintMB: peakFootprintMB(),
        maxRSSMB: maxRSSMB(),
        assetStatus: String(describing: status)
    )
    let text = collector.segments.map(\.text).joined(separator: " ")
    return Output(text: text, segments: collector.segments, words: collector.words, metrics: metrics)
}

func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
    if buffer.format == format { return buffer }
    let ratio = format.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
    guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
    var consumed = false
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
        if consumed { status.pointee = .noDataNow; return nil }
        consumed = true
        status.pointee = .haveData
        return buffer
    }
    return error == nil && output.frameLength > 0 ? output : nil
}

@main
struct Main {
    static func main() async {
        let args = Arguments(CommandLine.arguments)
        guard let audio = args.audio else {
            fail("usage: scout-transcribe-eval --audio FILE [--out FILE] [--module speech|dictation] [--preset progressive|whole] [--locale current|en-US|...] [--context FILE] [--paced] [--context-mode init|set|late] [--install-assets]")
        }
        do {
            let output = try await runApple(args, audio: audio)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(output)
            if let out = args.out {
                try data.write(to: out)
                let m = output.metrics
                log(String(format: "%@ %@ locale=%@ ctx=%d paced=%d audio=%.1fs load=%.2fs analysis=%.2fs lag=%.2fs rtf=%.3f peak=%.0fMB words=%d", m.engine, m.preset, m.resolvedLocale ?? "-", m.contextualStrings, m.paced ? 1 : 0, m.audioSeconds, m.loadSeconds, m.analysisSeconds, m.finalizeLagSeconds, m.realTimeFactor, m.peakFootprintMB, output.words.count))
            } else {
                FileHandle.standardOutput.write(data)
            }
            exit(0)
        } catch {
            fail("error: \(error)")
        }
    }
}
