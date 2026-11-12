import Foundation

public struct Word: Codable, Hashable, Sendable {
    public var text: String
    public var range: TimeRange
    public var confidence: Double?

    public init(text: String, range: TimeRange, confidence: Double? = nil) {
        self.text = text
        self.range = range
        self.confidence = confidence
    }
}

public struct Utterance: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var range: TimeRange
    public var text: String
    public var words: [Word]

    public init(id: String, range: TimeRange, text: String, words: [Word] = []) {
        self.id = id
        self.range = range
        self.text = text
        self.words = words
    }

    public func split(at cuts: [SessionTime]) -> [Utterance] {
        let inside = cuts.filter { $0 > range.start && $0 < range.end }.sorted()
        guard !inside.isEmpty else { return [self] }
        var pieces: [Utterance] = []
        for (lower, upper) in zip([-SessionTime.infinity] + inside, inside + [SessionTime.infinity]) {
            let span = TimeRange(start: max(range.start, lower), end: min(range.end, upper))
            let id = pieces.isEmpty ? self.id : "\(self.id)-\(pieces.count + 1)"
            if words.isEmpty {
                let middle = (range.start + range.end) / 2
                if middle > lower, middle <= upper { pieces.append(Utterance(id: id, range: span, text: text)) }
                continue
            }
            let taken = words.filter { $0.range.end > lower && $0.range.end <= upper }.map { word in
                Word(text: word.text, range: TimeRange(start: max(word.range.start, span.start), end: word.range.end), confidence: word.confidence)
            }
            guard let first = taken.first, let last = taken.last else { continue }
            let start = lower.isInfinite ? span.start : first.range.start
            let end = upper.isInfinite ? span.end : last.range.end
            pieces.append(Utterance(id: id, range: TimeRange(start: start, end: end), text: taken.map(\.text).joined(separator: " "), words: taken))
        }
        return pieces
    }
}

public struct ContextChange: Codable, Hashable, Sendable {
    public var at: SessionTime
    public var context: AppContext

    public init(at: SessionTime, context: AppContext) {
        self.at = at
        self.context = context
    }
}

public struct Focus: Codable, Hashable, Sendable {
    public var range: TimeRange
    public var target: Target

    public init(range: TimeRange, target: Target) {
        self.range = range
        self.target = target
    }
}

public struct Mark: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var at: SessionTime
    public var point: Point
    public var target: Target?

    public init(id: String, at: SessionTime, point: Point, target: Target? = nil) {
        self.id = id
        self.at = at
        self.point = point
        self.target = target
    }
}

public struct VisualChange: Codable, Hashable, Sendable {
    public var at: SessionTime
    public var magnitude: Double

    public init(at: SessionTime, magnitude: Double) {
        self.at = at
        self.magnitude = magnitude
    }
}

public enum Command: String, Codable, Hashable, Sendable {
    case split
    case discardCurrent
}

public struct CommandSignal: Codable, Hashable, Sendable {
    public var at: SessionTime
    public var command: Command

    public init(at: SessionTime, command: Command) {
        self.at = at
        self.command = command
    }
}

public enum Signal: Hashable, Sendable {
    case utterance(Utterance)
    case context(ContextChange)
    case focus(Focus)
    case mark(Mark)
    case visualChange(VisualChange)
    case command(CommandSignal)
    case clock(SessionTime)

    public var time: SessionTime {
        switch self {
        case .utterance(let utterance): utterance.range.end
        case .context(let change): change.at
        case .focus(let focus): focus.range.end
        case .mark(let mark): mark.at
        case .visualChange(let change): change.at
        case .command(let signal): signal.at
        case .clock(let time): time
        }
    }
}

extension Signal: Codable {
    private enum Kind: String, Codable {
        case utterance, context, focus, mark, visualChange, command, clock
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case at
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .utterance: self = .utterance(try Utterance(from: decoder))
        case .context: self = .context(try ContextChange(from: decoder))
        case .focus: self = .focus(try Focus(from: decoder))
        case .mark: self = .mark(try Mark(from: decoder))
        case .visualChange: self = .visualChange(try VisualChange(from: decoder))
        case .command: self = .command(try CommandSignal(from: decoder))
        case .clock: self = .clock(try container.decode(SessionTime.self, forKey: .at))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .utterance(let value):
            try container.encode(Kind.utterance, forKey: .type)
            try value.encode(to: encoder)
        case .context(let value):
            try container.encode(Kind.context, forKey: .type)
            try value.encode(to: encoder)
        case .focus(let value):
            try container.encode(Kind.focus, forKey: .type)
            try value.encode(to: encoder)
        case .mark(let value):
            try container.encode(Kind.mark, forKey: .type)
            try value.encode(to: encoder)
        case .visualChange(let value):
            try container.encode(Kind.visualChange, forKey: .type)
            try value.encode(to: encoder)
        case .command(let value):
            try container.encode(Kind.command, forKey: .type)
            try value.encode(to: encoder)
        case .clock(let time):
            try container.encode(Kind.clock, forKey: .type)
            try container.encode(time, forKey: .at)
        }
    }
}
