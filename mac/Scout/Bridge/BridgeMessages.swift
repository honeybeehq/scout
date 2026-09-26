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

nonisolated struct BridgeHoverMessage: Codable, Sendable {
    var at: Double?
    var element: BridgeElement?
}

nonisolated struct BridgePinnedMessage: Codable, Sendable {
    var id: String
    var element: BridgeElement?
}

nonisolated struct BridgeSignalMessage: Codable, Sendable, Equatable {
    var at: Double?
    var kind: String
    var message: String?
    var stack: String?
    var method: String?
    var url: String?
    var status: Int?
}

extension BridgeElement {
    nonisolated func target(clientID: String) -> Target {
        Target(
            id: "web:\(clientID):\(id)",
            provider: .web,
            role: role.map { $0.prefix(1).uppercased() + $0.dropFirst() },
            label: label ?? text,
            identifier: testId,
            frame: nil,
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
