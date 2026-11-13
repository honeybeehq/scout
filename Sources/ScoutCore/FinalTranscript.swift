import Foundation

public struct TranscribedSegment: Codable, Hashable, Sendable {
    public var range: TimeRange
    public var text: String
    public var words: [Word]

    public init(range: TimeRange, text: String, words: [Word] = []) {
        self.range = range
        self.text = text
        self.words = words
    }
}

public struct FinalTranscript: Codable, Hashable, Sendable {
    public static let fileName = "transcript.json"

    public var engine: String
    public var locale: String?
    public var audioSeconds: Double
    public var elapsedSeconds: Double
    public var utterances: [Utterance]

    public init(engine: String, locale: String?, audioSeconds: Double, elapsedSeconds: Double, utterances: [Utterance]) {
        self.engine = engine
        self.locale = locale
        self.audioSeconds = audioSeconds
        self.elapsedSeconds = elapsedSeconds
        self.utterances = utterances
    }

    public static func read(from directory: URL) -> FinalTranscript? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder().decode(FinalTranscript.self, from: data)
    }

    public func write(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }

    public static func gaps(between ranges: [TimeRange]) -> [SessionTime] {
        let sorted = ranges.sorted { $0.start < $1.start }
        return zip(sorted, sorted.dropFirst()).map { previous, next in
            next.start > previous.end ? (previous.end + next.start) / 2 : next.start
        }
    }

    public static func utterances(from segments: [TranscribedSegment], droppingSpeechIn commands: [TimeRange], splittingAt boundaries: [SessionTime], idPrefix: String = "t") -> [Utterance] {
        func isCommand(_ range: TimeRange) -> Bool {
            let middle = (range.start + range.end) / 2
            return commands.contains { middle >= $0.start && middle <= $0.end }
        }
        let cuts = Array(Set(boundaries)).sorted()
        var result: [Utterance] = []
        for segment in segments.sorted(by: { $0.range.start < $1.range.start }) {
            let kept = segment.words.filter { !isCommand($0.range) }
            let utterance: Utterance
            if segment.words.isEmpty {
                guard !isCommand(segment.range) else { continue }
                utterance = Utterance(id: "", range: segment.range, text: segment.text)
            } else if kept.count == segment.words.count {
                utterance = Utterance(id: "", range: segment.range, text: segment.text, words: kept)
            } else {
                guard let first = kept.first, let last = kept.last else { continue }
                utterance = Utterance(id: "", range: TimeRange(start: first.range.start, end: last.range.end), text: kept.map(\.text).joined(separator: " "), words: kept)
            }
            for var piece in utterance.split(at: cuts) {
                let text = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                piece.text = text
                piece.id = "\(idPrefix)\(result.count + 1)"
                result.append(piece)
            }
        }
        return result
    }
}
