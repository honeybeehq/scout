import Foundation
import ScoutCore

nonisolated enum ScoutPaths {
    static var support: URL { ScoutDataRoot.url }
}

@main struct GameOwnerProof {
    static func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw CocoaError(.coderReadCorrupt)
    }

    static func main() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let bridge = BridgeServer()
        bridge.start()
        defer { bridge.stop() }
        bridge.setSession(active: true)
        try await waitFor { bridge.port != nil }
        print(String(data: try Data(contentsOf: BridgeServer.configurationURL), encoding: .utf8)!.replacingOccurrences(of: "\n", with: ""))
        fflush(stdout)
        try await waitFor { bridge.clients.count == 2 && bridge.recentlyHovered()?.hello?.project?.root == "/fixture/current" }
        let reply = await bridge.requestPin(id: "owner-pin", at: Date())!
        let target = reply.element.target(clientID: reply.client.id)
        let snippet = Snippet(id: "owner-task", range: TimeRange(start: 0, end: 1), marks: [Mark(id: "owner-pin", at: 0.5, point: Point(x: 260, y: 180), target: target)], openingContext: AppContext(app: AppIdentity(bundleID: nil, name: "Game"), location: "http://127.0.0.1:5178"))
        let project = bridge.project(for: snippet)!
        let folder = output.appendingPathComponent("game-snapshots")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        bridge.onGameState = { client, data, taskID, _ in
            var state = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
            state["_scoutClientID"] = client.id
            state["_scoutTargetClientID"] = snippet.webClientID
            state["_scoutProjectRoot"] = client.hello?.project?.root
            try! JSONSerialization.data(withJSONObject: state).write(to: folder.appendingPathComponent("\(taskID ?? "0.5").json"))
        }
        await bridge.requestGameState(taskID: snippet.id, projectRoot: "/fixture/stale", clientID: snippet.webClientID)
        let task = try TaskComposer.compose(snippet, title: "Game owner", project: project, sessionDirectory: output)
        try task.message.write(to: output.appendingPathComponent("message.txt"), atomically: true, encoding: .utf8)
        let state = try JSONSerialization.jsonObject(with: Data(contentsOf: task.directory.appendingPathComponent("game-state.json"))) as! [String: Any]
        let save = try JSONSerialization.jsonObject(with: Data(contentsOf: task.directory.appendingPathComponent("save.json"))) as! [String: Any]
        let result: [String: Any] = ["projectRoot": project.rootPath, "locationProjectRoot": bridge.project(forLocation: "http://127.0.0.1:5178")!.rootPath, "state": state, "save": save, "target": target.id]
        print(String(data: try JSONSerialization.data(withJSONObject: result), encoding: .utf8)!)
        fflush(stdout)
    }
}
