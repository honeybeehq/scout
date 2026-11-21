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
        var gameAttachments: [ComposedTask.Attachment] = []
        let snapshots = sessionDirectory.appendingPathComponent("game-snapshots")
        let candidates = (try? FileManager.default.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil)) ?? []
        let owner = snippet.webClientID
        let owned = candidates.filter { url in
            guard let owner, let data = try? Data(contentsOf: url), let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return (state["_scoutTargetClientID"] as? String ?? state["_scoutClientID"] as? String) == owner
        }
        let scoped = (owned.isEmpty ? candidates : owned).filter { url in
            guard let data = try? Data(contentsOf: url), let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            if !owned.isEmpty { return true }
            if let owner, let bound = state["_scoutTargetClientID"] as? String, bound != owner { return false }
            if let project {
                return state["_scoutProjectRoot"] as? String == project.rootPath
                    && (owner == nil || url.deletingPathExtension().lastPathComponent == snippet.id)
            }
            guard let clientID = state["_scoutClientID"] as? String else { return false }
            return snippet.targets.contains { $0.id.hasPrefix("web:\(clientID):") }
        }
        let closed = scoped.first { $0.deletingPathExtension().lastPathComponent == snippet.id }
        let selected = closed ?? scoped.compactMap { url -> (URL, Double)? in
            guard let at = Double(url.deletingPathExtension().lastPathComponent), at >= snippet.range.start, at <= snippet.range.end + 1 else { return nil }
            return (url, at)
        }.sorted { $0.1 < $1.1 }.last?.0
        if let selected, let attached = try? attachGameState(from: selected, into: directory), let block = try? gameStateBlock(in: directory) {
            gameAttachments = attached
            details.append(block)
        }
        let lines = ["## \(title)", "", quote(snippet.transcript), ""] + details.map { $0 + "\n" }
        let markdown = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let snippetURL = directory.appendingPathComponent("snippet.json")
        try encoder.encode(snippet).write(to: snippetURL)
        let taskURL = directory.appendingPathComponent("task.md")
        try (markdown + (gameAttachments.isEmpty ? "" : "\n\n" + gameAttachments.map(\.line).joined(separator: "\n"))).write(to: taskURL, atomically: true, encoding: .utf8)

        let attachments = extraAttachments + gameAttachments + [.init(kind: .file, url: snippetURL)]
        return ComposedTask(title: title, markdown: markdown, directory: directory, attachments: attachments)
    }

    static func gameStateBlock(in directory: URL) throws -> String {
        let data = try Data(contentsOf: directory.appendingPathComponent("game-state.json"))
        let state = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let fields = ["name", "build", "scene", "seed", "frame", "clock", "position", "saveStatus"]
        return (["**Game state**"] + fields.compactMap { key in
            guard let value = state[key] else { return nil }
            let rendered = (value as? String) ?? (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])).flatMap { String(data: $0, encoding: .utf8) } ?? "unknown"
            return "- \(key): \(rendered)"
        }).joined(separator: "\n")
    }

    static func attachGameState(from source: URL, into directory: URL) throws -> [ComposedTask.Attachment] {
        let data = try Data(contentsOf: source)
        guard var state = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        state.removeValue(forKey: "_scoutProjectRoot")
        state.removeValue(forKey: "_scoutClientID")
        state.removeValue(forKey: "_scoutTargetClientID")
        var attachments: [ComposedTask.Attachment] = []
        if let save = state.removeValue(forKey: "save") {
            let saveData = try JSONSerialization.data(withJSONObject: save, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
            if saveData.count <= 262144 {
                let url = directory.appendingPathComponent("save.json")
                try saveData.write(to: url, options: .atomic)
                state["saveFile"] = "save.json"
                attachments.append(.init(kind: .file, url: url))
            } else {
                state["saveStatus"] = "omitted: exceeds 256 KiB"
            }
        }
        if state["saveFile"] == nil { try? FileManager.default.removeItem(at: directory.appendingPathComponent("save.json")) }
        let url = directory.appendingPathComponent("game-state.json")
        try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        return [.init(kind: .file, url: url)] + attachments
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
