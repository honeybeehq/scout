import Foundation
import ScoutCore

nonisolated enum BridgeProtocol {
    static let version = 1
    static let ports: ClosedRange<UInt16> = 47811...47819
}

nonisolated struct BridgeEnvelope: Decodable {
    var type: String
    var id: String?
}

nonisolated struct BridgeHello: Codable, Sendable, Equatable {
    struct App: Codable, Sendable, Equatable {
        struct Framework: Codable, Sendable, Equatable {
            var name: String?
            var version: String?
            var meta: String?
        }

        var name: String?
        var kind: String?
        var url: String?
        var bundleId: String?
        var pid: Int32?
        var framework: Framework?
    }

    struct Project: Codable, Sendable, Equatable {
        var root: String?
        var gitBranch: String?
    }

    struct SDK: Codable, Sendable, Equatable {
        var name: String?
        var version: String?
    }

    var token: String?
    var app: App?
    var project: Project?
    var sdk: SDK?
    var capabilities: [String]?
}

nonisolated struct BridgeElement: Codable, Sendable, Equatable {
    struct Source: Codable, Sendable, Equatable {
        var file: String
        var line: Int?
        var column: Int?
    }

    struct Bounds: Codable, Sendable, Equatable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
        var space: String?
    }

    var id: String
    var kind: String?
    var game: JSONValue?
    var role: String?
    var label: String?
    var text: String?
    var testId: String?
    var selector: String?
    var component: String?
    var ownerStack: [String]?
    var source: Source?
    var bounds: Bounds?
}

nonisolated struct BridgeContextMessage: Codable, Sendable, Equatable {
    var route: String?
    var url: String?
    var title: String?
}

nonisolated struct BridgeViewport: Codable, Sendable, Equatable {
    var x: Double
    var y: Double
    var scale: Double?
}

nonisolated struct BridgeHoverMessage: Codable, Sendable {
    var at: Double?
    var element: BridgeElement?
    var viewport: BridgeViewport?
}

nonisolated struct BridgePinnedMessage: Codable, Sendable {
    var id: String
    var element: BridgeElement?
    var viewport: BridgeViewport?
}

nonisolated struct BridgeSignalMessage: Codable, Sendable, Equatable {
    var at: Double?
    var kind: String
    var level: String?
    var message: String?
    var stack: String?
    var method: String?
    var url: String?
    var status: Int?
}

extension BridgeElement {
    nonisolated func screenFrame(in viewport: BridgeViewport?) -> Rect? {
        guard let bounds else { return nil }
        if bounds.space == "screen" {
            return Rect(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height)
        }
        guard let viewport else { return nil }
        let scale = viewport.scale ?? 1
        return Rect(x: viewport.x + bounds.x * scale, y: viewport.y + bounds.y * scale, width: bounds.width * scale, height: bounds.height * scale)
    }

    nonisolated func target(clientID: String, viewport: BridgeViewport? = nil) -> Target {
        Target(
            id: "web:\(clientID):\(id)",
            provider: .web,
            kind: kind,
            game: game,
            role: role.map { $0.prefix(1).uppercased() + $0.dropFirst() },
            label: label ?? text,
            identifier: testId,
            frame: screenFrame(in: viewport),
            ancestry: (ownerStack ?? []).reversed().dropFirst().map { $0 },
            component: component,
            selector: selector,
            source: source.map { SourceLocation(file: $0.file, line: $0.line, column: $0.column) }
        )
    }
}

extension Target {
    nonisolated func merged(withAccessibility fallback: Target?) -> Target {
        var merged = self
        if merged.frame == nil { merged.frame = fallback?.frame }
        if merged.label == nil { merged.label = fallback?.label }
        if merged.role == nil { merged.role = fallback?.role }
        return merged
    }
}

nonisolated enum BridgeGameState {
    static func payload(from data: Data) -> Data? {
        guard data.count <= 525312,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let game = object["game"] as? [String: Any],
              game["name"] is String, game["build"] is String, game["scene"] is String,
              game["frame"] is NSNumber, game["clock"] is NSNumber, game["position"] != nil,
              let payload = try? JSONSerialization.data(withJSONObject: game, options: [.withoutEscapingSlashes]), payload.count <= 524288 else { return nil }
        if let save = game["save"], let bytes = try? JSONSerialization.data(withJSONObject: save, options: [.fragmentsAllowed, .withoutEscapingSlashes]), bytes.count > 262144 { return nil }
        return payload
    }
}
