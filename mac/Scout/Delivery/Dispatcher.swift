import AppKit
import Observation
import ScoutCore

enum Destination: Hashable {
    case session(id: String, title: String, agent: String)
    case newSession(cwd: String, agent: String)
    case clipboard

    var label: String {
        switch self {
        case .session(_, let title, let agent): "\(title) · \(agent)"
        case .newSession(let cwd, let agent): "New \(agent) session in \(URL(fileURLWithPath: cwd).lastPathComponent)"
        case .clipboard: "Clipboard"
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

        var isFinished: Bool {
            if case .sent = self { return true }
            return false
        }
    }

    let snippet: Snippet
    let sessionID: String
    let sessionDirectory: URL
    var title: String
    var project: ProjectReference?
    var destination: Destination?
    var state: State = .preparing
    var attachments: [ComposedTask.Attachment] = []
    var runtimeNotes: [String] = []

    var id: String { "\(sessionID)/\(snippet.id)" }

    init(snippet: Snippet, sessionID: String, sessionDirectory: URL) {
        self.snippet = snippet
        self.sessionID = sessionID
        self.sessionDirectory = sessionDirectory
        title = TaskComposer.title(for: snippet)
    }
}

@Observable
final class Dispatcher {
    private(set) var cards: [SnippetCard] = []
    private(set) var sessions: [HiveSession] = []
    var autoSendDelay: TimeInterval { preferences.autoSendDelay }
    var defaultAgent: String { preferences.defaultAgent }
    var dryRun = false
    var attachmentProvider: ((SnippetCard) async -> [ComposedTask.Attachment])?

    private let integrations: Integrations
    private let bridge: BridgeServer
    private let preferences: Preferences
    private let resolver = ProjectResolver()

    init(integrations: Integrations, bridge: BridgeServer, preferences: Preferences) {
        self.integrations = integrations
        self.bridge = bridge
        self.preferences = preferences
    }

    var pendingCount: Int {
        cards.filter { !$0.state.isFinished }.count
    }

    func accept(_ snippet: Snippet, from session: ScoutingSession, sendImmediately: Bool) {
        let card = SnippetCard(snippet: snippet, sessionID: session.id, sessionDirectory: session.directory)
        card.runtimeNotes = session.runtimeEvents(around: snippet.range).map(Self.describe)
        cards.append(card)
        Task {
            if let title = await TitleWriter.title(for: snippet), !card.state.isFinished, card.state != .sending {
                card.title = title
            }
        }
        Task {
            if let project = bridge.project(forLocation: snippet.primaryContext?.location) {
                card.project = project
            } else {
                card.project = await resolver.resolve(snippet.primaryContext)
            }
            await refreshSessions()
            card.destination = chooseDestination(for: card.project)
            guard card.state == .preparing else { return }
            if card.destination == nil {
                card.state = .needsDestination
            } else if sendImmediately {
                await send(card)
            } else if preferences.autoSend {
                await countdown(card)
            } else {
                card.state = .held
            }
        }
    }

    func send(_ card: SnippetCard) async {
        guard let destination = card.destination else {
            card.state = .needsDestination
            return
        }
        card.state = .sending
        do {
            if let attachmentProvider {
                card.attachments = await attachmentProvider(card)
            }
            let task = try TaskComposer.compose(card.snippet, title: card.title, project: card.project, runtimeNotes: card.runtimeNotes, sessionDirectory: card.sessionDirectory, extraAttachments: card.attachments)
            let key = "scout:\(card.sessionID):\(card.snippet.id)"
            if dryRun {
                try task.message.write(to: task.directory.appendingPathComponent("message.txt"), atomically: true, encoding: .utf8)
                card.state = .sent("\(destination.label) (dry run)")
                return
            }
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
        } catch {
            card.state = .failed(error.localizedDescription)
        }
    }

    func hold(_ card: SnippetCard) {
        if case .countdown = card.state { card.state = .held }
    }

    func choose(_ destination: Destination, for card: SnippetCard) {
        card.destination = destination
        if card.state == .needsDestination || card.state == .held {
            card.state = .held
        }
    }

    func dismiss(_ card: SnippetCard) {
        cards.removeAll { $0 === card }
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
        return options
    }

    private func countdown(_ card: SnippetCard) async {
        let deadline = Date().addingTimeInterval(autoSendDelay)
        card.state = .countdown(until: deadline)
        try? await Task.sleep(for: .seconds(autoSendDelay))
        guard card.state == .countdown(until: deadline) else { return }
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

    private static func describe(_ event: ScoutingSession.RuntimeEvent) -> String {
        let signal = event.signal
        switch signal.kind {
        case "network":
            return "\(signal.method ?? "GET") \(signal.url ?? "?") failed with \(signal.status.map(String.init) ?? "no response") (\(event.source))"
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
