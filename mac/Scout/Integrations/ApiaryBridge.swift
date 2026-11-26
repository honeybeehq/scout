import AppKit
import Foundation
import Network
import ScoutCore

nonisolated struct ApiaryDiscovery: Decodable, Sendable {
    var `protocol`: String
    var socketPath: String
    var token: String
    var pid: Int32
    var instanceId: String

    static let protocolVersion = "apiary-scout/1"

    static var path: String {
        let prefix = "--apiary-bridge="
        if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }) {
            return String(argument.dropFirst(prefix.count))
        }
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["SCOUT_APIARY_BRIDGE"], !path.isEmpty { return path }
        let home = environment["APIARY_HOME_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory() + "/.apiary"
        return home + "/scout-bridge.json"
    }

    static func read(from path: String = ApiaryDiscovery.path) -> ApiaryDiscovery? {
        guard let data = FileManager.default.contents(atPath: path),
              let discovery = try? JSONDecoder().decode(ApiaryDiscovery.self, from: data),
              discovery.protocol.split(separator: "/").first == "apiary-scout",
              discovery.pid > 0, kill(discovery.pid, 0) == 0 || errno == EPERM
        else { return nil }
        return discovery
    }
}

nonisolated enum ApiaryBridgeError: Error, Equatable, LocalizedError {
    case absent
    case unreachable
    case timeout
    case refused(code: String, message: String)

    var code: String {
        switch self {
        case .absent: "absent"
        case .unreachable: "unreachable"
        case .timeout: "timeout"
        case .refused(let code, _): code
        }
    }

    var errorDescription: String? {
        switch self {
        case .absent: "Apiary isn't running."
        case .unreachable: "Apiary didn't answer."
        case .timeout: "Apiary didn't answer in time."
        case .refused(_, let message): message
        }
    }
}

nonisolated struct ApiaryHello: Sendable {
    var instanceId: String
    var apiaryPID: pid_t
    var capabilities: Set<String>
    var windows: [Rect]
}

nonisolated struct ApiaryPoint: Sendable {
    var hit: Bool
    var stack: [JSONValue]
    var staleWindows: Bool
}

nonisolated struct ApiaryLook: Hashable, Sendable {
    var key: String
    var image: String?
    var tint: String?
    var tintDark: String?
    var glyph: String?
    var iconSvg: String?

    init(key: String, image: String? = nil, tint: String? = nil, tintDark: String? = nil, glyph: String? = nil, iconSvg: String? = nil) {
        self.key = key
        self.image = image
        self.tint = tint
        self.tintDark = tintDark
        self.glyph = glyph
        self.iconSvg = iconSvg
    }

    init?(_ value: JSONValue?) {
        guard case .object(let fields)? = value, case .string(let key)? = fields["key"], !key.isEmpty else { return nil }
        func text(_ name: String) -> String? {
            if case .string(let value)? = fields[name], !value.isEmpty { return value }
            return nil
        }
        self.init(key: key, image: text("image"), tint: text("tint"), tintDark: text("tintDark"), glyph: text("glyph"), iconSvg: text("iconSvg"))
    }
}

