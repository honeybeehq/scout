import Foundation
import ScoutCore

extension Dispatcher {
    func file(_ card: SnippetCard, in target: LinearTarget) async {
        card.state = .sending
        card.linearStep = .checking
        defer { card.linearStep = nil }
        await linear.loadTeamDetails(target.team.id)
        await ensureBrief(for: card)
        card.videoFailed = false
        card.addToFailed = false
        let includeVideo = includesVideo(card)
        let video = includeVideo ? await preparedVideo(for: card) : nil
        if includeVideo, video == nil {
            card.videoFailed = true
            card.state = .failed("Scout couldn't prepare the video.")
            return
        }
        let images = await linearImages(for: card)
        let base = issueInput(for: card)
        let marks = card.snippet.marks
        let hasRecording = card.hasRecording
        let assembled: @Sendable ([StoredAsset]) -> IssueInput = { assets in
            var input = base
            if let clip = assets.first(where: \.isVideo), let video {
                input.clip = .included(url: clip.url.absoluteString, duration: video.duration, hiddenParts: video.hiddenParts)
            } else {
                input.clip = hasRecording ? .notIncluded : .none
            }
            input.pins = assets.compactMap { asset in
                guard let number = Self.pinNumber(asset.name) else { return nil }
                let caption = marks.indices.contains(number - 1) ? marks[number - 1].target?.displayName ?? "Pinned spot" : "Pinned spot"
                return IssueInput.Pin(number: number, caption: caption, url: asset.url.absoluteString)
            }
            return input
        }
        let compose: @Sendable ([StoredAsset]) -> IssueDraft = { IssueComposer.compose(assembled($0)) }
        let addTo = card.linearOptions.addTo
        var composeComment: (@Sendable ([StoredAsset], String?) -> String)?
        if addTo != nil {
            composeComment = { assets, existing in IssueComposer.composeComment(assembled(assets), existing: existing) }
        }
        if dryRun {
            var local = images.map { StoredAsset(provider: .linear, name: $0.lastPathComponent, url: URL(string: $0.lastPathComponent) ?? $0, contentHash: "") }
            if let video { local.insert(StoredAsset(provider: .linear, name: video.url.lastPathComponent, url: URL(string: video.url.lastPathComponent) ?? video.url, contentHash: "", kind: .video, byteCount: video.byteCount), at: 0) }
            let draft = compose(local)
            let directory = card.sessionDirectory.appendingPathComponent("snippets/\(card.snippet.id)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if let addTo, let composeComment {
                    let header = "<!-- comment on \(addTo.identifier) in \(target.team.key) -->\n\n"
                    try (header + composeComment(local, nil) + "\n").write(to: directory.appendingPathComponent("comment.md"), atomically: true, encoding: .utf8)
                } else {
                    let header = "# \(draft.title)\n\n<!-- team \(target.team.key) · labels \(labelIDs(for: card, team: target.team.id)) · priority \(priority(for: card)) -->\n\n"
                    try (header + draft.markdown + "\n").write(to: directory.appendingPathComponent("issue.md"), atomically: true, encoding: .utf8)
                }
                card.state = .sent("\(target.label) (dry run)")
            } catch {
                card.state = .failed(error.localizedDescription)
            }
            return
        }
        let parent: (issue: LinearIssueRef, position: Int)?
        do {
            parent = addTo == nil ? try await linearParent?(card) : nil
        } catch {
            card.state = .failed("Couldn't file the parent issue. " + ((error as? LinearError)?.message ?? "Couldn't reach Linear."))
            return
        }
        do {
            let request = LinearFiler.Request(
                key: card.linearKey,
                target: target,
                credential: try linear.credential(),
                images: images,
                video: video,
                includeVideo: includeVideo,
                clipTitle: "Scout clip · \(IssueComposer.clock(video?.duration ?? 0))",
                previous: card.linearReceipt,
                labelIDs: labelIDs(for: card, team: target.team.id),
                priority: priority(for: card),
                parent: parent?.issue,
                subIssuePosition: parent?.position,
                compose: compose,
                addTo: addTo?.ref,
                composeComment: composeComment
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
        } catch LinearError.targetGone(let identifier) {
            card.addToFailed = true
            card.state = .failed(LinearError.targetGone(identifier).message)
        } catch LinearError.forbidden where addTo != nil {
            card.addToFailed = true
            card.state = .failed("Scout can't add to \(addTo?.identifier ?? "that issue"): it isn't in \(target.team.key) or this key can't see it.")
        } catch LinearError.deletedRemotely {
            card.linearReceipt = LinearReceipt(key: card.linearKey, status: .deletedRemotely, assets: card.linearReceipt?.assets ?? [])
            card.state = .failed(LinearError.deletedRemotely.message)
        } catch let error as LinearError {
            card.videoFailed = error == .tooLarge || error == .videoUploadFailed
            card.state = .failed(error.message)
        } catch {
            card.state = .failed("Couldn't reach Linear.")
        }
    }

