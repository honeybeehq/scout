import CryptoKit
import Foundation

nonisolated struct LinearIssueRef: Codable, Hashable, Sendable {
    var id: String
    var identifier: String
    var url: URL
}

nonisolated struct LinearIssue: Decodable, Sendable {
    var ref: LinearIssueRef
    var isGone: Bool
    var description: String?
    var parent: LinearIssueRef?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.remoteID(.id)
        let identifier = try container.remoteText(.identifier, limit: 24)
        let url = try container.decode(String.self, forKey: .url)
        guard let url = RemoteURL.issue(url) else {
            throw DecodingError.dataCorruptedError(forKey: .url, in: container, debugDescription: "Unexpected issue URL")
        }
        ref = LinearIssueRef(id: id, identifier: identifier, url: url)
        let trashed = try container.decodeIfPresent(Bool.self, forKey: .trashed) ?? false
        let archived = try container.decodeIfPresent(String.self, forKey: .archivedAt) != nil
        isGone = trashed || archived
        description = try container.decodeIfPresent(String.self, forKey: .description).map { String($0.prefix(20_000)) }
        parent = try container.decodeIfPresent(LinearIssue.self, forKey: .parent)?.ref
    }

    private enum CodingKeys: String, CodingKey { case id, identifier, url, trashed, archivedAt, description, parent }
}

nonisolated struct LinearUploadTarget: Decodable, Sendable {
    private struct Header: Decodable {
        var key: String
        var value: String
    }

    var uploadURL: URL
    var assetURL: URL
    var contentType = "application/octet-stream"
    var headers: [(String, String)]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let upload = RemoteURL.https(try container.decode(String.self, forKey: .uploadUrl)) else {
            throw DecodingError.dataCorruptedError(forKey: .uploadUrl, in: container, debugDescription: "Unexpected upload URL")
        }
        guard let asset = RemoteURL.asset(try container.decode(String.self, forKey: .assetUrl)) else {
            throw DecodingError.dataCorruptedError(forKey: .assetUrl, in: container, debugDescription: "Unexpected asset URL")
        }
        uploadURL = upload
        assetURL = asset
        let forbidden: Set<String> = ["authorization", "cookie", "host", "content-length"]
        headers = (try container.decodeIfPresent([Header].self, forKey: .headers) ?? [])
            .filter { !forbidden.contains($0.key.lowercased()) && $0.key.count <= 64 && $0.value.count <= 2048 }
            .map { ($0.key, $0.value) }
    }

    private enum CodingKeys: String, CodingKey { case uploadUrl, assetUrl, headers }
}

nonisolated enum RemoteURL {
    static func https(_ text: String) -> URL? {
        guard text.count <= 4096, let url = URL(string: text), url.scheme == "https", url.host() != nil else { return nil }
        return url
    }

    static func issue(_ text: String) -> URL? {
        https(text).flatMap { $0.host() == "linear.app" ? $0 : nil }
    }

    static func asset(_ text: String) -> URL? {
        https(text).flatMap { $0.host() == "uploads.linear.app" ? $0 : nil }
    }
}

nonisolated struct LinearIssueInput: Sendable {
    var id: String?
    var teamID: String
    var projectID: String?
    var title: String
    var description: String
    var labelIDs: [String]
    var priority: Int
    var parentID: String?
    var subIssueSortOrder: Int?

    var value: LinearValue {
        var input: [String: LinearValue] = [
            "teamId": .string(teamID),
            "title": .string(title),
            "description": .string(description),
            "labelIds": .list(labelIDs.map(LinearValue.string)),
            "priority": .int(priority),
        ]
        if let id { input["id"] = .string(id) }
        if let projectID { input["projectId"] = .string(projectID) }
        if let parentID { input["parentId"] = .string(parentID) }
        if let subIssueSortOrder { input["subIssueSortOrder"] = .int(subIssueSortOrder) }
        return .object(input)
    }
}

