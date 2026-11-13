import Foundation
import ScoutCore

nonisolated struct SpeechContextTerms: Equatable, Sendable {
    static let limit = 200
    static let userLimit = 100
    static let phraseLength = 2...48

    private(set) var pinned: [String] = []
    private var recent: [String] = []

    var all: [String] { pinned + recent }
    var count: Int { pinned.count + recent.count }

    @discardableResult
    mutating func pin(_ phrases: [String]) -> Bool {
        let before = pinned
        pinned = []
        for phrase in phrases.prefix(Self.userLimit) where Self.phraseLength.contains(phrase.count) {
            if !pinned.contains(where: { $0.caseInsensitiveCompare(phrase) == .orderedSame }) { pinned.append(phrase) }
        }
        recent.removeAll { phrase in pinned.contains { $0.caseInsensitiveCompare(phrase) == .orderedSame } }
        return before != pinned
    }

    @discardableResult
    mutating func note(_ context: AppContext) -> Bool {
        var phrases = [context.app.name]
        if let title = context.windowTitle { phrases += Self.phrases(in: title) }
        if let name = context.project?.name { phrases.append(name) }
        return remember(phrases)
    }

    @discardableResult
    mutating func note(_ target: Target) -> Bool {
        remember([target.label, target.component].compactMap { $0 })
    }

    @discardableResult
    mutating func remember(_ phrases: [String]) -> Bool {
        var changed = false
        for raw in phrases {
            let phrase = Self.clean(raw)
            guard Self.phraseLength.contains(phrase.count), !Self.isNumeric(phrase) else { continue }
            guard !pinned.contains(where: { $0.caseInsensitiveCompare(phrase) == .orderedSame }) else { continue }
            if let index = recent.firstIndex(where: { $0.caseInsensitiveCompare(phrase) == .orderedSame }) {
                guard index != recent.count - 1 else { continue }
                recent.remove(at: index)
            } else {
                changed = true
            }
            recent.append(phrase)
        }
        let room = Self.limit - pinned.count
        if recent.count > room {
            recent.removeFirst(recent.count - max(room, 0))
            changed = true
        }
        return changed
    }

    static func phrases(in title: String) -> [String] {
        title.components(separatedBy: Self.separators)
            .map(clean)
            .filter { !$0.isEmpty }
    }

    static func userTerms(from text: String) -> [String] {
        text.split { $0 == "\n" || $0 == "," }
            .map { clean(String($0)) }
            .filter { !$0.isEmpty }
    }

    private static let separators: [String] = [" — ", " – ", " - ", " | ", " · ", " • ", " / ", " :: ", ": ", "\t"]

    private static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-–—|·•:;,()[]{}\"'"))
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private static func isNumeric(_ phrase: String) -> Bool {
        phrase.allSatisfy { $0.isNumber || $0.isPunctuation || $0.isWhitespace }
    }
}

nonisolated extension String {
    func components(separatedBy separators: [String]) -> [String] {
        var pieces = [self]
        for separator in separators {
            pieces = pieces.flatMap { $0.components(separatedBy: separator) }
        }
        return pieces
    }
}
