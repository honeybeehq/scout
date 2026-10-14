import Darwin
import Foundation
import ScoutCore

nonisolated final class ProjectResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: (project: ProjectReference?, at: Date)] = [:]
    private static let cacheLifetime: TimeInterval = 60

    func resolve(_ context: AppContext?) async -> ProjectReference? {
        guard let context else { return nil }
        if let project = context.project { return project }
        guard let location = context.location, let url = URL(string: location), url.host != nil else { return nil }
        let key = "url:" + Self.origin(of: url)
        if let cached = cached(key) { return cached }
        let project = await Task.detached(priority: .utility) { Self.project(for: url) }.value
        store(project, for: key)
        return project
    }

    static func project(for url: URL) -> ProjectReference? {
        if let nectar = nectarProject(for: url) { return nectar }
        guard let target = localTarget(of: url) else { return nil }
        if let listening = project(listeningOn: target.port) { return listening }
        guard let pid = target.pid, let cwd = workingDirectory(of: pid), let root = gitRoot(containing: cwd) else { return nil }
        return reference(root: root, branch: gitBranch(at: root))
    }

    private func cached(_ key: String) -> ProjectReference?? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = cache[key], Date().timeIntervalSince(entry.at) < Self.cacheLifetime else { return nil }
        return entry.project
    }

    private func store(_ project: ProjectReference?, for key: String) {
        lock.lock()
        cache[key] = (project, Date())
        lock.unlock()
    }

    static func localTarget(of url: URL) -> (port: Int, pid: pid_t?)? {
        guard let host = url.host?.lowercased() else { return nil }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]" || host == "0.0.0.0" {
            return (url.port ?? (url.scheme == "https" ? 443 : 80), nil)
        }
        guard host.hasSuffix(".localhost"), let route = portlessRoute(for: host) else { return nil }
        return (route.port, route.pid > 0 ? route.pid : nil)
    }

    struct PortlessRoute: Decodable {
        var hostname: String
        var port: Int
        var pid: pid_t
    }

    static var portlessStateDirectories: [URL] {
        if let directory = ProcessInfo.processInfo.environment["PORTLESS_STATE_DIR"] {
            return [URL(fileURLWithPath: directory, isDirectory: true)]
        }
        return [
            URL(fileURLWithPath: NSHomeDirectory() + "/.portless", isDirectory: true),
            URL(fileURLWithPath: "/tmp/portless", isDirectory: true),
        ]
    }

    static func portlessRoute(for host: String, in directories: [URL] = portlessStateDirectories) -> PortlessRoute? {
        let routes = directories.flatMap { directory -> [PortlessRoute] in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("routes.json")) else { return [] }
            return (try? JSONDecoder().decode([PortlessRoute].self, from: data)) ?? []
        }
        .filter { $0.pid == 0 || kill($0.pid, 0) == 0 || errno == EPERM }
        if let exact = routes.first(where: { $0.hostname.lowercased() == host }) { return exact }
        return routes
            .filter { host.hasSuffix("." + $0.hostname.lowercased()) }
            .max { $0.hostname.count < $1.hostname.count }
    }

    struct NectarEnv: Decodable {
        struct URLs: Decodable {
            var local: String?
            var mesh: String?
            var `public`: String?
        }

        var repo: String?
        var branch: String?
        var worktree: String?
        var borrowed_worktree: Bool?
        var status: String?
        var urls: URLs?
    }

    static var nectarEnvironments: URL {
        let root = ProcessInfo.processInfo.environment["NECTAR_HOME"] ?? NSHomeDirectory() + "/.nectar"
        return URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("envs", isDirectory: true)
    }

    static func nectarProject(for url: URL, in directory: URL = nectarEnvironments) -> ProjectReference? {
        let wanted = origin(of: url)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let env = try? JSONDecoder().decode(NectarEnv.self, from: data),
                  env.status != "stopped", env.status != "expired",
                  let urls = env.urls
            else { continue }
            let origins = [urls.local, urls.mesh, urls.public].compactMap { $0.flatMap(URL.init(string:)).map(origin(of:)) }
            guard origins.contains(wanted) else { continue }
            let source = env.borrowed_worktree == true ? env.worktree : env.repo
            guard let source, let root = gitRoot(containing: source) else { continue }
            return reference(root: root, branch: env.branch ?? gitBranch(at: root))
        }
        return nil
    }

    static func origin(of url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? "http"
        let host = url.host?.lowercased() ?? ""
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }

    static func reference(root: String, branch: String?) -> ProjectReference {
        ProjectReference(rootPath: root, name: URL(fileURLWithPath: root).lastPathComponent, gitBranch: branch)
    }

    static func project(listeningOn port: Int) -> ProjectReference? {
        guard let pid = listeningProcess(port: port), let cwd = workingDirectory(of: pid), let root = gitRoot(containing: cwd) else { return nil }
        return reference(root: root, branch: gitBranch(at: root))
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
