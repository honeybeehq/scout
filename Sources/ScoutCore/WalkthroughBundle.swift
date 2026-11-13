import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct WalkthroughBundle: Sendable {
    public static let entryName = "walkthrough.json"
    public static let textName = "walkthrough.md"
    public static let clipName = "clip.mp4"
    public static let partialSuffix = ".partial"
    public static let pasteboardType = "com.trmd.scout.walkthrough"

    public enum WriteError: Error, CustomStringConvertible {
        case alreadyFinished(URL)
        case mismatchedID(String)
        case sync(String, Int32)

        public var description: String {
            switch self {
            case .alreadyFinished(let url): "a walkthrough already exists at \(url.path)"
            case .mismatchedID(let id): "the walkthrough \(id) doesn't belong in this bundle"
            case .sync(let path, let code): "couldn't sync \(path) (errno \(code))"
            }
        }
    }

    public let id: String
    public let root: URL

    public init(id: String, root: URL = WalkthroughBundle.defaultRoot()) {
        self.id = id
        self.root = root.standardizedFileURL
    }

    public var partialDirectory: URL { root.appendingPathComponent(id + Self.partialSuffix, isDirectory: true) }
    public var directory: URL { root.appendingPathComponent(id, isDirectory: true) }

    public func url(for relativePath: String) -> URL {
        partialDirectory.appendingPathComponent(relativePath)
    }

    public func prepare() throws {
        try FileManager.default.createDirectory(at: partialDirectory.appendingPathComponent("frames/thumbs", isDirectory: true), withIntermediateDirectories: true)
    }

    public func discard() {
        try? FileManager.default.removeItem(at: partialDirectory)
    }

    @discardableResult
    public func finish(_ walkthrough: Walkthrough) throws -> URL {
        let manager = FileManager.default
        guard walkthrough.id == id else { throw WriteError.mismatchedID(walkthrough.id) }
        guard !manager.fileExists(atPath: directory.path) else { throw WriteError.alreadyFinished(directory) }
        try prepare()
        try pruneUnreferenced(walkthrough)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(walkthrough).write(to: url(for: Self.entryName))
        try Data(WalkthroughText.render(walkthrough, bundle: directory).utf8).write(to: url(for: Self.textName))
        try syncTree(partialDirectory)
        try manager.moveItem(at: partialDirectory, to: directory)
        try sync(root.path)
        return directory
    }

    private func pruneUnreferenced(_ walkthrough: Walkthrough) throws {
        let manager = FileManager.default
        let kept = Set(walkthrough.frames.flatMap { [$0.file] + ($0.thumb.map { [$0] } ?? []) })
        for folder in ["frames", "frames/thumbs"] {
            let files = (try? manager.contentsOfDirectory(atPath: url(for: folder).path)) ?? []
            for name in files where !kept.contains("\(folder)/\(name)") {
                var isDirectory: ObjCBool = false
                guard manager.fileExists(atPath: url(for: "\(folder)/\(name)").path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
                try manager.removeItem(at: url(for: "\(folder)/\(name)"))
            }
        }
        if walkthrough.clip == nil { try? manager.removeItem(at: url(for: Self.clipName)) }
    }

    private func syncTree(_ directory: URL) throws {
        let manager = FileManager.default
        for name in try manager.contentsOfDirectory(atPath: directory.path) {
            let child = directory.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: child.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue { try syncTree(child) } else { try sync(child.path) }
        }
        try sync(directory.path)
    }

    private func sync(_ path: String) throws {
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { throw WriteError.sync(path, errno) }
        defer { close(descriptor) }
        #if canImport(Darwin)
        if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        #endif
        guard fsync(descriptor) == 0 else { throw WriteError.sync(path, errno) }
    }

    public static func sweepPartials(in root: URL = defaultRoot(), olderThan age: TimeInterval = 86_400, now: Date = Date(), log: (String) -> Void = { _ in }) {
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: root.path)) ?? []
        for name in names where name.hasPrefix("wt_") && name.hasSuffix(partialSuffix) {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            guard now.timeIntervalSince(modified) > age else { continue }
            #if os(macOS)
            let removed = (try? manager.trashItem(at: folder, resultingItemURL: nil)) != nil
            #else
            let removed = (try? manager.removeItem(at: folder)) != nil
            #endif
            log("\(removed ? "trashed" : "failed to trash") \(folder.path) age \(Int(now.timeIntervalSince(modified)))s")
        }
    }

    public static func defaultRoot() -> URL {
        ScoutDataRoot.url.appendingPathComponent("walkthroughs", isDirectory: true)
    }

    public static func newID(at date: Date = Date()) -> String {
        var generator = SystemRandomNumberGenerator()
        return newID(at: date, using: &generator)
    }

    public static func newID(at date: Date, using generator: inout some RandomNumberGenerator) -> String {
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        var time = UInt64(max(0, date.timeIntervalSince1970 * 1000))
        var timePart: [Character] = []
        for _ in 0..<10 {
            timePart.append(alphabet[Int(time & 31)])
            time >>= 5
        }
        let randomPart = (0..<16).map { _ in alphabet[Int(generator.next() & 31)] }
        return "wt_" + String(timePart.reversed()) + String(randomPart)
    }
}