nonisolated struct ApiaryTarget: Hashable, Sendable {
    var kind: String
    var id: String
    var sessionID: String?
    var title: String
    var handle: String?
    var subtitle: String?
    var focused: Bool
    var open: Bool
    var name: String?
    var displayName: String?
    var sessionTitle: String?
    var championName: String?
    var championID: String?
    var workspaceID: String?
    var workspaceName: String?
    var state: String?
    var look: ApiaryLook?
    var viaApiary = true

    init(kind: String, id: String, sessionID: String?, title: String, handle: String? = nil, subtitle: String? = nil, focused: Bool = false, open: Bool = false) {
        self.kind = kind
        self.id = id
        self.sessionID = sessionID
        self.title = title
        self.handle = handle
        self.subtitle = subtitle
        self.focused = focused
        self.open = open
    }

    init?(_ value: JSONValue) {
        guard case .object(let fields) = value,
              case .string(let kind)? = fields["kind"],
              case .string(let id)? = fields["id"]
        else { return nil }
        func text(_ key: String) -> String? {
            if case .string(let value)? = fields[key], !value.isEmpty { return value }
            return nil
        }
        func flag(_ key: String) -> Bool {
            if case .bool(let value)? = fields[key] { return value }
            return false
        }
        self.init(
            kind: kind,
            id: id,
            sessionID: text("sessionId") ?? (kind == "session" ? id : nil),
            title: text("title") ?? text("championName") ?? text("displayName") ?? text("name") ?? text("handle") ?? id,
            handle: text("handle"),
            subtitle: text("subtitle"),
            focused: flag("focused"),
            open: flag("open")
        )
        name = text("name")
        displayName = text("displayName")
        sessionTitle = text("sessionTitle")
        championName = text("championName") ?? (kind == "champion" ? title : nil)
        championID = text("championId") ?? (kind == "champion" ? id : nil)
        workspaceID = text("workspaceId")
        workspaceName = text("workspaceName")
        look = ApiaryLook(fields["look"])
    }

    var isProject: Bool { kind == "project" }

    var isChampion: Bool { kind == "champion" || championName != nil }

    var searchText: String {
        [title, name, displayName, sessionTitle, championName, championID, id, sessionID, handle, subtitle, kind, isProject ? "orchestrator" : nil, workspaceID, workspaceName]
            .compactMap { $0 }.joined(separator: " ").lowercased()
    }

    var workspaceLabel: String? { workspaceName ?? workspaceID }

    var key: String { "\(kind):\(id)" }

    var reference: JSONValue {
        .object(["kind": .string(kind), "id": .string(id)])
    }
}

