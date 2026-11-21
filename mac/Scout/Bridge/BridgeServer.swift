import Foundation
import Network
import Observation
import ScoutCore

@Observable
final class BridgeServer {
    struct Client: Identifiable, Equatable {
        let id: String
        var hello: BridgeHello?
        var context: BridgeContextMessage?
        var lastHoverAt: Date?
        var hovered: BridgeElement?
        var viewport: BridgeViewport?

        var name: String {
            hello?.app?.name ?? hello?.app?.url.flatMap { URL(string: $0)?.host() } ?? "App"
        }

        var origin: String? {
            (context?.url ?? hello?.app?.url).flatMap(BridgeServer.origin(of:))
        }
    }

    private(set) var clients: [Client] = []
    private(set) var port: UInt16?
    private(set) var failure: String?

    var onHover: ((Client, BridgeElement, BridgeViewport?, Date) -> Void)?
    var onContext: ((Client) -> Void)?
    var onGameState: ((Client, Data, String?, Date?) -> Void)?
    var onSignal: ((Client, BridgeSignalMessage) -> Void)?

    private let sdkServer = SDKServer()
    private var sdkURL: String?
    private var knownProjects: [String: ProjectReference] = [:]
    private var listeners: [Int: NWListener] = [:]
    private var readyListeners = Set<Int>()
    private var listenerGeneration = UUID()
    private var connections: [String: NWConnection] = [:]
    private struct GameRequest {
        var clientID: String
        var taskID: String?
        var at: Date?
        var continuation: CheckedContinuation<Void, Never>?
        var received = false
    }
    private var gameRequests: [String: GameRequest] = [:]
    private var pendingPins: [String: CheckedContinuation<PinReply?, Never>] = [:]

    struct PinReply {
        var client: Client
        var element: BridgeElement
        var viewport: BridgeViewport?
    }
    private var sessionActive = false
    private var aimActive = false
    private let token = BridgeServer.loadOrCreateToken()

    static var configurationURL: URL { ScoutPaths.support.appendingPathComponent("bridge.json") }

    func start() {
        guard listeners.isEmpty else { return }
        sdkServer.onReady = { [weak self] url in
            self?.sdkURL = url
            self?.writeConfiguration()
        }
        sdkServer.start()
        listen(on: BridgeProtocol.ports.lowerBound)
    }

