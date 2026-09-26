import Foundation

public protocol SemanticSimilarity: Sendable {
    func similarity(of candidate: String, to context: String) -> Double?
}

public struct LexicalSimilarity: SemanticSimilarity {
    public var minimumCandidateTerms: Int
    public var minimumContextTerms: Int

    public init(minimumCandidateTerms: Int = 2, minimumContextTerms: Int = 3) {
        self.minimumCandidateTerms = minimumCandidateTerms
        self.minimumContextTerms = minimumContextTerms
    }

    public func similarity(of candidate: String, to context: String) -> Double? {
        let candidateTerms = TextAnalysis.contentTerms(candidate)
        let contextTerms = TextAnalysis.contentTerms(context)
        guard candidateTerms.count >= minimumCandidateTerms, contextTerms.count >= minimumContextTerms else { return nil }
        let dot = candidateTerms.keys.sorted().reduce(0.0) { sum, term in
            sum + Double(candidateTerms[term]! * (contextTerms[term] ?? 0))
        }
        return dot / (Self.norm(candidateTerms) * Self.norm(contextTerms))
    }

    private static func norm(_ terms: [String: Int]) -> Double {
        terms.keys.sorted().reduce(0.0) { $0 + Double(terms[$1]! * terms[$1]!) }.squareRoot()
    }
}
