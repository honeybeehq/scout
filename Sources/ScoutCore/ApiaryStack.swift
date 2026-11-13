import Foundation

public struct ApiaryStack: Hashable, Sendable {
    public var levels: [JSONValue]

    public init(levels: [JSONValue]) {
        self.levels = levels
    }

    private static let innerKinds: Set<String> = ["dom", "element", "entity"]

    private func fields(_ level: JSONValue) -> [String: JSONValue]? {
        guard case .object(let fields) = level else { return nil }
        return fields
    }

    private func string(_ fields: [String: JSONValue], _ key: String) -> String? {
        guard case .string(let value)? = fields[key], !value.isEmpty else { return nil }
        return value
    }

    private func kind(_ fields: [String: JSONValue]) -> String? {
        string(fields, "level")
    }

    public var innermost: [String: JSONValue]? {
        levels.reversed().lazy.compactMap(fields).first { kind($0).map(Self.innerKinds.contains) ?? false }
            ?? levels.last.flatMap(fields)
    }

    public var identity: JSONValue? {
        guard var level = innermost else { return nil }
        level["bounds"] = nil
        level["text"] = nil
        return .object(level)
    }

    public var bounds: Rect? {
        for level in levels.reversed() {
            guard let fields = fields(level), case .object(let box)? = fields["bounds"],
                  case .number(let x)? = box["x"], case .number(let y)? = box["y"],
                  case .number(let w)? = box["w"], case .number(let h)? = box["h"]
            else { continue }
            return Rect(x: x, y: y, width: w, height: h)
        }
        return nil
    }

    public var elementBounds: Rect? {
        guard let level = innermost, let kind = kind(level), kind == "dom" || kind == "element" else { return nil }
        return ApiaryStack(levels: [.object(level)]).bounds
    }

    public var url: String? {
        levels.reversed().lazy.compactMap(fields).first { kind($0) == "dom" }.flatMap { string($0, "url") }
    }

    public var label: String? {
        guard let (role, name) = roleAndName else { return nil }
        let kind = role ?? "element"
        guard let name else { return kind }
        let short = name.count > 60 ? String(name.prefix(59)) + "…" : name
        return "\(kind) “\(short)”"
    }

    public var name: String? {
        roleAndName?.name
    }

    private var roleAndName: (role: String?, name: String?)? {
        guard let level = innermost else { return nil }
        switch kind(level) {
        case "dom":
            return (string(level, "role") ?? string(level, "tag"), string(level, "name") ?? string(level, "text"))
        case "element":
            return (string(level, "role"), string(level, "label"))
        case "entity":
            return (string(level, "kind"), string(level, "title") ?? string(level, "handle") ?? string(level, "id"))
        case "pane":
            return (string(level, "viewType").map { "\($0) pane" }, string(level, "title"))
        case "window":
            return ("window", string(level, "title"))
        default:
            return nil
        }
    }
}

public struct SemanticHit: Hashable, Sendable {
    public var at: SessionTime
    public var via: Walkthrough.Via
    public var point: Point
    public var markID: String?
    public var stack: ApiaryStack

    public init(at: SessionTime, via: Walkthrough.Via, point: Point, markID: String? = nil, stack: ApiaryStack) {
        self.at = at
        self.via = via
        self.point = point
        self.markID = markID
        self.stack = stack
    }
}
