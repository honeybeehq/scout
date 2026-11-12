import Foundation
import ScoutCore

struct ComposedTask {
    var title: String
    var markdown: String
    var directory: URL
    var attachments: [Attachment]

    struct Attachment {
        enum Kind: String {
            case video, image, file
        }

        var kind: Kind
        var url: URL

        var line: String {
            "[Attached \(kind.rawValue): \(url.path)]"
        }
    }

    var message: String {
        ([markdown] + (attachments.isEmpty ? [] : [attachments.map(\.line).joined(separator: "\n")])).joined(separator: "\n\n")
    }
}

enum TaskComposer {
    static func title(for snippet: Snippet) -> String {
        let text = snippet.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstSentence = text.split(whereSeparator: { ".!?".contains($0) }).first.map(String.init) ?? text
        let cleaned = stripLeadingCues(firstSentence)
        guard !cleaned.isEmpty else { return "Feedback" }
        let capitalized = cleaned.prefix(1).uppercased() + cleaned.dropFirst()
        return shorten(capitalized, limit: 64)
    }

    static func shorten(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = String(text.prefix(limit))
        for separator in [", and ", " and ", ", so ", ", but ", ", "] {
            if let range = head.range(of: separator, options: .backwards), head.distance(from: head.startIndex, to: range.lowerBound) >= 24 {
                return String(head[..<range.lowerBound])
            }
        }
        let words = head.split(separator: " ").dropLast()
        return words.joined(separator: " ") + "…"
    }

    private static let leadingCues = [
        "one more thing", "another thing", "next thing", "the next thing", "next up", "moving on", "okay so", "ok so",
        "okay", "ok", "so", "um", "uh", "and", "also", "next", "now", "then", "alright", "all right", "right",
    ]

    static func stripLeadingCues(_ text: String) -> String {
        var remaining = Substring(text.trimmingCharacters(in: .whitespaces))
        var changed = true
        while changed {
            changed = false
            for cue in leadingCues {
                guard remaining.lowercased().hasPrefix(cue) else { continue }
                let rest = remaining.dropFirst(cue.count)
                guard rest.isEmpty || rest.first.map({ $0 == "," || $0 == " " || $0 == "." }) == true else { continue }
                remaining = rest.drop { $0 == "," || $0 == " " || $0 == "." }
                changed = true
                break
            }
        }
        return String(remaining)
    }

    static func compose(_ snippet: Snippet, title: String, project: ProjectReference?, runtimeNotes: [String] = [], openQuestion: String? = nil, sessionDirectory: URL, extraAttachments: [ComposedTask.Attachment] = []) throws -> ComposedTask {
        let directory = sessionDirectory.appendingPathComponent("snippets/\(snippet.id)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var details: [String] = []
        if let context = snippet.primaryContext {
            details.append("**Where:** " + describe(context, project: project))
        } else if let project {
            details.append("**Where:** repo `\(project.rootPath)`" + (project.gitBranch.map { " (branch `\($0)`)" } ?? ""))
        }
        let targets = snippet.targets.prefix(3)
        if !targets.isEmpty {
            details.append("**Pointed at:** " + targets.map(describe).joined(separator: "; "))
        }
        if !runtimeNotes.isEmpty {
            details.append((["**Runtime:**"] + runtimeNotes.prefix(5).map { "- `\($0)`" }).joined(separator: "\n"))
        }
        if let openQuestion, !openQuestion.isEmpty { details.append("Open question: \(openQuestion)") }
        if snippet.range.duration > 0 {
            details.append("**When:** \(format(snippet.range.start))–\(format(snippet.range.end)) into the session")
        }
        let lines = ["## \(title)", "", quote(snippet.transcript), ""] + details.map { $0 + "\n" }
        let markdown = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let snippetURL = directory.appendingPathComponent("snippet.json")
        try encoder.encode(snippet).write(to: snippetURL)
        let taskURL = directory.appendingPathComponent("task.md")
        try markdown.write(to: taskURL, atomically: true, encoding: .utf8)

        let attachments = extraAttachments + [.init(kind: .file, url: snippetURL)]
        return ComposedTask(title: title, markdown: markdown, directory: directory, attachments: attachments)
    }

    private static func quote(_ text: String) -> String {
        text.split(separator: "\n").map { "> " + $0 }.joined(separator: "\n")
    }

    private static func describe(_ context: AppContext, project: ProjectReference?) -> String {
        var parts = [context.app.name]
        if let location = context.location {
            parts.append(location)
        } else if let title = context.windowTitle, !title.isEmpty {
            parts.append("“\(title)”")
        }
        if let project {
            let branch = project.gitBranch.map { " (branch `\($0)`)" } ?? ""
            parts.append("repo `\(project.rootPath)`\(branch)")
        }
        return parts.joined(separator: " · ")
    }

    private static func describe(_ target: Target) -> String {
        var parts = [target.displayName]
        if let source = target.source { parts.append("`\(source.description)`") }
        if let selector = target.selector { parts.append("selector `\(selector)`") }
        if let identifier = target.identifier, !identifier.isEmpty { parts.append("id `\(identifier)`") }
        if let parent = target.ancestry.first { parts.append("in \(parent)") }
        return parts.joined(separator: " · ")
    }

    private static func format(_ seconds: SessionTime) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