actor ApiaryBridge {
    static let pointAtBudget: Duration = .milliseconds(30)
    static let retryBudget: Duration = .milliseconds(100)
    static let idleClose: Duration = .seconds(30)

    private let discoveryPath: String?
    private var socket: BridgeSocket?
    private var hello: ApiaryHello?
    private var connecting: Task<ApiaryHello, Error>?
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var nextID = 1
    private var quietUntil: ContinuousClock.Instant?
    private var lastUse = ContinuousClock.now
    private var checkedAt = ContinuousClock.now
    private var idleWatch: Task<Void, Never>?
    private(set) var log: [String] = []

    init(discoveryPath: String? = nil) {
        self.discoveryPath = discoveryPath
    }

    var isConnected: Bool { hello != nil }

    func connect() async -> ApiaryHello? {
        try? await ensure()
    }

    func disconnect() {
        drop(.unreachable)
    }

    func apiaryPID() async -> pid_t? {
        (try? await ensure())?.apiaryPID
    }

    func pointAt(_ point: Point, reason: String, retry: Bool) async -> ApiaryPoint? {
        let params: JSONValue = .object(["x": .number(point.x), "y": .number(point.y), "reason": .string(reason), "dom": .bool(true)])
        var answer = try? await call("pointAt", params, timeout: Self.pointAtBudget)
        if answer == nil, retry {
            answer = try? await call("pointAt", params, timeout: Self.retryBudget)
        }
        guard case .object(let fields)? = answer else { return nil }
        var stack: [JSONValue] = []
        if case .array(let levels)? = fields["stack"] { stack = levels }
        let stale = fields["staleWindows"] == .bool(true)
        if stale { Task { await self.refreshHello() } }
        return ApiaryPoint(hit: fields["hit"] == .bool(true), stack: stack, staleWindows: stale)
    }

    func focusedChat() async throws -> ApiaryTarget? {
        let answer = try await call("focusedChat", .object([:]), timeout: .milliseconds(500))
        guard case .object(let fields) = answer, let target = fields["target"] else { return nil }
        return ApiaryTarget(target).map { var target = $0; target.focused = true; return target }
    }

    func listTargets(limit: Int = 500) async throws -> [ApiaryTarget] {
        let answer = try await call("listTargets", .object(["limit": .number(Double(limit))]), timeout: .milliseconds(1500))
        guard case .object(let fields) = answer, case .array(let rows)? = fields["targets"] else { return [] }
        return rows.compactMap(ApiaryTarget.init)
    }

    func deliver(_ params: JSONValue, timeout: Duration = .milliseconds(3000)) async throws -> [String: JSONValue] {
        let answer = try await call("deliver", params, timeout: timeout)
        guard case .object(let fields) = answer else { throw ApiaryBridgeError.unreachable }
        return fields
    }

    func call(_ verb: String, _ params: JSONValue, timeout: Duration) async throws -> JSONValue {
        _ = try await ensure()
        return try await send(verb, params, timeout: timeout)
    }

    private func refreshHello() async {
        guard let discovery = ApiaryDiscovery.read(from: discoveryPath ?? ApiaryDiscovery.path),
              let answer = try? await send("hello", Self.helloParams(token: discovery.token), timeout: .milliseconds(500)),
              let refreshed = Self.hello(from: answer, pid: discovery.pid)
        else { return }
        hello = refreshed
    }

    private func ensure() async throws -> ApiaryHello {
        lastUse = .now
        if let hello {
            guard ContinuousClock.now - checkedAt > .seconds(2) else { return hello }
            checkedAt = .now
            if ApiaryDiscovery.read(from: discoveryPath ?? ApiaryDiscovery.path)?.instanceId == hello.instanceId { return hello }
            note("instance changed")
            drop(.unreachable)
        }
        if let connecting { return try await connecting.value }
        if let quietUntil, ContinuousClock.now < quietUntil { throw ApiaryBridgeError.absent }
        let task = Task { try await self.open() }
        connecting = task
        defer { connecting = nil }
        do {
            let hello = try await task.value
            self.hello = hello
            checkedAt = .now
            quietUntil = nil
            watchIdle()
            return hello
        } catch {
            quietUntil = .now + .seconds(1)
            throw error
        }
    }

    private func open() async throws -> ApiaryHello {
        guard let discovery = ApiaryDiscovery.read(from: discoveryPath ?? ApiaryDiscovery.path) else { throw ApiaryBridgeError.absent }
        let socket = BridgeSocket(path: discovery.socketPath)
        self.socket = socket
        do {
            try await socket.open()
        } catch {
            self.socket = nil
            socket.close()
            throw ApiaryBridgeError.unreachable
        }
        Task { await self.read(from: socket) }
        let started = ContinuousClock.now
        let answer: JSONValue
        do {
            answer = try await send("hello", Self.helloParams(token: discovery.token), timeout: .seconds(2))
        } catch {
            drop(.unreachable, ifCurrent: socket)
            throw error
        }
        guard var hello = Self.hello(from: answer, pid: discovery.pid), hello.instanceId == discovery.instanceId || hello.instanceId.isEmpty else {
            drop(.unreachable, ifCurrent: socket)
            throw ApiaryBridgeError.unreachable
        }
        hello.instanceId = discovery.instanceId
        note("hello \(Self.milliseconds(ContinuousClock.now - started)) ms")
        return hello
    }

    private static func helloParams(token: String) -> JSONValue {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return .object([
            "protocol": .string(ApiaryDiscovery.protocolVersion),
            "token": .string(token),
            "client": .object([
                "name": .string("Scout"),
                "version": .string(version),
                "bundleId": .string(Bundle.main.bundleIdentifier ?? "com.trmdy.scout"),
                "pid": .number(Double(ProcessInfo.processInfo.processIdentifier)),
            ]),
        ])
    }

    private static func hello(from answer: JSONValue, pid: pid_t) -> ApiaryHello? {
        guard case .object(let fields) = answer else { return nil }
        var instance = ""
        if case .object(let apiary)? = fields["apiary"], case .string(let id)? = apiary["instanceId"] { instance = id }
        var capabilities: Set<String> = []
        if case .array(let names)? = fields["capabilities"] {
            for case .string(let name) in names { capabilities.insert(name) }
        }
        var windows: [Rect] = []
        if case .array(let list)? = fields["windows"] {
            for case .object(let window) in list {
                if let rect = ApiaryStack(levels: [.object(["level": .string("window"), "bounds": window["bounds"] ?? .null])]).bounds { windows.append(rect) }
            }
        }
        return ApiaryHello(instanceId: instance, apiaryPID: pid, capabilities: capabilities, windows: windows)
    }

    private func send(_ verb: String, _ params: JSONValue, timeout: Duration) async throws -> JSONValue {
        guard let socket else { throw ApiaryBridgeError.unreachable }
        let id = nextID
        nextID += 1
        let line: Data
        do {
            var data = try JSONEncoder().encode(Request(id: id, verb: verb, params: params))
            data.append(0x0A)
            line = data
        } catch {
            throw ApiaryBridgeError.refused(code: "badRequest", message: "\(error)")
        }
        let started = ContinuousClock.now
        defer { note("\(verb) \(Self.milliseconds(ContinuousClock.now - started)) ms") }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            socket.write(line) { [weak self] failed in
                guard failed, let self else { return }
                Task { await self.drop(.unreachable, ifCurrent: socket) }
            }
            Task {
                try? await Task.sleep(for: timeout)
                self.complete(id, with: .failure(ApiaryBridgeError.timeout))
            }
        }
    }

    private func complete(_ id: Int, with result: Result<JSONValue, Error>) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }

    private func read(from socket: BridgeSocket) async {
        while true {
            guard let line = try? await socket.readLine() else {
                drop(.unreachable, ifCurrent: socket)
                return
            }
            guard let response = try? JSONDecoder().decode(Response.self, from: line), let id = response.id else { continue }
            if response.ok == true {
                complete(id, with: .success(response.result ?? .null))
            } else {
                let code = response.error?.code ?? "internal"
                complete(id, with: .failure(ApiaryBridgeError.refused(code: code, message: response.error?.message ?? code)))
            }
        }
    }

    private func drop(_ error: ApiaryBridgeError, ifCurrent socket: BridgeSocket) {
        if self.socket === socket {
            drop(error)
        } else {
            socket.close()
        }
    }

    private func drop(_ error: ApiaryBridgeError) {
        socket?.close()
        socket = nil
        hello = nil
        idleWatch?.cancel()
        idleWatch = nil
        let waiting = pending
        pending.removeAll()
        waiting.values.forEach { $0.resume(throwing: error) }
    }

    private func watchIdle() {
        idleWatch?.cancel()
        idleWatch = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                if ContinuousClock.now - self.lastUse >= Self.idleClose, self.pending.isEmpty {
                    self.note("idle close")
                    self.drop(.unreachable)
                    return
                }
            }
        }
    }

    private func note(_ line: String) {
        log.append(line)
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }

    nonisolated static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return ((Double(parts.seconds) + Double(parts.attoseconds) / 1e18) * 10_000).rounded() / 10
    }

    private struct Request: Encodable {
        var id: Int
        var verb: String
        var params: JSONValue
    }

    private struct Response: Decodable {
        struct Failure: Decodable {
            var code: String?
            var message: String?
        }

        var id: Int?
        var ok: Bool?
        var result: JSONValue?
        var error: Failure?
    }
}

