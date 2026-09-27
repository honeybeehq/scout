import AppKit
import AVFoundation
import Observation
import ScoutCore

@Observable
final class SessionReview {
    enum Edge {
        case start
        case end
    }

    let sessionID: String
    let directory: URL
    let startedAt: Date
    let segmentation: Segmentation
    private(set) var ledger: SessionLedger
    private(set) var video: ExportedClip?
    private(set) var display: CaptureDisplay?
    private(set) var isLive: Bool
    private(set) var filmstrip: [CGImage] = []
    var selectedTaskID: String?
    var playhead: SessionTime = 0
    var isEditingText = false

    static let minimumTaskLength: SessionTime = 0.6
    static let snapTolerance: SessionTime = 1.2

    private let dispatcher: Dispatcher
    private weak var session: ScoutingSession?
    private var undoStack: [[Snapshot]] = []
    private var saveTask: Task<Void, Never>?

    private struct Snapshot {
        let card: SnippetCard
        let snippet: Snippet
        let title: String
        let transcriptOverride: String?
        let excludedTargetIDs: Set<String>
    }

    init(session: ScoutingSession, dispatcher: Dispatcher) {
        sessionID = session.id
        directory = session.directory
        startedAt = session.startedAt
        segmentation = session.segmentation
        ledger = session.ledger
        video = session.video
        display = session.recorder?.display
        isLive = session.phase != .ended
        self.session = session
        self.dispatcher = dispatcher
    }

    init(directory: URL, record: ReviewRecord, ledger: SessionLedger, dispatcher: Dispatcher) {
        sessionID = record.sessionID
        self.directory = directory
        startedAt = record.startedAt
        segmentation = Segmentation(rawValue: record.segmentation) ?? .automatic
        self.ledger = ledger
        video = record.video.map { ExportedClip(url: directory.appendingPathComponent($0.file), range: TimeRange(start: $0.start, end: $0.end)) }
        display = record.display
        isLive = false
        self.dispatcher = dispatcher
    }

    var tasks: [SnippetCard] {
        dispatcher.cards(inSession: sessionID)
    }

    var selectedTask: SnippetCard? {
        tasks.first { $0.snippet.id == selectedTaskID } ?? tasks.first
    }

    var duration: SessionTime {
        max(ledger.end, video?.range.end ?? 0, tasks.map(\.snippet.range.end).max() ?? 0)
    }

    var unsentCount: Int {
        tasks.filter { !$0.isLocked }.count
    }

    var leftoverSpeech: [Utterance] {
        ledger.utterances(outside: tasks.map(\.snippet.range))
    }

    var apps: [String] {
        var seen = Set<String>()
        return ledger.contexts.map(\.context.app.name).filter { seen.insert($0).inserted }
    }

    var canUndo: Bool { !undoStack.isEmpty }

    func refreshFromSession() {
        guard let session else { return }
        ledger = session.ledger
        video = session.video ?? video
        display = session.recorder?.display ?? display
        isLive = session.phase != .ended
        for card in tasks {
            card.sessionVideo = card.sessionVideo ?? video
            card.sessionDisplay = card.sessionDisplay ?? display
        }
        if !isLive { Task { await loadFilmstrip() } }
    }

    func select(_ card: SnippetCard) {
        selectedTaskID = card.snippet.id
        playhead = card.snippet.range.start
    }

    func selectAdjacent(_ offset: Int) {
        let list = tasks
        guard !list.isEmpty else { return }
        let index = list.firstIndex { $0.snippet.id == selectedTask?.snippet.id } ?? 0
        select(list[min(max(index + offset, 0), list.count - 1)])
    }

    func canSplit(_ card: SnippetCard, at time: SessionTime) -> Bool {
        guard !card.isLocked else { return false }
        let range = card.snippet.range
        return time - range.start >= Self.minimumTaskLength && range.end - time >= Self.minimumTaskLength
    }

    @discardableResult
    func split(_ card: SnippetCard, at requested: SessionTime) -> SnippetCard? {
        let time = ledger.snapped(requested, tolerance: Self.snapTolerance)
        let at = canSplit(card, at: time) ? time : requested
        guard canSplit(card, at: at) else { return nil }
        recordUndo()
        let range = card.snippet.range
        let second = makeCard(range: TimeRange(start: at, end: range.end), like: card)
        card.replaceSnippet(ledger.snippet(id: card.snippet.id, range: TimeRange(start: range.start, end: at)))
        dispatcher.insert(second)
        scheduleSave()
        return second
    }

    func nextTask(after card: SnippetCard) -> SnippetCard? {
        tasks.first { $0.snippet.range.start >= card.snippet.range.end - 0.01 && $0 !== card }
    }

    func canJoin(_ card: SnippetCard) -> Bool {
        guard !card.isLocked, let next = nextTask(after: card) else { return false }
        return !next.isLocked
    }

