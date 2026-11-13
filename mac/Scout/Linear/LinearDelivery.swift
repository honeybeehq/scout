import Foundation
import ScoutCore

extension Dispatcher {
    func file(_ card: SnippetCard, in target: LinearTarget) async {
        card.state = .sending
        card.linearStep = .checking
        defer { card.linearStep = nil }
        await linear.loadTeamDetails(target.team.id)
        await ensureBrief(for: card)
        let images = await linearImages(for: card)
        let base = issueInput(for: card)
        let marks = card.snippet.marks
        let compose: @Sendable ([StoredAsset]) -> IssueDraft = { assets in
            var input = base
            input.pins = assets.compactMap { asset in
                guard let number = Self.pinNumber(asset.name) else { return nil }
                let caption = marks.indices.contains(number - 1) ? marks[number - 1].target?.displayName ?? "Pinned spot" : "Pinned spot"
                return IssueInput.Pin(number: number, caption: caption, url: asset.url.absoluteString)
            }
            return IssueComposer.compose(input)
        }
        if dryRun {
            let local = images.map { StoredAsset(provider: .linear, name: $0.lastPathComponent, url: URL(string: $0.lastPathComponent) ?? $0, contentHash: "") }
            let draft = compose(local)
            let directory = card.sessionDirectory.appendingPathComponent("snippets/\(card.snippet.id)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let header = "# \(draft.title)\n\n<!-- team \(target.team.key) · labels \(labelIDs(for: card, team: target.team.id)) · priority \(priority(for: card)) -->\n\n"
                try (header + draft.markdown + "\n").write(to: directory.appendingPathComponent("issue.md"), atomically: true, encoding: .utf8)
                card.state = .sent("\(target.label) (dry run)")
            } catch {
                card.state = .failed(error.localizedDescription)
            }
            return
        }
        do {
            let request = LinearFiler.Request(
                key: card.linearKey,
                target: target,
                credential: try linear.credential(),
                images: images,
                previous: card.linearReceipt,
                labelIDs: labelIDs(for: card, team: target.team.id),
                priority: priority(for: card),
                compose: compose
            )
            let receipt = try await linear.filer.file(request, pending: { [weak self, weak card] receipt in
                guard let card else { return }
                card.linearReceipt = receipt
                self?.onCardChanged?(card)
            }, report: { [weak card] step in
                card?.linearStep = step
            })
            card.linearReceipt = receipt
            card.state = .sent(receipt.issue?.identifier ?? target.label)
        } catch LinearError.deletedRemotely {
            card.linearReceipt = LinearReceipt(key: card.linearKey, status: .deletedRemotely, assets: card.linearReceipt?.assets ?? [])
            card.state = .failed(LinearError.deletedRemotely.message)
        } catch let error as LinearError {
            card.state = .failed(error.message)
        } catch {
            card.state = .failed("Couldn't reach Linear.")
        }
    }

    func fileAsNewIssue(_ card: SnippetCard) async {
        guard card.linearReceipt?.status == .deletedRemotely, !card.isLocked else { return }
        card.linearGeneration += 1
        card.linearReceipt = nil
        card.state = .held
        await send(card)
    }

    func ensureBrief(for card: SnippetCard, regenerate: Bool = false) async {
        let input = card.briefInput
        if !regenerate, let brief = card.brief, brief.edited || brief.inputFingerprint == input.fingerprint { return }
        guard !card.isLocked || card.state == .sending, !card.isBriefing else { return }
        card.isBriefing = true
        let brief = await TaskSummarisers.current.brief(for: input)
        card.isBriefing = false
        guard card.briefInput.fingerprint == input.fingerprint, regenerate || card.brief?.edited != true else { return }
        card.brief = brief
        onCardChanged?(card)
    }

    func teamLabels(_ teamID: String) -> [LinearLabel] {
        linear.labels[teamID]?.value ?? []
    }

    func labelIDs(for card: SnippetCard, team teamID: String) -> [String] {
        let labels = teamLabels(teamID)
        if let chosen = card.linearOptions.labelIDs {
            return labels.isEmpty ? chosen : chosen.filter { id in labels.contains { $0.id == id } }
        }
        return LinearInference.labelIDs(for: card.brief?.kind ?? .bug, in: labels)
    }

    func priority(for card: SnippetCard) -> Int {
        card.linearOptions.priority ?? LinearPriority(card.brief?.urgency ?? .none).rawValue
    }

    func previewIssue(for card: SnippetCard) -> IssueDraft {
        var input = issueInput(for: card)
        input.pins = card.snippet.marks.enumerated().map { index, mark in
            IssueInput.Pin(number: index + 1, caption: mark.target?.displayName ?? "Pinned spot", url: "pin-\(index + 1).png")
        }
        return IssueComposer.compose(input)
    }

    private func issueInput(for card: SnippetCard) -> IssueInput {
        IssueInput(
            key: card.linearKey,
            title: card.title,
            brief: card.brief,
            transcript: card.transcript,
            transcriptEdited: card.transcriptOverride != nil,
            context: card.snippet.primaryContext,
            project: card.project,
            targets: card.targets,
            runtimeNotes: card.runtimeNotes,
            range: card.snippet.range,
            pins: [],
            homeDirectory: NSHomeDirectory()
        )
    }

    private func linearImages(for card: SnippetCard) async -> [URL] {
        let directory = card.sessionDirectory.appendingPathComponent("snippets/\(card.snippet.id)", isDirectory: true)
        let snippet = card.deliverableSnippet
        let attachments: [ComposedTask.Attachment]
        if let recorder = card.recorder {
            attachments = await SnippetMedia.attachments(for: snippet, recorder: recorder, into: directory, clip: false)
        } else if let video = card.sessionVideo {
            attachments = await SnippetMedia.attachments(for: snippet, video: video, displays: card.sessionDisplays, into: directory, clip: false)
        } else {
            attachments = []
        }
        return attachments.filter { $0.kind == .image }.map(\.url)
    }

    nonisolated private static func pinNumber(_ name: String) -> Int? {
        guard name.hasPrefix("pin-"), name.hasSuffix(".png") else { return nil }
        return Int(name.dropFirst(4).dropLast(4))
    }
}