nonisolated enum ApiaryWindows {
    static func topmostOwner(at point: Point) -> pid_t? {
        let own = ProcessInfo.processInfo.processIdentifier
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in windows {
            guard let owner = window[kCGWindowOwnerPID as String] as? pid_t, owner != own,
                  (window[kCGWindowLayer as String] as? Int ?? 0) == 0,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.contains(CGPoint(x: point.x, y: point.y))
            else { continue }
            return owner
        }
        return nil
    }
}

nonisolated final class BridgeSocket: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "scout.apiary.bridge")
    private var buffer = Data()
    private var scanned = 0

    init(path: String) {
        connection = NWConnection(to: .unix(path: path), using: .tcp)
    }

    func open() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = OnceFlag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumed.run { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    resumed.run { continuation.resume(throwing: error) }
                case .cancelled:
                    resumed.run { continuation.resume(throwing: ApiaryBridgeError.unreachable) }
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

    func write(_ data: Data, failed: @escaping @Sendable (Bool) -> Void) {
        connection.send(content: data, completion: .contentProcessed { error in failed(error != nil) })
    }

    func readLine() async throws -> Data {
        while true {
            if let newline = buffer[(buffer.startIndex + scanned)...].firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer = Data(buffer[(newline + 1)...])
                scanned = 0
                if line.isEmpty { continue }
                return line
            }
            scanned = buffer.count
            buffer.append(try await receive())
        }
    }

    private func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: ApiaryBridgeError.unreachable)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }
}

nonisolated final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}
