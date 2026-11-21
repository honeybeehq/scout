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
    static func duplicateTerm(for card: SnippetCard) -> String {
        var term = IssueComposer.title(card.title)
        if let target = card.targets.first, let name = target.component ?? target.label, !name.isEmpty, !term.localizedCaseInsensitiveContains(name) {
            term += " " + name
        }
        return String(term.prefix(200))
    }

    func checkDuplicates(for card: SnippetCard, in target: LinearTarget, debounce: Bool) async {
        guard !card.isLocked, linear.isConnected else { return }
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
        let own = [
            linear.viewer.map { LinearIdentity.issueID(workspaceID: $0.organization.id, key: card.linearKey) },
            card.linearReceipt?.issue?.id,
        ].compactMap { $0 }
        do {
            let found = try await linear.duplicates(term: term, team: target.team.id)
            guard card.duplicates == .checking(term: term) else { return }
            card.duplicates = .found(term: term, found.filter { !own.contains($0.id) })
        } catch {
            guard card.duplicates == .checking(term: term) else { return }
            card.duplicates = .failed(term: term)
        }
    }
}