nonisolated extension LinearOperations {
    struct IssueData: Decodable, Sendable { var issue: LinearIssue? }
    struct IssueCreateData: Decodable, Sendable {
        struct Payload: Decodable, Sendable {
            var success: Bool
            var issue: LinearIssue?
        }
        var issueCreate: Payload
    }
    struct FileUploadData: Decodable, Sendable {
        struct Payload: Decodable, Sendable {
            var success: Bool
            var uploadFile: LinearUploadTarget?
        }
        var fileUpload: Payload
    }
    struct SearchData: Decodable, Sendable { var searchIssues: LinearNodes<LinearIssue> }
    struct AttachmentCreateData: Decodable, Sendable {
        struct Attachment: Decodable, Sendable {
            var id: String

            init(from decoder: Decoder) throws {
                id = try decoder.container(keyedBy: CodingKeys.self).remoteID(.id)
            }

            private enum CodingKeys: String, CodingKey { case id }
        }
        struct Payload: Decodable, Sendable {
            var success: Bool
            var attachment: Attachment?
        }
        var attachmentCreate: Payload
    }

    static func issue(id: String) -> LinearOperation<IssueData> {
        LinearOperation(
            name: "issue",
            document: "query($id: String!) { issue(id: $id) { id identifier url trashed archivedAt parent { id identifier url } } }",
            variables: ["id": .string(id)]
        )
    }

    static func createIssue(_ input: LinearIssueInput) -> LinearOperation<IssueCreateData> {
        LinearOperation(
            name: "issueCreate",
            kind: .mutation(teamID: input.teamID),
            document: "mutation($input: IssueCreateInput!) { issueCreate(input: $input) { success issue { id identifier url } } }",
            variables: ["input": input.value]
        )
    }

    static func fileUpload(contentType: String, filename: String, size: Int, teamID: String) -> LinearOperation<FileUploadData> {
        LinearOperation(
            name: "fileUpload",
            kind: .mutation(teamID: teamID),
            document: "mutation($contentType: String!, $filename: String!, $size: Int!) { fileUpload(contentType: $contentType, filename: $filename, size: $size) { success uploadFile { uploadUrl assetUrl headers { key value } } } }",
            variables: ["contentType": .string(contentType), "filename": .string(filename), "size": .int(size)]
        )
    }

    struct IssueClipsData: Decodable, Sendable {
        struct Attachment: Decodable, Sendable {
            var id: String
            var url: String
            var subtitle: String?

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = try container.remoteID(.id)
                url = String(try container.decode(String.self, forKey: .url).prefix(4096))
                subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle).map { RemoteText.clean($0) }
            }

            private enum CodingKeys: String, CodingKey { case id, url, subtitle }
        }
        struct Issue: Decodable, Sendable {
            var description: String?
            var attachments: LinearNodes<Attachment>
        }
        var issue: Issue?
    }
    struct IssueUpdateData: Decodable, Sendable {
        struct Payload: Decodable, Sendable { var success: Bool }
        var issueUpdate: Payload
    }
    struct AttachmentDeleteData: Decodable, Sendable {
        struct Payload: Decodable, Sendable { var success: Bool }
        var attachmentDelete: Payload
    }

    static func issueClips(id: String) -> LinearOperation<IssueClipsData> {
        LinearOperation(
            name: "issueClips",
            document: "query($id: String!) { issue(id: $id) { description attachments(first: 50) { nodes { id url subtitle } } } }",
            variables: ["id": .string(id)]
        )
    }

    static func updateDescription(issueID: String, teamID: String, description: String) -> LinearOperation<IssueUpdateData> {
        LinearOperation(
            name: "issueUpdate",
            kind: .mutation(teamID: teamID),
            document: "mutation($id: String!, $input: IssueUpdateInput!) { issueUpdate(id: $id, input: $input) { success } }",
            variables: ["id": .string(issueID), "input": .object(["description": .string(description)])]
        )
    }

    static func deleteAttachment(id: String, teamID: String) -> LinearOperation<AttachmentDeleteData> {
        LinearOperation(
            name: "attachmentDelete",
            kind: .mutation(teamID: teamID),
            document: "mutation($id: String!) { attachmentDelete(id: $id) { success } }",
            variables: ["id": .string(id)]
        )
    }

    static func attachClip(id: String?, issueID: String, teamID: String, url: URL, title: String) -> LinearOperation<AttachmentCreateData> {
        var input: [String: LinearValue] = [
            "issueId": .string(issueID),
            "url": .string(url.absoluteString),
            "title": .string(title),
            "subtitle": .string(LinearFiler.clipSubtitle),
        ]
        if let id { input["id"] = .string(id) }
        return LinearOperation(
            name: "attachmentCreate",
            kind: .mutation(teamID: teamID),
            document: "mutation($input: AttachmentCreateInput!) { attachmentCreate(input: $input) { success attachment { id } } }",
            variables: ["input": .object(input)]
        )
    }

    static func searchIssues(term: String, team: String) -> LinearOperation<SearchData> {
        LinearOperation(
            name: "searchIssues",
            document: "query($term: String!, $team: ID!) { searchIssues(term: $term, first: 5, filter: { team: { id: { eq: $team } } }) { nodes { id identifier url trashed archivedAt description parent { id identifier url } } } }",
            variables: ["term": .string(term), "team": .string(team)]
        )
    }
}

