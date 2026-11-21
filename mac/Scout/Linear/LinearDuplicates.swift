import Foundation

enum DuplicateCheck: Equatable {
    case idle
    case checking(term: String)
    case found(term: String, [LinearCandidate])
    case failed(term: String)

    var term: String? {
        switch self {
        case .idle: nil
        case .checking(let term), .found(let term, _), .failed(let term): term
        }
    }

    var candidates: [LinearCandidate] {
        if case .found(_, let candidates) = self { candidates } else { [] }
    }
}

extension Dispatcher {
    private static let stopwords: Set<String> = [
        "the", "and", "for", "with", "this", "that", "these", "those", "from", "into", "onto", "when", "then", "than",
        "should", "would", "could", "can", "are", "was", "were", "been", "being", "has", "have", "had", "its", "it's",
        "not", "but", "too", "very", "just", "also", "all", "any", "some", "our", "your", "their", "there", "here",
        "what", "which", "who", "how", "why", "where", "about", "please", "make", "made", "does", "did", "get", "got",
    ]

    static func duplicateTerm(for card: SnippetCard) -> String {
        let title = IssueComposer.title(card.title).replacingOccurrences(of: #"\[[^\]]{1,40}\]"#, with: " ", options: .regularExpression)
        var words: [String] = []
        func add(_ text: String) {
            for word in text.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") }) {
                let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
                guard trimmed.count >= 3, !stopwords.contains(trimmed.lowercased()), !words.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { continue }
                words.append(trimmed)
            }
        }
        add(title)
        if let target = card.targets.first, let name = target.component ?? target.label { add(name) }
        let term = words.prefix(12).joined(separator: " ")
        return String((term.isEmpty ? IssueComposer.title(card.title) : term).prefix(200))
    }

    static func duplicateTitle(for card: SnippetCard) -> String {
        let title = IssueComposer.title(card.title).replacingOccurrences(of: #"\[[^\]]{1,40}\]"#, with: " ", options: .regularExpression)
        return String(title.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(200))
    }

    func checkDuplicates(for card: SnippetCard, in target: LinearTarget, excluding own: Set<String>, debounce: Bool) async {
        guard !card.isLocked, !card.addToFailed, linear.isConnected else { return }
        let term = Self.duplicateTerm(for: card)
        guard term.count >= 3 else {
            card.duplicates = .idle
            return
        }
        if card.duplicates.term == term, card.duplicates != .failed(term: term) { return }
        if debounce {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
        }
        card.duplicates = .checking(term: term)
        let session = "scout:\(card.sessionID):"
        do {
            let title = Self.duplicateTitle(for: card)
            let found = try await linear.duplicates(terms: title.count >= 3 && title != term ? [title, term] : [term], team: target.team.id)
            guard card.duplicates == .checking(term: term) else { return }
            card.duplicates = .found(term: term, found.filter { !own.contains($0.id) && $0.marker?.hasPrefix(session) != true })
        } catch {
            guard card.duplicates == .checking(term: term) else { return }
            card.duplicates = .failed(term: term)
        }
    }
}

extension SessionReview {
    var ownLinearIssueIDs: Set<String> {
        var ids = Set(tasks.compactMap { $0.linearReceipt?.addedTo == nil ? $0.linearReceipt?.issue?.id : nil })
        if let parent = linearParent?.issue.id { ids.insert(parent) }
        if let workspace = dispatcher.linear.viewer?.organization.id {
            for card in tasks { ids.insert(LinearIdentity.issueID(workspaceID: workspace, key: card.linearKey)) }
            ids.insert(LinearIdentity.issueID(workspaceID: workspace, key: linearParentKey))
        }
        return ids
    }
}
