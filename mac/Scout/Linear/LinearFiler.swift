import CryptoKit
import Foundation

actor LinearFiler {
    enum Identity: Sendable {
        case clientID
        case marker
    }

    enum Step: Sendable, Equatable {
        case checking
        case uploading(Int, of: Int)
        case uploadingVideo(sent: Int, total: Int)
        case creating
        case creatingParent
        case attaching
        case updating
        case waiting(until: Date)
    }

    struct Request: Sendable {
        var key: String
        var target: LinearTarget
        var credential: LinearCredential
        var images: [URL]
        var video: RenderedMedia?
        var includeVideo: Bool
        var clipTitle: String
        var previous: LinearReceipt?
        var labelIDs: [String]
        var priority: Int
        var parent: LinearIssueRef?
        var compose: @Sendable ([StoredAsset]) -> IssueDraft
    }

    typealias Report = @MainActor @Sendable (Step) -> Void
    typealias Pending = @MainActor @Sendable (LinearReceipt) -> Void

    private static let markerWorkspacesKey = "linear.markerWorkspaces"

    private let api: any LinearAPI
    struct Memory: @unchecked Sendable {
        let defaults: UserDefaults
    }

    private let memory: Memory
    private var workspaces: [String: String] = [:]
    private var tail: Task<Void, Never>?

    init(api: any LinearAPI, memory: Memory) {
        self.api = api
        self.memory = memory
    }

    private func identity(for workspace: String) -> Identity {
        (memory.defaults.stringArray(forKey: Self.markerWorkspacesKey) ?? []).contains(workspace) ? .marker : .clientID
    }

    private func useMarkers(for workspace: String) {
        let known = memory.defaults.stringArray(forKey: Self.markerWorkspacesKey) ?? []
        if !known.contains(workspace) { memory.defaults.set(known + [workspace], forKey: Self.markerWorkspacesKey) }
    }

    func file(_ request: Request, pending: @escaping Pending, report: @escaping Report) async throws -> LinearReceipt {
        let previous = tail
        let task = Task {
            await previous?.value
            return try await self.perform(request, pending: pending, report: report)
        }
        tail = Task { _ = await task.result }
        return try await task.value
    }

    private func perform(_ request: Request, pending: Pending, report: @escaping Report) async throws -> LinearReceipt {
        let workspace = try await retrying(report) { try await self.workspaceID(request.credential) }
        let mode = identity(for: workspace)
        let issueID = mode == .clientID ? LinearIdentity.issueID(workspaceID: workspace, key: request.key) : nil
        await report(.checking)
        let video = request.video.flatMap { LocalAsset.video($0, includeVideo: request.includeVideo) }
        let storage = LinearStorage(api: api, credential: request.credential, teamID: request.target.team.id)
        if let existing = try await find(issueID, request: request, report: report) {
            var kept = (request.previous?.assets ?? []).filter { !$0.isVideo || $0.contentHash == video?.contentHash }
            if let video, !kept.contains(where: \.isVideo) {
                kept.insert(try await upload(video, to: storage, report: report), at: 0)
            }
            let attached = kept.contains(where: \.isVideo) ? request.previous?.clipAttachmentID : nil
            var receipt = LinearReceipt(key: request.key, status: .filed(existing.ref), assets: kept, clipAttachmentID: attached, unlinkedClip: request.previous?.unlinkedClip, parent: existing.parent)
            receipt = try await reconcileClip(receipt, issue: existing.ref, request: request, report: report)
            return await attachClip(receipt, video: video, request: request, workspace: workspace, mode: mode, report: report)
        }
        var stored: [StoredAsset] = []
        if let asset = video {
            if let done = request.previous?.assets.first(where: { $0.contentHash == asset.contentHash }) {
                stored.append(done)
            } else {
                stored.append(try await upload(asset, to: storage, report: report))
            }
        }
        for (index, url) in request.images.enumerated() {
            guard let asset = LocalAsset.image(at: url) else { continue }
            if let done = request.previous?.assets.first(where: { $0.contentHash == asset.contentHash }) {
                stored.append(done)
                continue
            }
            await report(.uploading(index + 1, of: request.images.count))
            stored.append(try await retrying(report) { try await storage.store(asset, name: url.lastPathComponent) { _, _ in } })
        }
        await pending(LinearReceipt(key: request.key, status: .pending, assets: stored))
        let draft = request.compose(stored)
        let input = LinearIssueInput(
            id: issueID,
            teamID: request.target.team.id,
            projectID: request.target.project?.id,
            title: draft.title,
            description: draft.markdown,
            labelIDs: request.labelIDs,
            priority: request.priority,
            parentID: request.parent?.id
        )
        await report(.creating)
        do {
            let reply = try await retrying(report) { try await self.api.perform(LinearOperations.createIssue(input), credential: request.credential) }.issueCreate
            guard reply.success, let issue = reply.issue else { throw LinearError.server("Linear didn't create the issue.") }
            return await attachClip(LinearReceipt(key: request.key, status: .filed(issue.ref), assets: stored, parent: request.parent), video: video, request: request, workspace: workspace, mode: mode, report: report)
        } catch {
            if let existing = try await find(issueID, request: request, report: report) {
                return await attachClip(LinearReceipt(key: request.key, status: .filed(existing.ref), assets: stored, parent: existing.parent ?? request.parent), video: video, request: request, workspace: workspace, mode: mode, report: report)
            }
            if mode == .clientID, case LinearError.server(let message) = error, Self.refusesClientIDs(message) {
                useMarkers(for: workspace)
                var retry = request
                retry.previous = LinearReceipt(key: request.key, status: .pending, assets: stored)
                return try await perform(retry, pending: pending, report: report)
            }
            throw error
        }
    }

    private func upload(_ asset: LocalAsset, to storage: LinearStorage, report: @escaping Report) async throws -> StoredAsset {
        await report(.uploadingVideo(sent: 0, total: asset.byteCount))
        let progress: @Sendable (Int, Int) -> Void = { sent, total in
            Task { @MainActor in report(.uploadingVideo(sent: sent, total: max(total, asset.byteCount))) }
        }
        return try await retrying(report) { try await storage.store(asset, name: "clip.mp4", progress: progress) }
    }

    private func reconcileClip(_ receipt: LinearReceipt, issue: LinearIssueRef, request: Request, report: Report) async throws -> LinearReceipt {
        guard let state = try await retrying(report, { try await self.api.perform(LinearOperations.issueClips(id: issue.id), credential: request.credential) }).issue else { return receipt }
        var receipt = receipt
        let current = receipt.video?.url.absoluteString
        let teamID = request.target.team.id
        var unlinked = false
        for node in state.attachments.nodes where node.subtitle == Self.clipSubtitle && node.url != current {
            await report(.updating)
            let reply = try await retrying(report) { try await self.api.perform(LinearOperations.deleteAttachment(id: node.id, teamID: teamID), credential: request.credential) }
            guard reply.attachmentDelete.success else { throw LinearError.server("Linear didn't remove the earlier clip card.") }
            if receipt.clipAttachmentID == node.id { receipt.clipAttachmentID = nil }
            unlinked = true
        }
        if let description = state.description, description.contains("clip.mp4"), current.map({ !description.contains($0) }) ?? true {
            let clip: IssueInput.Clip
            if let current, let media = request.video {
                clip = .included(url: current, duration: media.duration, hiddenParts: media.hiddenParts)
            } else {
                clip = .notIncluded
            }
            if let updated = IssueComposer.replacingClip(in: description, with: clip), updated != description {
                await report(.updating)
                let reply = try await retrying(report) { try await self.api.perform(LinearOperations.updateDescription(issueID: issue.id, teamID: teamID, description: updated), credential: request.credential) }
                guard reply.issueUpdate.success else { throw LinearError.server("Linear didn't update the issue's clip link.") }
                unlinked = true
            }
        }
        if unlinked { receipt.unlinkedClip = true }
        return receipt
    }

    static let clipSubtitle = "Recorded with Scout"

    private func attachClip(_ receipt: LinearReceipt, video current: LocalAsset?, request: Request, workspace: String, mode: Identity, report: Report) async -> LinearReceipt {
        guard request.includeVideo, receipt.clipAttachmentID == nil, let current, let video = receipt.video, video.contentHash == current.contentHash, let issue = receipt.issue else { return receipt }
        var receipt = receipt
        let id = mode == .clientID ? LinearIdentity.clipAttachmentID(workspaceID: workspace, key: request.key, contentHash: video.contentHash) : nil
        let operation = LinearOperations.attachClip(id: id, issueID: issue.id, teamID: request.target.team.id, url: video.url, title: request.clipTitle)
        await report(.attaching)
        do {
            let reply = try await retrying(report) { try await self.api.perform(operation, credential: request.credential) }.attachmentCreate
            if reply.success { receipt.clipAttachmentID = reply.attachment?.id ?? id }
        } catch LinearError.server(let message) where id != nil && Self.meansConflict(message) {
            receipt.clipAttachmentID = id
        } catch {}
        return receipt
    }

    private static func meansConflict(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("already exists") || lowered.contains("conflict")
    }

    func updateDescription(of issue: LinearIssueRef, team teamID: String, to description: String, credential: LinearCredential) async -> Bool {
        let previous = tail
        let task = Task { () -> Bool in
            await previous?.value
            let operation = LinearOperations.updateDescription(issueID: issue.id, teamID: teamID, description: description)
            return (try? await self.retrying({ _ in }) { try await self.api.perform(operation, credential: credential) }.issueUpdate.success) ?? false
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    private func find(_ issueID: String?, request: Request, report: Report) async throws -> LinearIssue? {
        let issue: LinearIssue?
        if let issueID {
            do {
                issue = try await retrying(report) { try await self.api.perform(LinearOperations.issue(id: issueID), credential: request.credential) }.issue
            } catch LinearError.notFound {
                issue = nil
            }
        } else {
            let marker = "`\(request.key)`"
            let nodes = try await retrying(report) {
                try await self.api.perform(LinearOperations.searchIssues(term: request.key, team: request.target.team.id), credential: request.credential)
            }.searchIssues.nodes
            issue = nodes.first { $0.description?.contains(marker) == true }
        }
        guard let issue else { return nil }
        if issue.isGone { throw LinearError.deletedRemotely }
        return issue
    }

    private func workspaceID(_ credential: LinearCredential) async throws -> String {
        let fingerprint = SHA256.hash(data: Data(credential.authorization.utf8)).map { String(format: "%02x", $0) }.joined()
        if let known = workspaces[fingerprint] { return known }
        let workspace = try await api.perform(LinearOperations.viewer, credential: credential).viewer.organization.id
        workspaces[fingerprint] = workspace
        return workspace
    }

    private func retrying<Value: Sendable>(_ report: Report, _ body: @Sendable () async throws -> Value) async throws -> Value {
        var delays: [Double] = [2, 8, 30]
        var waits = 0
        while true {
            do {
                return try await body()
            } catch LinearError.offline where !delays.isEmpty {
                try await Task.sleep(for: .seconds(delays.removeFirst()))
            } catch LinearError.rateLimited(let until) where waits < 3 {
                waits += 1
                let resume = until ?? Date().addingTimeInterval(60)
                await report(.waiting(until: resume))
                try await Task.sleep(for: .seconds(min(3600, max(1, resume.timeIntervalSinceNow))))
            }
        }
    }

    private static func refusesClientIDs(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("argument validation") && lowered.contains("id")
    }
}
