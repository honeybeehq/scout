import Foundation
import Observation
import ScoutCore
import ScoutRanking
import Security

struct SuggestionOutcome: Sendable {
    enum Kind: String, Sendable {
        case confident
        case unsure
        case failed
        case timedOut
    }

    var kind: Kind
    var key: String?
    var detail: String
    var roundTrip: Duration
    var probability: Double?
    var anyFits: Double?
    var topIndex: Int?
    var topKind: String?
    var candidates = 0
}

@Observable
final class TargetSuggestions {
    static let privacyURL = URL(string: "https://typesafe.ai/legal/privacy-policy")!
    static let limit: Duration = .milliseconds(2500)
    static let disclosure = "When a recording finishes, Scout asks TypeSafe which chat it belongs in. It sends the names and bios of your Champions, Projects and sessions, their project and workspace names, a rough recency (like “active today”), the first 500 characters of the transcript, the page title, the site's host name only and the name of the app you were in."
    static let exclusions = "Screenshots, audio, full URLs and file paths are never sent. Scout only highlights a suggestion and never sends on its own."

    private static let enabledKey = "suggest.typesafe"
    private static let offeredKey = "suggest.typesafe.offered"
    private static let environmentKey = "SCOUT_TYPESAFE_API_KEY"
    private static let session = URLSession(configuration: .ephemeral)

    private let defaults = UserDefaults.standard
    private let persists: Bool
    private(set) var enabled: Bool?
    private(set) var offered: Bool
    private(set) var hasKey = false
    private(set) var keyProblem: String?
    private(set) var lastOutcome: SuggestionOutcome?
    private(set) var requests = 0
    @ObservationIgnored private(set) var requestedAt: ContinuousClock.Instant?
    var draftKey = ""

    @ObservationIgnored private var memoryKey: String?
    @ObservationIgnored private var keySource = "none"
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var feedback: RankFeedback?
    @ObservationIgnored private var candidates: [ApiaryTarget]?
    @ObservationIgnored private var launched = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private(set) var lastBody: Data?
    @ObservationIgnored private(set) var warmUps = 0
    @ObservationIgnored var onResult: ((SuggestionOutcome) -> Void)?

