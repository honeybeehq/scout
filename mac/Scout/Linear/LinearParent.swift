import Foundation
import ScoutCore

nonisolated struct LinearParent: Codable, Hashable, Sendable {
    var issue: LinearIssueRef
    var target: LinearTarget
    var description: String?
}

struct LinearParentPlan {
    var target: LinearTarget
    var children: [SnippetCard]
    var elsewhere: [SnippetCard]

    var waitingChildren: Int {
        children.filter { !$0.isLocked }.count
    }

    var waitingElsewhere: [SnippetCard] {
        elsewhere.filter { !$0.isLocked }
    }

    var cautionText: String? {
        let waiting = waitingElsewhere
        guard !waiting.isEmpty else { return nil }
        let keys = waiting.compactMap { $0.destination?.linearTarget?.team.key }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let teams = keys.count == 1 ? keys[0] : keys.dropLast().joined(separator: ", ") + " and " + (keys.last ?? "")
        return waiting.count == 1 ? "1 task goes to \(teams) and won't be a sub-issue." : "\(waiting.count) tasks go to \(teams) and won't be sub-issues."
    }
}

extension SessionReview {
    var linearParentKey: String {
        "scout:\(sessionID):parent"
    }

    var linearStructure: LinearStructure {
        linearStructureChoice ?? dispatcher.linear.preferences.structure(for: segmentation)
    }

    var showsLinearStructure: Bool {
        tasks.contains { !$0.isLocked && $0.destination?.linearTarget != nil }
    }

    var linearPlan: LinearParentPlan? {
        guard linearStructure == .parent else { return nil }
        let linear = tasks.filter { $0.destination?.linearTarget != nil && ($0.linearOptions.addTo == nil || $0.linearReceipt?.issue != nil) }
        func standalone(_ card: SnippetCard) -> Bool {
            guard let receipt = card.linearReceipt, receipt.issue != nil else { return false }
            if receipt.addedTo != nil { return true }
            return receipt.parent == nil || receipt.parent?.id != linearParent?.issue.id
        }
        guard let target = linearParent?.target ?? linear.first(where: { !standalone($0) })?.destination?.linearTarget else { return nil }
        var plan = LinearParentPlan(target: target, children: [], elsewhere: [])
        for card in linear {
            let sameTeam = card.destination?.linearTarget?.team.id == target.team.id
            if standalone(card) {
                if !sameTeam { plan.elsewhere.append(card) }
            } else if sameTeam {
                plan.children.append(card)
            } else {
                plan.elsewhere.append(card)
            }
        }
        return plan.children.isEmpty ? nil : plan
    }

    var parentTitle: String {
        linearParentTitle ?? linearSessionLine?.title ?? suggestedParentTitle
    }

    var suggestedParentTitle: String {
        linearSessionLine?.title ?? "Playtest · \(startedAt.formatted(.dateTime.day().month(.abbreviated).hour().minute())) · \(apps.first ?? "Scout")"
    }

    func loadSessionLine() async {
        if let running = sessionLineLoad { return await running.value }
        guard linearSessionLine == nil, !tasks.isEmpty else { return }
        let inputs = tasks.map(\.briefInput)
        let load = Task {
            let line = await TaskSummarisers.current.sessionLine(for: inputs)
            if let line, linearSessionLine == nil {
                linearSessionLine = line
                save()
            }
        }
        sessionLineLoad = load
        await load.value
    }

    func parentDraft(_ plan: LinearParentPlan) -> IssueDraft {
        func child(_ card: SnippetCard, team: Bool) -> ParentInput.Child {
            let fallback = team ? card.destination?.linearTarget?.team.key : nil
            return ParentInput.Child(title: card.title, identifier: card.linearReceipt?.issue?.identifier ?? fallback)
        }
        let apps = self.apps
        let count = plan.children.count
        let fallback = "\(count == 1 ? "1 task" : "\(count) tasks") from a \(SessionTimeline.clock(duration)) session" + (apps.isEmpty ? "." : " in \(apps.prefix(3).joined(separator: ", ")).")
        let input = ParentInput(
            key: linearParentKey,
            title: parentTitle,
            summary: linearSessionLine?.summary ?? fallback,
            children: plan.children.map { child($0, team: false) },
            elsewhere: plan.elsewhere.map { child($0, team: true) },
            recorded: startedAt.formatted(date: .abbreviated, time: .shortened) + " · " + SessionTimeline.clock(duration),
            apps: Array(apps.prefix(5)),
            project: tasks.lazy.compactMap(\.project).first
        )
        var draft = IssueComposer.composeParent(input)
        draft.markdown = draft.markdown.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        return draft
    }

    func ensureLinearParent(for card: SnippetCard) async throws -> (issue: LinearIssueRef, position: Int)? {
        guard !dispatcher.dryRun, let plan = linearPlan, let position = plan.children.firstIndex(where: { $0 === card }) else { return nil }
        if let parent = linearParent { return (parent.issue, position) }
        if let running = parentFiling { return (try await running.value, position) }
        let filing = Task { try await fileParent(plan, reporting: card) }
        parentFiling = filing
        defer { parentFiling = nil }
        return (try await filing.value, position)
    }

    private func fileParent(_ plan: LinearParentPlan, reporting card: SnippetCard) async throws -> LinearIssueRef {
        await loadSessionLine()
        let draft = parentDraft(plan)
        let request = LinearFiler.Request(
            key: linearParentKey,
            target: plan.target,
            credential: try dispatcher.linear.credential(),
            images: [],
            video: nil,
            includeVideo: false,
            clipTitle: "",
            previous: nil,
            labelIDs: [],
            priority: 0,
            parent: nil,
            compose: { _ in draft }
        )
        let receipt: LinearReceipt
        do {
            receipt = try await dispatcher.linear.filer.file(request, pending: { _ in }, report: { [weak card] step in
                card?.linearStep = step == .creating ? .creatingParent : step
            })
        } catch LinearError.deletedRemotely {
            throw LinearError.server("It was deleted in Linear. Choose One issue per task to file the rest.")
        }
        guard let issue = receipt.issue else { throw LinearError.server("Linear didn't create the parent issue.") }
        if let parent = linearParent { return parent.issue }
        linearParent = LinearParent(issue: issue, target: plan.target, description: draft.markdown)
        save()
        return issue
    }

    func finishSending() async {
        if let parent = linearParent, let plan = linearPlan, !dispatcher.dryRun, let credential = try? dispatcher.linear.credential() {
            let markdown = parentDraft(plan).markdown
            if markdown != parent.description,
               await dispatcher.linear.filer.updateDescription(of: parent.issue, team: parent.target.team.id, to: markdown, credential: credential) {
                linearParent?.description = markdown
            }
        }
        save()
    }
}
