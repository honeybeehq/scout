import Foundation
import Security

nonisolated enum LinearError: Error, Equatable, Sendable {
    case unauthorized
    case forbidden
    case rateLimited(until: Date?)
    case offline
    case malformed
    case outsideTestTeam
    case keychain(OSStatus)
    case notFound
    case deletedRemotely
    case uploadFailed
    case videoUploadFailed
    case tooLarge
    case server(String)

    var message: String {
        switch self {
        case .unauthorized: "Linear didn't accept this key."
        case .forbidden: "This key can't see that in Linear."
        case .rateLimited(let until):
            if let until { "Linear asked Scout to slow down. Try again at \(until.formatted(date: .omitted, time: .shortened))." }
            else { "Linear asked Scout to slow down. Try again in a minute." }
        case .offline: "Couldn't reach Linear."
        case .malformed: "Linear sent a reply Scout couldn't read."
        case .outsideTestTeam: "Development builds only file into the test team."
        case .keychain: "Scout couldn't use your Keychain."
        case .notFound: "Linear couldn't find that."
        case .deletedRemotely: "This task's issue was deleted in Linear."
        case .uploadFailed: "An image couldn't be uploaded to Linear."
        case .videoUploadFailed: "The video couldn't be uploaded to Linear."
        case .tooLarge: "The video is too big for Linear."
        case .server(let message): message
        }
    }
}

nonisolated struct LinearOperation<Response: Decodable & Sendable>: Sendable {
    enum Kind: Sendable {
        case query
        case mutation(teamID: String)
    }

    var name: String
    var kind: Kind = .query
    var document: String
    var variables: [String: LinearValue] = [:]

    #if DEBUG
    static var testTeamIDs: Set<String> {
        Set((ProcessInfo.processInfo.environment["SCOUT_LINEAR_TEST_TEAM"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    }
    #endif

    func checkAllowed() throws(LinearError) {
        #if DEBUG
        if case .mutation(let teamID) = kind, !Self.testTeamIDs.contains(teamID) { throw .outsideTestTeam }
        #endif
    }
}

nonisolated protocol LinearAPI: Sendable {
    func perform<Response>(_ operation: LinearOperation<Response>, credential: LinearCredential) async throws(LinearError) -> Response
    func upload(_ file: URL, to target: LinearUploadTarget, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws(LinearError)
}

nonisolated enum LinearValue: Encodable, Hashable, Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case list([LinearValue])
    case object([String: LinearValue])

    var string: String? {
        if case .string(let value) = self { value } else { nil }
    }

    var object: [String: LinearValue]? {
        if case .object(let value) = self { value } else { nil }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .list(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

nonisolated struct LinearViewer: Decodable, Hashable, Sendable {
    struct Organization: Decodable, Hashable, Sendable {
        var id: String
        var name: String
        var urlKey: String

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.remoteID(.id)
            name = try container.remoteText(.name)
            urlKey = try container.remoteText(.urlKey, limit: 48)
        }

        private enum CodingKeys: String, CodingKey { case id, name, urlKey }
    }

    var id: String
    var name: String
    var organization: Organization

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.remoteID(.id)
        name = try container.remoteText(.name)
        organization = try container.decode(Organization.self, forKey: .organization)
    }

    private enum CodingKeys: String, CodingKey { case id, name, organization }
}

nonisolated struct LinearTeam: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var key: String
    var name: String

    init(id: String, key: String, name: String) {
        self.id = id
        self.key = key
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.remoteID(.id)
        key = try container.remoteText(.key, limit: 12)
        name = try container.remoteText(.name)
    }

    var label: String { "\(key) · \(name)" }

    private enum CodingKeys: String, CodingKey { case id, key, name }
}

nonisolated struct LinearProject: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var isOpen = true

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.remoteID(.id)
        name = try container.remoteText(.name)
        let completed = try container.decodeIfPresent(String.self, forKey: .completedAt)
        let canceled = try container.decodeIfPresent(String.self, forKey: .canceledAt)
        isOpen = completed == nil && canceled == nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
    }

    private enum CodingKeys: String, CodingKey { case id, name, completedAt, canceledAt }
}

nonisolated struct LinearLabel: Decodable, Hashable, Identifiable, Sendable {
    private struct Parent: Decodable { var id: String }

    var id: String
    var name: String
    var parentID: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.remoteID(.id)
        name = try container.remoteText(.name)
        parentID = try container.decodeIfPresent(Parent.self, forKey: .parent).map(\.id)
    }

    private enum CodingKeys: String, CodingKey { case id, name, parent }
}

nonisolated struct LinearNodes<Node: Decodable & Sendable>: Decodable, Sendable {
    var nodes: [Node]
}

