import AVFoundation
import Darwin
import FluidAudio
import Foundation

struct Arguments {
    var audio: URL?
    var out: URL?
    var modelFolder: URL?
    var label = "parakeet-tdt-0.6b-v2"

    init(_ argv: [String]) {
        var i = 1
        func next() -> String { i += 1; return argv[i] }
        while i < argv.count {
            switch argv[i] {
            case "--audio": audio = URL(fileURLWithPath: next())
            case "--out": out = URL(fileURLWithPath: next())
            case "--model-folder": modelFolder = URL(fileURLWithPath: next())
            case "--label": label = next()
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
    var reportedProcessingSeconds: Double
    var reportedConfidence: Double
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
        guard let audio = args.audio, let modelFolder = args.modelFolder else {
            fail("usage: scout-parakeet-eval --audio FILE --model-folder DIR [--out FILE] [--label NAME]")
        }
        for required in ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecision.mlmodelc", "parakeet_vocab.json"] {
            guard FileManager.default.fileExists(atPath: modelFolder.appendingPathComponent(required).path) else {
                fail("\(required) missing in \(modelFolder.path); refusing to run so FluidAudio never downloads")
            }
        }
        do {
            let file = try AVAudioFile(forReading: audio)
            let audioSeconds = Double(file.length) / file.processingFormat.sampleRate
            let started = Date()
            let models = try AsrModels.loadLocal(from: modelFolder, version: .v2)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            let loaded = Date()
            var state = try TdtDecoderState(decoderLayers: models.version.decoderLayers)
            let result = try await manager.transcribe(audio, decoderState: &state)
            let finished = Date()

            let timings = result.tokenTimings ?? []
            let words = buildWordTimings(from: timings).map { WordOut(text: $0.word, start: $0.startTime, end: $0.endTime, confidence: nil) }
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let segment = SegmentOut(text: text, start: words.first?.start ?? 0, end: words.last?.end ?? audioSeconds, finalizedAt: finished.timeIntervalSince(started))
            let analysis = finished.timeIntervalSince(loaded)
            let metrics = Metrics(
                machine: sysctlString("hw.model"),
                chip: sysctlString("machdep.cpu.brand_string"),
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                engine: args.label,
                preset: "whole",
                requestedLocale: "en",
                resolvedLocale: "en",
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
                modelFolder: modelFolder.lastPathComponent,
                reportedProcessingSeconds: result.processingTime,
                reportedConfidence: Double(result.confidence)
            )
            let output = Output(text: text, segments: text.isEmpty ? [] : [segment], words: words, metrics: metrics)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(output)
            if let out = args.out {
                try data.write(to: out)
                log(String(format: "%@ audio=%.1fs load=%.2fs analysis=%.2fs rtf=%.3f peak=%.0fMB words=%d", metrics.engine, metrics.audioSeconds, metrics.loadSeconds, metrics.analysisSeconds, metrics.realTimeFactor, metrics.peakFootprintMB, words.count))
            } else {
                FileHandle.standardOutput.write(data)
            }
            exit(0)
        } catch {
            fail("error: \(error)")
        }
    }
}
