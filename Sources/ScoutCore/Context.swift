import Foundation

public struct AppIdentity: Codable, Hashable, Sendable {
    public var bundleID: String?
    public var name: String
    public var processID: Int32?

    public init(bundleID: String?, name: String, processID: Int32? = nil) {
        self.bundleID = bundleID
        self.name = name
        self.processID = processID
    }

    public func isSameApp(as other: AppIdentity) -> Bool {
        if let bundleID, let otherBundleID = other.bundleID { return bundleID == otherBundleID }
        return name == other.name
    }
}

public struct AppContext: Codable, Hashable, Sendable {
    public var app: AppIdentity
    public var windowTitle: String?
    public var location: String?
    public var project: ProjectReference?

    public init(app: AppIdentity, windowTitle: String? = nil, location: String? = nil, project: ProjectReference? = nil) {
        self.app = app
        self.windowTitle = windowTitle
        self.location = location
        self.project = project
    }
}

public struct ProjectReference: Codable, Hashable, Sendable {
    public var rootPath: String
    public var name: String?
    public var gitBranch: String?

    public init(rootPath: String, name: String? = nil, gitBranch: String? = nil) {
        self.rootPath = rootPath
        self.name = name
        self.gitBranch = gitBranch
    }
}