    func fileWithoutVideo(_ card: SnippetCard) async {
        guard !card.isLocked else { return }
        card.linearOptions.includeVideo = false
        card.videoFailed = false
        card.state = .held
        await send(card)
    }

    func includesVideo(_ card: SnippetCard) -> Bool {
        card.hasRecording && (card.linearOptions.includeVideo ?? linear.preferences.includesVideo)
    }

    func preparedVideo(for card: SnippetCard) async -> RenderedMedia? {
        guard includesVideo(card) else { return nil }
        let redaction = card.linearOptions.redaction
        let key = "\(card.snippet.range.start)|\(card.snippet.range.end)|\(redaction?.fingerprint ?? "none")"
        if let current = card.videoPreparation, current.key == key { return await current.task.value }
        let previous = card.videoPreparation?.task
        previous?.cancel()
        let directory = card.sessionDirectory.appendingPathComponent("snippets/\(card.snippet.id)", isDirectory: true)
        let snippet = card.snippet
        let recorder = card.recorder
        let session = card.sessionVideo
        let task = Task { () -> RenderedMedia? in
            _ = await previous?.value
            guard !Task.isCancelled else { return nil }
            let clip: ExportedClip?
            if let recorder {
                clip = await SnippetMedia.clip(for: snippet, recorder: recorder, into: directory)
            } else if let session {
                clip = await SnippetMedia.clip(for: snippet, video: session, into: directory)
            } else {
                clip = nil
            }
            guard let clip, !Task.isCancelled else { return nil }
            return try? await ClipRedactor.render(clip, redaction: redaction)
        }
        card.videoPreparation = (key, task)
        card.isPreparingVideo = true
        let media = await task.value
        if card.videoPreparation?.key == key {
            card.preparedVideo = media
            card.isPreparingVideo = false
            if media == nil { card.videoPreparation = nil }
        }
        return media
    }

    func clipDuration(for card: SnippetCard) -> Double {
        if let media = card.preparedVideo, media.redaction == card.linearOptions.redaction { return media.duration }
        let range = card.clipRange
        return card.linearOptions.redaction?.keptDuration(in: range) ?? range.duration
    }

    func fileAsNewIssue(_ card: SnippetCard) async {
        if card.addToFailed, !card.isLocked {
            card.linearOptions.addTo = nil
            card.linearOptions.fileNew = true
            card.addToFailed = false
            card.state = .held
            await send(card)
            return
        }
        guard card.linearReceipt?.status == .deletedRemotely, !card.isLocked else { return }
        card.linearGeneration += 1
        card.linearReceipt = nil
        card.state = .held
        await send(card)
    }

    func chooseAnotherIssue(_ card: SnippetCard) {
        guard card.addToFailed, !card.isLocked else { return }
        card.linearOptions.addTo = nil
        card.linearOptions.fileNew = nil
        card.addToFailed = false
        card.duplicates = .idle
        card.state = .held
        onCardChanged?(card)
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
        let input = previewInput(for: card)
        if let addTo = card.linearOptions.addTo {
            return IssueDraft(title: "Comment on \(addTo.identifier)", markdown: IssueComposer.composeComment(input, existing: nil))
        }
        return IssueComposer.compose(input)
    }

    private func previewInput(for card: SnippetCard) -> IssueInput {
        var input = issueInput(for: card)
        if includesVideo(card) {
            let hidden = card.linearOptions.redaction.map { $0.regions.count + $0.mergedCuts(in: card.clipRange).count } ?? 0
            input.clip = .included(url: "clip.mp4", duration: clipDuration(for: card), hiddenParts: hidden)
        } else if card.hasRecording {
            input.clip = .notIncluded
        }
        let redaction = card.linearOptions.redaction
        input.pins = card.snippet.marks.enumerated().compactMap { index, mark in
            guard redaction?.cuts(near: mark.at, within: SnippetMedia.pinSlack) != true else { return nil }
            return IssueInput.Pin(number: index + 1, caption: mark.target?.displayName ?? "Pinned spot", url: "pin-\(index + 1).png")
        }
        return input
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
        let redaction = card.linearOptions.redaction
        if let recorder = card.recorder {
            attachments = await SnippetMedia.attachments(for: snippet, recorder: recorder, into: directory, clip: false, redaction: redaction)
        } else if let video = card.sessionVideo {
            attachments = await SnippetMedia.attachments(for: snippet, video: video, displays: card.sessionDisplays, into: directory, clip: false, redaction: redaction)
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
