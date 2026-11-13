import Foundation

public enum ScoutDataRoot {
    public static let releaseBundleID = "com.trmdy.scout"
    public static let environmentKey = "SCOUT_DATA_ROOT"
    public static let argumentPrefix = "--data-root="

    public struct Resolution: Equatable, Sendable {
        public var root: URL
        public var isRelease: Bool
        public var allowsPruning: Bool
        public var reason: String
    }

    public static let current: Resolution = resolve(
        bundleID: Bundle.main.bundleIdentifier,
        environment: ProcessInfo.processInfo.environment,
        arguments: ProcessInfo.processInfo.arguments,
        home: FileManager.default.homeDirectoryForCurrentUser
    )

    public static var url: URL { current.root }

    public static func resolve(bundleID: String?, environment: [String: String], arguments: [String], home: URL) -> Resolution {
        let flags = arguments.dropFirst().filter { $0.hasPrefix("--") }
        let isRelease = bundleID == releaseBundleID
        if let override = override(environment: environment, arguments: arguments) {
            return Resolution(root: override, isRelease: isRelease, allowsPruning: false, reason: "override")
        }
        #if os(macOS)
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        #else
        let support = environment["XDG_DATA_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
            ?? home.appendingPathComponent(".local/share", isDirectory: true)
        #endif
        guard isRelease else {
            let suffix = bundleID.map(sanitized) ?? "unbundled"
            return Resolution(root: support.appendingPathComponent("Scout-\(suffix)", isDirectory: true), isRelease: false, allowsPruning: false, reason: "bundle \(bundleID ?? "none")")
        }
        #if os(macOS)
        let root = support.appendingPathComponent("Scout", isDirectory: true)
        #else
        let root = support.appendingPathComponent("scout", isDirectory: true)
        #endif
        return Resolution(root: root, isRelease: true, allowsPruning: flags.isEmpty, reason: flags.isEmpty ? "release" : "release with \(flags.count) launch flag(s)")
    }

    private static func override(environment: [String: String], arguments: [String]) -> URL? {
        let fromArgument = arguments.last { $0.hasPrefix(argumentPrefix) }.map { String($0.dropFirst(argumentPrefix.count)) }
        let value = fromArgument ?? environment[environmentKey]
        guard let value, value.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
    }

    private static func sanitized(_ bundleID: String) -> String {
        String(bundleID.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" })
    }
}
