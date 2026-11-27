import Foundation

struct SuggestionTelemetryRow: Encodable {
    var schema = 1
    var at: Date
    var opening: Int
    var outcome: String
    var requested: Bool
    var requestToAnswerMs: Double?
    var openToAnswerMs: Double?
    var openToShownMs: Double?
    var preselectWindowMs: Double
    var topProbability: Double?
    var anyFits: Double?
    var candidates: Int?
    var topKind: String?
    var topIndex: Int?
    var error: String?
}

final class SuggestionTelemetry {
    static let fileName = "suggestions.jsonl"

    private struct Opening {
        var number: Int
        var directory: URL
        var at: Date
        var openedAt: ContinuousClock.Instant
        var on: Bool
        var requestedAt: ContinuousClock.Instant?
        var answeredAt: ContinuousClock.Instant?
        var outcome: SuggestionOutcome?
        var shown: TargetPickerModel.Suggestion = .none
        var shownAfter: Duration?
    }

    private var current: Opening?
    private(set) var written = 0

    func begin(opening: Int, debugDirectory: URL?, on: Bool, keeps: Bool) {
        flush()
        guard keeps, let debugDirectory, FileManager.default.fileExists(atPath: debugDirectory.path) else { return }
        current = Opening(number: opening, directory: debugDirectory, at: Date(), openedAt: .now, on: on)
    }

    func opened() {
        current?.openedAt = .now
    }

    func requested(at instant: ContinuousClock.Instant?) {
        guard let instant else { return }
        current?.requestedAt = instant
        current?.on = true
    }

    func answered(_ outcome: SuggestionOutcome, requestedAt: ContinuousClock.Instant?) {
        guard current != nil, current?.answeredAt == nil else { return }
        current?.on = true
        current?.outcome = outcome
        current?.answeredAt = .now
        if let requestedAt { current?.requestedAt = requestedAt }
    }

    func shown(_ suggestion: TargetPickerModel.Suggestion, after: Duration?) {
        current?.shown = suggestion
        current?.shownAfter = after
    }

    func flush() {
        guard let opening = current else { return }
        current = nil
        let outcome: String
        if !opening.on {
            outcome = "off"
        } else if opening.shown == .preselected {
            outcome = "preselected"
        } else if opening.shown == .highlighted {
            outcome = "highlighted-late"
        } else {
            switch opening.outcome?.kind {
            case .unsure: outcome = "silent-not-confident"
            case .failed, .timedOut: outcome = "silent-error"
            case .confident: outcome = "silent-filtered"
            case nil: outcome = opening.requestedAt == nil ? "silent-not-requested" : "silent-no-answer"
            }
        }
        func ms(_ duration: Duration?) -> Double? {
            duration.map { ($0.seconds * 10_000).rounded() / 10 }
        }
        func rounded(_ value: Double?) -> Double? {
            value.map { ($0 * 10_000).rounded() / 10_000 }
        }
        let answer = opening.outcome
        let failed = answer?.kind == .failed || answer?.kind == .timedOut
        var requestToAnswer: Double?
        if let answeredAt = opening.answeredAt, let requestedAt = opening.requestedAt { requestToAnswer = ms(answeredAt - requestedAt) }
        let row = SuggestionTelemetryRow(
            at: opening.at,
            opening: opening.number,
            outcome: outcome,
            requested: opening.requestedAt != nil,
            requestToAnswerMs: requestToAnswer,
            openToAnswerMs: opening.answeredAt.flatMap { ms($0 - opening.openedAt) },
            openToShownMs: ms(opening.shownAfter),
            preselectWindowMs: ms(TargetPickerModel.preselectWindow) ?? 0,
            topProbability: rounded(answer?.probability),
            anyFits: rounded(answer?.anyFits),
            candidates: answer.map(\.candidates),
            topKind: answer?.topKind,
            topIndex: answer?.topIndex,
            error: failed ? answer?.detail : nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard var line = try? encoder.encode(row) else { return }
        line.append(0x0A)
        let url = opening.directory.appendingPathComponent(Self.fileName)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url, options: .atomic)
        }
        written += 1
        NSLog("[scout-suggest] telemetry: opening %d %@", opening.number, outcome)
    }
}
