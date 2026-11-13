import Foundation
import Observation
import ScoutCore

enum Destination: Hashable, Codable {
    case session(id: String, title: String, agent: String)
    case newSession(cwd: String, agent: String)
    case clipboard
    case linear(LinearTarget)

    var allowsAutoSend: Bool {
        switch self {
        case .session, .newSession: true
        case .clipboard, .linear: false
        }
    }

    var linearTarget: LinearTarget? {
        if case .linear(let target) = self { target } else { nil }
    }

    var label: String {
        switch self {
        case .session(_, let title, let agent): "\(title) · \(agent)"
        case .newSession(let cwd, let agent): "New \(agent) session in \(URL(fileURLWithPath: cwd).lastPathComponent)"
        case .clipboard: "Clipboard"
        case .linear(let target): target.label
        }
    }

    var key: String {
        switch self {
        case .session(let id, _, _): "session-\(id)"
        case .newSession(let cwd, let agent): "new-\(agent)-\(cwd)"
        case .clipboard: "clipboard"
        case .linear(let target): "linear-\(target.team.id)-\(target.project?.id ?? "")"
        }
    }
}

@Observable
final class SnippetCard: Identifiable {
    enum State: Equatable {
        case preparing
        case countdown(until: Date)
        case needsDestination
        case held
        case sending
        case sent(String)
        case failed(String)
        case copiedInstead(String)
        case withdrawn

        var isFinished: Bool {
            if case .sent = self { return true }
            return false
        }

        var problem: String? {
            switch self {
            case .failed(let message): message
            case .copiedInstead(let reason): "Not sent, copied to the clipboard instead. hive said: \(reason)"
            default: nil
            }
        }

        var isClosed: Bool {
            switch self {
            case .sent, .withdrawn: true
            default: false
            }
        }
    }

    private(set) var snippet: Snippet
    let sessionID: String
    let sessionDirectory: URL
    var title: String {
        didSet { if title != oldValue, isUserEditing { titleIsCustom = true } }
    }
    private(set) var titleIsCustom = false
    var transcriptOverride: String?
    var optimiseAttachments: OptimiseAttachments?
    var excludedTargetIDs: Set<String> = []
    var isUserEditing = false
    var holdRequested = false
    var project: ProjectReference?
    var destination: Destination?
    var destinationChosenByUser = false
    var state: State = .preparing
    var attachments: [ComposedTask.Attachment] = []
    var runtimeNotes: [String] = []
    var brief: TaskBrief?
    var isBriefing = false
    var linearOptions = LinearTaskOptions()
    var linearReceipt: LinearReceipt?
    var linearGeneration = 0
    var linearStep: LinearFiler.Step?
    var preparedVideo: RenderedMedia?
    var videoPreparation: (key: String, task: Task<RenderedMedia?, Never>)?
    var isPreparingVideo = false
    var videoFailed = false
    var redactionSheet: RedactionSheet.Mode?
    var recorder: SegmentedScreenRecorder?
    var sessionVideo: ExportedClip?
    var sessionDisplays: CaptureDisplays?

    var id: String { "\(sessionID)/\(snippet.id)" }

    var isLocked: Bool {
        state.isFinished || state == .sending
    }

    var needsAttention: Bool {
        switch state {
        case .needsDestination, .held, .failed, .copiedInstead: true
        default: false
        }
    }

    var hasRecording: Bool {
        recorder != nil || sessionVideo != nil
    }

    var clipRange: TimeRange {
        TimeRange(start: max(0, snippet.range.start - 1), end: snippet.range.end + 1)
    }

    var transcript: String {
        transcriptOverride ?? snippet.transcript
    }

    var linearKey: String {
        "scout:\(sessionID):\(snippet.id)" + (linearGeneration > 0 ? ":g\(linearGeneration)" : "")
    }

    var briefInput: BriefInput {
        BriefInput(transcript: transcript, targets: targets, context: snippet.primaryContext, runtimeNotes: runtimeNotes, pinCount: snippet.marks.count)
    }

    var targets: [Target] {
        snippet.targets.filter { !excludedTargetIDs.contains($0.id) }
    }

    var deliverableSnippet: Snippet {
        var snippet = snippet
        if let transcriptOverride {
            snippet.utterances = [Utterance(id: "edited", range: snippet.range, text: transcriptOverride)]
        }
        snippet.marks = snippet.marks.map { mark in
            var mark = mark
            if let target = mark.target, excludedTargetIDs.contains(target.id) { mark.target = nil }
            return mark
        }
        snippet.focuses.removeAll { excludedTargetIDs.contains($0.target.id) }
        if let selection = optimiseAttachments {
            snippet.marks.removeAll { (selection.excludedPointers ?? []).contains(Walkthrough.milliseconds($0.at)) }
            for mark in selection.attachedMarks ?? [] where !snippet.marks.contains(where: { $0.id == mark.id }) { snippet.marks.append(mark) }
            snippet.focuses.removeAll { (selection.excludedPointers ?? []).contains(Walkthrough.milliseconds(($0.range.start + $0.range.end) / 2)) }
        }
        return snippet
    }

    init(snippet: Snippet, sessionID: String, sessionDirectory: URL) {
        self.snippet = snippet
        self.sessionID = sessionID
        self.sessionDirectory = sessionDirectory
        title = TaskComposer.title(for: snippet)
    }

    func replaceSnippet(_ newSnippet: Snippet) {
        guard !isLocked else { return }
        let transcriptChanged = newSnippet.transcript != snippet.transcript
        snippet = newSnippet
        attachments = []
        if transcriptChanged, !titleIsCustom { title = TaskComposer.title(for: newSnippet) }
    }

    func restoreTitle(_ title: String, custom: Bool) {
        self.title = title
        titleIsCustom = custom
    }

    func inheritDelivery(from source: SnippetCard) {
        project = source.project
        destination = source.destination
        destinationChosenByUser = source.destinationChosenByUser
        recorder = source.recorder
        sessionVideo = source.sessionVideo
        sessionDisplays = source.sessionDisplays
        runtimeNotes = source.runtimeNotes
        excludedTargetIDs = source.excludedTargetIDs
        optimiseAttachments = source.optimiseAttachments
        holdRequested = true
        state = destination == nil ? .needsDestination : .held
    }
}
