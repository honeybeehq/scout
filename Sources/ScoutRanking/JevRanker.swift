import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum JevRankerError: Error, Equatable, CustomStringConvertible {
    case missingKey
    case http(status: Int, detail: String)
    case malformed(String)

    public var description: String {
        switch self {
        case .missingKey: "No TypeSafe API key."
        case .http(let status, let detail): "TypeSafe answered \(status): \(detail)"
        case .malformed(let detail): "TypeSafe answer was malformed: \(detail)"
        }
    }
}

public struct JevRanker: TargetRanker {
    public static let defaultModel = "jev-1.14.0"
    public static let defaultEndpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!

    public var apiKey: String
    public var model: String
    public var endpoint: URL
    public var timeout: TimeInterval
    public var retries: Int
    public var session: URLSession

    public init(apiKey: String, model: String = JevRanker.defaultModel, endpoint: URL = JevRanker.defaultEndpoint, timeout: TimeInterval = 5, retries: Int = 2, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
        self.timeout = timeout
        self.retries = retries
        self.session = session
    }

    public struct Prepared: Sendable {
        public var body: Data
        public var labels: [String: String]
        public var fitQuestions: [String: String]
    }

    public static let chooseInstructions = """
    Scout recorded the spoken feedback in `feedback` while the user was on the page or app it names. \
    Which target in `targets` should receive this feedback and act on it? A Session is one agent working on the task in its bio; \
    a Champion owns a whole product; a Project orchestrator runs a multi-step effort. If the feedback names a target, choose that one. \
    Otherwise choose the target whose work most specifically covers what the feedback is about: a Session or Project working on exactly that \
    beats the Champion of the whole product, and the Champion beats an unrelated Session. Recent activity is only a weak hint.
    """

    public static let anyFitsInstructions = "Does one of the targets in `targets` clearly own what the spoken feedback in `feedback` is about, so it is obvious where to send it?"

    public static func prepare(_ feedback: RankFeedback, candidates: [RankCandidate], now: Date, model: String = JevRanker.defaultModel) throws -> Prepared {
        var labels: [String: String] = [:]
        var targets: [[String: Any]] = []
        var criteria: [String: Any] = [:]
        var questions: [String: Any] = [:]
        var fitQuestions: [String: String] = [:]
        for (index, candidate) in candidates.enumerated() {
            var label = "\(candidate.name) (\(candidate.kind.label))"
            var suffix = 2
            while labels[label] != nil {
                label = "\(candidate.name) (\(candidate.kind.label) \(suffix))"
                suffix += 1
            }
            labels[label] = candidate.key
            let recency = RecencyBucket(lastActiveAt: candidate.lastActiveAt, now: now)
            var target: [String: Any] = ["target": label, "kind": candidate.kind.label, "name": candidate.name, "recent_activity": recency.rawValue]
            if let bio = candidate.bio, !bio.isEmpty { target["bio"] = bio }
            if let project = candidate.project, !project.isEmpty { target["project"] = project }
            if let workspace = candidate.workspace, !workspace.isEmpty { target["workspace"] = workspace }
            targets.append(target)
            criteria[label] = [candidate.kind.label, candidate.bio].compactMap { $0 }.joined(separator: ": ")
            let fit = "fit_\(index)"
            fitQuestions[fit] = candidate.key
            questions[fit] = ["type": "noul", "instructions": "Is the target `\(label)` in `targets` the right one to receive the spoken feedback in `feedback` and act on it?"]
        }
        var context: [String: Any] = ["spoken_feedback": feedback.transcriptPrefix]
        if let title = feedback.pageTitle, !title.isEmpty { context["page_title"] = title }
        if let host = feedback.urlHost { context["site"] = host }
        if let app = feedback.appName, !app.isEmpty { context["app"] = app }
        questions["target"] = ["type": "choice", "instructions": chooseInstructions, "criteria": criteria]
        questions["any_fits"] = ["type": "noul", "instructions": anyFitsInstructions]
        let request: [String: Any] = ["model": model, "state": ["feedback": context, "targets": targets], "questions": questions]
        let body = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        return Prepared(body: body, labels: labels, fitQuestions: fitQuestions)
    }

    public func rank(_ feedback: RankFeedback, candidates: [RankCandidate], now: Date) async throws -> TargetRanking {
        guard !apiKey.isEmpty else { throw JevRankerError.missingKey }
        let prepared = try Self.prepare(feedback, candidates: candidates, now: now, model: model)
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = prepared.body
        let started = ContinuousClock.now
        var attempt = 0
        while true {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 {
                return try Self.parse(data, prepared: prepared, elapsed: .now - started)
            }
            if (status == 429 || status == 529), attempt < retries {
                attempt += 1
                let wait = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "retry-after").flatMap(Double.init) ?? 0.2 * pow(2, Double(attempt))
                try await Task.sleep(for: .seconds(min(wait, 2)))
                continue
            }
            throw JevRankerError.http(status: status, detail: String(decoding: data.prefix(300), as: UTF8.self))
        }
    }

    public static func parse(_ data: Data, prepared: Prepared, elapsed: Duration) throws -> TargetRanking {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = root["answers"] as? [String: Any],
              let target = answers["target"] as? [String: Any],
              let probabilities = target["probabilities"] as? [String: Any]
        else { throw JevRankerError.malformed("no target answer") }
        var scores: [(String, Double)] = []
        for (label, key) in prepared.labels.sorted(by: { $0.key < $1.key }) {
            scores.append((key, (probabilities[label] as? NSNumber)?.doubleValue ?? 0))
        }
        var fits: [String: Double] = [:]
        for (question, key) in prepared.fitQuestions {
            if let answer = answers[question] as? [String: Any], let value = (answer["noul"] as? NSNumber)?.doubleValue { fits[key] = value }
        }
        let anyFits = ((answers["any_fits"] as? [String: Any])?["noul"] as? NSNumber)?.doubleValue
        let tokens = ((root["usage"] as? [String: Any])?["input_tokens"] as? NSNumber)?.intValue
        var ranking = TargetRanking.normalized(scores, source: .jev, elapsed: elapsed, fits: fits, anyFits: anyFits, model: root["model"] as? String, inputTokens: tokens)
        if let confidence = (target["confidence"] as? NSNumber)?.doubleValue { ranking.confidence = confidence }
        return ranking
    }
}
