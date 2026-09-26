import AppKit
import Observation

enum ApiaryStatus: Equatable {
    case running
    case installed
    case missing
}

enum DeliveryRoute: String, CaseIterable, Identifiable {
    case matchProject
    case newSession
    case askEachTime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .matchProject: "Match project"
        case .newSession: "New session"
        case .askEachTime: "Ask me"
        }
    }

    var explanation: String {
        switch self {
        case .matchProject: "Send to the agent already working in that app's repo. Start one if none is."
        case .newSession: "Start a fresh agent session for every task."
        case .askEachTime: "Pick a session for each task before it's sent."
        }
    }
}

@Observable
final class Integrations {
    enum HiveStatus: Equatable {
        case checking
        case connected(activeSessions: Int)
        case unreachable(String)
        case missing
    }

    private(set) var hive: HiveStatus = .checking
    private(set) var apiary: ApiaryStatus = .missing
    private(set) var recentSessions: [HiveSession] = []

    var route = DeliveryRoute(rawValue: UserDefaults.standard.string(forKey: "delivery.route") ?? "") ?? .matchProject {
        didSet { UserDefaults.standard.set(route.rawValue, forKey: "delivery.route") }
    }

    let hiveClient = HiveClient()

    func refresh() async {
        apiary = Self.detectApiary()
        guard hiveClient.isInstalled else {
            hive = .missing
            recentSessions = []
            return
        }
        do {
            let sessions = try await hiveClient.activeSessions(limit: .max)
            recentSessions = Array(sessions.prefix(4))
            hive = .connected(activeSessions: sessions.count)
        } catch {
            hive = .unreachable(error.localizedDescription)
            recentSessions = []
        }
    }

    private static func detectApiary() -> ApiaryStatus {
        let gateway = URL(fileURLWithPath: NSHomeDirectory() + "/.hive/gateways/apiary.json")
        if let data = try? Data(contentsOf: gateway),
           let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let pid = record["pid"] as? Int32,
           kill(pid, 0) == 0 {
            return .running
        }
        let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.trmd.apiary") != nil
        return installed ? .installed : .missing
    }
}
