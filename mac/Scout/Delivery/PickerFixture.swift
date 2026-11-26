import AppKit
import SwiftUI

struct PickerEntry: Identifiable, Hashable {
    enum Kind: Hashable {
        case champion
        case orchestrator
        case session
        case clipboard
    }

    enum State: Hashable {
        case idle
        case working
        case waiting
    }

    var id: String
    var kind: Kind
    var title: String
    var detail: String?
    var workspace: String?
    var avatarID: String?
    var projectColor: String?
    var projectIcon: String?
    var state: State = .idle
    var focused = false
    var recent: Int?

    var kindLabel: String {
        switch kind {
        case .champion: "Champion"
        case .orchestrator: "Project"
        case .session: "Session"
        case .clipboard: "Clipboard"
        }
    }

    var shortTitle: String {
        if let cut = title.firstIndex(where: { $0 == "(" || $0 == "," || $0 == ":" }), kind == .champion {
            return String(title[..<cut]).trimmingCharacters(in: .whitespaces)
        }
        return title
    }

    var stateText: String? {
        switch state {
        case .idle: nil
        case .working: "Working"
        case .waiting: "Waiting for you"
        }
    }

    var subtitle: String {
        switch kind {
        case .champion: [workspace, stateText].compactMap { $0 }.joined(separator: " · ")
        case .orchestrator: ["Orchestrator", workspace].compactMap { $0 }.joined(separator: " · ")
        case .session: [detail, workspace, stateText].compactMap { $0 }.joined(separator: " · ")
        case .clipboard: detail ?? ""
        }
    }

    var search: String {
        [title, detail, workspace, kindLabel, avatarID, kind == .orchestrator ? "orchestrator" : nil].compactMap { $0 }.joined(separator: " ").lowercased()
    }
}

enum PickerFixture {
    static let walkthroughMeta = "1:42 · 2 pins · 3 asks"
    static let asks = [
        "Make the checkout total bold and line it up with the item prices",
        "The pay button wraps onto two lines on narrow windows",
        "Footer overlaps the cookie banner at the bottom of the page",
    ]

    private static func champion(_ id: String, _ title: String, _ workspace: String, _ state: PickerEntry.State = .idle, focused: Bool = false, recent: Int? = nil) -> PickerEntry {
        PickerEntry(id: "champion:\(id)", kind: .champion, title: title, workspace: workspace, avatarID: id, state: state, focused: focused, recent: recent)
    }

    private static func project(_ id: String, _ title: String, _ workspace: String, color: String, icon: String, recent: Int? = nil) -> PickerEntry {
        PickerEntry(id: "orchestrator:\(id)", kind: .orchestrator, title: title, workspace: workspace, projectColor: color, projectIcon: icon, recent: recent)
    }

