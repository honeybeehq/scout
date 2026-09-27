import AppKit
import Observation
import ScoutCore

@Observable
final class Dispatcher {
    private(set) var cards: [SnippetCard] = []
    private(set) var sessions: [HiveSession] = []
    var autoSendDelay: TimeInterval { preferences.autoSendDelay }
    var defaultAgent: String { preferences.defaultAgent }
    var dryRun = false
    var onCardChanged: ((SnippetCard) -> Void)?

    private let integrations: Integrations
    private let bridge: BridgeServer
    private let preferences: Preferences
    private let resolver = ProjectResolver()

    init(integrations: Integrations, bridge: BridgeServer, preferences: Preferences) {
        self.integrations = integrations
        self.bridge = bridge
        self.preferences = preferences
    }

    @discardableResult
    func accept(_ snippet: Snippet, from session: ScoutingSession, sendImmediately: Bool) -> SnippetCard {
        let card = SnippetCard(snippet: Self.widened(snippet), sessionID: session.id, sessionDirectory: session.directory)
        card.runtimeNotes = session.runtimeEvents(around: snippet.range).map(Self.describe)
        card.recorder = session.recorder
        cards.append(card)
        suggestTitle(for: card)
        Task {
            await resolve(card)
            guard card.state == .preparing else { return }
            if card.destination == nil {
                card.state = .needsDestination
            } else if card.holdRequested {
                card.state = .held
            } else if sendImmediately {
                await send(card)
            } else if preferences.autoSend, card.destination != .clipboard {
                await countdown(card)
            } else {
                card.state = .held
            }
            onCardChanged?(card)
        }
        return card
    }

    func prepare(_ card: SnippetCard) {
        Task {
            await resolve(card)
            if !card.isLocked, card.state != .withdrawn {
                card.state = card.destination == nil ? .needsDestination : .held
            }
            onCardChanged?(card)
        }
    }

    func send(_ card: SnippetCard) async {
        guard !card.state.isClosed, card.state != .sending else { return }
        guard let destination = card.destination else {
            card.state = .needsDestination
            return
        }
        card.state = .sending
        do {
            if card.attachments.isEmpty, preferences.includeClips {
                let directory = card.sessionDirectory.appendingPathComponent("snippets/\(card.snippet.id)", isDirectory: true)
                if let recorder = card.recorder {
                    card.attachments = await SnippetMedia.attachments(for: card.deliverableSnippet, recorder: recorder, into: directory)
                } else if let video = card.sessionVideo {
                    card.attachments = await SnippetMedia.attachments(for: card.deliverableSnippet, video: video, display: card.sessionDisplay, into: directory)
                }
            }
            let task = try TaskComposer.compose(card.deliverableSnippet, title: card.title, project: card.project, runtimeNotes: card.runtimeNotes, sessionDirectory: card.sessionDirectory, extraAttachments: card.attachments)
            let key = "scout:\(card.sessionID):\(card.snippet.id):\(Self.fingerprint(task.message + destination.key))"
            if dryRun {
                try task.message.write(to: task.directory.appendingPathComponent("message.txt"), atomically: true, encoding: .utf8)
                card.state = .sent("\(destination.label) (dry run)")
            } else {
                switch destination {
                case .session(let id, let title, _):
                    try await integrations.hiveClient.send(to: id, body: task.message, idempotencyKey: key)
                    card.state = .sent(title)
                case .newSession(let cwd, let agent):
                    let name = "scout-" + Self.slug(card.title) + "-" + String(card.snippet.id.suffix(4))
                    try await integrations.hiveClient.spawn(name: name, agent: agent, cwd: cwd, title: card.title, prompt: task.message, idempotencyKey: key)
                    card.state = .sent("new \(agent) session")
                case .clipboard:
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.writeObjects([task.message as NSString, task.directory as NSURL])
                    card.state = .sent("clipboard")
                }
            }
        } catch {
            card.state = .failed(error.localizedDescription)
        }
        onCardChanged?(card)
    }

    func hold(_ card: SnippetCard) {
        card.holdRequested = true
        if case .countdown = card.state { card.state = .held }
    }

    func choose(_ destination: Destination, for card: SnippetCard) {
        guard !card.isLocked else { return }
        card.destination = destination
        card.destinationChosenByUser = true
        if card.state == .needsDestination || card.state == .held {
            card.state = .held
        }
        onCardChanged?(card)
    }

    func withdraw(_ card: SnippetCard) {
        guard !card.state.isFinished else { return }
        card.state = .withdrawn
        cards.removeAll { $0 === card }
        onCardChanged?(card)
    }

    func removeFromStack(_ card: SnippetCard) {
        cards.removeAll { $0 === card }
    }

