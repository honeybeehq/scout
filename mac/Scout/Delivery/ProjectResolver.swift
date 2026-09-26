import Darwin
import Foundation
import ScoutCore

nonisolated final class ProjectResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: ProjectReference?] = [:]

    func resolve(_ context: AppContext?) async -> ProjectReference? {
        guard let context else { return nil }
        if let project = context.project { return project }
        guard let location = context.location, let url = URL(string: location), let port = Self.localPort(of: url) else { return nil }
        let key = "port:\(port)"
        if let cached = cached(key) { return cached }
        let project = await Task.detached(priority: .utility) { Self.project(listeningOn: port) }.value
        store(project, for: key)
        return project
    }

    private func cached(_ key: String) -> ProjectReference?? {
        lock.lock()
        defer { lock.unlock() }
        return cache[key]
    }

    private func store(_ project: ProjectReference?, for key: String) {
        lock.lock()
        cache[key] = project
        lock.unlock()
    }

    static func localPort(of url: URL) -> Int? {
        guard let host = url.host?.lowercased(),
              host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]" || host == "0.0.0.0"
        else { return nil }
        return url.port ?? (url.scheme == "https" ? 443 : 80)
    }

    static func project(listeningOn port: Int) -> ProjectReference? {
        guard let pid = listeningProcess(port: port), let cwd = workingDirectory(of: pid) else { return nil }
        guard let root = gitRoot(containing: cwd) else {
            return ProjectReference(rootPath: cwd, name: URL(fileURLWithPath: cwd).lastPathComponent)
        }
        return ProjectReference(rootPath: root, name: URL(fileURLWithPath: root).lastPathComponent, gitBranch: gitBranch(at: root))
    }

    static func listeningProcess(port: Int) -> pid_t? {
        let output = run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"])
        return output?.split(separator: "\n").first.flatMap { pid_t($0) }
    }

    static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    static func gitRoot(containing path: String) -> String? {
        var url = URL(fileURLWithPath: path)
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) { return url.path }
            url.deleteLastPathComponent()
        }
        return nil
    }

    static func gitBranch(at root: String) -> String? {
        guard let head = try? String(contentsOfFile: root + "/.git/HEAD", encoding: .utf8) else { return nil }
        let prefix = "ref: refs/heads/"
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix(prefix) ? String(trimmed.dropFirst(prefix.count)) : nil
    }

    private static func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