    static let entries: [PickerEntry] = [
        champion("scout", "Scout", "Personlig", .waiting, focused: true, recent: 0),
        champion("chris-design-lead", "Chris (Design lead)", "Honeybee", recent: 1),
        champion("kal-engineering-manager", "Needle (Engineer)", "Honeybee", recent: 2),
        champion("polish", "Polish", "Honeybee", recent: 4),
        champion("bob-chief-of-staff", "Bob (Chief)", "Digitech"),
        champion("klaus-engineering-manager", "Klaus (Engineer)", "Digitech", .waiting),
        champion("tony-triage", "Tony Triage", "Honeybee", .waiting),
        champion("dolly-docs", "Dolly Docs", "Honeybee"),
        champion("pollinate", "Pollinate", "Honeybee"),
        champion("pheromone", "Pheromone", "Honeybee", .waiting),
        champion("kondo-cleaner", "Kondo", "Honeybee", .waiting),
        champion("valhall", "Valhall", "Personlig"),
        champion("lyn", "Lyn", "Personlig"),
        champion("billing", "Billing", "Personlig"),
        project("project-e42bfd3feecd9a6a6afec0da3a2298ab", "Scout: agent picker redesign with Apiary icons", "Personlig", color: "slate", icon: "sparkle", recent: 3),
        project("project-fd9e51dce288170d32ab56783fbb0576", "Scout: landing page and docs", "Personlig", color: "pink", icon: "users"),
        project("project-59456e721a8f81b51ce85db6043f61dd", "Scout review window and Needle search", "Personlig", color: "ochre", icon: "machine"),
        project("project-9dc2e8f1590c3fcbfda5be29df0cc32b", "Scout: Linear integration", "Personlig", color: "violet", icon: "board"),
        project("project-9c7d7b26de63863275941134742d5889", "Scout: Optimise tasks and game integration", "Personlig", color: "violet", icon: "swarm"),
        project("project-c5236d633fa0495b8d72910b847ef786", "Beautiful Onboarding", "Honeybee", color: "orange", icon: "bolt"),
        project("project-89121791e0dd628c2822e893fd1be79f", "Pheromone as Apiary's event bus: design", "Honeybee", color: "ochre", icon: "gear"),
        project("project-2eef4e92946042a4a9d740f2f34de0a0", "Uni Micro Integration", "Digitech", color: "pink", icon: "layers"),
        project("project-23a2e294b90e4df880c9b1eda7c28574", "Fiken Integration", "Digitech", color: "violet", icon: "target"),
        project("project-edcd8678ab8f7b9926059704bd878491", "Tripletex: land in production", "Digitech", color: "teal", icon: "chat"),
        project("project-ba03173396f6da7bacd04c33ef8e491f", "Asterlode feedback 10 Nov", "Asterlode", color: "orange", icon: "terminal"),
        PickerEntry(id: "session:b01e4598-107e-46fd-940a-30ed2feadaf3", kind: .session, title: "Research: how Apiary renders Champion avatars", detail: "CL.02df", workspace: "Personlig", state: .working),
        PickerEntry(id: "session:28cfbe67-6ec2-4f45-b6bc-c71decccacd2", kind: .session, title: "Design: 3 target picker variants", detail: "apiary-66c1f91b", workspace: "Personlig", state: .working),
        PickerEntry(id: "session:hive-scout-docs", kind: .session, title: "scout docs pass", detail: "hive", workspace: nil),
        PickerEntry(id: "clipboard", kind: .clipboard, title: "Clipboard only", detail: "Copy the walkthrough and send nothing"),
    ]
}

enum PickerAvatars {
    static var directory: URL? {
        let prefix = "--picker-avatars="
        return ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }.map { URL(fileURLWithPath: String($0.dropFirst(prefix.count)), isDirectory: true) }
    }

    private static var cache: [String: NSImage] = [:]
    private static var missing: Set<String> = []

    static func image(_ id: String) -> NSImage? {
        if let image = cache[id] { return image }
        if missing.contains(id) { return nil }
        let url = directory.map { $0.appendingPathComponent("\(id).png") } ?? Bundle.main.url(forResource: "avatar-\(id)", withExtension: "png")
        guard let url, let image = NSImage(contentsOf: url) else {
            missing.insert(id)
            return nil
        }
        cache[id] = image
        return image
    }
}

enum ApiaryProjectColor {
    static func color(_ name: String?) -> Color {
        switch name {
        case "blue": Color(light: 0x4969AD, dark: 0x90ADE5)
        case "orange": Color(light: 0xA66036, dark: 0xDBA176)
        case "teal": Color(light: 0x347983, dark: 0x79BBC5)
        case "violet": Color(light: 0x8564AD, dark: 0xBC9CDE)
        case "pink": Color(light: 0xA44D76, dark: 0xD996B6)
        case "green": Color(light: 0x527642, dark: 0x9DBB81)
        case "ochre": Color(light: 0x8A6A2C, dark: 0xCFB27A)
        default: Color(light: 0x677584, dark: 0xA6B3C1)
        }
    }
}