    func retract(snippetID: String, sessionID: String) -> SnippetCard? {
        guard let card = cards.first(where: { $0.snippet.id == snippetID && $0.sessionID == sessionID }) else { return nil }
        withdraw(card)
        return card
    }

    func dismissDelivered() {
        cards.removeAll { $0.state.isFinished }
    }

    func destinations(for card: SnippetCard) -> [Destination] {
        var options: [Destination] = []
        let matching = sessions.filter { session in
            guard let root = card.project?.rootPath, let cwd = session.cwd else { return false }
            return cwd == root || cwd.hasPrefix(root + "/")
        }
        let others = sessions.filter { session in !matching.contains { $0.id == session.id } }
        options += (matching + others).prefix(8).map { .session(id: $0.id, title: $0.displayTitle, agent: $0.agent) }
        if let root = card.project?.rootPath {
            options.append(.newSession(cwd: root, agent: defaultAgent))
        }
        options.append(.clipboard)
        if let destination = card.destination, !options.contains(destination) {
            options.insert(destination, at: 0)
        }
        return options
    }

    private func resolve(_ card: SnippetCard) async {
        let snippet = card.snippet
        if card.project == nil {
            card.project = bridge.project(forLocation: snippet.primaryContext?.location) ?? snippet.targets.lazy.compactMap(bridge.project(forTarget:)).first
        }
        if card.project == nil {
            card.project = await resolver.resolve(snippet.primaryContext)
        }
        await refreshSessions()
        if !card.destinationChosenByUser, !card.isLocked {
            card.destination = chooseDestination(for: card.project)
        }
    }

    private func suggestTitle(for card: SnippetCard) {
        let original = card.snippet
        Task {
            guard let title = await TitleWriter.title(for: original) else { return }
            guard !card.titleIsCustom, card.snippet == original, !card.isLocked, card.state != .withdrawn else { return }
            card.title = title
        }
    }

    private func countdown(_ card: SnippetCard) async {
        let deadline = Date().addingTimeInterval(autoSendDelay)
        card.state = .countdown(until: deadline)
        try? await Task.sleep(for: .seconds(autoSendDelay))
        guard card.state == .countdown(until: deadline), !card.holdRequested else { return }
        await send(card)
    }

    private func refreshSessions() async {
        guard integrations.hiveClient.isInstalled else { return }
        sessions = (try? await integrations.hiveClient.activeSessions(limit: 60)) ?? sessions
    }

    private func chooseDestination(for project: ProjectReference?) -> Destination? {
        guard integrations.hiveClient.isInstalled else { return .clipboard }
        switch integrations.route {
        case .askEachTime:
            return nil
        case .newSession:
            return project.map { .newSession(cwd: $0.rootPath, agent: defaultAgent) }
        case .matchProject:
            guard let project else { return nil }
            let candidates = sessions.filter { session in
                guard let cwd = session.cwd else { return false }
                return cwd == project.rootPath || cwd.hasPrefix(project.rootPath + "/")
            }
            let best = candidates.sorted { lhs, rhs in
                if lhs.isWorking != rhs.isWorking { return !lhs.isWorking }
                return (lhs.lastOutputAt ?? .distantPast) > (rhs.lastOutputAt ?? .distantPast)
            }.first
            if let best { return .session(id: best.id, title: best.displayTitle, agent: best.agent) }
            return .newSession(cwd: project.rootPath, agent: defaultAgent)
        }
    }

    private static func widened(_ snippet: Snippet) -> Snippet {
        guard snippet.range.duration < 1 else { return snippet }
        var widened = snippet
        widened.range = TimeRange(start: max(0, snippet.range.start - 0.5), end: snippet.range.end + 0.5)
        return widened
    }

    static func fingerprint(_ text: String) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }

    static func describe(_ event: ScoutingSession.RuntimeEvent) -> String {
        let signal = event.signal
        switch signal.kind {
        case "network":
            return "\(signal.method ?? "GET") \(signal.url ?? "?") failed with \(signal.status.map(String.init) ?? "no response") (\(event.source))"
        case "console":
            return "console.\(signal.level ?? "log"): \(signal.message ?? "")  (\(event.source))"
        default:
            let firstFrame = signal.stack?.split(separator: "\n").first { $0.contains("at ") }.map { " — " + $0.trimmingCharacters(in: .whitespaces) } ?? ""
            return "\(signal.kind): \(signal.message ?? "unknown")\(firstFrame) (\(event.source))"
        }
    }

    private static func slug(_ text: String) -> String {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.prefix(4)
        return words.isEmpty ? "task" : words.joined(separator: "-")
    }
}
