import Foundation
import FoundationModels
import ScoutCore

enum TitleWriter {
    private static let instructions = """
    You name tasks for a coding agent. Given spoken feedback about an app, reply with one short imperative title of at most eight words, \
    like "Make the Pay now button primary". No quotes, no trailing period, no preamble.
    """

    static var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    static func title(for snippet: Snippet) async -> String? {
        guard isAvailable, !snippet.transcript.isEmpty else { return nil }
        let session = LanguageModelSession(instructions: instructions)
        var prompt = "Feedback: \(snippet.transcript)"
        if let target = snippet.targets.first { prompt += "\nPointed at: \(target.displayName)" }
        let options = GenerationOptions(temperature: 0.2, maximumResponseTokens: 24)
        guard let response = try? await session.respond(to: prompt, options: options) else { return nil }
        let title = response.content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”.'"))
        guard !title.isEmpty, title.count <= 80, !title.contains("\n") else { return nil }
        return title
    }
}
