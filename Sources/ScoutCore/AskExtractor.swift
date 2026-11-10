import Foundation

public enum AskExtractor {
    public static let engine = "scout-heuristic-1"
    public static let maximumAsks = 12
    public static let maximumLength = 160

    private static let requestVerbs: Set<String> = [
        "make", "fix", "add", "remove", "delete", "change", "move", "show", "hide", "rename", "use", "put", "check",
        "reconcile", "align", "increase", "decrease", "reduce", "center", "centre", "swap", "replace", "update", "turn",
        "set", "keep", "drop", "split", "merge", "sort", "group", "shorten", "lengthen", "enlarge", "shrink", "highlight",
        "disable", "enable", "allow", "prevent", "stop", "start", "label", "explain", "investigate", "find", "figure",
        "clean", "simplify", "darken", "lighten", "bump", "tweak", "restyle", "wrap", "truncate", "validate", "handle",
    ]

    private static let requestPhrases = [
        "should", "needs to", "need to", "has to", "have to", "must", "can you", "could you", "would you", "please",
        "i want", "i'd like", "i would like", "we need", "it would be nice", "let's", "make sure", "instead",
        "i'd expect", "i would expect", "i expect", "why is", "why does", "what if",
    ]

    private static let problemPhrases = [
        "too small", "too big", "too large", "too long", "too short", "too slow", "too dark", "too light", "too much",
        "too many", "too few", "too close", "too far", "doesn't", "does not", "isn't", "is not", "aren't", "won't",
        "can't", "cannot", "broken", "wrong", "missing", "overlap", "bug", "error", "not working", "only show",
        "confusing", "ugly", "hard to", "weird", "off by", "misaligned", "cut off", "crash", "fails", "failed", "slow",
        "flicker", "jumps", "laggy", "never", "nothing happens", "but the page", "but it",
    ]

    private static let leadingFillers: Set<String> = [
        "okay", "ok", "so", "and", "um", "uh", "also", "then", "alright", "right", "well", "yeah", "now", "oh", "hmm",
    ]

    private static let closings = ["that's it", "that is it", "that's all", "thats it", "done", "thank you", "thanks"]

    public static let thoughtGap = 1000

    private struct Thought {
        var sentences: [String] = []
        var segments: [Walkthrough.Segment] = []
        var score = 0
        var hasRequest = false
        var continuing = false
        var openedByBreak = false

        mutating func take(_ sentence: String, from segment: Walkthrough.Segment, score value: Int) {
            sentences.append(sentence)
            score += value
            if value >= 2 { hasRequest = true }
            if segments.last?.id != segment.id { segments.append(segment) }
        }
    }

    public static func asks(from segments: [Walkthrough.Segment], pointers: [Walkthrough.Pointer], drawings: [Walkthrough.Drawing], breaks: [Int] = []) -> [Walkthrough.Ask] {
        var found: [Thought] = []
        var current = Thought()
        var previousEnd: Int?
        var pendingBreaks = breaks.sorted()[...]
        func close() {
            guard !current.sentences.isEmpty else { return }
            if current.score >= 1 || current.openedByBreak { found.append(current) }
            current = Thought()
        }
        for segment in segments {
            var broken = false
            while let next = pendingBreaks.first, next <= segment.start {
                pendingBreaks.removeFirst()
                broken = true
            }
            if broken {
                close()
                current.openedByBreak = true
            } else if let previousEnd, segment.start - previousEnd >= thoughtGap {
                close()
            }
            previousEnd = segment.end
            for sentence in Self.sentences(in: segment.text) {
                if isClosing(sentence) {
                    close()
                    continue
                }
                let value = Self.score(sentence)
                if current.hasRequest {
                    if current.continuing, isContinuation(sentence), value == 0 {
                        current.take(sentence, from: segment, score: 0)
                        continue
                    }
                    close()
                }
                if value > 0 {
                    current.take(sentence, from: segment, score: value)
                    current.continuing = true
                } else if current.openedByBreak {
                    current.take(sentence, from: segment, score: 0)
                } else {
                    current.continuing = false
                }
            }
        }
        close()
        if found.count > maximumAsks {
            let kept = Set(found.indices.sorted { (found[$0].openedByBreak ? 1 : 0, found[$0].score, -$0) > (found[$1].openedByBreak ? 1 : 0, found[$1].score, -$1) }.prefix(maximumAsks))
            found = found.indices.filter(kept.contains).map { found[$0] }
        }
        return found.enumerated().map { index, thought in
            let pointed = thought.segments.flatMap { $0.pointers ?? [] }
            let drawn = thought.segments.flatMap { $0.drawings ?? [] }
            return Walkthrough.Ask(
                id: "a\(index + 1)",
                text: compose(thought.sentences),
                segments: thought.segments.map(\.id),
                pointers: pointed.isEmpty ? nil : pointed,
                drawings: drawn.isEmpty ? nil : drawn
            )
        }
    }

    static func isContinuation(_ sentence: String) -> Bool {
        let words = sentence.split { !$0.isLetter && $0 != "'" }
        return !words.isEmpty && words.count <= 4 && !isClosing(sentence)
    }

    static func isClosing(_ text: String) -> Bool {
        let plain = text.lowercased().replacingOccurrences(of: "’", with: "'").trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
        return closings.contains(plain)
    }

    static func sentences(in text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == "." || character == "!" || character == "?" || character == ";" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { sentences.append(trimmed) }
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { sentences.append(rest) }
        return sentences
    }

    static func score(_ sentence: String) -> Int {
        let lowered = sentence.lowercased().replacingOccurrences(of: "’", with: "'")
        if isClosing(sentence) { return 0 }
        let words = lowered.split { !$0.isLetter && $0 != "'" }.map(String.init)
        let content = words.drop { leadingFillers.contains($0) }
        guard content.count >= 3 else { return 0 }
        var score = 0
        if let first = content.first, requestVerbs.contains(first) { score += 3 }
        if requestPhrases.contains(where: { lowered.contains($0) }) { score += 2 }
        if problemPhrases.contains(where: { lowered.contains($0) }) { score += 1 }
        return score
    }

    static func compose(_ sentences: [String]) -> String {
        let cleaned = sentences.map(Self.stripFillers).filter { !$0.isEmpty }
        var text = ""
        for sentence in cleaned {
            let candidate = text.isEmpty ? sentence : text + " " + sentence
            if candidate.count > maximumLength, !text.isEmpty { break }
            text = candidate
        }
        return WalkthroughText.truncated(text, to: maximumLength)
    }

    static func stripFillers(_ sentence: String) -> String {
        var remainder = Substring(sentence)
        while true {
            let trimmed = remainder.drop { $0 == " " || $0 == "," }
            guard let end = trimmed.firstIndex(where: { !$0.isLetter && $0 != "'" }) ?? Optional(trimmed.endIndex),
                  end != trimmed.startIndex,
                  leadingFillers.contains(trimmed[trimmed.startIndex..<end].lowercased()),
                  trimmed[end...].contains(where: \.isLetter)
            else {
                remainder = trimmed
                break
            }
            remainder = trimmed[end...]
        }
        guard let first = remainder.first else { return "" }
        return first.uppercased() + remainder.dropFirst()
    }
}
