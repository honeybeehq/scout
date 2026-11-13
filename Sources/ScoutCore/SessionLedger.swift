import Foundation

public struct SessionLedger: Codable, Hashable, Sendable {
    public private(set) var utterances: [Utterance] = []
    public private(set) var marks: [Mark] = []
    public private(set) var focuses: [Focus] = []
    public private(set) var contexts: [ContextChange] = []
    public private(set) var end: SessionTime = 0

    public init() {}

    public init(replaying signals: some Sequence<Signal>) {
        for signal in signals { record(signal) }
    }

    public mutating func record(_ signal: Signal) {
        switch signal {
        case .utterance(let utterance):
            insert(utterance, into: &utterances) { $0.range.start }
        case .mark(let mark):
            insert(mark, into: &marks) { $0.at }
        case .focus(let focus):
            insert(focus, into: &focuses) { $0.range.start }
        case .context(let change):
            insert(change, into: &contexts) { $0.at }
        case .visualChange, .command, .clock:
            break
        }
        end = max(end, signal.time)
    }

    public mutating func replaceUtterances(with replacement: [Utterance]) {
        utterances = replacement.sorted { $0.range.start < $1.range.start }
        end = max(end, utterances.map(\.range.end).max() ?? end)
    }

    public mutating func extend(to time: SessionTime) {
        end = max(end, time)
    }

    public func snippet(id: String, range: TimeRange, closedBy: Breakpoint? = nil) -> Snippet {
        Snippet(
            id: id,
            range: range,
            utterances: utterances.filter { Self.midpoint($0.range).isWithin(range) },
            focuses: focuses.filter { Self.midpoint($0.range).isWithin(range) },
            marks: marks.filter { $0.at >= range.start && $0.at <= range.end },
            contexts: contexts.filter { $0.at.isWithin(range) },
            openingContext: context(at: range.start),
            closedBy: closedBy
        )
    }

    public func context(at time: SessionTime) -> AppContext? {
        contexts.last { $0.at <= time }?.context ?? contexts.first?.context
    }

    public func utterances(outside ranges: [TimeRange]) -> [Utterance] {
        utterances.filter { utterance in
            let middle = Self.midpoint(utterance.range)
            return !ranges.contains { middle.isWithin($0) }
        }
    }

    public var cutPoints: [SessionTime] {
        zip(utterances, utterances.dropFirst()).compactMap { previous, next in
            guard next.range.start >= previous.range.end else { return nil }
            return (previous.range.end + next.range.start) / 2
        }
    }

    public func snapped(_ time: SessionTime, tolerance: Double) -> SessionTime {
        let candidates = cutPoints + utterances.flatMap { [$0.range.start, $0.range.end] }
        guard let nearest = candidates.min(by: { abs($0 - time) < abs($1 - time) }), abs(nearest - time) <= tolerance else { return time }
        return nearest
    }

    private static func midpoint(_ range: TimeRange) -> SessionTime {
        (range.start + range.end) / 2
    }

    private func insert<Element>(_ element: Element, into array: inout [Element], by key: (Element) -> SessionTime) {
        let position = array.lastIndex { key($0) <= key(element) }.map { $0 + 1 } ?? 0
        array.insert(element, at: position)
    }
}

private extension SessionTime {
    func isWithin(_ range: TimeRange) -> Bool {
        self >= range.start && self < range.end
    }
}
