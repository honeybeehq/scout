import Foundation

public struct Target: Codable, Hashable, Sendable, Identifiable {
    public enum Provider: String, Codable, Sendable {
        case accessibility
        case web
        case native
        case region
    }

    public var id: String
    public var provider: Provider
    public var role: String?
    public var label: String?
    public var identifier: String?
    public var frame: Rect?
    public var ancestry: [String]
    public var component: String?
    public var selector: String?
    public var source: SourceLocation?

    public init(
        id: String,
        provider: Provider,
        role: String? = nil,
        label: String? = nil,
        identifier: String? = nil,
        frame: Rect? = nil,
        ancestry: [String] = [],
        component: String? = nil,
        selector: String? = nil,
        source: SourceLocation? = nil
    ) {
        self.id = id
        self.provider = provider
        self.role = role
        self.label = label
        self.identifier = identifier
        self.frame = frame
        self.ancestry = ancestry
        self.component = component
        self.selector = selector
        self.source = source
    }

    public var displayName: String {
        let kind = component ?? role ?? "Element"
        guard let label, !label.isEmpty else { return kind }
        return "\(kind) “\(label)”"
    }
}

public struct SourceLocation: Codable, Hashable, Sendable {
    public var file: String
    public var line: Int?
    public var column: Int?

    public init(file: String, line: Int? = nil, column: Int? = nil) {
        self.file = file
        self.line = line
        self.column = column
    }

    public var description: String {
        [file, line.map(String.init), column.map(String.init)].compactMap { $0 }.joined(separator: ":")
    }
}
