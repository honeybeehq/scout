import Foundation
import Network

final class SDKServer {
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var bundle: Data?
    var onReady: ((String) -> Void)?

    func start() {
        guard listener == nil else { return }
        bundle = Bundle.main.url(forResource: "scout", withExtension: "js").flatMap { try? Data(contentsOf: $0) }
        listen(on: 47911)
    }

    private func listen(on candidate: UInt16) {
        guard candidate <= 47920, let port = NWEndpoint.Port(rawValue: candidate) else { return }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else {
            listen(on: candidate + 1)
            return
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            MainActor.assumeIsolated {
                guard let self, let listener, self.listener === listener else { return }
                switch state {
                case .ready:
                    self.onReady?("http://127.0.0.1:\(candidate)/sdk/v1/scout.js")
                case .failed(let error):
                    listener.cancel()
                    self.listener = nil
                    if case .posix(let code) = error, code == .EADDRINUSE {
                        self.listen(on: candidate + 1)
                    }
                default:
                    break
                }
            }
        }
        listener.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.cancel() }
        connections = [:]
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .main)
        receive(connection, id: id, buffer: Data())
        Task { [weak self, weak connection] in
            try? await Task.sleep(for: .seconds(5))
            connection?.cancel()
            self?.connections.removeValue(forKey: id)
        }
    }

    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                var request = buffer
                if let data { request.append(data) }
                if let header = String(data: request, encoding: .utf8), header.contains("\r\n\r\n") {
                    let found = header.components(separatedBy: "\r\n").first == "GET /sdk/v1/scout.js HTTP/1.1"
                    let body = found ? self.bundle : nil
                    let status = body == nil ? "404 Not Found" : "200 OK"
                    let payload = body ?? Data()
                    let headers = "HTTP/1.1 \(status)\r\nContent-Type: text/javascript\r\nContent-Length: \(payload.count)\r\nAccess-Control-Allow-Origin: *\r\nCross-Origin-Resource-Policy: cross-origin\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(headers.utf8) + payload, completion: .contentProcessed { [weak self] _ in
                        MainActor.assumeIsolated {
                            connection.cancel()
                            self?.connections.removeValue(forKey: id)
                        }
                    })
                } else if complete || error != nil || request.count >= 8192 {
                    connection.cancel()
                    self.connections.removeValue(forKey: id)
                } else {
                    self.receive(connection, id: id, buffer: request)
                }
            }
        }
    }
}
