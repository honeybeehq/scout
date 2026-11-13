import Foundation
import FoundationModels
import ScoutCore

nonisolated struct BriefInput: Sendable {
    var transcript: String
    var targets: [Target]
    var context: AppContext?
    var runtimeNotes: [String]
    var pinCount: Int

    var fingerprint: String {
        let place: String = context?.location ?? context?.windowTitle ?? ""
        let app: String = context?.app.bundleID ?? ""
        var parts: [String] = [transcript, app, place]
        parts += targets.map(\.id)
        parts += runtimeNotes
        return Dispatcher.fingerprint(parts.joined(separator: "\u{1F}"))
    }
}

nonisolated struct SessionLine: Codable, Hashable, Sendable {
    var title: String
    var summary: String
}

nonisolated protocol TaskSummariser: Sendable {
    func title(for input: BriefInput) async -> String?
    func brief(for input: BriefInput) async -> TaskBrief
    func sessionLine(for inputs: [BriefInput]) async -> SessionLine?
}

nonisolated enum TaskSummarisers {
    static var current: any TaskSummariser {
        OnDeviceSummariser.isAvailable ? OnDeviceSummariser() : TemplateSummariser()
    }
}

nonisolated struct TemplateSummariser: TaskSummariser {
    func title(for input: BriefInput) async -> String? { nil }

    func brief(for input: BriefInput) async -> TaskBrief {
        TaskBrief(source: .template, inputFingerprint: input.fingerprint)
    }

    func sessionLine(for inputs: [BriefInput]) async -> SessionLine? { nil }
}

nonisolated struct OnDeviceSummariser: TaskSummariser {
    static let modelName = "apple-foundation-on-device"

    static var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    private static let titleInstructions = """
    You name tasks for a coding agent. Given spoken feedback about an app, reply with one short imperative title of at most eight words, \
    like "Make the Pay now button primary". No quotes, no trailing period, no preamble.
    """

    private static let briefInstructions = """
    You turn spoken feedback about an app into a short issue for its developers. Use only what the feedback says. \
    Leave a field empty when the feedback doesn't say it. Never invent steps, numbers or names. Write plain sentences without markdown.
    """

    private static let sessionInstructions = """
    You name a feedback session for its developers. Given the spoken feedback of each task, reply with a short title of at most \
    eight words for the whole session and one plain sentence that sums it up. Use only what the feedback says. No markdown.
    """

    @Generable
    struct SessionDraft {
        @Guide(description: "A short title for the whole session, at most eight words, like \"Checkout flow playtest\".")
        var title: String
        @Guide(description: "One sentence that sums up what the feedback was about.")
        var summary: String
    }

    func sessionLine(for inputs: [BriefInput]) async -> SessionLine? {
        let spoken = inputs.map(\.transcript).filter { !$0.isEmpty }
        guard Self.isAvailable, !spoken.isEmpty else { return nil }
        let session = LanguageModelSession(instructions: Self.sessionInstructions)
        let budget = max(60, 2000 / spoken.count)
        let prompt = spoken.enumerated().map { index, text in
            "Task \(index + 1): " + text.split(separator: " ").prefix(budget).joined(separator: " ")
        }.joined(separator: "\n")
        let options = GenerationOptions(temperature: 0.2)
        guard let draft = try? await session.respond(to: prompt, generating: SessionDraft.self, options: options).content else { return nil }
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"“”.'"))
        let summary = draft.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 80, !title.contains("\n"), !summary.contains("\n") else { return nil }
        return SessionLine(title: title, summary: summary)
    }

    @Generable
    struct Draft {
        @Guide(description: "What is wrong, in one or two sentences. Empty if the feedback asks for something new.")
        var problem: String
        @Guide(description: "What the user expected or wants instead. Empty if not said.")
        var expected: String
        @Guide(description: "What happens now. Empty if not said.")
        var actual: String
        @Guide(description: "Steps to see the problem, only if the feedback describes them.", .maximumCount(6))
        var steps: [String]
        @Guide(description: "Checks that tell a developer the task is done.", .maximumCount(4))
        var acceptance: [String]
        @Guide(description: "The kind of feedback.", .anyOf(["bug", "polish", "feature", "question"]))
        var kind: String
        @Guide(description: "How urgent the user made it sound. Use high or urgent only for crashes, data loss or something that blocks them.", .anyOf(["none", "low", "medium", "high", "urgent"]))
        var urgency: String
    }

    func title(for input: BriefInput) async -> String? {
        guard Self.isAvailable, !input.transcript.isEmpty else { return nil }
        let session = LanguageModelSession(instructions: Self.titleInstructions)
        var prompt = "Feedback: \(input.transcript)"
        if let target = input.targets.first { prompt += "\nPointed at: \(target.displayName)" }
        let options = GenerationOptions(temperature: 0.2, maximumResponseTokens: 24)
        guard let response = try? await session.respond(to: prompt, options: options) else { return nil }
        let title = response.content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”.'"))
        guard !title.isEmpty, title.count <= 80, !title.contains("\n") else { return nil }
        return title
    }

    func brief(for input: BriefInput) async -> TaskBrief {
        guard Self.isAvailable, !input.transcript.isEmpty else { return await TemplateSummariser().brief(for: input) }
        let session = LanguageModelSession(instructions: Self.briefInstructions)
        let words = input.transcript.split(separator: " ")
        var prompt = "Feedback: " + words.suffix(2500).joined(separator: " ")
        if let context = input.context { prompt += "\nApp: \(context.app.name)" + (context.location.map { " at \($0)" } ?? "") }
        if !input.targets.isEmpty { prompt += "\nPointed at: " + input.targets.prefix(3).map(\.displayName).joined(separator: "; ") }
        if !input.runtimeNotes.isEmpty { prompt += "\nErrors in the app: " + input.runtimeNotes.prefix(3).joined(separator: "; ") }
        let options = GenerationOptions(temperature: 0.2)
        guard let draft = try? await session.respond(to: prompt, generating: Draft.self, options: options).content else {
            return await TemplateSummariser().brief(for: input)
        }
        func text(_ value: String) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return TaskBrief(
            problem: text(draft.problem),
            expected: text(draft.expected),
            actual: text(draft.actual),
            steps: draft.steps.compactMap(text),
            acceptance: draft.acceptance.compactMap(text),
            kind: TaskBrief.Kind(rawValue: draft.kind) ?? .bug,
            urgency: TaskBrief.Urgency(rawValue: draft.urgency) ?? .none,
            source: .onDevice(model: Self.modelName),
            inputFingerprint: input.fingerprint
        )
    }
}