nonisolated struct ApiaryGlyph: Shape {
    var name: String

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let data = ApiaryIconPaths.paths[name] else { return path }
        let tokens = data.split(separator: " ")
        let scale = min(rect.width, rect.height) / 16
        var index = 0
        func number() -> CGFloat {
            let value = index < tokens.count ? Double(tokens[index]) ?? 0 : 0
            index += 1
            return CGFloat(value)
        }
        func point() -> CGPoint {
            let x = number()
            let y = number()
            return CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
        }
        while index < tokens.count {
            let command = tokens[index]
            index += 1
            switch command {
            case "M":
                path.move(to: point())
            case "L":
                path.addLine(to: point())
            case "C":
                let first = point()
                let second = point()
                let end = point()
                path.addCurve(to: end, control1: first, control2: second)
            case "Z":
                path.closeSubpath()
            default:
                break
            }
        }
        return path
    }
}

struct ProjectGlyphView: View {
    var color: String?
    var icon: String?
    var size: CGFloat

    var body: some View {
        let name = icon ?? "sparkle"
        ApiaryGlyph(name: name)
            .stroke(ApiaryProjectColor.color(color), style: StrokeStyle(lineWidth: (ApiaryIconPaths.strokeWidths[name] ?? 1.5) * size / 16, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }
}

struct MonogramTile: View {
    var text: String
    var size: CGFloat

    var body: some View {
        Text(String(text.prefix(1)).uppercased())
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(Palette.textSecondary)
            .frame(width: size, height: size)
            .background(Palette.raised, in: .rect(cornerRadius: size * 0.28, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(Palette.hairline))
    }
}

struct EntryIcon: View {
    enum Look {
        case bare
        case tile
    }

    var entry: PickerEntry
    var size: CGFloat
    var look: Look = .tile

    var body: some View {
        switch entry.kind {
        case .champion:
            if let id = entry.avatarID, let image = PickerAvatars.image(id) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size * 1.5, height: size * 1.5)
                    .frame(width: size, height: size)
            } else {
                MonogramTile(text: entry.title, size: size)
            }
        case .orchestrator:
            if look == .bare {
                ProjectGlyphView(color: entry.projectColor, icon: entry.projectIcon, size: size * 0.86)
                    .frame(width: size, height: size)
            } else {
                ProjectGlyphView(color: entry.projectColor, icon: entry.projectIcon, size: size * 0.6)
                    .frame(width: size, height: size)
                    .background(ApiaryProjectColor.color(entry.projectColor).opacity(0.14), in: .rect(cornerRadius: size * 0.28, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(ApiaryProjectColor.color(entry.projectColor).opacity(0.28)))
            }
        case .session:
            MonogramTile(text: entry.title, size: size)
        case .clipboard:
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: size, height: size)
                .background(Palette.raised, in: .rect(cornerRadius: size * 0.28, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(Palette.hairline))
        }
    }
}

struct HighlightText: View {
    var text: String
    var query: String
    var size: CGFloat = 13
    var weight: Font.Weight = .regular
    var color: Color = Palette.text
    var dim: Color = Palette.textSecondary

    var body: some View {
        let runs = Self.runs(text, query)
        if runs.count == 1, runs[0].1 == false {
            Text(text).font(.system(size: size, weight: weight)).foregroundStyle(color)
        } else {
            runs.reduce(Text("")) { result, run in
                result + Text(run.0)
                    .font(.system(size: size, weight: run.1 ? .bold : weight))
                    .foregroundStyle(run.1 ? color : dim)
            }
        }
    }

    static func runs(_ text: String, _ query: String) -> [(String, Bool)] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map { Array($0) }
        let source = Array(text)
        let lower = Array(text.lowercased())
        guard !words.isEmpty, lower.count == source.count else { return [(text, false)] }
        var mask = Array(repeating: false, count: source.count)
        for word in words where !word.isEmpty && word.count <= lower.count {
            var start = 0
            while start + word.count <= lower.count {
                if Array(lower[start..<(start + word.count)]) == word {
                    for index in start..<(start + word.count) { mask[index] = true }
                    start += word.count
                } else {
                    start += 1
                }
            }
        }
        var runs: [(String, Bool)] = []
        for (index, character) in source.enumerated() {
            if let last = runs.last, last.1 == mask[index] {
                runs[runs.count - 1].0.append(character)
            } else {
                runs.append((String(character), mask[index]))
            }
        }
        return runs
    }
}