    init() {
        let development = !ScoutDataRoot.current.isRelease
        let override = development ? Self.argument("suggest-typesafe") : nil
        persists = override == nil
        switch override {
        case "on": enabled = true; offered = true
        case "off": enabled = false; offered = true
        case "unset": enabled = nil; offered = false
        default:
            enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool
            offered = UserDefaults.standard.bool(forKey: Self.offeredKey)
        }
        if development, let value = ProcessInfo.processInfo.environment[Self.environmentKey] {
            unsetenv(Self.environmentKey)
            let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                memoryKey = key
                keySource = "environment"
            }
        }
        hasKey = memoryKey != nil || TypeSafeKeychain.contains()
        if memoryKey == nil, hasKey { keySource = "keychain" }
        NSLog("[scout-suggest] TypeSafe suggestions %@, key %@", enabled.map { $0 ? "on" : "off" } ?? "unset", hasKey ? "from \(keySource)" : "missing")
    }

    var isOn: Bool { enabled == true && hasKey }

    var showsOffer: Bool { enabled == nil && !offered }

    var state: String {
        guard let enabled else { return "unset" }
        return enabled ? (hasKey ? "on" : "on, no key") : "off"
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        offered = true
        if persists {
            defaults.set(value, forKey: Self.enabledKey)
            defaults.set(true, forKey: Self.offeredKey)
        }
        if !value { cancel() }
    }

    func markOffered() {
        offered = true
        if persists { defaults.set(true, forKey: Self.offeredKey) }
    }

    func saveKey() {
        let key = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let status = TypeSafeKeychain.save(key)
        draftKey = ""
        if status == errSecSuccess {
            memoryKey = nil
            keySource = "keychain"
            hasKey = true
            keyProblem = nil
        } else {
            keyProblem = "The Keychain refused the key (error \(status))."
        }
    }

    func removeKey() {
        TypeSafeKeychain.remove()
        memoryKey = nil
        keySource = "none"
        hasKey = false
        cancel()
    }

    private func apiKey() -> String? {
        if let memoryKey { return memoryKey }
        guard let key = TypeSafeKeychain.read() else {
            hasKey = false
            return nil
        }
        return key
    }

    func begin() {
        cancel()
        generation += 1
        feedback = nil
        candidates = nil
        launched = false
        lastOutcome = nil
        lastBody = nil
        requestedAt = nil
    }

    func offer(feedback: RankFeedback?) {
        guard self.feedback == nil, let feedback, !feedback.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        self.feedback = feedback
        launch()
    }

    func offer(candidates: [ApiaryTarget]) {
        let rows = candidates.filter { $0.kind != TargetPickerModel.clipboardKind }
        guard self.candidates == nil, rows.count > 1 else { return }
        self.candidates = rows
        launch()
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    func warmUp() {
        guard isOn else { return }
        warmUps += 1
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 5)
        request.httpMethod = "HEAD"
        let started = ContinuousClock.now
        Task {
            let status = ((try? await Self.session.data(for: request))?.1 as? HTTPURLResponse)?.statusCode ?? 0
            NSLog("[scout-suggest] connection warmed in %.0f ms (HTTP %d, no key, no data)", (ContinuousClock.now - started).seconds * 1000, status)
        }
    }

    func launch() {
        guard !launched, isOn, let feedback, let candidates, let key = apiKey() else { return }
        launched = true
        requests += 1
        let rows = candidates.map(Self.candidate)
        let now = Date()
        if !ScoutDataRoot.current.isRelease { lastBody = try? JevRanker.prepare(feedback, candidates: rows, now: now).body }
        let ranker = JevRanker(apiKey: key, endpoint: Self.endpoint, timeout: Self.limit.seconds, retries: 0, session: Self.session)
        let delay = Self.delay
        let generation = generation
        NSLog("[scout-suggest] request %d: %d candidates", requests, rows.count)
        requestedAt = .now
        task = Task { [weak self] in
            let started = ContinuousClock.now
            var outcome: SuggestionOutcome
            var top: (index: Int, kind: String)?
            do {
                let ranking = try await Self.rank(ranker, feedback, rows, now: now)
                if let key = ranking.top?.key, let index = rows.firstIndex(where: { $0.key == key }) { top = (index, rows[index].kind.rawValue) }
                if let pick = ranking.suggestion() {
                    outcome = SuggestionOutcome(kind: .confident, key: pick.key, detail: "confident", roundTrip: .now - started, probability: pick.probability, anyFits: ranking.anyFits)
                } else {
                    outcome = SuggestionOutcome(kind: .unsure, key: nil, detail: "not confident", roundTrip: .now - started, probability: ranking.top?.probability, anyFits: ranking.anyFits)
                }
            } catch is CancellationError {
                return
            } catch is SuggestionTimeout {
                outcome = SuggestionOutcome(kind: .timedOut, key: nil, detail: "timed out", roundTrip: .now - started)
            } catch let error as JevRankerError {
                let detail = switch error {
                case .missingKey: "no key"
                case .http(let status, _): "HTTP \(status)"
                case .malformed: "malformed answer"
                }
                outcome = SuggestionOutcome(kind: .failed, key: nil, detail: detail, roundTrip: .now - started)
            } catch let error as URLError {
                outcome = SuggestionOutcome(kind: .failed, key: nil, detail: "offline (\(error.code.rawValue))", roundTrip: .now - started)
            } catch {
                outcome = SuggestionOutcome(kind: .failed, key: nil, detail: String(describing: type(of: error)), roundTrip: .now - started)
            }
            outcome.topIndex = top?.index
            outcome.topKind = top?.kind
            outcome.candidates = rows.count
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled, let self, self.generation == generation else { return }
            NSLog("[scout-suggest] answer in %.0f ms: %@", outcome.roundTrip.seconds * 1000, outcome.detail)
            self.task = nil
            self.lastOutcome = outcome
            self.onResult?(outcome)
        }
    }

    private struct SuggestionTimeout: Error {}

    private static func rank(_ ranker: JevRanker, _ feedback: RankFeedback, _ candidates: [RankCandidate], now: Date) async throws -> TargetRanking {
        let budget = Self.limit
        return try await withThrowingTaskGroup(of: TargetRanking?.self) { group in
            group.addTask { try await ranker.rank(feedback, candidates: candidates, now: now) }
            group.addTask {
                try await Task.sleep(for: budget)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let ranking = first else { throw SuggestionTimeout() }
            return ranking
        }
    }

    static func candidate(_ target: ApiaryTarget) -> RankCandidate {
        let kind: RankCandidate.Kind = target.isProject ? .project : target.isChampion ? .champion : .session
        return RankCandidate(
            key: target.key,
            kind: kind,
            name: target.title,
            bio: target.bio ?? target.sessionTitle.flatMap { $0 == target.title ? nil : $0 },
            project: kind == .project ? nil : target.subtitle.map(scrubbed),
            workspace: target.workspaceName,
            lastActiveAt: target.lastActiveAt
        )
    }

    static func feedback(transcript: String, context: AppContext?) -> RankFeedback {
        RankFeedback(transcript: transcript, pageURL: context?.location, pageTitle: context?.windowTitle.map(scrubbed), appName: context?.app.name)
    }

    static func feedback(from walkthrough: Walkthrough) -> RankFeedback {
        let app = walkthrough.context?.apps.last
        return RankFeedback(
            transcript: walkthrough.transcript.segments.map(\.text).joined(separator: " "),
            pageURL: app?.url,
            pageTitle: app?.windowTitle.map(scrubbed),
            appName: app?.name
        )
    }

    static func scrubbed(_ text: String) -> String {
        text.split(separator: " ", omittingEmptySubsequences: true)
            .filter { !$0.contains("/") && !$0.hasPrefix("~") && !$0.contains("\\") }
            .joined(separator: " ")
    }

    private static var endpoint: URL {
        guard !ScoutDataRoot.current.isRelease, let value = argument("suggest-endpoint") ?? ProcessInfo.processInfo.environment["TYPESAFE_ENDPOINT"], let url = URL(string: value) else {
            return JevRanker.defaultEndpoint
        }
        return url
    }

    private static var delay: Duration {
        guard !ScoutDataRoot.current.isRelease, let value = argument("suggest-delay-ms").flatMap(Int.init) else { return .zero }
        return .milliseconds(value)
    }

    private static func argument(_ name: String) -> String? {
        let prefix = "--\(name)="
        return ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }
}

