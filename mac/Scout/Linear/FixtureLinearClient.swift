import Foundation

nonisolated struct FixtureLinearClient: LinearAPI {
    var directory: URL
    var rejectsKeys = false
    var state: URL?

    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    func perform<Response>(_ operation: LinearOperation<Response>, credential: LinearCredential) async throws(LinearError) -> Response {
        try operation.checkAllowed()
        try? await Task.sleep(for: .milliseconds(150))
        if let state, let reply = try await remote(operation, state: state) {
            return try LinearResponse.decode(reply, status: 200, rateLimitReset: nil)
        }
        let names = [
            rejectsKeys ? "\(operation.name)-rejected" : nil,
            operation.variables["team"]?.string.map { "\(operation.name)-\($0)" },
            operation.name,
        ].compactMap { $0 }
        let file = names.map { directory.appendingPathComponent("\($0).json") }.first { FileManager.default.fileExists(atPath: $0.path) }
        guard let file, let data = try? Data(contentsOf: file) else { throw .offline }
        return try LinearResponse.decode(data, status: 200, rateLimitReset: nil)
    }

    func upload(_ file: URL, to target: LinearUploadTarget, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws(LinearError) {
        guard let state, let data = try? Data(contentsOf: file) else { throw .uploadFailed }
        let uploads = state.appendingPathComponent("uploads", isDirectory: true)
        try? FileManager.default.createDirectory(at: uploads, withIntermediateDirectories: true)
        let destination = uploads.appendingPathComponent(target.uploadURL.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        let seconds = target.contentType.hasPrefix("video/") ? environment["SCOUT_LINEAR_FIXTURE_UPLOAD_SECONDS"].flatMap(Double.init) ?? 0 : 0
        let steps = seconds > 0 ? 20 : 1
        let total = Int64(data.count)
        for step in 1...steps {
            if seconds > 0 { try? await Task.sleep(for: .seconds(seconds / Double(steps))) }
            progress(total * Int64(step) / Int64(steps), total)
        }
        do { try data.write(to: destination) } catch { throw .uploadFailed }
        log(state, "PUT upload \(target.uploadURL.lastPathComponent) \(target.contentType) \(data.count) bytes")
    }

    private func remote<Response>(_ operation: LinearOperation<Response>, state: URL) async throws(LinearError) -> Data? {
        let issues = state.appendingPathComponent("issues", isDirectory: true)
        try? FileManager.default.createDirectory(at: issues, withIntermediateDirectories: true)
        switch operation.name {
        case "issue":
            let id = operation.variables["id"]?.string ?? ""
            log(state, "issue(id: \(id))")
            guard let issue = stored(id, in: issues) else { return reply(errors: "Entity not found: Issue", code: "INVALID_INPUT") }
            return reply(["issue": issue])
        case "issueCreate":
            guard let input = operation.variables["input"]?.object else { throw .malformed }
            let requested = input["id"]?.string
            let parentID = input["parentId"]?.string
            log(state, "issueCreate(id: \(requested ?? "none"), team: \(teamKey(input["teamId"]?.string ?? "")), parentId: \(parentID ?? "none"), title: \(input["title"]?.string ?? ""))")
            if requested != nil, environment["SCOUT_LINEAR_FIXTURE_REFUSE_IDS"] == "1" {
                return reply(errors: "Argument Validation Error: id is not allowed", code: "INVALID_INPUT")
            }
            let id = requested ?? UUID().uuidString.lowercased()
            if stored(id, in: issues) != nil { return reply(errors: "Conflict: an entity with this id already exists", code: "INVALID_INPUT") }
            let teamID = input["teamId"]?.string ?? ""
            let number = nextNumber(state)
            let identifier = "\(teamKey(teamID))-\(number)"
            var issue: [String: Any] = [
                "id": id,
                "identifier": identifier,
                "url": "https://linear.app/acme/issue/\(identifier.lowercased())",
                "trashed": false,
                "teamId": teamID,
                "title": input["title"]?.string ?? "",
                "description": input["description"]?.string ?? "",
                "priority": input["priority"].flatMap { if case .int(let value) = $0 { value } else { nil } } ?? 0,
                "labelIds": (input["labelIds"].flatMap { if case .list(let values) = $0 { values.compactMap(\.string) } else { nil } }) ?? [],
                "state": "Backlog",
            ]
            if let project = input["projectId"]?.string { issue["projectId"] = project }
            if let parentID {
                guard let parent = stored(parentID, in: issues) else { return reply(errors: "Entity not found: parent issue", code: "INVALID_INPUT") }
                issue["parent"] = ["id": parentID, "identifier": parent["identifier"] ?? "", "url": parent["url"] ?? ""]
            }
            if let data = try? JSONSerialization.data(withJSONObject: issue, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: issues.appendingPathComponent("\(id).json"))
            }
            log(state, "created \(identifier) id=\(id)")
            if let delay = environment["SCOUT_LINEAR_FIXTURE_CREATE_DELAY"].flatMap(Double.init) {
                log(state, "holding the issueCreate reply for \(delay) s")
                try? await Task.sleep(for: .seconds(delay))
            }
            return reply(["issueCreate": ["success": true, "issue": issue]])
        case "fileUpload":
            let name = operation.variables["filename"]?.string ?? "file"
            let contentType = operation.variables["contentType"]?.string ?? "?"
            let size = operation.variables["size"].flatMap { if case .int(let value) = $0 { value } else { nil } } ?? 0
            let token = UUID().uuidString.lowercased()
            log(state, "fileUpload(\(name), \(contentType), \(size) bytes)")
            if contentType.hasPrefix("video/"), let limit = environment["SCOUT_LINEAR_FIXTURE_MAX_VIDEO"].flatMap(Int.init), size > limit {
                return reply(errors: "File too large: \(size) bytes exceeds the upload limit", code: "INVALID_INPUT")
            }
            return reply(["fileUpload": ["success": true, "uploadFile": [
                "uploadUrl": "https://storage.fixture.invalid/\(token)",
                "assetUrl": "https://uploads.linear.app/fixture/\(token)/\(name)",
                "headers": [["key": "x-goog-content-length-range", "value": "0,52428800"]],
            ]]])
        case "issueClips":
            let id = operation.variables["id"]?.string ?? ""
            log(state, "issueClips(id: \(id))")
            guard let issue = stored(id, in: issues) else { return reply(errors: "Entity not found: Issue", code: "INVALID_INPUT") }
            let nodes = (issue["attachments"] as? [[String: Any]] ?? []).map { ["id": $0["id"] ?? "", "url": $0["url"] ?? "", "subtitle": $0["subtitle"] ?? ""] }
            return reply(["issue": ["description": issue["description"] ?? "", "attachments": ["nodes": nodes]]])
        case "issueUpdate":
            let id = operation.variables["id"]?.string ?? ""
            guard var issue = stored(id, in: issues), let description = operation.variables["input"]?.object?["description"]?.string else { return reply(errors: "Entity not found: Issue", code: "INVALID_INPUT") }
            let clipLine = description.split(separator: "\n").first { $0.contains("clip.mp4") || $0.contains("Video not included") } ?? ""
            log(state, "issueUpdate(id: \(id), \(issue["identifier"] ?? "?"), clip line: \(clipLine), description: \(description.count) chars)")
            issue["description"] = description
            issue["updatedCount"] = (issue["updatedCount"] as? Int ?? 0) + 1
            if let data = try? JSONSerialization.data(withJSONObject: issue, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: issues.appendingPathComponent("\(id).json"))
            }
            return reply(["issueUpdate": ["success": true]])
        case "attachmentDelete":
            let id = operation.variables["id"]?.string ?? ""
            log(state, "attachmentDelete(id: \(id))")
            let files = (try? FileManager.default.contentsOfDirectory(at: issues, includingPropertiesForKeys: nil)) ?? []
            for file in files {
                let issueID = file.deletingPathExtension().lastPathComponent
                guard var issue = stored(issueID, in: issues), var attachments = issue["attachments"] as? [[String: Any]],
                      attachments.contains(where: { $0["id"] as? String == id }) else { continue }
                attachments.removeAll { $0["id"] as? String == id }
                issue["attachments"] = attachments
                if let data = try? JSONSerialization.data(withJSONObject: issue, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: issues.appendingPathComponent("\(issueID).json"))
                }
                return reply(["attachmentDelete": ["success": true]])
            }
            return reply(errors: "Entity not found: Attachment", code: "INVALID_INPUT")
        case "attachmentCreate":
            guard let input = operation.variables["input"]?.object else { throw .malformed }
            let id = input["id"]?.string ?? UUID().uuidString.lowercased()
            let issueID = input["issueId"]?.string ?? ""
            log(state, "attachmentCreate(id: \(input["id"]?.string ?? "none"), issue: \(issueID), url: \(input["url"]?.string ?? ""), title: \(input["title"]?.string ?? ""))")
            guard var issue = stored(issueID, in: issues) else { return reply(errors: "Entity not found: Issue", code: "INVALID_INPUT") }
            var attachments = issue["attachments"] as? [[String: Any]] ?? []
            if attachments.contains(where: { $0["id"] as? String == id }) {
                return reply(["attachmentCreate": ["success": true, "attachment": ["id": id]]])
            }
            attachments.append(["id": id, "url": input["url"]?.string ?? "", "title": input["title"]?.string ?? "", "subtitle": input["subtitle"]?.string ?? ""])
            issue["attachments"] = attachments
            if let data = try? JSONSerialization.data(withJSONObject: issue, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: issues.appendingPathComponent("\(issueID).json"))
            }
            return reply(["attachmentCreate": ["success": true, "attachment": ["id": id]]])
        case "searchIssues":
            let term = operation.variables["term"]?.string ?? ""
            log(state, "searchIssues(\(term))")
            let files = (try? FileManager.default.contentsOfDirectory(at: issues, includingPropertiesForKeys: nil)) ?? []
            let matches = files.compactMap { stored($0.deletingPathExtension().lastPathComponent, in: issues) }
                .filter { ($0["description"] as? String)?.contains(term) == true }
            return reply(["searchIssues": ["nodes": matches]])
        default:
            return nil
        }
    }

    private func stored(_ id: String, in issues: URL) -> [String: Any]? {
        guard RemoteText.isID(id), let data = try? Data(contentsOf: issues.appendingPathComponent("\(id).json")) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func teamKey(_ teamID: String) -> String {
        struct Envelope: Decodable { var data: LinearOperations.TeamsData }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("teams.json")),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        else { return "TST" }
        return envelope.data.teams.nodes.first { $0.id == teamID }?.key ?? "TST"
    }

    private func nextNumber(_ state: URL) -> Int {
        let counter = state.appendingPathComponent("counter")
        let number = ((try? String(contentsOf: counter, encoding: .utf8)).flatMap { Int($0) } ?? 0) + 1
        try? String(number).write(to: counter, atomically: true, encoding: .utf8)
        return number
    }

    private func reply(_ data: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["data": data])
    }

    private func reply(errors message: String, code: String) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["errors": [["message": message, "extensions": ["code": code]]]])
    }

    private func log(_ state: URL, _ line: String) {
        let file = state.appendingPathComponent("requests.log")
        let stamp = ISO8601DateFormatter().string(from: .now)
        let entry = Data("\(stamp) \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(entry)
            try? handle.close()
        } else {
            try? entry.write(to: file)
        }
    }
}
