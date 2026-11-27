import Foundation

public struct HeuristicRanker: TargetRanker {
    public var nameWeight: Double
    public var keywordWeight: Double
    public var normalizesKeywords: Bool
    public var recencyWeight: Double
    public var temperature = 1.5

    public init(nameWeight: Double = 3, keywordWeight: Double = 2.5, normalizesKeywords: Bool = true, recencyWeight: Double = 0.5) {
        self.nameWeight = nameWeight
        self.keywordWeight = keywordWeight
        self.normalizesKeywords = normalizesKeywords
        self.recencyWeight = recencyWeight
    }

    public static let untuned = HeuristicRanker(keywordWeight: 0.35, normalizesKeywords: false, recencyWeight: 1)

    public func rank(_ feedback: RankFeedback, candidates: [RankCandidate], now: Date) async throws -> TargetRanking {
        let started = ContinuousClock.now
        let spoken = [feedback.transcript, feedback.pageTitle ?? ""].joined(separator: " ")
        let spokenPhrase = " " + Self.words(spoken).joined(separator: " ") + " "
        let context = Set(Self.keywords(spoken + " " + (feedback.urlHost ?? "") + " " + (feedback.appName ?? "")))
        let scores = candidates.map { candidate -> (String, Double) in
            let nameWords = Self.words(candidate.name)
            var name = 0.0
            if !nameWords.isEmpty, spokenPhrase.contains(" " + nameWords.joined(separator: " ") + " ") {
                name = 1
            } else {
                let distinctive = Set(Self.keywords(candidate.name))
                if !distinctive.isEmpty { name = 0.5 * Double(distinctive.intersection(context).count) / Double(distinctive.count) }
            }
            let profile = Set(Self.keywords([candidate.name, candidate.bio ?? "", candidate.project ?? "", candidate.workspace ?? ""].joined(separator: " ")))
            let shared = Double(profile.intersection(context).count)
            let keyword = normalizesKeywords ? keywordWeight * shared / Double(max(profile.count, 1)).squareRoot() : min(2.5, keywordWeight * shared)
            let recency = RecencyBucket(lastActiveAt: candidate.lastActiveAt, now: now).weight
            let score = nameWeight * name + keyword + recencyWeight * recency
            return (candidate.key, exp(temperature * score))
        }
        return .normalized(scores, source: .heuristic, elapsed: .now - started)
    }

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .folding(options: [.diacriticInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    static func keywords(_ text: String) -> [String] {
        words(text).filter { $0.count >= 3 && !stopwords.contains($0) }.map(stem)
    }

    static func stem(_ word: String) -> String {
        for suffix in ["ing", "es", "s"] where word.count > suffix.count + 3 && word.hasSuffix(suffix) {
            return String(word.dropLast(suffix.count))
        }
        return word
    }

    static let stopwords: Set<String> = [
        "the", "and", "for", "but", "not", "with", "this", "that", "there", "here", "its", "it's", "just", "like", "should", "would", "could",
        "when", "what", "which", "who", "whatever", "then", "than", "from", "into", "onto", "out", "off", "all", "any", "one", "two", "some",
        "are", "was", "were", "been", "being", "have", "has", "had", "does", "did", "doing", "can", "cant", "don", "dont", "isn", "doesn",
        "you", "your", "they", "them", "their", "our", "we", "she", "his", "her", "him", "itself", "myself", "okay", "yeah", "right", "now",
        "also", "again", "still", "even", "only", "very", "really", "pretty", "sure", "thing", "things", "stuff", "look", "watch", "want",
        "need", "needs", "make", "makes", "get", "gets", "got", "say", "says", "said", "way", "too", "more", "most", "much", "every",
        "about", "after", "before", "over", "under", "down", "up", "next", "back", "same", "other", "another", "each", "both", "how", "why",
        "www", "com", "http", "https", "html",
    ]
}