nonisolated enum LinearOperations {
    struct ViewerData: Decodable, Sendable { var viewer: LinearViewer }
    struct TeamsData: Decodable, Sendable { var teams: LinearNodes<LinearTeam> }
    struct ProjectsData: Decodable, Sendable {
        struct Team: Decodable, Sendable { var projects: LinearNodes<LinearProject> }
        var team: Team?
    }
    struct LabelsData: Decodable, Sendable {
        struct Team: Decodable, Sendable { var labels: LinearNodes<LinearLabel> }
        var team: Team?
    }

    static let viewer = LinearOperation<ViewerData>(
        name: "viewer",
        document: "query { viewer { id name organization { id name urlKey } } }"
    )

    static let teams = LinearOperation<TeamsData>(
        name: "teams",
        document: "query { teams(first: 100) { nodes { id key name } } }"
    )

    static func projects(team: String) -> LinearOperation<ProjectsData> {
        LinearOperation(
            name: "projects",
            document: "query($team: String!) { team(id: $team) { projects(first: 100) { nodes { id name completedAt canceledAt } } } }",
            variables: ["team": .string(team)]
        )
    }

    static func labels(team: String) -> LinearOperation<LabelsData> {
        LinearOperation(
            name: "labels",
            document: "query($team: String!) { team(id: $team) { labels(first: 250) { nodes { id name parent { id } } } } }",
            variables: ["team": .string(team)]
        )
    }
}

nonisolated enum LinearResponse {
    static let maxBytes = 2_000_000

    private struct Envelope<Payload: Decodable>: Decodable {
        var data: Payload?
        var errors: [Failure]?
    }

    private struct Failure: Decodable {
        struct Extensions: Decodable { var code: String? }
        var message: String?
        var extensions: Extensions?
    }

    static func decode<Response: Decodable>(_ data: Data, status: Int, rateLimitReset: String?) throws(LinearError) -> Response {
        guard data.count <= maxBytes else { throw .malformed }
        let resetAt = rateLimitReset.flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
        if status == 401 { throw .unauthorized }
        if status == 429 { throw .rateLimited(until: resetAt) }
        let envelope: Envelope<Response>
        do {
            envelope = try JSONDecoder().decode(Envelope<Response>.self, from: data)
        } catch {
            throw status >= 500 ? .server("Linear is having trouble (\(status)).") : .malformed
        }
        if let failure = envelope.errors?.first {
            switch failure.extensions?.code?.uppercased() {
            case "AUTHENTICATION_ERROR": throw .unauthorized
            case "FORBIDDEN": throw .forbidden
            case "RATELIMITED": throw .rateLimited(until: resetAt)
            case _ where failure.message?.localizedCaseInsensitiveContains("not found") == true: throw .notFound
            default: throw .server(String(RemoteText.clean(failure.message ?? "Linear returned an error.").prefix(200)))
            }
        }
        guard let payload = envelope.data else { throw .malformed }
        return payload
    }
}

nonisolated struct LinearRequestBody: Encodable {
    var query: String
    var variables: [String: LinearValue]
}

nonisolated struct LinearClient: LinearAPI {
    static let endpoint = URL(string: "https://api.linear.app/graphql")!
    private static let session = URLSession(configuration: .ephemeral)

    func perform<Response>(_ operation: LinearOperation<Response>, credential: LinearCredential) async throws(LinearError) -> Response {
        try operation.checkAllowed()
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(credential.authorization, forHTTPHeaderField: "Authorization")
        guard let body = try? JSONEncoder().encode(LinearRequestBody(query: operation.document, variables: operation.variables)) else { throw .malformed }
        request.httpBody = body
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw .offline
        }
        guard let http = response as? HTTPURLResponse else { throw .malformed }
        return try LinearResponse.decode(data, status: http.statusCode, rateLimitReset: http.value(forHTTPHeaderField: "X-RateLimit-Requests-Reset"))
    }

    func upload(_ file: URL, to target: LinearUploadTarget, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws(LinearError) {
        var request = URLRequest(url: target.uploadURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 600)
        request.httpMethod = "PUT"
        request.setValue(target.contentType, forHTTPHeaderField: "Content-Type")
        for (key, value) in target.headers { request.setValue(value, forHTTPHeaderField: key) }
        let response: URLResponse
        do {
            (_, response) = try await Self.session.upload(for: request, fromFile: file, delegate: UploadProgress(report: progress))
        } catch {
            throw .offline
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw .uploadFailed }
    }
}

nonisolated final class UploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    let report: @Sendable (Int64, Int64) -> Void

    init(report: @escaping @Sendable (Int64, Int64) -> Void) {
        self.report = report
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        report(totalBytesSent, totalBytesExpectedToSend)
    }
}

nonisolated enum RemoteText {
    static func clean(_ text: String, limit: Int = 120) -> String {
        let flattened = text.unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) ? " " : String($0) }
            .joined()
            .trimmingCharacters(in: .whitespaces)
        return flattened.count > limit ? String(flattened.prefix(limit - 1)) + "…" : flattened
    }

    static func isID(_ text: String) -> Bool {
        (1...64).contains(text.count) && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}

nonisolated extension KeyedDecodingContainer {
    func remoteText(_ key: Key, limit: Int = 120) throws -> String {
        RemoteText.clean(try decode(String.self, forKey: key), limit: limit)
    }

    func remoteID(_ key: Key) throws -> String {
        let id = try decode(String.self, forKey: key)
        guard RemoteText.isID(id) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Unexpected id")
        }
        return id
    }
}
