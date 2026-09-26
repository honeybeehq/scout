import Foundation

enum TextAnalysis {
    static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        func flush() {
            while current.hasSuffix("'") { current.removeLast() }
            if !current.isEmpty { tokens.append(current) }
            current = ""
        }
        var previousWasLowercase = false
        for character in text {
            defer { previousWasLowercase = character.isLowercase }
            if character.isLetter || character.isNumber {
                if character.isUppercase && previousWasLowercase { flush() }
                current.append(contentsOf: character.lowercased())
            } else if character == "'" || character == "\u{2019}" {
                if !current.isEmpty { current.append("'") }
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }

    static func contentTerms(_ text: String) -> [String: Int] {
        var terms: [String: Int] = [:]
        for token in tokens(text) where !stopwords.contains(token) {
            let stemmed = stem(token)
            guard stemmed.count >= 2 else { continue }
            terms[stemmed, default: 0] += 1
        }
        return terms
    }

    static func stem(_ token: String) -> String {
        var word = token
        if word.hasSuffix("'s") { word.removeLast(2) }
        word.removeAll { $0 == "'" }
        for (suffix, replacement) in suffixRules where word.hasSuffix(suffix) && word.count - suffix.count >= 3 {
            if suffix == "s" && word.hasSuffix("ss") { continue }
            return String(word.dropLast(suffix.count)) + replacement
        }
        return word
    }

    private static let suffixRules: [(String, String)] = [
        ("ations", ""), ("ation", ""), ("ating", ""), ("ated", ""), ("ates", ""), ("ate", ""),
        ("ies", "y"), ("ied", "y"), ("ings", ""), ("ing", ""), ("ers", ""), ("er", ""),
        ("ed", ""), ("es", ""), ("ly", ""), ("s", ""), ("e", ""),
    ]

    static let stopwords: Set<String> = [
        "a", "about", "above", "after", "again", "all", "almost", "also", "am", "an", "and", "any", "are", "aren't",
        "as", "at", "back", "be", "because", "been", "before", "being", "below", "between", "both", "but", "by",
        "can", "can't", "cannot", "could", "couldn't", "did", "didn't", "do", "does", "doesn't", "doing", "don't",
        "down", "during", "each", "either", "else", "even", "ever", "every", "few", "for", "from", "further", "get",
        "gets", "getting", "go", "goes", "going", "gonna", "got", "had", "hadn't", "has", "hasn't", "have",
        "haven't", "having", "he", "her", "here", "here's", "hers", "him", "his", "how", "i", "i'd", "i'll", "i'm",
        "i've", "if", "in", "into", "is", "isn't", "it", "it's", "its", "itself", "just", "kind", "kinda", "know",
        "let", "let's", "like", "little", "look", "looks", "lot", "make", "makes", "maybe", "me", "might", "more",
        "most", "much", "must", "my", "need", "needs", "never", "no", "nor", "not", "now", "of", "off", "oh", "ok",
        "okay", "on", "once", "one", "only", "or", "other", "our", "ours", "out", "over", "own", "pretty",
        "probably", "quite", "rather", "really", "right", "same", "see", "seems", "she", "should", "shouldn't",
        "so", "some", "something", "sort", "still", "such", "sure", "than", "that", "that's", "the", "their",
        "theirs", "them", "then", "there", "there's", "these", "they", "they're", "thing", "things", "think",
        "this", "those", "though", "through", "to", "too", "um", "uh", "under", "until", "up", "us", "very",
        "want", "wants", "was", "wasn't", "way", "we", "we'll", "we're", "we've", "well", "were", "weren't",
        "what", "what's", "when", "where", "which", "while", "who", "whole", "why", "will", "with", "won't",
        "would", "wouldn't", "yeah", "yes", "yet", "you", "you'd", "you'll", "you're", "you've", "your",
        "yours", "actually", "basically", "bit", "anyway", "wait", "hmm", "mean", "said", "say", "says",
        "able", "already", "always", "another", "around", "come", "done", "fine", "first",
        "good", "great", "guess", "happen", "happens", "hey", "instead", "keep", "less", "lots", "next",
        "nice", "nothing", "often", "people", "put", "seem", "since", "stuff", "take", "tell", "try",
        "use", "used", "via", "whatever", "whether", "work", "works",
    ]
}

struct PhraseMatch: Sendable {
    var phrase: String
    var weight: Double
    var start: Int
    var length: Int

    var end: Int { start + length }

    func overlaps(_ other: PhraseMatch) -> Bool {
        start < other.end && other.start < end
    }
}

struct PhraseSet: Sendable {
    private struct Phrase: Sendable {
        var text: String
        var tokens: [String]
        var weight: Double
    }

    private let phrases: [Phrase]

    init(_ weighted: [WeightedPhrase]) {
        phrases = weighted
            .map { Phrase(text: $0.phrase, tokens: TextAnalysis.tokens($0.phrase), weight: $0.weight) }
            .filter { !$0.tokens.isEmpty }
            .sorted { $0.tokens.count > $1.tokens.count }
    }

    init(_ texts: [String], weight: Double) {
        self.init(texts.map { WeightedPhrase($0, weight: weight) })
    }

    func matchAtLead(of tokens: [String], openers: Set<String>, depth: Int) -> PhraseMatch? {
        var position = 0
        while position < tokens.count && position <= depth {
            if let match = longestMatch(in: tokens, at: position) { return match }
            guard openers.contains(tokens[position]) else { return nil }
            position += 1
        }
        return nil
    }

    func matchInTail(of tokens: [String], depth: Int) -> PhraseMatch? {
        let windowStart = max(0, tokens.count - depth)
        var best: PhraseMatch?
        for position in windowStart..<tokens.count {
            guard let match = longestMatch(in: tokens, at: position) else { continue }
            if best == nil || match.length > best!.length { best = match }
        }
        return best
    }

    private func longestMatch(in tokens: [String], at position: Int) -> PhraseMatch? {
        for phrase in phrases where position + phrase.tokens.count <= tokens.count {
            if tokens[position..<(position + phrase.tokens.count)].elementsEqual(phrase.tokens) {
                return PhraseMatch(phrase: phrase.text, weight: phrase.weight, start: position, length: phrase.tokens.count)
            }
        }
        return nil
    }
}
