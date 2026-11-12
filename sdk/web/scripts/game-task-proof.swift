import Foundation
import ScoutCore

@main struct Proof {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let message = try Data(contentsOf: root.appendingPathComponent("game-message.json"))
        guard let payload = BridgeGameState.payload(from: message) else { throw CocoaError(.coderReadCorrupt) }
        let folder = root.appendingPathComponent("session/game-snapshots")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var game = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
        game["_scoutProjectRoot"] = "/fixture/game"
        try JSONSerialization.data(withJSONObject: game).write(to: folder.appendingPathComponent("game-pin.json"))
        let target = Target(id: "web:fixture:game:Scout fixture:asteroid-17", provider: .web, kind: "game", role: "asteroid", label: "Asteroid A-17")
        let snippet = Snippet(id: "game-pin", range: TimeRange(start: 0, end: 2), marks: [Mark(id: "pin-1", at: 1, point: Point(x: 260, y: 180), target: target)])
        let task = try TaskComposer.compose(snippet, title: "Asteroid A-17 hitch", project: ProjectReference(rootPath: "/fixture/game"), runtimeNotes: ["perf signal verified in bridge.json"], sessionDirectory: root.appendingPathComponent("session"))
        try task.message.write(to: task.directory.appendingPathComponent("message.txt"), atomically: true, encoding: .utf8)
        print(task.message)
    }
}