    func join(_ card: SnippetCard) {
        guard canJoin(card), let next = nextTask(after: card) else { return }
        recordUndo()
        let range = card.snippet.range.union(next.snippet.range)
        if card.transcriptOverride != nil || next.transcriptOverride != nil {
            card.transcriptOverride = [card.transcript, next.transcript].joined(separator: " ")
        }
        card.excludedTargetIDs.formUnion(next.excludedTargetIDs)
        let override = card.transcriptOverride
        card.replaceSnippet(ledger.snippet(id: card.snippet.id, range: range))
        card.transcriptOverride = override
        dispatcher.dismiss(next)
        scheduleSave()
    }

    func delete(_ card: SnippetCard) {
        guard !card.isLocked else { return }
        recordUndo()
        let list = tasks
        let index = list.firstIndex { $0 === card }
        dispatcher.dismiss(card)
        let remaining = tasks
        if let index, !remaining.isEmpty {
            select(remaining[min(index, remaining.count - 1)])
        } else {
            selectedTaskID = nil
        }
        scheduleSave()
    }

    func boundaryLimits(_ card: SnippetCard, edge: Edge) -> ClosedRange<SessionTime> {
        let list = tasks
        let range = card.snippet.range
        switch edge {
        case .start:
            let previousEnd = list.filter { $0.snippet.range.end <= range.start + 0.01 && $0 !== card }.map(\.snippet.range.end).max() ?? 0
            let neighbor = list.first { abs($0.snippet.range.end - range.start) < 0.05 && $0 !== card }
            let lower = neighbor.map { $0.isLocked ? range.start : $0.snippet.range.start + Self.minimumTaskLength } ?? previousEnd
            return min(lower, range.start)...max(range.start, range.end - Self.minimumTaskLength)
        case .end:
            let nextStart = list.filter { $0.snippet.range.start >= range.end - 0.01 && $0 !== card }.map(\.snippet.range.start).min() ?? duration
            let neighbor = list.first { abs($0.snippet.range.start - range.end) < 0.05 && $0 !== card }
            let upper = neighbor.map { $0.isLocked ? range.end : $0.snippet.range.end - Self.minimumTaskLength } ?? nextStart
            return min(range.end, range.start + Self.minimumTaskLength)...max(upper, range.end)
        }
    }

    func beginBoundaryDrag() {
        recordUndo()
    }

    func moveBoundary(of card: SnippetCard, edge: Edge, to requested: SessionTime, snap: Bool) {
        guard !card.isLocked else { return }
        let limits = boundaryLimits(card, edge: edge)
        let target = snap ? ledger.snapped(requested, tolerance: Self.snapTolerance * 0.5) : requested
        let time = min(max(target, limits.lowerBound), limits.upperBound)
        let range = card.snippet.range
        switch edge {
        case .start:
            if let neighbor = tasks.first(where: { abs($0.snippet.range.end - range.start) < 0.05 && $0 !== card }), !neighbor.isLocked {
                neighbor.replaceSnippet(ledger.snippet(id: neighbor.snippet.id, range: TimeRange(start: neighbor.snippet.range.start, end: time)))
            }
            card.replaceSnippet(ledger.snippet(id: card.snippet.id, range: TimeRange(start: time, end: range.end)))
        case .end:
            if let neighbor = tasks.first(where: { abs($0.snippet.range.start - range.end) < 0.05 && $0 !== card }), !neighbor.isLocked {
                neighbor.replaceSnippet(ledger.snippet(id: neighbor.snippet.id, range: TimeRange(start: time, end: neighbor.snippet.range.end)))
            }
            card.replaceSnippet(ledger.snippet(id: card.snippet.id, range: TimeRange(start: range.start, end: time)))
        }
        scheduleSave()
    }

    @discardableResult
    func makeTask(from utterance: Utterance) -> SnippetCard {
        recordUndo()
        let gapStart = tasks.filter { $0.snippet.range.end <= utterance.range.start + 0.01 }.map(\.snippet.range.end).max() ?? 0
        let gapEnd = tasks.filter { $0.snippet.range.start >= utterance.range.end - 0.01 }.map(\.snippet.range.start).min() ?? duration
        let start = max(gapStart, utterance.range.start - 0.3)
        let end = min(gapEnd, utterance.range.end + 0.3)
        let card = SnippetCard(snippet: ledger.snippet(id: newTaskID(), range: TimeRange(start: start, end: end)), sessionID: sessionID, sessionDirectory: directory)
        card.recorder = session?.recorder
        card.sessionVideo = video
        card.sessionDisplay = display
        dispatcher.prepareHeld(card)
        select(card)
        scheduleSave()
        return card
    }

    func neighbor(for utterance: Utterance) -> SnippetCard? {
        let middle = (utterance.range.start + utterance.range.end) / 2
        let list = tasks
        let before = list.last { $0.snippet.range.start <= middle }
        let after = list.first { $0.snippet.range.start > middle }
        return [before, after]
            .compactMap { $0 }
            .filter { !$0.isLocked }
            .min { distance($0, utterance) < distance($1, utterance) }
    }

