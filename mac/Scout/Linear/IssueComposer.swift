import Foundation
import ScoutCore

nonisolated struct IssueInput: Sendable {
    struct Pin: Sendable {
        var number: Int
        var caption: String
        var url: String
    }

    enum Clip: Sendable {
        case none
        case notIncluded
        case included(url: String, duration: Double, hiddenParts: Int)
    }

    var key: String
    var title: String
    var brief: TaskBrief?
    var transcript: String
    var transcriptEdited: Bool
    var context: AppContext?
    var project: ProjectReference?
    var targets: [Target]
    var runtimeNotes: [String]
    var range: TimeRange
    var clip: Clip = .none
    var pins: [Pin]
    var homeDirectory: String
}

nonisolated struct IssueDraft: Sendable {
    var title: String
    var markdown: String
}

nonisolated enum IssueComposer {
    static let titleLimit = 120
    static let transcriptLimit = 6000

    static func compose(_ input: IssueInput) -> IssueDraft {
        var blocks: [String] = []
        if let brief = input.brief, brief.hasSummary {
            blocks.append(summary(brief))
        }
        blocks.append("### What was said\n" + quote(transcript(input)))
        if let clip = clipBlock(input.clip) { blocks.append(clip) }
        if !input.pins.isEmpty {
            blocks.append((["### Pins"] + input.pins.map { "![Pin \($0.number) · \(escaped($0.caption))](\($0.url))" }).joined(separator: "\n"))
        }
        let context = contextLines(input)
        if !context.isEmpty {
            blocks.append((["### Context"] + context).joined(separator: "\n"))
        }
        blocks.append("---\nFiled from Scout · `\(input.key)`")
        let markdown = blocks.joined(separator: "\n\n").replacingOccurrences(of: input.homeDirectory, with: "~")
        return IssueDraft(title: title(input.title), markdown: markdown)
    }

    static func clipBlock(_ clip: IssueInput.Clip) -> String? {
        switch clip {
        case .none: nil
        case .notIncluded: "### Clip\n_Video not included._"
        case .included(let url, let duration, let hidden):
            "### Clip\n[clip.mp4 · \(clock(duration))](\(url))" + (hidden == 0 ? "" : hidden == 1 ? " · 1 part hidden in Scout before upload" : " · \(hidden) parts hidden in Scout before upload")
        }
    }

    static func replacingClip(in description: String, with clip: IssueInput.Clip) -> String? {
        guard let block = clipBlock(clip) else { return nil }
        var lines = description.components(separatedBy: "\n")
        guard let heading = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "### Clip" }) else {
            guard let line = lines.firstIndex(where: { $0.contains("clip.mp4") }), let last = block.components(separatedBy: "\n").last else { return nil }
            lines[line] = last
            return lines.joined(separator: "\n")
        }
        let blank: (String) -> Bool = { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        var end = heading + 1
        while end < lines.count, blank(lines[end]) { end += 1 }
        while end < lines.count, !blank(lines[end]), !lines[end].hasPrefix("#"), !lines[end].hasPrefix("---") { end += 1 }
        lines.replaceSubrange(heading..<end, with: block.components(separatedBy: "\n"))
        return lines.joined(separator: "\n")
    }

    static func title(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let title = flat.isEmpty ? "Feedback from Scout" : flat
        return title.count > titleLimit ? String(title.prefix(titleLimit - 1)) + "…" : title
    }

    private static func summary(_ brief: TaskBrief) -> String {
        var parts: [String] = []
        let lead = [("Problem", brief.problem), ("Expected", brief.expected), ("Actual", brief.actual)]
            .compactMap { label, text in
                text.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : "**\(label).** \($0)" }
            }
        if !lead.isEmpty { parts.append(lead.joined(separator: "\n")) }
        if !brief.filledSteps.isEmpty {
            parts.append((["**Steps to reproduce**"] + brief.filledSteps.enumerated().map { "\($0.offset + 1). \($0.element)" }).joined(separator: "\n"))
        }
        if !brief.filledAcceptance.isEmpty {
            parts.append((["**Acceptance criteria**"] + brief.filledAcceptance.map { "- [ ] \($0)" }).joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    private static func transcript(_ input: IssueInput) -> String {
        var text = input.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { text = "(nothing was said)" }
        if text.count > transcriptLimit {
            text = String(text.prefix(transcriptLimit)) + " … (truncated, full transcript in Scout)"
        }
        return input.transcriptEdited ? text + "\n\n*(edited in Scout)*" : text
    }

    private static func contextLines(_ input: IssueInput) -> [String] {
        var lines: [String] = []
        if let context = input.context {
            var app = "- **App:** \(context.app.name)"
            if let bundleID = context.app.bundleID { app += " (`\(bundleID)`)" }
            if let window = context.windowTitle, !window.isEmpty, window != context.app.name { app += " · window “\(withoutQueries(window))”" }
            lines.append(app)
            if let location = context.location, !location.isEmpty {
                lines.append("- **URL / scene:** `\(withoutQueries(location))`")
            }
        }
        if let project = input.project {
            let name = project.name ?? URL(fileURLWithPath: project.rootPath).lastPathComponent
            lines.append("- **Repo:** `\(name)`" + (project.gitBranch.map { " · branch `\($0)`" } ?? ""))
        }
        let targets = input.targets.prefix(3).map { target($0, root: input.project?.rootPath) }
        if targets.count == 1 {
            lines.append("- **Pointed at:** " + targets[0])
        } else if !targets.isEmpty {
            lines.append((["- **Pointed at:**"] + targets.map { "  - \($0)" }).joined(separator: "\n"))
        }
        if !input.runtimeNotes.isEmpty {
            lines.append((["- **Runtime errors:**"] + input.runtimeNotes.prefix(5).map { "  - `\(withoutQueries($0).replacingOccurrences(of: "`", with: "'"))`" }).joined(separator: "\n"))
        }
        if input.range.duration > 0 {
            lines.append("- **Recorded:** \(clock(input.range.start))–\(clock(input.range.end)) into the session")
        }
        return lines
    }

    private static func target(_ target: Target, root: String?) -> String {
        var parts: [String] = []
        if let component = target.component { parts.append("`\(component)`") }
        if let label = target.label, !label.isEmpty { parts.append("\"\(escaped(label))\"") }
        if parts.isEmpty { parts.append(escaped(target.displayName)) }
        var line = parts.joined(separator: " ")
        if var source = target.source {
            if let root, source.file.hasPrefix(root + "/") { source.file = String(source.file.dropFirst(root.count + 1)) }
            line += " · `\(source.description)`"
        }
        if let selector = target.selector { line += " · selector `\(selector)`" }
        return line
    }

    static func withoutQueries(_ text: String) -> String {
        guard let pattern = try? NSRegularExpression(pattern: #"(\b[a-zA-Z][a-zA-Z0-9+.-]*://[^\s?#`'"]+)[?#][^\s`'"]*"#) else { return text }
        return pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1")
    }

    private static func quote(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")").replacingOccurrences(of: "\n", with: " ")
    }

    static func clock(_ seconds: SessionTime) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