enum TypeSafeKeychain {
    static let service = ScoutDataRoot.current.isRelease ? "com.trmdy.scout.typesafe" : "\(Bundle.main.bundleIdentifier ?? "unbundled").typesafe"
    static let account = "api-key"

    static func contains() -> Bool {
        [true, false].contains { dataProtection in
            var query = Self.query(dataProtection: dataProtection)
            query[kSecMatchLimit] = kSecMatchLimitOne
            query[kSecReturnAttributes] = true
            return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
        }
    }

    static func read() -> String? {
        for dataProtection in [true, false] {
            var query = Self.query(dataProtection: dataProtection)
            query[kSecReturnData] = true
            query[kSecMatchLimit] = kSecMatchLimitOne
            var result: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) {
                return key
            }
        }
        return nil
    }

    static func save(_ key: String) -> OSStatus {
        remove()
        let status = add(key, dataProtection: true)
        return status == errSecMissingEntitlement ? add(key, dataProtection: false) : status
    }

    static func remove() {
        SecItemDelete(Self.query(dataProtection: true) as CFDictionary)
        SecItemDelete(Self.query(dataProtection: false) as CFDictionary)
    }

    private static func add(_ key: String, dataProtection: Bool) -> OSStatus {
        var attributes = Self.query(dataProtection: dataProtection)
        attributes[kSecValueData] = Data(key.utf8)
        attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecAttrLabel] = "Scout · TypeSafe API key"
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    private static func query(dataProtection: Bool) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: false,
        ]
        if dataProtection { query[kSecUseDataProtectionKeychain] = true }
        return query
    }
}
