import Foundation
import XCTest

final class NetworkBlock: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests: [URL] = []

    static var attempted: [URL] {
        lock.withLock { requests }
    }

    static func reset() {
        lock.withLock { requests = [] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        if let url = request.url { lock.withLock { requests.append(url) } }
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}

nonisolated enum WhisperTestFolders {
    static var model: URL {
        if let path = ProcessInfo.processInfo.environment["SCOUT_WHISPER_MODEL_FOLDER"] { return URL(fileURLWithPath: path, isDirectory: true) }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Scout", isDirectory: true)
        return WhisperModelStore.installFolder(under: support)
    }

    static var tokenizer: URL {
        ProcessInfo.processInfo.environment["SCOUT_WHISPER_TOKENIZER_FOLDER"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? model
    }
}

final class WhisperOfflineLoadTests: XCTestCase {
    override func setUp() {
        super.setUp()
        NetworkBlock.reset()
        URLProtocol.registerClass(NetworkBlock.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(NetworkBlock.self)
        super.tearDown()
    }

    func testModelAndTokenizerLoadWithoutAnyNetworkRequest() async throws {
        let model = WhisperTestFolders.model
        let tokenizer = WhisperTestFolders.tokenizer
        try XCTSkipUnless(WhisperModelFiles.isComplete(model) || FileManager.default.fileExists(atPath: model.appendingPathComponent("config.json").path), "no model at \(model.path); set SCOUT_WHISPER_MODEL_FOLDER")
        let engine = WhisperEngine(modelFolder: model, tokenizerFolder: tokenizer)
        try await engine.prepare()
        let loaded = await engine.isLoaded
        XCTAssertTrue(loaded, "WhisperKit did not finish loading")
        let tokens = try await engine.encode(" checkout page")
        XCTAssertFalse(tokens.isEmpty, "the tokenizer produced no tokens")
        XCTAssertEqual(NetworkBlock.attempted, [], "WhisperKit reached for the network while loading: \(NetworkBlock.attempted)")
        await engine.unload()
    }

    func testMissingTokenizerFailsInsteadOfFetchingFromTheHub() async throws {
        let model = WhisperTestFolders.model
        try XCTSkipUnless(FileManager.default.fileExists(atPath: model.appendingPathComponent("config.json").path), "no model at \(model.path); set SCOUT_WHISPER_MODEL_FOLDER")
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("scout-whisper-no-tokenizer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        let engine = WhisperEngine(modelFolder: model, tokenizerFolder: empty)
        do {
            try await engine.prepare()
            XCTFail("loading succeeded without a local tokenizer")
        } catch {
            let loaded = await engine.isLoaded
            XCTAssertFalse(loaded)
        }
        XCTAssertTrue(NetworkBlock.attempted.allSatisfy { $0.host?.hasSuffix("huggingface.co") == true }, "unexpected hosts: \(NetworkBlock.attempted)")
        await engine.unload()
    }

    func testPinnedTableMatchesTheVerifiedFiles() throws {
        let model = WhisperTestFolders.model
        let tokenizer = WhisperTestFolders.tokenizer
        try XCTSkipUnless(FileManager.default.fileExists(atPath: model.appendingPathComponent("config.json").path), "no model at \(model.path); set SCOUT_WHISPER_MODEL_FOLDER")
        XCTAssertEqual(WhisperPins.files.count, 24)
        XCTAssertEqual(WhisperPins.totalBytes, 648_662_093)
        for file in WhisperPins.files {
            XCTAssertTrue(file.url.absoluteString.contains("/resolve/\(file.path.hasPrefix("tokenizer") ? WhisperPins.tokenizerRevision : WhisperPins.modelRevision)/"), file.url.absoluteString)
            XCTAssertNoThrow(try WhisperModelFiles.verify(file, in: file.path.hasPrefix("tokenizer") ? tokenizer : model), file.path)
        }
    }
}
