import Foundation
import ScoutCore

struct PendingItem: Sendable {
    enum Payload: Sendable {
        case focus(Focus)
        case mark(Mark)
        case context(ContextChange)
        case visual(VisualChange)
        case filler(Utterance)
    }

    var anchor: SessionTime
    var payload: Payload

    var isMark: Bool {
        if case .mark = payload { return true }
        return false
    }
}

struct PendingBuffer: Sendable {
    private(set) var items: [PendingItem] = []

    var count: Int { items.count }

    mutating func insert(_ item: PendingItem) {
        guard let last = items.last, last.anchor > item.anchor else {
            items.append(item)
            return
        }
        let index = items.firstIndex { $0.anchor > item.anchor } ?? items.endIndex
        items.insert(item, at: index)
    }

    mutating func removeAll(before time: SessionTime) -> [PendingItem] {
        removePrefix { $0.anchor < time }
    }

    mutating func removeAll(through time: SessionTime) -> [PendingItem] {
        removePrefix { $0.anchor <= time }
    }

    mutating func removeAllItems() -> [PendingItem] {
        defer { items.removeAll() }
        return items
    }

    func items(through time: SessionTime) -> ArraySlice<PendingItem> {
        items.prefix { $0.anchor <= time }
    }

    var firstMarkAnchor: SessionTime? { items.first(where: \.isMark)?.anchor }

    private mutating func removePrefix(while belongs: (PendingItem) -> Bool) -> [PendingItem] {
        let count = items.prefix(while: belongs).count
        let removed = Array(items.prefix(count))
        items.removeFirst(count)
        return removed
    }
}

struct ContextTimeline: Sendable {
    private var changes: [ContextChange] = []

    var count: Int { changes.count }

    mutating func insert(_ change: ContextChange) {
        guard let last = changes.last, last.at > change.at else {
            changes.append(change)
            return
        }
        let index = changes.firstIndex { $0.at > change.at } ?? changes.endIndex
        changes.insert(change, at: index)
    }

    func context(at time: SessionTime) -> AppContext? {
        var low = 0
        var high = changes.count
        while low < high {
            let middle = (low + high) / 2
            if changes[middle].at <= time { low = middle + 1 } else { high = middle }
        }
        return low == 0 ? nil : changes[low - 1].context
    }

    mutating func prune(keepingFrom time: SessionTime) {
        guard let lastBefore = changes.lastIndex(where: { $0.at <= time }), lastBefore > 0 else { return }
        changes.removeFirst(lastBefore)
    }
}

struct DominantTarget: Sendable {
    var target: Target
    var weight: Double
    var isPinned: Bool

    func isRelated(to other: DominantTarget) -> Bool {
        target.id == other.target.id
            || target.ancestry.contains(other.target.id)
            || other.target.ancestry.contains(target.id)
    }
}

struct TargetTally: Sendable {
    private struct Entry: Sendable {
        var target: Target
        var weight: Double
        var updatedAt: SessionTime
        var isPinned: Bool
    }

    private var entries: [String: Entry] = [:]

    mutating func add(_ target: Target, weight: Double, at time: SessionTime, pinned: Bool, halfLife: Double) {
        guard var entry = entries[target.id] else {
            entries[target.id] = Entry(target: target, weight: weight, updatedAt: time, isPinned: pinned)
            return
        }
        if time >= entry.updatedAt {
            entry.weight = entry.weight * Self.decay(time - entry.updatedAt, halfLife: halfLife) + weight
            entry.updatedAt = time
        } else {
            entry.weight += weight * Self.decay(entry.updatedAt - time, halfLife: halfLife)
        }
        entry.isPinned = entry.isPinned || pinned
        entries[target.id] = entry
    }

    func dominant(at time: SessionTime, halfLife: Double, minimumWeight: Double) -> DominantTarget? {
        var best: DominantTarget?
        for id in entries.keys.sorted() {
            let entry = entries[id]!
            let weight = entry.weight * Self.decay(max(0, time - entry.updatedAt), halfLife: halfLife)
            if weight >= minimumWeight, weight > (best?.weight ?? 0) {
                best = DominantTarget(target: entry.target, weight: weight, isPinned: entry.isPinned)
            }
        }
        return best
    }

    private static func decay(_ elapsed: Double, halfLife: Double) -> Double {
        halfLife > 0 ? pow(0.5, elapsed / halfLife) : 1
    }
}

struct SnippetDraft: Sendable {
    var snippet: Snippet
    var lastSpeech: Utterance?
    var lastSpeechSpan: TimeRange?
    var speechDuration: Double = 0
    var lastActivity: SessionTime
    var targets = TargetTally()
    var recentTexts: [String] = []
    var hasUnpublishedChanges = false

    init(id: String, start: SessionTime) {
        snippet = Snippet(id: id, range: TimeRange(start: start, end: start))
        lastActivity = start
    }

    var isMarksOnly: Bool { lastSpeech == nil }

    var committedThrough: SessionTime {
        lastSpeech?.range.end ?? lastActivity
    }

    mutating func addSpeech(_ utterance: Utterance, span: TimeRange, cohesionWindow: Int) {
        insertUtterance(utterance)
        speechDuration += span.duration
        if let lastSpeechSpan, span.end <= lastSpeechSpan.end { return }
        lastSpeech = utterance
        lastSpeechSpan = span
        lastActivity = max(lastActivity, span.end)
        recentTexts.append(utterance.text)
        if recentTexts.count > cohesionWindow { recentTexts.removeFirst(recentTexts.count - cohesionWindow) }
    }

    mutating func attribute(_ item: PendingItem, markWeight: Double, halfLife: Double) {
        switch item.payload {
        case .focus(let focus):
            snippet.focuses.append(focus)
            targets.add(focus.target, weight: focus.range.duration, at: focus.range.end, pinned: false, halfLife: halfLife)
        case .mark(let mark):
            snippet.marks.append(mark)
            include(mark.at)
            if let target = mark.target {
                targets.add(target, weight: markWeight, at: mark.at, pinned: true, halfLife: halfLife)
            }
            if isMarksOnly { lastActivity = max(lastActivity, mark.at) }
        case .context(let change):
            snippet.contexts.append(change)
            include(change.at)
        case .filler(let utterance):
            insertUtterance(utterance)
        case .visual:
            return
        }
        hasUnpublishedChanges = true
    }

    private mutating func insertUtterance(_ utterance: Utterance) {
        if let last = snippet.utterances.last, last.range.start > utterance.range.start {
            let index = snippet.utterances.firstIndex { $0.range.start > utterance.range.start } ?? snippet.utterances.endIndex
            snippet.utterances.insert(utterance, at: index)
        } else {
            snippet.utterances.append(utterance)
        }
        include(utterance.range.start)
        include(utterance.range.end)
        hasUnpublishedChanges = true
    }

    private mutating func include(_ time: SessionTime) {
        snippet.range = snippet.range.union(TimeRange(start: time, end: time))
    }
}