    private func listen(on candidate: UInt16) {
        guard BridgeProtocol.ports.contains(candidate) else {
            failure = "No free port between \(BridgeProtocol.ports.lowerBound) and \(BridgeProtocol.ports.upperBound)."
            return
        }
        let generation = UUID()
        listenerGeneration = generation
        readyListeners = []
        guard let port = NWEndpoint.Port(rawValue: candidate) else { return }
        for (index, host) in [NWEndpoint.Host.ipv4(.loopback), .ipv6(.loopback)].enumerated() {
            do {
                let parameters = parameters()
                parameters.requiredLocalEndpoint = .hostPort(host: host, port: port)
                listeners[index] = try NWListener(using: parameters)
            } catch {
                if let error = error as? NWError, case .posix(let code) = error, code == .EADDRINUSE {
                    stopListeners()
                    listen(on: candidate + 1)
                    return
                }
                failure = error.localizedDescription
            }
        }
        guard !listeners.isEmpty else { return }
        for (index, listener) in listeners {
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated {
                    guard let self, self.listenerGeneration == generation, self.listeners[index] != nil,
                          self.readyListeners.count == self.listeners.count else {
                        connection.cancel()
                        return
                    }
                    self.accept(connection)
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self, self.listenerGeneration == generation, self.listeners[index] != nil else { return }
                    self.listenerChanged(state, port: candidate, index: index)
                }
            }
            listener.start(queue: .main)
        }
    }

    private func stopListeners() {
        listenerGeneration = UUID()
        listeners.values.forEach { $0.cancel() }
        listeners = [:]
        readyListeners = []
        port = nil
    }

    func stop() {
        sdkServer.stop()
        sdkURL = nil
        stopListeners()
        connections.values.forEach { $0.cancel() }
        connections = [:]
        clients = []
        for id in Array(gameRequests.keys) { finishGameRequest(id) }
    }

    func setSession(active: Bool) {
        sessionActive = active
        if active {
            for index in clients.indices { clients[index].lastHoverAt = nil }
        } else {
            for id in Array(gameRequests.keys) { finishGameRequest(id) }
        }
        broadcast(["type": "session", "active": active])
    }

    func requestGameState(taskID: String? = nil, projectRoot: String? = nil, clientID: String? = nil) async {
        guard sessionActive else { return }
        let games = clients.filter { $0.hello?.capabilities?.contains("game") == true }
        let explicit = clientID.flatMap { id in games.first { $0.id == id } }
        let fallback = games.filter { client in
            client.lastHoverAt != nil && (projectRoot == nil || client.hello?.project?.root == projectRoot)
        }.max { ($0.lastHoverAt ?? .distantPast) < ($1.lastHoverAt ?? .distantPast) }
        guard let client = explicit ?? fallback else { return }
        let id = UUID().uuidString
        await withCheckedContinuation { continuation in
            gameRequests[id] = GameRequest(clientID: client.id, taskID: taskID, continuation: continuation)
            send(["type": "snapshot", "id": id], to: client.id)
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(750))
                self?.finishGameRequest(id)
            }
        }
    }

    private func finishGameRequest(_ id: String) {
        gameRequests.removeValue(forKey: id)?.continuation?.resume()
    }

    func setAim(active: Bool) {
        guard aimActive != active else { return }
        aimActive = active
        broadcast(["type": "aim", "active": active])
    }

    func recentlyHovered(within interval: TimeInterval = 1.2) -> Client? {
        clients
            .filter { ($0.lastHoverAt.map { Date().timeIntervalSince($0) < interval }) == true }
            .max { ($0.lastHoverAt ?? .distantPast) < ($1.lastHoverAt ?? .distantPast) }
    }

    func requestPin(id: String, at date: Date, timeout: Duration = .milliseconds(220)) async -> PinReply? {
        guard let client = recentlyHovered(within: 2) else { return nil }
        gameRequests[id] = GameRequest(clientID: client.id, at: date)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            self?.finishGameRequest(id)
        }
        send(["type": "pin", "id": id, "at": date.timeIntervalSince1970 * 1000], to: client.id)
        return await withCheckedContinuation { continuation in
            pendingPins[id] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.resolvePin(id, with: nil)
            }
        }
    }

    func project(forTarget target: Target) -> ProjectReference? {
        guard target.provider == .web else { return nil }
        let parts = target.id.split(separator: ":", maxSplits: 2)
        guard parts.count == 3 else { return nil }
        return knownProjects[String(parts[1])]
    }

    func project(for snippet: Snippet) -> ProjectReference? {
        if let target = snippet.webTarget { return project(forTarget: target) }
        return project(forLocation: snippet.primaryContext?.location)
    }

    func project(forLocation location: String?) -> ProjectReference? {
        guard let location, let origin = Self.origin(of: location) else { return nil }
        let client = clients.filter { $0.origin == origin && $0.lastHoverAt != nil && knownProjects[$0.id] != nil }
            .max { ($0.lastHoverAt ?? .distantPast) < ($1.lastHoverAt ?? .distantPast) }
        return client.flatMap { knownProjects[$0.id] }
    }

    private func resolvePin(_ id: String, with result: PinReply?) {
        pendingPins.removeValue(forKey: id)?.resume(returning: result)
    }

    private func parameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.maximumMessageSize = 1 << 20
        websocket.setClientRequestHandler(.main) { _, headers in
            let origin = headers.first { $0.name.lowercased() == "origin" }?.value
            return NWProtocolWebSocket.Response(status: Self.isAllowedOrigin(origin) ? .accept : .reject, subprotocol: nil)
        }
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        return parameters
    }

    nonisolated static func isAllowedOrigin(_ origin: String?) -> Bool {
        guard let origin else { return true }
        guard origin != "null" else { return false }
        guard let host = URL(string: origin)?.host()?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]" || host.hasSuffix(".localhost")
    }

    nonisolated static func origin(of location: String) -> String? {
        guard let url = URL(string: location), let scheme = url.scheme, let host = url.host() else { return nil }
        return "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
    }

    private func listenerChanged(_ state: NWListener.State, port candidate: UInt16, index: Int) {
        switch state {
        case .ready:
            readyListeners.insert(index)
        case .failed(let error):
            if case .posix(let code) = error, code == .EADDRINUSE {
                stopListeners()
                listen(on: candidate + 1)
                return
            }
            listeners.removeValue(forKey: index)?.cancel()
            readyListeners.remove(index)
            guard !listeners.isEmpty else {
                stopListeners()
                failure = error.localizedDescription
                return
            }
        default:
            return
        }
        guard readyListeners.count == listeners.count else { return }
        port = candidate
        failure = nil
        if listeners.count == 1 {
            NSLog("[scout-bridge] Listening on %@ only; the other loopback address is unavailable.", listeners[0] != nil ? "127.0.0.1" : "::1")
        }
        writeConfiguration()
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID().uuidString
        connections[id] = connection
        clients.append(Client(id: id))
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed, .cancelled: self?.drop(id)
                default: break
                }
            }
        }
        connection.start(queue: .main)
        receive(on: connection, id: id)
    }

    private func drop(_ id: String) {
        connections.removeValue(forKey: id)?.cancel()
        clients.removeAll { $0.id == id }
        for requestID in gameRequests.keys.filter({ gameRequests[$0]?.clientID == id }) { finishGameRequest(requestID) }
    }

    private func receive(on connection: NWConnection, id: String) {
        connection.receiveMessage { [weak self] data, _, _, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data, !data.isEmpty { self.handle(data, from: id) }
                if error == nil, self.connections[id] != nil {
                    self.receive(on: connection, id: id)
                } else {
                    self.drop(id)
                }
            }
        }
    }

    private func handle(_ data: Data, from id: String) {
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(BridgeEnvelope.self, from: data),
              let index = clients.firstIndex(where: { $0.id == id })
        else {
            send(["type": "error", "code": "invalidRequest", "message": "Expected a JSON object with a type."], to: id)
            return
        }
        if envelope.type != "hello", clients[index].hello == nil {
            send(["type": "error", "code": "unauthorized", "message": "Send hello with the token from bridge.json first."], to: id)
            return
        }
        switch envelope.type {
        case "hello":
            guard let hello = try? decoder.decode(BridgeHello.self, from: data) else { return }
            guard hello.token == token else {
                send(["type": "error", "code": "unauthorized", "message": "Missing or wrong token. Scout's SDK adapters read it from bridge.json."], to: id)
                connections[id]?.cancel()
                return
            }
            clients[index].hello = hello
            if let root = hello.project?.root {
                knownProjects[id] = ProjectReference(rootPath: root, name: URL(fileURLWithPath: root).lastPathComponent, gitBranch: hello.project?.gitBranch)
            }
            send([
                "type": "welcome",
                "scout": ["version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"],
                "session": ["active": sessionActive],
                "capabilities": ["session", "aim", "pin", "highlight", "snapshot"],
            ], to: id)
            if aimActive { send(["type": "aim", "active": true], to: id) }
        case "context":
            clients[index].context = try? decoder.decode(BridgeContextMessage.self, from: data)
            onContext?(clients[index])
        case "hover":
            guard let hover = try? decoder.decode(BridgeHoverMessage.self, from: data), let element = hover.element else { return }
            let date = hover.at.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
            clients[index].lastHoverAt = Date()
            clients[index].hovered = element
            clients[index].viewport = hover.viewport ?? clients[index].viewport
            onHover?(clients[index], element, clients[index].viewport, date)
        case "pinned":
            guard let pinned = try? decoder.decode(BridgePinnedMessage.self, from: data) else { return }
            resolvePin(pinned.id, with: pinned.element.map { PinReply(client: clients[index], element: $0, viewport: pinned.viewport ?? clients[index].viewport) })
        case "gameState":
            guard sessionActive, let requestID = envelope.id, let request = gameRequests[requestID],
                  request.clientID == id, !request.received,
                  let payload = BridgeGameState.payload(from: data) else { return }
            gameRequests[requestID]?.received = true
            onGameState?(clients[index], payload, request.taskID, request.at)
        case "gameStateDone":
            if let requestID = envelope.id, gameRequests[requestID]?.clientID == id { finishGameRequest(requestID) }
        case "signal":
            guard let signal = try? decoder.decode(BridgeSignalMessage.self, from: data) else { return }
            onSignal?(clients[index], signal)
        case "error":
            break
        default:
            var error: [String: Any] = ["type": "error", "code": "unsupported", "message": "Unknown message type \(envelope.type)."]
            if let requestID = envelope.id { error["id"] = requestID }
            send(error, to: id)
        }
    }

    private func broadcast(_ message: [String: Any]) {
        for client in clients where client.hello != nil {
            send(message, to: client.id)
        }
    }

    private func send(_ message: [String: Any], to id: String) {
        guard let connection = connections[id] else { return }
        var payload = message
        payload["v"] = BridgeProtocol.version
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "message", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    private func writeConfiguration() {
        guard let port else { return }
        var configuration: [String: Any] = ["port": Int(port), "token": token, "pid": Int(ProcessInfo.processInfo.processIdentifier), "protocol": BridgeProtocol.version]
        if let sdkURL { configuration["sdkURL"] = sdkURL }
        guard let data = try? JSONSerialization.data(withJSONObject: configuration, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: ScoutPaths.support, withIntermediateDirectories: true)
        try? data.write(to: Self.configurationURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.configurationURL.path)
    }

    private static func loadOrCreateToken() -> String {
        if let data = try? Data(contentsOf: configurationURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let token = object["token"] as? String, token.count >= 32 {
            return token
        }
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
