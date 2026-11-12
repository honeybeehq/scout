import AppKit
import AVFoundation
import Observation
import ScoutCore
import ScoutSegmenter

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
    private(set) var tasks: [SnippetCard]
    private(set) var discardedRanges: [TimeRange]
    private(set) var video: ExportedClip?
    private(set) var display: CaptureDisplay?
    private(set) var displays: CaptureDisplays?
    private(set) var isFinishing: Bool
    private(set) var filmstrip: [CGImage] = []
    private(set) var saveError: String?
    var optimise: OptimiseReview {
        if let optimiser { return optimiser }
        let value = OptimiseReview(review: self)
        optimiser = value
        return value
    }
    private var optimiser: OptimiseReview?
    var selectedTaskID: String?
    var playhead: SessionTime = 0
    var isEditingText = false
    var confirmingDiscard = false

    static let minimumTaskLength: SessionTime = 0.6
    static let snapTolerance: SessionTime = 1.2

    private let dispatcher: Dispatcher
    private let isFiller: (Utterance) -> Bool
    private weak var session: ScoutingSession?
    private var undoStack: [UndoStep] = []
    private var groupingUndo = false
    var undoDepth: Int { undoStack.count }
    private struct UndoStep {
        let snapshots: [Snapshot]
        let proposalIDs: [String]
    }
    var walkthrough: Walkthrough?
    private var saveTask: Task<Void, Never>?

    private struct Snapshot {
        let card: SnippetCard
        let snippet: Snippet
        let title: String
        let titleIsCustom: Bool
        let transcriptOverride: String?
        let excludedTargetIDs: Set<String>
        let optimiseAttachments: OptimiseAttachments?
    }

    init(session: ScoutingSession, dispatcher: Dispatcher) {
        sessionID = session.id
        directory = session.directory
        startedAt = session.startedAt
        segmentation = session.segmentation
        ledger = session.ledger
        tasks = session.cards.filter { $0.state != .withdrawn }.sorted { $0.snippet.range.start < $1.snippet.range.start }
        discardedRanges = session.discardedRanges
        video = session.video
        let displays = session.recorder?.displays
        self.displays = displays
        display = displays?.start
        isFinishing = session.video == nil && session.recorder != nil
        self.session = session
        self.dispatcher = dispatcher
        isFiller = { [weak session] utterance in session?.isFiller(utterance) ?? false }
    }

    init(directory: URL, record: ReviewRecord, ledger: SessionLedger, cards: [SnippetCard], dispatcher: Dispatcher) {
        sessionID = record.sessionID
        self.directory = directory
        startedAt = record.startedAt
        segmentation = Segmentation(rawValue: record.segmentation) ?? .automatic
        self.ledger = ledger
        tasks = cards.sorted { $0.snippet.range.start < $1.snippet.range.start }
        discardedRanges = (record.discarded ?? []).map { TimeRange(start: $0.start, end: $0.end) }
        video = record.video.map { ExportedClip(url: directory.appendingPathComponent($0.file), range: TimeRange(start: $0.start, end: $0.end)) }
        displays = record.displays
        display = record.display
        isFinishing = false
        self.dispatcher = dispatcher
        let segmenter = Segmenter()
        isFiller = { segmenter.isFiller($0) }
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

    var needsAttention: Bool {
        tasks.contains(where: \.needsAttention) || !leftoverSpeech.isEmpty
    }

    var isPreparing: Bool {
        tasks.contains { $0.state == .preparing }
    }

    var leftoverSpeech: [Utterance] {
        ledger.utterances(outside: tasks.map(\.snippet.range) + discardedRanges).filter { !isFiller($0) }
    }

    func isLeftover(_ utterance: Utterance) -> Bool {
        let middle = (utterance.range.start + utterance.range.end) / 2
        let ranges = tasks.map(\.snippet.range) + discardedRanges
        return !ranges.contains { middle >= $0.start && middle < $0.end } && !isFiller(utterance)
    }

    var apps: [String] {
        var seen = Set<String>()
        return ledger.contexts.map(\.context.app.name).filter { seen.insert($0).inserted }
    }

    var canUndo: Bool { !undoStack.isEmpty }

    var canDiscard: Bool {
        !isFinishing && !tasks.contains { $0.isLocked }
    }

    func contains(_ card: SnippetCard) -> Bool {
        tasks.contains { $0 === card }
    }

    func refreshFromSession() {
        guard let session else { return }
        ledger = session.ledger
        video = session.video ?? video
        displays = session.recorder?.displays ?? displays
        display = displays?.start ?? display
        isFinishing = session.video == nil && session.recorder != nil && session.phase == .ended && isFinishing
        for card in session.cards where card.state != .withdrawn && !contains(card) {
            tasks.append(card)
        }
        sortTasks()
        for card in tasks {
            card.sessionVideo = card.sessionVideo ?? video
            card.sessionDisplays = card.sessionDisplays ?? displays
        }
        scheduleSave()
    }

    func videoFinished() {
        isFinishing = false
        refreshFromSession()
        save()
    }

    func cardChanged(_ card: SnippetCard) {
        guard contains(card) else { return }
        if card.state.isFinished { undoStack.removeAll() }
        if card.state == .withdrawn { tasks.removeAll { $0 === card } }
        scheduleSave()
    }

    func select(_ card: SnippetCard) {
        selectedTaskID = card.snippet.id
        playhead = card.snippet.range.start
    }

    func selectAdjacent(_ offset: Int) {
        guard !tasks.isEmpty else { return }
        let index = tasks.firstIndex { $0.snippet.id == selectedTask?.snippet.id } ?? 0
        select(tasks[min(max(index + offset, 0), tasks.count - 1)])
    }

    func canSplit(_ card: SnippetCard, at time: SessionTime) -> Bool {
        guard !card.isLocked else { return false }
        let range = card.snippet.range
        return time - range.start >= Self.minimumTaskLength && range.end - time >= Self.minimumTaskLength
    }

    @discardableResult
    func split(_ card: SnippetCard, at requested: SessionTime) -> SnippetCard? {
        let snapped = ledger.snapped(requested, tolerance: Self.snapTolerance)
        let at = canSplit(card, at: snapped) ? snapped : requested
        guard canSplit(card, at: at) else { return nil }
        recordUndo()
        let range = card.snippet.range
        let second = SnippetCard(snippet: ledger.snippet(id: newTaskID(), range: TimeRange(start: at, end: range.end)), sessionID: sessionID, sessionDirectory: directory)
        second.inheritDelivery(from: card)
        card.transcriptOverride = nil
        card.replaceSnippet(ledger.snippet(id: card.snippet.id, range: TimeRange(start: range.start, end: at)))
        tasks.append(second)
        sortTasks()
        if second.project == nil || second.destination == nil { dispatcher.prepare(second) }
        scheduleSave()
        return second
    }

    func nextTask(after card: SnippetCard) -> SnippetCard? {
        guard let index = tasks.firstIndex(where: { $0 === card }), index + 1 < tasks.count else { return nil }
        return tasks[index + 1]
    }

    func canJoin(_ card: SnippetCard) -> Bool {
        guard !card.isLocked, let next = nextTask(after: card) else { return false }
        return !next.isLocked
    }

    func join(_ card: SnippetCard) {
        guard canJoin(card), let next = nextTask(after: card) else { return }
        recordUndo()
        let range = card.snippet.range.union(next.snippet.range)
        let override: String? = card.transcriptOverride != nil || next.transcriptOverride != nil ? [card.transcript, next.transcript].joined(separator: " ") : nil
        card.excludedTargetIDs.formUnion(next.excludedTargetIDs)
        if let extra = next.optimiseAttachments {
            var selection = card.optimiseAttachments ?? OptimiseAttachments()
            selection.frames = Array(Set(selection.frames + extra.frames)).sorted()
            selection.pointers = Array(Set(selection.pointers + extra.pointers)).sorted()
            selection.excludedFrames = Array(Set((selection.excludedFrames ?? []) + (extra.excludedFrames ?? []))).sorted()
            selection.excludedPointers = Array(Set((selection.excludedPointers ?? []) + (extra.excludedPointers ?? []))).sorted()
            selection.attachedMarks = (selection.attachedMarks ?? []) + (extra.attachedMarks ?? [])
            selection.frameFiles = (selection.frameFiles ?? [:]).merging(extra.frameFiles ?? [:]) { first, _ in first }
            selection.question = selection.question ?? extra.question
            card.optimiseAttachments = selection
        }
        card.replaceSnippet(ledger.snippet(id: card.snippet.id, range: range))
        card.transcriptOverride = override
        tasks.removeAll { $0 === next }
        dispatcher.withdraw(next)
        scheduleSave()
    }

    func delete(_ card: SnippetCard) {
        guard !card.isLocked, let index = tasks.firstIndex(where: { $0 === card }) else { return }
        recordUndo()
        tasks.remove(at: index)
        dispatcher.withdraw(card)
        if tasks.isEmpty {
            selectedTaskID = nil
        } else {
            select(tasks[min(index, tasks.count - 1)])
        }
        scheduleSave()
    }

    func boundaryLimits(_ card: SnippetCard, edge: Edge) -> ClosedRange<SessionTime> {
        guard let index = tasks.firstIndex(where: { $0 === card }) else { return card.snippet.range.start...card.snippet.range.end }
        let range = card.snippet.range
        let previous = index > 0 ? tasks[index - 1] : nil
        let next = index + 1 < tasks.count ? tasks[index + 1] : nil
        switch edge {
        case .start:
            let lower: SessionTime
            if let previous {
                let touching = abs(previous.snippet.range.end - range.start) < 0.05
                lower = touching && !previous.isLocked ? previous.snippet.range.start + Self.minimumTaskLength : previous.snippet.range.end
            } else {
                lower = 0
            }
            return min(lower, range.start)...max(range.start, range.end - Self.minimumTaskLength)
        case .end:
            let upper: SessionTime
            if let next {
                let touching = abs(next.snippet.range.start - range.end) < 0.05
                upper = touching && !next.isLocked ? next.snippet.range.end - Self.minimumTaskLength : next.snippet.range.start
            } else {
                upper = duration
            }
            return min(range.end, range.start + Self.minimumTaskLength)...max(upper, range.end)
        }
    }

    func beginBoundaryDrag() {
        recordUndo()
    }

    func beginTextEdit() {
        recordUndo()
    }

    func moveBoundary(of card: SnippetCard, edge: Edge, to requested: SessionTime, snap: Bool) {
        guard !card.isLocked, let index = tasks.firstIndex(where: { $0 === card }) else { return }
        let limits = boundaryLimits(card, edge: edge)
        let target = snap ? ledger.snapped(requested, tolerance: Self.snapTolerance * 0.5) : requested
        let time = min(max(target, limits.lowerBound), limits.upperBound)
        let range = card.snippet.range
        switch edge {
        case .start:
            if index > 0, abs(tasks[index - 1].snippet.range.end - range.start) < 0.05, !tasks[index - 1].isLocked {
                let previous = tasks[index - 1]
                previous.replaceSnippet(ledger.snippet(id: previous.snippet.id, range: TimeRange(start: previous.snippet.range.start, end: time)))
            }
            card.replaceSnippet(ledger.snippet(id: card.snippet.id, range: TimeRange(start: time, end: range.end)))
        case .end:
            if index + 1 < tasks.count, abs(tasks[index + 1].snippet.range.start - range.end) < 0.05, !tasks[index + 1].isLocked {
                let next = tasks[index + 1]
                next.replaceSnippet(ledger.snippet(id: next.snippet.id, range: TimeRange(start: time, end: next.snippet.range.end)))
            }
            card.replaceSnippet(ledger.snippet(id: card.snippet.id, range: TimeRange(start: range.start, end: time)))
        }
        scheduleSave()
    }

    @discardableResult
    func makeTask(from utterance: Utterance) -> SnippetCard {
        recordUndo()
        let (lower, upper) = gap(around: utterance)
        let range = TimeRange(start: max(lower, utterance.range.start - 0.3), end: min(upper, utterance.range.end + 0.3))
        let card = SnippetCard(snippet: ledger.snippet(id: newTaskID(), range: range), sessionID: sessionID, sessionDirectory: directory)
        card.recorder = session?.recorder
        card.sessionVideo = video
        card.sessionDisplays = displays
        card.holdRequested = true
        tasks.append(card)
        sortTasks()
        dispatcher.prepare(card)
        select(card)
        scheduleSave()
        return card
    }

    func neighbor(for utterance: Utterance) -> SnippetCard? {
        let middle = (utterance.range.start + utterance.range.end) / 2
        let before = tasks.last { $0.snippet.range.start <= middle }
        let after = tasks.first { $0.snippet.range.start > middle }
        return [before, after]
            .compactMap { $0 }
            .filter { !$0.isLocked }
            .min { distance($0, utterance) < distance($1, utterance) }
    }

    func attach(_ utterance: Utterance, to card: SnippetCard) {
        guard !card.isLocked, let index = tasks.firstIndex(where: { $0 === card }) else { return }
        recordUndo()
        let range = card.snippet.range
        let lower = index > 0 ? tasks[index - 1].snippet.range.end : 0
        let upper = index + 1 < tasks.count ? tasks[index + 1].snippet.range.start : duration
        let wanted = range.union(TimeRange(start: utterance.range.start - 0.2, end: utterance.range.end + 0.2))
        let clamped = TimeRange(start: max(lower, wanted.start), end: min(upper, wanted.end))
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

    func edited(_ card: SnippetCard) {
        dispatcher.hold(card)
        scheduleSave()
    }

    func undo() {
        guard let step = undoStack.popLast() else { return }
        let snapshots = step.snapshots
        let restored = Set(snapshots.map { ObjectIdentifier($0.card) })
        for card in tasks where !restored.contains(ObjectIdentifier(card)) && !card.isLocked {
            dispatcher.withdraw(card)
        }
        tasks = tasks.filter { restored.contains(ObjectIdentifier($0)) || $0.isLocked }
        for snapshot in snapshots {
            let card = snapshot.card
            if !contains(card) {
                if card.state == .withdrawn { card.state = card.destination == nil ? .needsDestination : .held }
                tasks.append(card)
            }
            guard !card.isLocked else { continue }
            card.replaceSnippet(snapshot.snippet)
            card.restoreTitle(snapshot.title, custom: snapshot.titleIsCustom)
            card.transcriptOverride = snapshot.transcriptOverride
            card.excludedTargetIDs = snapshot.excludedTargetIDs
            card.optimiseAttachments = snapshot.optimiseAttachments
        }
        sortTasks()
        if selectedTask == nil, let first = tasks.first { select(first) }
        scheduleSave()
        optimiser?.didUndo(step.proposalIDs)
        try? saveAgentAsks()
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
            guard !Task.isCancelled else { return }
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
            display: displays?.start ?? display,
            displayHops: displays.flatMap { $0.hops.isEmpty ? nil : $0.hops },
            discarded: discardedRanges.map { .init(start: $0.start, end: $0.end) },
            tasks: tasks.map(ReviewRecord.Task.init)
        )
        do {
            try ReviewRecord.write(record, to: directory)
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }

    var optimiseMarkedCuts: [SessionTime] {
        (ledger.markedCuts ?? []) + tasks.compactMap { $0.snippet.closedBy }.filter { $0.isHard && $0.reasons.contains { $0.kind == .command || $0.kind == .cuePhrase } }.map(\.at)
    }

    func optimiseValidation(_ proposal: OptimiseProposal) -> String? {
        if tasks.contains(where: { proposal.tasks.contains($0.snippet.id) && $0.isLocked }) { return "Sent or sending tasks cannot change." }
        if proposal.kind == .split, let at = proposal.at {
            let time = Double(at) / 1000
            if ledger.utterances.contains(where: { $0.range.start < time && time < $0.range.end }) { return "Split between utterances so speech stays intact." }
        }
        if proposal.kind == .attach {
            if !(proposal.frames ?? []).isEmpty && video == nil && walkthrough == nil { return "This recording has no frames." }
            if video == nil, let walkthrough {
                let frames = Set(walkthrough.frames.map(\.t))
                if !(proposal.frames ?? []).allSatisfy(frames.contains) { return "A referenced still frame does not exist." }
            }
            let times = Set(ledger.marks.map { Walkthrough.milliseconds($0.at) })
            if !(proposal.pointers ?? []).allSatisfy(times.contains) { return "A referenced pointer does not exist." }
        }
        return proposal.validationMessage(tasks: tasks.map(\.snippet), markedCuts: optimiseMarkedCuts, duration: duration)
    }

    func applyOptimise(_ proposal: OptimiseProposal) throws {
        if let message = optimiseValidation(proposal) {
            throw NSError(domain: "Scout.Optimise", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        let selected = tasks.filter { proposal.tasks.contains($0.snippet.id) }
        guard selected.allSatisfy({ !$0.isLocked }), let first = selected.first else {
            throw NSError(domain: "Scout.Optimise", code: 2, userInfo: [NSLocalizedDescriptionKey: "Sent or sending tasks cannot change."])
        }
        switch proposal.kind {
        case .merge:
            for _ in selected.dropFirst() { join(first) }
        case .split:
            guard split(first, at: Double(proposal.at!) / 1000) != nil else { return }
        case .drop:
            delete(first)
        case .retitle:
            recordUndo()
            first.restoreTitle(proposal.title!, custom: true)
        case .flag, .attach, .detach:
            recordUndo()
            var attachments = first.optimiseAttachments ?? OptimiseAttachments()
            if proposal.kind == .flag { attachments.question = proposal.question }
            if proposal.kind == .attach {
                if let walkthrough {
                    var files = attachments.frameFiles ?? [:]
                    for frame in walkthrough.frames where (proposal.frames ?? []).contains(frame.t) { files[frame.t] = directory.appendingPathComponent(frame.file).path }
                    attachments.frameFiles = files
                }
                attachments.excludedFrames = (attachments.excludedFrames ?? []).filter { !(proposal.frames ?? []).contains($0) }
                attachments.excludedPointers = (attachments.excludedPointers ?? []).filter { !(proposal.pointers ?? []).contains($0) }
                attachments.attachedMarks = (attachments.attachedMarks ?? []) + ledger.marks.filter { (proposal.pointers ?? []).contains(Walkthrough.milliseconds($0.at)) }
                attachments.frames = Array(Set(attachments.frames + (proposal.frames ?? []))).sorted()
                attachments.pointers = Array(Set(attachments.pointers + (proposal.pointers ?? []))).sorted()
            }
            if proposal.kind == .detach {
                attachments.excludedFrames = Array(Set((attachments.excludedFrames ?? []) + (proposal.frames ?? []))).sorted()
                attachments.excludedPointers = Array(Set((attachments.excludedPointers ?? []) + (proposal.pointers ?? []))).sorted()
                attachments.attachedMarks = (attachments.attachedMarks ?? []).filter { !(proposal.pointers ?? []).contains(Walkthrough.milliseconds($0.at)) }
                attachments.frames.removeAll { (proposal.frames ?? []).contains($0) }
                attachments.pointers.removeAll { (proposal.pointers ?? []).contains($0) }
            }
            first.optimiseAttachments = attachments
            first.attachments = []
        }
        if let title = proposal.title, proposal.kind == .merge { first.restoreTitle(title, custom: true) }
        scheduleSave()
    }

    private func gap(around utterance: Utterance) -> (SessionTime, SessionTime) {
        let middle = (utterance.range.start + utterance.range.end) / 2
        let lower = tasks.filter { $0.snippet.range.start <= middle }.map(\.snippet.range.end).max() ?? 0
        let upper = tasks.filter { $0.snippet.range.start > middle }.map(\.snippet.range.start).min() ?? duration
        return (min(lower, middle), max(upper, middle))
    }

    private func distance(_ card: SnippetCard, _ utterance: Utterance) -> SessionTime {
        let range = card.snippet.range
        return max(0, max(utterance.range.start - range.end, range.start - utterance.range.end))
    }

    private func sortTasks() {
        tasks.sort { $0.snippet.range.start < $1.snippet.range.start }
    }

    private func newTaskID() -> String {
        "task-" + UUID().uuidString.prefix(6).lowercased()
    }

    func groupOptimiseUndo(ids: [String], _ action: () throws -> Void) rethrows {
        if groupingUndo {
            try action()
            return
        }
        recordUndo()
        groupingUndo = true
        defer {
            groupingUndo = false
            if !undoStack.isEmpty {
                let step = undoStack.removeLast()
                undoStack.append(UndoStep(snapshots: step.snapshots, proposalIDs: ids))
            }
        }
        try action()
    }

    private func recordUndo() {
        guard !groupingUndo else { return }
        undoStack.append(UndoStep(snapshots: tasks.map {
            Snapshot(card: $0, snippet: $0.snippet, title: $0.title, titleIsCustom: $0.titleIsCustom, transcriptOverride: $0.transcriptOverride, excludedTargetIDs: $0.excludedTargetIDs, optimiseAttachments: $0.optimiseAttachments)
        }, proposalIDs: []))
        if undoStack.count > 60 { undoStack.removeFirst() }
        for card in tasks { dispatcher.hold(card) }
    }
}
