import Foundation

public struct TaskBrief: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case bug, polish, feature, question
    }

    public enum Urgency: String, Codable, CaseIterable, Sendable {
        case none, low, medium, high, urgent
    }

    public enum Source: Codable, Hashable, Sendable {
        case onDevice(model: String)
        case template
    }

    public var problem: String?
    public var expected: String?
    public var actual: String?
    public var steps: [String]
    public var acceptance: [String]
    public var kind: Kind
    public var urgency: Urgency
    public var source: Source
    public var inputFingerprint: String
    public var edited: Bool

    public init(
        problem: String? = nil,
        expected: String? = nil,
        actual: String? = nil,
        steps: [String] = [],
        acceptance: [String] = [],
        kind: Kind = .bug,
        urgency: Urgency = .none,
        source: Source,
        inputFingerprint: String,
        edited: Bool = false
    ) {
        self.problem = problem
        self.expected = expected
        self.actual = actual
        self.steps = steps
        self.acceptance = acceptance
        self.kind = kind
        self.urgency = urgency
        self.source = source
        self.inputFingerprint = inputFingerprint
        self.edited = edited
    }

    public var hasSummary: Bool {
        [problem, expected, actual].contains { !Self.isBlank($0 ?? "") } || !filledSteps.isEmpty || !filledAcceptance.isEmpty
    }

    public var filledSteps: [String] { steps.filter { !Self.isBlank($0) } }
    public var filledAcceptance: [String] { acceptance.filter { !Self.isBlank($0) } }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
