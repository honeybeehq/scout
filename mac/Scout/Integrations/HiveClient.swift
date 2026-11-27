import Foundation
import Network

struct HiveSession: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var handle: String?
    var title: String?
    var agent: String
    var cwd: String?
    var lastOutputAt: Date?
    var isWorking: Bool
    var isWaitingForYou: Bool
    var isRunning: Bool
    var workspaceTag: String?
    var isChampion = false

    var pickerTarget: ApiaryTarget {
        var target = ApiaryTarget(kind: "session", id: id, sessionID: id, title: isChampion ? name : displayTitle, handle: handle, subtitle: projectName)
        target.name = name
        target.sessionTitle = title
        target.championName = isChampion ? name : nil
        target.workspaceID = workspaceTag.map { String($0.dropFirst("apiary:workspace=".count)) }
        target.state = isWaitingForYou ? "Waiting for you" : isWorking ? "Working" : nil
        target.lastActiveAt = lastOutputAt
        target.viaApiary = false
        return target
    }

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return name
    }

    var projectName: String? {
        cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
    }
}

nonisolated struct HiveClient: Sendable {
    enum HiveError: LocalizedError {
        case notInstalled
        case handshakeFailed
        case timedOut
        case requestFailed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled: "hive isn't running on this Mac."
            case .handshakeFailed: "hive answered with an unexpected protocol."
            case .timedOut: "hive didn't answer in time."
            case .requestFailed(let message): message
            }
        }
    }

    static let protocolVersion = "v2/2"

    var socketPath: String

    init(socketPath: String = HiveClient.defaultSocketPath) {
        self.socketPath = socketPath
    }

    static var defaultSocketPath: String {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["HIVE_V2_SOCKET_PATH"] { return path }
        if let dataDirectory = environment["HIVE_V2_DATA_DIR"] { return dataDirectory + "/hived.sock" }
        return NSHomeDirectory() + "/.hive/v2/hived.sock"
    }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: socketPath)
    }

    func activeSessions(limit: Int = 50, timeout: Duration = .seconds(8)) async throws -> [HiveSession] {
        let result = try await call(verb: "list", params: ["lifecycle": "active"], timeout: timeout)
        let views = (result["views"] as? [[String: Any]]) ?? []
        return views
            .compactMap(Self.session(from:))
            .sorted { ($0.lastOutputAt ?? .distantPast) > ($1.lastOutputAt ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }

    struct Receipt: Sendable {
        var messageID: String?
        var deduped: Bool
    }

    @discardableResult
    func send(to sessionID: String, body: String, idempotencyKey: String? = nil) async throws -> Receipt {
        var params: [String: Any] = ["beeId": sessionID, "body": body, "urgency": "next"]
        if let idempotencyKey { params["idempotencyKey"] = idempotencyKey }
        let result = try await call(verb: "send", params: params)
        let messageID = (result["messageId"] as? Int).map(String.init) ?? result["messageId"] as? String
        return Receipt(messageID: messageID, deduped: result["deduped"] as? Bool ?? false)
    }

    @discardableResult
    func spawn(name: String, agent: String, cwd: String, title: String?, prompt: String, idempotencyKey: String? = nil) async throws -> String? {
        var params: [String: Any] = ["name": name, "agent": agent, "cwd": cwd, "prompt": prompt]
        if let title { params["title"] = title }
        if let idempotencyKey { params["idempotencyKey"] = idempotencyKey }
        let result = try await call(verb: "spawn", params: params)
        return result["beeId"] as? String
    }

    func stop(_ beeID: String) async throws {
        _ = try await call(verb: "stop", params: ["beeId": beeID])
    }

    struct OptimiseStatus: Sendable {
        let state: String?
        let generation: Int?
        let logPath: String?
        let pending: Bool
        let undelivered: Bool
        let failure: String?
    }

    func optimiseStatus(_ beeID: String) async throws -> OptimiseStatus {
        let result = try await call(verb: "view", params: ["beeId": beeID])
        guard let bee = result["bee"] as? [String: Any], bee["id"] as? String == beeID else { throw HiveError.requestFailed("hive returned a different optimiser session.") }
        let runtime = result["runtime"] as? [String: Any]
        let view = result["view"] as? [String: Any]
        let commandResult = try await call(verb: "commands", params: ["beeId": beeID])
        let commands = commandResult["commands"] as? [[String: Any]] ?? []
        let pending = commands.contains { ["queued", "running"].contains($0["status"] as? String ?? "") }
        let failed = commands.first { ["spawn", "send_wake"].contains($0["verb"] as? String ?? "") && ($0["status"] as? String == "failed" || ($0["failureCause"] != nil && !($0["failureCause"] is NSNull))) }
        let flags = view?["flags"] as? [String] ?? []
        let crashed = runtime?["state"] as? String == "stopped" && runtime?["exitCause"] as? String == "crashed"
        let failureFlags = flags.filter { ["spawn_failed", "auth_needed", "resource_blocked", "node_unreachable"].contains($0) }
        for flag in flags where !failureFlags.contains(flag) { NSLog("[scout-optimise] unknown hive flag: %@", flag) }
        let failedBoot = !failureFlags.isEmpty || failed != nil || crashed
        var failure: String?
        if failedBoot {
            let audit = try await call(verb: "audit.tail", params: ["beeId": beeID, "limit": 100])
            let rows = audit["rows"] as? [[String: Any]] ?? []
            let detail = rows.reversed().compactMap { row -> String? in
                guard ["command.requeued", "flag.set", "runtime.transition"].contains(row["kind"] as? String ?? ""), let payload = row["payload"] as? [String: Any] else { return nil }
                return payload["detail"] as? String ?? payload["exitDetail"] as? String
            }.first
            failure = "Claude could not start: " + (detail ?? failed?["failureCause"].map { String(describing: $0) } ?? (failureFlags.isEmpty ? "the harness exited before completing its reply" : failureFlags.joined(separator: ", ")))
        }
        let mailResult = try await call(verb: "mailbox", params: ["beeId": beeID])
        let messages = mailResult["messages"] as? [[String: Any]] ?? []
        return OptimiseStatus(state: runtime?["state"] as? String, generation: runtime?["generation"] as? Int, logPath: bee["sessionLogPath"] as? String, pending: pending, undelivered: messages.contains { $0["deliveredAt"] == nil || $0["deliveredAt"] is NSNull }, failure: failure)
    }

    func finalOptimiseReply(_ status: OptimiseStatus) throws -> String? {
        guard status.state == "idle" || status.state == "stopped", let path = status.logPath else { return nil }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        try handle.seek(toOffset: length > 4_194_304 ? length - 4_194_304 : 0)
        let data = try handle.readToEnd() ?? Data()
        var reply: String?
        for line in data.split(separator: 10) {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], row["isSidechain"] as? Bool != true, row["parent_tool_use_id"] == nil || row["parent_tool_use_id"] is NSNull else { continue }
            if row["type"] as? String == "assistant", let message = row["message"] as? [String: Any], message["role"] as? String == "assistant", let content = message["content"] as? [[String: Any]] {
                reply = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
            }
            if row["type"] as? String == "result", row["is_error"] as? Bool != true, let result = row["result"] as? String { reply = result }
        }
        return reply
    }

    func stopOptimise(_ beeID: String) async throws {
        let deadline = Date().addingTimeInterval(20)
        var sent = false
        var stoppedGeneration: Int?
        var previousState: String?
        var last: OptimiseStatus?
        while Date() < deadline {
            let status = try await optimiseStatus(beeID)
            last = status
            if status.state == "stopped", !status.pending { return }
            let newer = (status.generation ?? 0) > (stoppedGeneration ?? 0)
            let woke = previousState == "stopped" && status.state != "stopped"
            if !sent || newer || woke {
                try await stop(beeID)
                sent = true
                stoppedGeneration = status.generation
            }
            previousState = status.state
            try await Task.sleep(for: .milliseconds(500))
        }
        let fields = "state=\(last?.state ?? "none") generation=\(last?.generation.map(String.init) ?? "none") pending=\(last?.pending.description ?? "none") undelivered=\(last?.undelivered.description ?? "none") lastStopGeneration=\(stoppedGeneration.map(String.init) ?? "none")"
        NSLog("[scout-optimise] stop confirmation timed out bee=%@ %@", beeID, fields)
        throw HiveError.requestFailed("Claude has not confirmed cancellation. Check its optimiser session in hive. " + fields)
    }

    private static func session(from view: [String: Any]) -> HiveSession? {
        guard let bee = view["bee"] as? [String: Any],
              let id = bee["id"] as? String,
              (bee["lifecycle"] as? String) == "active"
        else { return nil }
        let state = view["view"] as? [String: Any]
        let runtime = view["runtime"] as? [String: Any]
        let tags = bee["tags"] as? [String] ?? []
        return HiveSession(
            id: id,
            name: bee["name"] as? String ?? id,
            handle: bee["handle"] as? String,
            title: bee["title"] as? String,
            agent: bee["agent"] as? String ?? "agent",
            cwd: bee["cwd"] as? String,
            lastOutputAt: (bee["lastOutputAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) },
            isWorking: state?["working"] as? Bool ?? false,
            isWaitingForYou: state?["waitingForYou"] as? Bool ?? false,
            isRunning: (runtime?["state"] as? String) == "running",
            workspaceTag: tags.first { $0.hasPrefix("apiary:workspace=") },
            isChampion: tags.contains("apiary:role=champion")
        )
    }

    private func call(verb: String, params: [String: Any], timeout: Duration = .seconds(8)) async throws -> [String: Any] {
        guard isInstalled else { throw HiveError.notInstalled }
        let connection = LineConnection(path: socketPath)
        defer { connection.close() }
        let expired = Once()
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            expired.run { connection.close() }
        }
        defer { watchdog.cancel() }
        do {
            return try await exchange(on: connection, verb: verb, params: params)
        } catch {
            throw expired.hasRun ? HiveError.timedOut : error
        }
    }

    private func exchange(on connection: LineConnection, verb: String, params: [String: Any]) async throws -> [String: Any] {
        try await connection.open()

        let hello = try await connection.readJSON()
        guard (hello["protocol"] as? String) == Self.protocolVersion else { throw HiveError.handshakeFailed }
        try await connection.writeJSON(["protocol": Self.protocolVersion])
        try await connection.writeJSON(["id": 1, "verb": verb, "params": params])

        while true {
            let message = try await connection.readJSON()
            guard (message["id"] as? Int) == 1 else { continue }
            if message["ok"] as? Bool == true {
                return message["result"] as? [String: Any] ?? [:]
            }
            let error = message["error"] as? [String: Any]
            throw HiveError.requestFailed(error?["message"] as? String ?? "hive rejected \(verb).")
        }
    }
}

nonisolated private final class LineConnection: @unchecked Sendable {
    enum LineError: Error {
        case closed
        case malformed
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "scout.hive.connection")
    private var buffer = Data()
    private var scanned = 0

    init(path: String) {
        connection = NWConnection(to: .unix(path: path), using: .tcp)
    }

    func open() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = Once()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumed.run { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    resumed.run { continuation.resume(throwing: error) }
                case .cancelled:
                    resumed.run { continuation.resume(throwing: LineError.closed) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    func close() {
        connection.cancel()
    }

    func writeJSON(_ object: [String: Any]) async throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    func readJSON() async throws -> [String: Any] {
        while true {
            if let newline = buffer[(buffer.startIndex + scanned)...].firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[(newline + 1)...])
                scanned = 0
                guard !line.isEmpty else { continue }
                guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw LineError.malformed }
                return object
            }
            scanned = buffer.count
            buffer.append(try await receive())
        }
    }

    private func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4 << 20) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: LineError.closed)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }
}

nonisolated private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    var hasRun: Bool {
        lock.lock()
        defer { lock.unlock() }
        return done
    }

    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}