    func attach(_ utterance: Utterance, to card: SnippetCard) {
        guard !card.isLocked else { return }
        recordUndo()
        let list = tasks
        let range = card.snippet.range
        let lowerLimit = list.filter { $0 !== card && $0.snippet.range.start < range.start }.map(\.snippet.range.end).max() ?? 0
        let upperLimit = list.filter { $0 !== card && $0.snippet.range.start > range.start }.map(\.snippet.range.start).min() ?? duration
        let wanted = range.union(TimeRange(start: utterance.range.start - 0.2, end: utterance.range.end + 0.2))
        let clamped = TimeRange(start: max(lowerLimit, wanted.start), end: min(upperLimit, wanted.end))
        let override = card.transcriptOverride.map { utterance.range.start < range.start ? utterance.text + " " + $0 : $0 + " " + utterance.text }
        card.replaceSnippet(ledger.snippet(id: card.snippet.id, range: clamped))
        card.transcriptOverride = override
        select(card)
        scheduleSave()
    }

    func assignDestinationToWaiting(_ destination: Destination) {
        for card in tasks where !card.isLocked {
            dispatcher.choose(destination, for: card)
        }
        scheduleSave()
    }

    private func distance(_ card: SnippetCard, _ utterance: Utterance) -> SessionTime {
        let range = card.snippet.range
        return max(0, max(utterance.range.start - range.end, range.start - utterance.range.end))
    }

    func edited(_ card: SnippetCard) {
        dispatcher.hold(card)
        scheduleSave()
    }

    func undo() {
        guard let snapshots = undoStack.popLast() else { return }
        let restored = Set(snapshots.map { ObjectIdentifier($0.card) })
        for card in tasks where !restored.contains(ObjectIdentifier(card)) && !card.isLocked {
            dispatcher.dismiss(card)
        }
        for snapshot in snapshots {
            let card = snapshot.card
            if !dispatcher.cards.contains(where: { $0 === card }) {
                if card.state == .withdrawn { card.state = card.destination == nil ? .needsDestination : .held }
                dispatcher.insert(card)
            }
            guard !card.isLocked else { continue }
            card.replaceSnippet(snapshot.snippet)
            card.title = snapshot.title
            card.transcriptOverride = snapshot.transcriptOverride
            card.excludedTargetIDs = snapshot.excludedTargetIDs
        }
        scheduleSave()
    }

    func sessionTime(forVideoTime seconds: Double) -> SessionTime {
        seconds + (video?.range.start ?? 0)
    }

    func videoTime(forSessionTime time: SessionTime) -> Double {
        max(0, time - (video?.range.start ?? 0))
    }

    func loadFilmstrip(count: Int = 48) async {
        guard filmstrip.isEmpty, let video else { return }
        let asset = AVURLAsset(url: video.url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: 160, height: 90)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        let length = video.range.duration
        guard length > 0 else { return }
        var frames: [CGImage] = []
        for index in 0..<count {
            let seconds = length * (Double(index) + 0.5) / Double(count)
            if let image = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image {
                frames.append(image)
            }
        }
        filmstrip = frames
    }

    func frame(at time: SessionTime, maximumSize: CGSize = CGSize(width: 640, height: 400)) async -> CGImage? {
        guard let video else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video.url))
        generator.maximumSize = maximumSize
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        return try? await generator.image(at: CMTime(seconds: videoTime(forSessionTime: time), preferredTimescale: 600)).image
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            self?.save()
        }
    }

    func save() {
        let record = ReviewRecord(
            sessionID: sessionID,
            startedAt: startedAt,
            segmentation: segmentation.rawValue,
            duration: duration,
            video: video.map { .init(file: $0.url.lastPathComponent, start: $0.range.start, end: $0.range.end) },
            display: display,
            tasks: tasks.map(ReviewRecord.Task.init)
        )
        try? ReviewRecord.write(record, to: directory)
    }

    private func makeCard(range: TimeRange, like source: SnippetCard) -> SnippetCard {
        let card = SnippetCard(snippet: ledger.snippet(id: newTaskID(), range: range), sessionID: sessionID, sessionDirectory: directory)
        card.project = source.project
        card.destination = source.destination
        card.destinationChosenByUser = source.destinationChosenByUser
        card.recorder = source.recorder
        card.sessionVideo = source.sessionVideo ?? video
        card.sessionDisplay = source.sessionDisplay ?? display
        card.runtimeNotes = source.runtimeNotes
        card.excludedTargetIDs = source.excludedTargetIDs
        card.state = source.destination == nil ? .needsDestination : .held
        return card
    }

    private func newTaskID() -> String {
        "task-" + UUID().uuidString.prefix(6).lowercased()
    }

    private func recordUndo() {
        undoStack.append(tasks.map { Snapshot(card: $0, snippet: $0.snippet, title: $0.title, transcriptOverride: $0.transcriptOverride, excludedTargetIDs: $0.excludedTargetIDs) })
        if undoStack.count > 60 { undoStack.removeFirst() }
        for card in tasks { dispatcher.hold(card) }
    }
}
