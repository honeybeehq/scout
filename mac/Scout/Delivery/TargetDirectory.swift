import Foundation

struct TargetDirectory {
    var targets: [ApiaryTarget]
    var source: TargetPickerModel.Source

    static func load(apiary: ApiaryBridge, hive: HiveClient) async -> TargetDirectory {
        async let focused = try? apiary.focusedChat()
        async let listed = try? apiary.listTargets()
        async let active = try? hive.activeSessions(limit: .max, timeout: .seconds(1))
        let rows = await listed ?? []
        let focus = await focused
        let sessions = await active
        return merge(listed: rows, focused: focus, sessions: sessions)
    }

    static func merge(listed: [ApiaryTarget], focused: ApiaryTarget?, sessions: [HiveSession]?) -> TargetDirectory {
        var rows = listed
        if let focused {
            if let index = rows.firstIndex(where: { $0.key == focused.key }) {
                rows[index].focused = true
                rows.insert(rows.remove(at: index), at: 0)
            } else {
                rows.insert(focused, at: 0)
            }
        }
        var bySession: [String: Int] = [:]
        for (index, row) in rows.enumerated() {
            if let id = row.sessionID { bySession[id] = index }
        }
        for session in sessions ?? [] {
            let target = session.pickerTarget
            if let index = bySession[session.id] {
                rows[index].sessionTitle = session.title
                rows[index].name = rows[index].name ?? target.name
                rows[index].subtitle = rows[index].subtitle ?? target.subtitle
                rows[index].workspaceID = rows[index].workspaceID ?? target.workspaceID
                rows[index].championName = rows[index].championName ?? target.championName
                rows[index].championID = rows[index].championID ?? target.championID
                if session.isChampion { rows[index].title = rows[index].championName ?? rows[index].title }
            } else {
                bySession[session.id] = rows.count
                rows.append(target)
            }
        }
        return TargetDirectory(targets: rows, source: !listed.isEmpty || focused != nil ? .apiary : sessions == nil ? .none : .hive)
    }
}
