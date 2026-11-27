import Foundation

struct Report {
    var all: [ResolvedCase]
    var baseline: [String: Run]
    var untuned: [String: Run]
    var recording: Recording?

    var cases: [ResolvedCase] { all.filter { !$0.isNoFit } }
    var noFit: [ResolvedCase] { all.filter(\.isNoFit) }

    func percent(_ part: Int, _ whole: Int) -> String {
        whole == 0 ? "–" : String(format: "%.0f%% (%d/%d)", 100 * Double(part) / Double(whole), part, whole)
    }

    func hits(_ keys: (ResolvedCase) -> [String]?, within: Int) -> Int {
        cases.filter { item in keys(item).map { $0.prefix(within).contains(item.gold) } ?? false }.count
    }

    func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((p / 100 * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }

    func binomialTwoSided(_ k: Int, _ n: Int) -> Double {
        guard n > 0 else { return 1 }
        func choose(_ n: Int, _ k: Int) -> Double { k == 0 ? 1 : (1...k).reduce(1.0) { $0 * Double(n - k + $1) / Double($1) } }
        let tail = (0...min(k, n - k)).reduce(0.0) { $0 + choose(n, $1) } / pow(2, Double(n))
        return min(1, 2 * tail)
    }

    var markdown: String {
        var out: [String] = []
        let n = cases.count
        let jev = Dictionary((recording?.runs ?? []).filter { $0.attempt == 0 }.map { ($0.caseID, $0) }, uniquingKeysWith: { a, _ in a })
        let hasJev = !jev.isEmpty
        out.append("## Accuracy (\(n) cases with a correct target; \(noFit.count) no-fit cases are only used in the gate table)\n")
        out.append("| Method | Top-1 | Top-3 |")
        out.append("|---|---|---|")
        out.append("| Baseline, untuned: recency + name + raw keyword overlap | \(percent(hits({ untuned[$0.id]?.keys }, within: 1), n)) | \(percent(hits({ untuned[$0.id]?.keys }, within: 3), n)) |")
        out.append("| Baseline, tuned on this set: recency + name + length-normalised keywords | \(percent(hits({ baseline[$0.id]?.keys }, within: 1), n)) | \(percent(hits({ baseline[$0.id]?.keys }, within: 3), n)) |")
        if hasJev {
            out.append("| Jev Choice (\(recording?.model ?? "")) | \(percent(hits({ jev[$0.id]?.keys }, within: 1), n)) | \(percent(hits({ jev[$0.id]?.keys }, within: 3), n)) |")
            out.append("| Jev per-target Noul, sorted | \(percent(hits({ jev[$0.id]?.fitKeys }, within: 1), n)) | \(percent(hits({ jev[$0.id]?.fitKeys }, within: 3), n)) |")
            let errors = jev.values.filter { $0.error != nil }.count
            if errors > 0 { out.append("\n\(errors) Jev requests failed and count as misses.") }
            let jevRight = Set(cases.filter { jev[$0.id]?.keys.first == $0.gold }.map(\.id))
            let baseRight = Set(cases.filter { baseline[$0.id]?.keys.first == $0.gold }.map(\.id))
            let onlyJev = jevRight.subtracting(baseRight).count
            let onlyBase = baseRight.subtracting(jevRight).count
            out.append("\nHead to head on top-1 against the tuned baseline: Jev right and baseline wrong in \(onlyJev) cases, baseline right and Jev wrong in \(onlyBase). Exact McNemar p = \(String(format: "%.4f", binomialTwoSided(min(onlyJev, onlyBase), onlyJev + onlyBase))).")
        }

        let tags = Set(cases.flatMap(\.tags)).subtracting(["no-fit"]).sorted()
        out.append("\n## Top-1 by case type\n")
        out.append(hasJev ? "| Tag | Cases | Baseline | Jev |\n|---|---|---|---|" : "| Tag | Cases | Baseline |\n|---|---|---|")
        for tag in tags {
            let subset = cases.filter { $0.tags.contains(tag) }
            let base = subset.filter { baseline[$0.id]?.keys.first == $0.gold }.count
            var row = "| \(tag) | \(subset.count) | \(percent(base, subset.count)) |"
            if hasJev { row += " \(percent(subset.filter { jev[$0.id]?.keys.first == $0.gold }.count, subset.count)) |" }
            out.append(row)
        }

        if hasJev {
            out.append("\n## Confident picks only\n")
            out.append("Coverage is the share of labelled cases where the top pick clears the bar and gets highlighted. Precision is the share of those highlights that are correct. The last column counts no-fit cases, where no candidate fits, that would still get a highlight.\n")
            out.append("| Gate | Coverage | Precision | Wrong highlights | Highlights on no-fit cases |")
            out.append("|---|---|---|---|---|")
            func gate(_ label: String, _ runs: [String: Run], _ pass: (Run) -> Bool, keys: (Run) -> [String] = { $0.keys }) {
                let kept = cases.filter { runs[$0.id].map { $0.error == nil && pass($0) } ?? false }
                let right = kept.filter { runs[$0.id].flatMap { keys($0).first } == $0.gold }.count
                let noFitKept = noFit.filter { runs[$0.id].map { $0.error == nil && pass($0) } ?? false }.count
                let noFitRuns = noFit.filter { runs[$0.id] != nil }.count
                out.append("| \(label) | \(percent(kept.count, n)) | \(percent(right, kept.count)) | \(kept.count - right) | \(percent(noFitKept, noFitRuns)) |")
            }
            for threshold in [0.0, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.95] {
                gate("Jev top probability ≥ \(threshold)", jev, { $0.top >= threshold })
            }
            for threshold in [0.5, 0.7, 0.9] {
                gate("Jev confidence ≥ \(threshold)", jev, { $0.confidence >= threshold })
            }
            for threshold in [0.6, 0.8, 0.9] {
                for fits in [0.5, 0.7] {
                    gate("Jev top probability ≥ \(threshold) and any-fits Noul ≥ \(fits)", jev, { $0.top >= threshold && ($0.anyFits ?? 0) >= fits })
                }
            }
            gate("Recommended: TargetRanking.suggestion() defaults (top ≥ 0.8, any-fits ≥ 0.5)", jev, { $0.top >= 0.8 && ($0.anyFits ?? 0) >= 0.5 })
            for fit in [0.5, 0.7] {
                gate("Jev top Choice pick's own Noul ≥ \(fit)", jev, { ($0.ranked.first?.fit ?? 0) >= fit })
            }
            for threshold in [0.5, 0.7, 0.9] {
                gate("Baseline softmax top ≥ \(threshold) (reference)", baseline, { $0.top >= threshold })
            }

            let ok = (recording?.runs ?? []).filter { $0.error == nil }
            let ms = ok.map(\.milliseconds)
            out.append("\n## Latency\n")
            out.append("Wall clock per request from the harness (sequential, one request per case, all questions in one request). \(ok.count) successful requests over \(recording?.runs.map(\.attempt).max().map { $0 + 1 } ?? 0) pass(es).\n")
            out.append("| p50 | p95 | max | mean | warm-up (first request, excluded) | mean input tokens |")
            out.append("|---|---|---|---|---|---|")
            let tokens = ok.compactMap(\.inputTokens)
            out.append(String(format: "| %.0f ms | %.0f ms | %.0f ms | %.0f ms | %@ | %@ |", percentile(ms, 50), percentile(ms, 95), ms.max() ?? 0, ms.isEmpty ? 0 : ms.reduce(0, +) / Double(ms.count), recording?.warmupMilliseconds.map { String(format: "%.0f ms", $0) } ?? "–", tokens.isEmpty ? "–" : String(tokens.reduce(0, +) / tokens.count)))
            let within300 = ms.filter { $0 <= 300 }.count
            out.append("\n\(percent(within300, ms.count)) of requests finished within the 300 ms budget.")

            let attempts = Set((recording?.runs ?? []).map(\.attempt))
            if attempts.count > 1 {
                let grouped = Dictionary(grouping: (recording?.runs ?? []).filter { $0.error == nil }, by: \.caseID)
                let stable = grouped.values.filter { Set($0.compactMap { $0.keys.first }).count == 1 }.count
                out.append("\nTop pick identical across \(attempts.count) passes in \(percent(stable, grouped.count)) of cases.")
            }

            if !noFit.isEmpty {
                out.append("\n## No-fit cases\n")
                out.append("| Case | Jev top pick | p | any-fits Noul | its own Noul |")
                out.append("|---|---|---|---|---|")
                for item in noFit {
                    guard let run = jev[item.id] else { continue }
                    out.append("| \(item.id) | \(run.keys.first.map { name($0, in: item) } ?? run.error ?? "–") | \(String(format: "%.2f", run.top)) | \(run.anyFits.map { String(format: "%.2f", $0) } ?? "–") | \(run.ranked.first?.fit.map { String(format: "%.2f", $0) } ?? "–") |")
                }
            }

            out.append("\n## Jev misses\n")
            out.append("| Case | Tags | Correct | Jev picked | p | Correct at rank |")
            out.append("|---|---|---|---|---|---|")
            for item in cases {
                guard let run = jev[item.id], run.keys.first != item.gold else { continue }
                let rank = run.keys.firstIndex(of: item.gold).map { String($0 + 1) } ?? "–"
                out.append("| \(item.id) | \(item.tags.joined(separator: ", ")) | \(name(item.gold, in: item)) | \(run.keys.first.map { name($0, in: item) } ?? run.error ?? "–") | \(String(format: "%.2f", run.top)) | \(rank) |")
            }
        }

        out.append("\n## Baseline misses\n")
        out.append("| Case | Tags | Correct | Baseline picked |")
        out.append("|---|---|---|---|")
        for item in cases {
            guard let run = baseline[item.id], run.keys.first != item.gold else { continue }
            out.append("| \(item.id) | \(item.tags.joined(separator: ", ")) | \(name(item.gold, in: item)) | \(run.keys.first.map { name($0, in: item) } ?? "–") |")
        }
        return out.joined(separator: "\n") + "\n"
    }

    func name(_ key: String, in item: ResolvedCase) -> String {
        item.candidates.first { $0.key == key }.map { "\($0.name) (\($0.kind.label))" } ?? key
    }
}
