import Foundation
import Observation

@MainActor
@Observable
final class WhisperModelStore {
    enum State: Equatable {
        case notInstalled
        case downloading(progress: Double)
        case verifying(progress: Double)
        case installed
        case preparing
        case ready
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .downloading, .verifying, .preparing: true
            case .notInstalled, .installed, .ready, .failed: false
            }
        }

        var summary: String {
            switch self {
            case .notInstalled: "not installed"
            case .downloading(let progress): "downloading \(Int(progress * 100))%"
            case .verifying(let progress): "verifying \(Int(progress * 100))%"
            case .installed: "installed, not loaded"
            case .preparing: "preparing"
            case .ready: "ready"
            case .failed(let reason): "failed: \(reason)"
            }
        }

        fileprivate var logStep: Int? {
            switch self {
            case .downloading(let progress), .verifying(let progress): Int(progress * 20)
            default: nil
            }
        }
    }

    static let downloadBytes = WhisperPins.totalBytes
    static let displayName = WhisperPins.displayName

    let folder: URL
    let tokenizerFolder: URL
    let partialFolder: URL
    private(set) var state: State = .notInstalled {
        didSet {
            guard state != oldValue else { return }
            switch (oldValue, state) {
            case (.downloading, .downloading), (.verifying, .verifying):
                if oldValue.logStep != state.logStep { NSLog("[scout-whisper] %@ (%lld of %lld bytes)", state.summary, partialBytes, Self.downloadBytes) }
            default:
                NSLog("[scout-whisper] %@", state.summary)
            }
        }
    }
    private(set) var installedBytes: Int64 = 0
    private(set) var partialBytes: Int64 = 0
    private(set) var preparingSince: Date?
    private(set) var engine: WhisperEngine?
    private(set) var isLoaded = false
    @ObservationIgnored private var job: Task<Void, Never>?

    nonisolated static func installFolder(under support: URL) -> URL {
        support.appendingPathComponent("Models/whisper/\(WhisperPins.installName)", isDirectory: true)
    }

    init(folder: URL, tokenizerFolder: URL? = nil) {
        self.folder = folder
        self.tokenizerFolder = tokenizerFolder ?? folder
        partialFolder = folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent + ".partial", isDirectory: true)
        installedBytes = WhisperModelFiles.diskUsage(of: folder)
        partialBytes = WhisperModelFiles.diskUsage(of: partialFolder)
        state = installedEngine() == nil ? .notInstalled : .installed
        NSLog("[scout-whisper] %@ at %@", state.summary, folder.path)
    }

    var isInstalled: Bool {
        switch state {
        case .installed, .preparing, .ready: true
        case .notInstalled, .downloading, .verifying, .failed: false
        }
    }

    var readyEngine: WhisperEngine? {
        isInstalled ? engine : nil
    }

    func refresh() {
        installedBytes = WhisperModelFiles.diskUsage(of: folder)
        partialBytes = WhisperModelFiles.diskUsage(of: partialFolder)
        guard !state.isBusy else { return }
        if case .failed = state { return }
        state = installedEngine() == nil ? .notInstalled : (isLoaded ? .ready : .installed)
    }

    private func installedEngine() -> WhisperEngine? {
        guard WhisperModelFiles.isComplete(model: folder, tokenizer: tokenizerFolder) else {
            engine = nil
            return nil
        }
        if engine == nil { engine = WhisperEngine(modelFolder: folder, tokenizerFolder: tokenizerFolder) }
        return engine
    }

    func download() {
        guard !state.isBusy else { return }
        job = Task { await install() }
    }

    func warmUp() {
        guard !state.isBusy, !isLoaded, let engine = installedEngine() else { return }
        job = Task { await prepare(engine) }
    }

    func cancel() {
        switch state {
        case .downloading, .verifying: job?.cancel()
        case .notInstalled, .installed, .preparing, .ready, .failed: break
        }
    }

    func remove() {
        job?.cancel()
        job = nil
        Task {
            await engine?.unload()
            engine = nil
            isLoaded = false
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: partialFolder)
            state = .notInstalled
            refresh()
        }
    }

    private func install() async {
        if !WhisperModelFiles.isComplete(model: folder, tokenizer: tokenizerFolder) {
            do {
                try await downloadFiles()
                try await verifyFiles()
                try moveIntoPlace()
            } catch is CancellationError {
                state = .notInstalled
                refresh()
                return
            } catch {
                NSLog("[scout-whisper] install failed: %@", error.localizedDescription)
                state = .failed(error.localizedDescription)
                refresh()
                return
            }
        }
        guard let engine = installedEngine() else {
            state = .failed("The model files are incomplete.")
            refresh()
            return
        }
        await prepare(engine)
    }

    private func downloadFiles() async throws {
        state = .downloading(progress: Double(WhisperModelFiles.diskUsage(of: partialFolder)) / Double(Self.downloadBytes))
        let downloader = WhisperDownloader(destination: partialFolder) { [weak self] bytes in
            Task { @MainActor in self?.report(.downloading(progress: Double(bytes) / Double(Self.downloadBytes)), bytes: bytes) }
        }
        try await Task.detached(priority: .utility) { try await downloader.run() }.value
    }

    private func verifyFiles() async throws {
        state = .verifying(progress: 0)
        let partial = partialFolder
        let reporter: @Sendable (Int64) -> Void = { [weak self] bytes in
            Task { @MainActor in self?.report(.verifying(progress: Double(bytes) / Double(Self.downloadBytes)), bytes: bytes) }
        }
        try await Task.detached(priority: .utility) {
            var hashed: Int64 = 0
            var lastReport: Int64 = 0
            for file in WhisperPins.files {
                do {
                    try WhisperModelFiles.verify(file, in: partial) { bytes in
                        hashed += bytes
                        if hashed - lastReport >= 8 << 20 {
                            lastReport = hashed
                            reporter(hashed)
                        }
                    }
                } catch let mismatch as WhisperModelFiles.Mismatch {
                    try? FileManager.default.removeItem(at: partial.appendingPathComponent(file.path))
                    NSLog("[scout-whisper] removed %@ after a failed check", file.path)
                    throw mismatch
                }
            }
        }.value
    }

    private func moveIntoPlace() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: folder.path) { try manager.removeItem(at: folder) }
        try manager.moveItem(at: partialFolder, to: folder)
    }

    private func prepare(_ engine: WhisperEngine) async {
        if await engine.isLoaded {
            isLoaded = true
            state = .ready
            refresh()
            return
        }
        state = .preparing
        preparingSince = .now
        defer { preparingSince = nil }
        do {
            try await engine.prepare()
            isLoaded = true
            state = .ready
        } catch {
            NSLog("[scout-whisper] the model did not load: %@", error.localizedDescription)
            state = .failed("The model did not load: \(error.localizedDescription)")
        }
        refresh()
    }

    private func report(_ progress: State, bytes: Int64) {
        guard state.isBusy else { return }
        state = progress
        partialBytes = bytes
    }
}
