import Foundation
import XCTest

nonisolated final class NetworkBlock: URLProtocol, @unchecked Sendable {
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
    static let modelVariable = "SCOUT_WHISPER_MODEL_FOLDER"
    static let tokenizerVariable = "SCOUT_WHISPER_TOKENIZER_FOLDER"

    static func model() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment[modelVariable] else {
            throw XCTSkip("SKIPPED, NOT PASSED: \(modelVariable) is not set. Export it as an environment variable (TEST_RUNNER_\(modelVariable)=… in the shell before xcodebuild test, not as a build setting) pointing at the verified model folder.")
        }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("config.json").path) else {
            throw XCTSkip("SKIPPED, NOT PASSED: \(modelVariable)=\(path) has no config.json; point it at the verified model folder.")
        }
        return folder
    }

    static func tokenizer() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment[tokenizerVariable] else { return try model() }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

nonisolated final class WhisperOfflineLoadTests: XCTestCase {
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
        let model = try WhisperTestFolders.model()
        let tokenizer = try WhisperTestFolders.tokenizer()
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
        let model = try WhisperTestFolders.model()
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
        XCTAssertFalse(NetworkBlock.attempted.isEmpty, "the missing tokenizer should have made WhisperKit try the Hub, which the block must catch")
        XCTAssertTrue(NetworkBlock.attempted.allSatisfy { $0.host?.hasSuffix("huggingface.co") == true }, "unexpected hosts: \(NetworkBlock.attempted)")
        await engine.unload()
    }

    func testPinnedTableMatchesTheVerifiedFiles() throws {
        let model = try WhisperTestFolders.model()
        let tokenizer = try WhisperTestFolders.tokenizer()
        XCTAssertEqual(WhisperPins.files.count, 24)
        XCTAssertEqual(WhisperPins.totalBytes, 648_662_093)
        for file in WhisperPins.files {
            XCTAssertTrue(file.url.absoluteString.contains("/resolve/\(file.path.hasPrefix("tokenizer") ? WhisperPins.tokenizerRevision : WhisperPins.modelRevision)/"), file.url.absoluteString)
            XCTAssertNoThrow(try WhisperModelFiles.verify(file, in: file.path.hasPrefix("tokenizer") ? tokenizer : model), file.path)
        }
    }
}