nonisolated enum LinearIdentity {
    static func issueID(workspaceID: String, key: String) -> String {
        uuid(workspaceID + "\n" + key)
    }

    static func clipAttachmentID(workspaceID: String, key: String, contentHash: String) -> String {
        uuid(workspaceID + "\n" + key + ":clip:" + contentHash)
    }

    private static func uuid(_ text: String) -> String {
        var bytes = Array(SHA256.hash(data: Data(text.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let parts = [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4), hex.dropFirst(16).prefix(4), hex.dropFirst(20)]
        return parts.joined(separator: "-")
    }
}

nonisolated struct LinearCandidate: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var identifier: String
    var title: String
    var url: URL
    var state: String?

    var ref: LinearIssueRef {
        LinearIssueRef(id: id, identifier: identifier, url: url)
    }
}

nonisolated struct LinearCandidateNode: Decodable, Sendable {
    private struct State: Decodable { var name: String? }

    var candidate: LinearCandidate?

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self),
              let id = try? container.remoteID(.id),
              let identifier = try? container.remoteText(.identifier, limit: 24),
              let title = try? container.remoteText(.title, limit: 120),
              let url = (try? container.decode(String.self, forKey: .url)).flatMap(RemoteURL.issue)
        else { return }
        let trashed = (try? container.decodeIfPresent(Bool.self, forKey: .trashed)) ?? false
        let archived = ((try? container.decodeIfPresent(String.self, forKey: .archivedAt)) ?? nil) != nil
        guard !trashed, !archived else { return }
        let state = ((try? container.decodeIfPresent(State.self, forKey: .state)) ?? nil)?.name.map { RemoteText.clean($0, limit: 32) }
        candidate = LinearCandidate(id: id, identifier: identifier, title: title, url: url, state: state)
    }

    private enum CodingKeys: String, CodingKey { case id, identifier, title, url, trashed, archivedAt, state }
}

nonisolated struct LinearCommentRef: Codable, Hashable, Sendable {
    var id: String
    var url: URL?
}

nonisolated struct LinearCommentTarget: Decodable, Sendable {
    struct Comment: Decodable, Sendable {
        var id: String
        var url: URL?
        var body: String

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.remoteID(.id)
            url = try container.decodeIfPresent(String.self, forKey: .url).flatMap(RemoteURL.issue)
            body = String((try container.decodeIfPresent(String.self, forKey: .body) ?? "").prefix(20_000))
        }

        private enum CodingKeys: String, CodingKey { case id, url, body }
    }

    private struct Team: Decodable { var id: String }

    var issue: LinearIssue
    var teamID: String
    var comments: [Comment]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        issue = try LinearIssue(from: decoder)
        teamID = try container.decode(Team.self, forKey: .team).id
        comments = try container.decodeIfPresent(LinearNodes<Comment>.self, forKey: .comments)?.nodes ?? []
    }

    private enum CodingKeys: String, CodingKey { case team, comments }
}

nonisolated extension LinearOperations {
    struct DuplicatesData: Decodable, Sendable { var searchIssues: LinearNodes<LinearCandidateNode> }
    struct CommentTargetData: Decodable, Sendable { var issue: LinearCommentTarget? }
    struct CommentCreateData: Decodable, Sendable {
        struct Comment: Decodable, Sendable {
            var id: String
            var url: URL?

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = try container.remoteID(.id)
                url = try container.decodeIfPresent(String.self, forKey: .url).flatMap(RemoteURL.issue)
            }

            private enum CodingKeys: String, CodingKey { case id, url }
        }
        struct Payload: Decodable, Sendable {
            var success: Bool
            var comment: Comment?
        }
        var commentCreate: Payload
    }

    static func duplicates(term: String, team: String) -> LinearOperation<DuplicatesData> {
        LinearOperation(
            name: "duplicates",
            document: "query($term: String!, $team: ID!) { searchIssues(term: $term, first: 6, filter: { team: { id: { eq: $team } }, state: { type: { nin: [\"completed\", \"canceled\"] } } }) { nodes { id identifier title url trashed archivedAt state { name } } } }",
            variables: ["term": .string(term), "team": .string(team)]
        )
    }

    static func commentTarget(id: String) -> LinearOperation<CommentTargetData> {
        LinearOperation(
            name: "commentTarget",
            document: "query($id: String!) { issue(id: $id) { id identifier url trashed archivedAt description team { id } comments(first: 100) { nodes { id url body } } } }",
            variables: ["id": .string(id)]
        )
    }

    static func createComment(id: String?, issueID: String, teamID: String, body: String) -> LinearOperation<CommentCreateData> {
        var input: [String: LinearValue] = ["issueId": .string(issueID), "body": .string(body)]
        if let id { input["id"] = .string(id) }
        return LinearOperation(
            name: "commentCreate",
            kind: .mutation(teamID: teamID),
            document: "mutation($input: CommentCreateInput!) { commentCreate(input: $input) { success comment { id url } } }",
            variables: ["input": .object(input)]
        )
    }
}

nonisolated extension LinearIdentity {
    static func commentID(workspaceID: String, key: String, target: String) -> String {
        Self.issueID(workspaceID: workspaceID, key: key + ":comment:" + target)
    }
}
