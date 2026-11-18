import Foundation

public struct OptimiseProposal: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case merge, split, retitle, attach, detach, flag, drop
    }

    public var id: String
    public var kind: Kind
    public var tasks: [String]
    public var at: Int?
    public var title: String?
    public var frames: [Int]?
    public var pointers: [Int]?
    public var question: String?
    public var crossesMarkedCut: Bool?
    public var why: String

    public func validationMessage(tasks available: [Snippet], markedCuts: [SessionTime], duration: SessionTime) -> String? {
        guard !id.isEmpty, !why.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "A proposal needs an ID and a reason." }
        let selected = tasks.compactMap { id in available.first { $0.id == id } }
        guard !tasks.isEmpty, Set(tasks).count == tasks.count, selected.count == tasks.count else { return "A referenced task no longer exists." }
        if kind != .merge && tasks.count != 1 { return "This edit needs exactly one task." }
        if kind == .merge {
            guard selected.count >= 2 else { return "A merge needs at least two tasks." }
            let indices = available.indices.filter { tasks.contains(available[$0].id) }
            guard indices.last! - indices.first! + 1 == indices.count else { return "Only adjacent tasks can merge." }
            let start = selected.map(\.range.start).min()!
            let end = selected.map(\.range.end).max()!
            if markedCuts.contains(where: { $0 > start && $0 < end }) && crossesMarkedCut != true { return "This merge crosses an explicit cut. It needs a marked-cut exception and reason." }
        }
        if kind == .attach, let task = selected.first {
            for time in ((frames ?? []) + (pointers ?? [])).map({ Double($0) / 1000 }) {
                let lower = min(task.range.start, time)
                let upper = max(task.range.end, time)
                if markedCuts.contains(where: { $0 > lower && $0 < upper && ($0 <= task.range.start || $0 >= task.range.end) }) && crossesMarkedCut != true { return "This attachment crosses an explicit cut. It needs a marked-cut exception and reason." }
            }
        }
        if kind == .split {
            guard let at, Double(at) / 1000 - selected[0].range.start >= 0.6, selected[0].range.end - Double(at) / 1000 >= 0.6 else { return "Split must leave at least 0.6 seconds on each side." }
        }
        if kind == .retitle && (title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) { return "A retitle needs a title." }
        if kind == .flag && (question?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) { return "A flag needs a question." }
        if kind == .attach || kind == .detach {
            guard !(frames ?? []).isEmpty || !(pointers ?? []).isEmpty else { return "Choose frames or pointers." }
        }
        guard ((frames ?? []) + (pointers ?? [])).allSatisfy({ $0 >= 0 && Double($0) / 1000 <= duration }) else { return "An attachment time is outside the recording." }
        return nil
    }
}

public struct OptimiseDocument: Codable, Sendable {
    public var v: Int
    public var engine: String
    public var model: String
    public var startedAt: String
    public var finishedAt: String
    public var proposals: [OptimiseProposal]

    public static func read(from url: URL) throws -> Self {
        try decode(Data(contentsOf: url))
    }

    public static func decode(_ data: Data) throws -> Self {
        let document = try JSONDecoder().decode(Self.self, from: data)
        guard document.v == 1, !document.engine.isEmpty, Set(document.proposals.map(\.id)).count == document.proposals.count else {
            throw CocoaError(.coderReadCorrupt)
        }
        return document
    }
}

public struct OptimiseAttachments: Codable, Hashable, Sendable {
    public var frames: [Int] = []
    public var pointers: [Int] = []
    public var question: String?
    public var excludedFrames: [Int]?
    public var excludedPointers: [Int]?
    public var attachedMarks: [Mark]?
    public var frameFiles: [Int: String]?
    public init() {}
}
