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

    func upload(_ file: URL, to target: LinearUploadTarget) async throws(LinearError) {
        guard let state else { throw .uploadFailed }
        let uploads = state.appendingPathComponent("uploads", isDirectory: true)
        try? FileManager.default.createDirectory(at: uploads, withIntermediateDirectories: true)
        let destination = uploads.appendingPathComponent(target.uploadURL.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        do { try FileManager.default.copyItem(at: file, to: destination) } catch { throw .uploadFailed }
        log(state, "PUT upload \(target.uploadURL.lastPathComponent)")
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
            log(state, "issueCreate(id: \(requested ?? "none"))")
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
            let token = UUID().uuidString.lowercased()
            log(state, "fileUpload(\(name))")
            return reply(["fileUpload": ["success": true, "uploadFile": [
                "uploadUrl": "https://storage.fixture.invalid/\(token)",
                "assetUrl": "https://uploads.linear.app/fixture/\(token)/\(name)",
                "headers": [["key": "x-goog-content-length-range", "value": "0,52428800"]],
            ]]])
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
