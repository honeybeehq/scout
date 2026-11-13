import Foundation
import ScoutCore

nonisolated struct LinearTarget: Codable, Hashable, Sendable {
    enum Reason: Codable, Hashable, Sendable {
        case repo(rootPath: String)
        case app(bundleID: String)
        case defaultTeam
    }

    var team: LinearTeam
    var project: LinearProjectRef?
    var reason: Reason

    var label: String {
        if let project { "Linear · \(team.key) › \(project.name)" } else { "Linear · \(team.key)" }
    }
}

nonisolated enum LinearRouting {
    static func target(
        project: ProjectReference?,
        app: AppIdentity?,
        routes: [LinearRoute],
        defaultTeam: LinearTeam?,
        defaultProject: LinearProjectRef?
    ) -> LinearTarget? {
        if let path = project.map({ normalized($0.rootPath) }) {
            let match = routes
                .compactMap { route -> (LinearRoute, String)? in
                    guard case .repo(let rootPath) = route.match else { return nil }
                    let root = normalized(rootPath)
                    return path == root || path.hasPrefix(root + "/") ? (route, root) : nil
                }
                .max { $0.1.count < $1.1.count }
            if let (route, root) = match {
                return LinearTarget(team: route.team, project: route.project, reason: .repo(rootPath: root))
            }
        }
        if let bundleID = app?.bundleID {
            let match = routes
                .compactMap { route -> (LinearRoute, String)? in
                    guard case .app(let prefix) = route.match else { return nil }
                    return bundleID == prefix || bundleID.hasPrefix(prefix + ".") ? (route, prefix) : nil
                }
                .max { $0.1.count < $1.1.count }
            if let (route, prefix) = match {
                return LinearTarget(team: route.team, project: route.project, reason: .app(bundleID: prefix))
            }
        }
        return defaultTeam.map { LinearTarget(team: $0, project: defaultProject, reason: .defaultTeam) }
    }

    @MainActor
    static func target(for card: SnippetCard, preferences: LinearPreferences) -> LinearTarget? {
        target(
            project: card.project ?? card.snippet.primaryContext?.project,
            app: card.snippet.primaryContext?.app,
            routes: preferences.routes,
            defaultTeam: preferences.defaultTeam,
            defaultProject: preferences.defaultProject
        )
    }

    private static func normalized(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        return standardized.count > 1 && standardized.hasSuffix("/") ? String(standardized.dropLast()) : standardized
    }
}
