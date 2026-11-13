import AVFoundation
import Darwin
import Foundation
import WhisperKit

struct Arguments {
    var audio: URL?
    var out: URL?
    var modelFolder: String?
    var tokenizerFolder: URL?
    var language = "en"
    var label = "whisper"
    var prewarm = false

    init(_ argv: [String]) {
        var i = 1
        func next() -> String { i += 1; return argv[i] }
        while i < argv.count {
            switch argv[i] {
            case "--audio": audio = URL(fileURLWithPath: next())
            case "--out": out = URL(fileURLWithPath: next())
            case "--model-folder": modelFolder = next()
            case "--tokenizer-folder": tokenizerFolder = URL(fileURLWithPath: next())
            case "--language": language = next()
            case "--label": label = next()
            case "--prewarm": prewarm = true
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
    var modelFolder: String
    var encodingSeconds: Double
    var decodingLoopSeconds: Double
    var decodingFallbacks: Double
    var decodingWindows: Double
    var tokensPerSecond: Double
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

@main
struct Main {
    static func main() async {
        let args = Arguments(CommandLine.arguments)
        guard let audio = args.audio, let modelFolder = args.modelFolder, let tokenizerFolder = args.tokenizerFolder else {
            fail("usage: scout-whisper-eval --audio FILE --model-folder DIR --tokenizer-folder DIR [--out FILE] [--language en] [--label NAME] [--prewarm]")
        }
        guard FileManager.default.fileExists(atPath: tokenizerFolder.appendingPathComponent("tokenizer.json").path) else {
            fail("tokenizer.json missing in \(tokenizerFolder.path); refusing to run because WhisperKit would fall back to a Hub download")
        }
        do {
            let file = try AVAudioFile(forReading: audio)
            let audioSeconds = Double(file.length) / file.processingFormat.sampleRate
            let started = Date()
            let config = WhisperKitConfig(
                modelFolder: modelFolder,
                tokenizerFolder: tokenizerFolder,
                verbose: false,
                logLevel: .error,
                prewarm: args.prewarm,
                load: true,
                download: false
            )
            let pipe = try await WhisperKit(config)
            let loaded = Date()
            let options = DecodingOptions(task: .transcribe, language: args.language, wordTimestamps: true)
            let results = try await pipe.transcribe(audioPath: audio.path, decodeOptions: options)
            let finished = Date()

            var segments: [SegmentOut] = []
            var words: [WordOut] = []
            var encoding = 0.0, decodingLoop = 0.0, fallbacks = 0.0, windows = 0.0, loops = 0.0, pipeline = 0.0
            for result in results {
                for segment in result.segments {
                    let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    segments.append(SegmentOut(text: text, start: Double(segment.start), end: Double(segment.end), finalizedAt: finished.timeIntervalSince(started)))
                    for word in segment.words ?? [] {
                        let w = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !w.isEmpty else { continue }
                        words.append(WordOut(text: w, start: Double(word.start), end: Double(word.end), confidence: Double(word.probability)))
                    }
                }
                encoding += result.timings.encoding
                decodingLoop += result.timings.decodingLoop
                fallbacks += result.timings.totalDecodingFallbacks
                windows += result.timings.totalDecodingWindows
                loops += result.timings.totalDecodingLoops
                pipeline += result.timings.fullPipeline
            }
            let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            let analysis = finished.timeIntervalSince(loaded)
            let metrics = Metrics(
                machine: sysctlString("hw.model"),
                chip: sysctlString("machdep.cpu.brand_string"),
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                engine: args.label,
                preset: "whole",
                requestedLocale: args.language,
                resolvedLocale: results.first?.language,
                contextualStrings: 0,
                paced: false,
                audioSeconds: audioSeconds,
                loadSeconds: loaded.timeIntervalSince(started),
                analysisSeconds: analysis,
                finalizeLagSeconds: analysis,
                totalSeconds: finished.timeIntervalSince(started),
                realTimeFactor: analysis / audioSeconds,
                peakFootprintMB: peakFootprintMB(),
                maxRSSMB: maxRSSMB(),
                assetStatus: nil,
                modelFolder: URL(fileURLWithPath: modelFolder).lastPathComponent,
                encodingSeconds: encoding,
                decodingLoopSeconds: decodingLoop,
                decodingFallbacks: fallbacks,
                decodingWindows: windows,
                tokensPerSecond: pipeline > 0 ? loops / pipeline : 0
            )
            let output = Output(text: text, segments: segments, words: words, metrics: metrics)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(output)
            if let out = args.out {
                try data.write(to: out)
                let m = metrics
                log(String(format: "%@ audio=%.1fs load=%.2fs analysis=%.2fs rtf=%.3f peak=%.0fMB words=%d fallbacks=%.0f", m.engine, m.audioSeconds, m.loadSeconds, m.analysisSeconds, m.realTimeFactor, m.peakFootprintMB, words.count, m.decodingFallbacks))
            } else {
                FileHandle.standardOutput.write(data)
            }
            exit(0)
        } catch {
            fail("error: \(error)")
        }
    }
}
