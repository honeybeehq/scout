import Foundation
import Observation

nonisolated enum LinearStructure: String, Codable, CaseIterable, Identifiable, Sendable {
    case perTask
    case parent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .perTask: "One issue per task"
        case .parent: "Parent issue with sub-issues"
        }
    }
}

nonisolated struct LinearProjectRef: Codable, Hashable, Sendable {
    var id: String
    var name: String

    init(_ project: LinearProject) {
        id = project.id
        name = project.name
    }
}

nonisolated struct LinearRoute: Codable, Hashable, Identifiable, Sendable {
    enum Match: Codable, Hashable, Sendable {
        case repo(rootPath: String)
        case app(bundleID: String)
    }

    var match: Match
    var name: String
    var team: LinearTeam
    var project: LinearProjectRef?

    var id: Match { match }

    var detail: String {
        switch match {
        case .repo(let rootPath): (rootPath as NSString).abbreviatingWithTildeInPath
        case .app(let bundleID): bundleID
        }
    }
}

@Observable
final class LinearPreferences {
    static let initialAutomaticStructure = LinearStructure.perTask
    static let initialManualStructure = LinearStructure.parent
    static let initialIncludesVideo = false

    private let defaults: UserDefaults

    var defaultTeam: LinearTeam? {
        didSet {
            if defaultTeam?.id != oldValue?.id { defaultProject = nil }
            store(defaultTeam, as: "linear.defaultTeam")
        }
    }

    var defaultProject: LinearProjectRef? {
        didSet { store(defaultProject, as: "linear.defaultProject") }
    }

    var routes: [LinearRoute] {
        didSet { store(routes, as: "linear.routes") }
    }

    var automaticStructure: LinearStructure {
        didSet { defaults.set(automaticStructure.rawValue, forKey: "linear.structure.automatic") }
    }

    var manualStructure: LinearStructure {
        didSet { defaults.set(manualStructure.rawValue, forKey: "linear.structure.manual") }
    }

    var includesVideo: Bool {
        didSet { defaults.set(includesVideo, forKey: "linear.includeVideo") }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        defaults.register(defaults: [
            "linear.structure.automatic": Self.initialAutomaticStructure.rawValue,
            "linear.structure.manual": Self.initialManualStructure.rawValue,
            "linear.includeVideo": Self.initialIncludesVideo,
        ])
        defaultTeam = Self.load(LinearTeam.self, from: defaults, key: "linear.defaultTeam")
        defaultProject = Self.load(LinearProjectRef.self, from: defaults, key: "linear.defaultProject")
        routes = Self.load([LinearRoute].self, from: defaults, key: "linear.routes") ?? []
        automaticStructure = LinearStructure(rawValue: defaults.string(forKey: "linear.structure.automatic") ?? "") ?? Self.initialAutomaticStructure
        manualStructure = LinearStructure(rawValue: defaults.string(forKey: "linear.structure.manual") ?? "") ?? Self.initialManualStructure
        includesVideo = defaults.bool(forKey: "linear.includeVideo")
    }

    func structure(for segmentation: Segmentation) -> LinearStructure {
        switch segmentation {
        case .automatic: automaticStructure
        case .manual: manualStructure
        }
    }

    func setTeam(_ team: LinearTeam, for route: LinearRoute) {
        guard let index = routes.firstIndex(where: { $0.id == route.id }), routes[index].team.id != team.id else { return }
        routes[index].team = team
        routes[index].project = nil
    }

    func setProject(_ project: LinearProjectRef?, for route: LinearRoute) {
        guard let index = routes.firstIndex(where: { $0.id == route.id }) else { return }
        routes[index].project = project
    }

    private func store(_ value: (some Encodable)?, as key: String) {
        if let value, let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private static func load<Value: Decodable>(_ type: Value.Type, from defaults: UserDefaults, key: String) -> Value? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}
