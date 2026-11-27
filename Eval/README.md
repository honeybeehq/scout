# Target ranking eval

Measures how well a ranker picks the target a finished Scout recording should go to. It compares TypeSafe Jev with a recency and name/keyword heuristic. The ranking client lives in `Sources/ScoutRanking`. The app does not use it yet.

## Fixtures

- `Fixtures/targets.json` is a pool of 37 synthetic targets in the bridge's `listTargets` row shape: 12 Champions, 9 Projects and 16 sessions across three workspaces. Each row adds two proposed fields that the bridge does not send yet: `bio` (a Champion's or Project's one-line purpose; sessions fall back to `sessionTitle`) and `lastActiveAt`.
- `Fixtures/cases.json` holds 42 labelled cases. Each one has the feedback (transcript, page URL, page title, frontmost app), 6 to 15 candidates taken from the pool, minutes since each candidate was last active (3 days when not listed), and the correct target. Short aliases name the targets: `c:<champion id>`, `p:<project id>`, `s:<session title>`.
- Hard cases are tagged `similar-name` (Scout and Scout Site, Fjordbank Web and Fjordbank App, two Scout Projects), `recent-wrong` (the most recently active candidate is wrong), `no-name` (the feedback names no target), `named`, `context-mismatch` (it names a target other than the page it was recorded on), `decoy-word`, `large` (13 to 15 candidates) and `vague`.
- Labelling rule: a target the feedback names wins. Otherwise the Session or Project working on exactly that thing wins over the product's Champion, and the Champion wins over unrelated work.

## What Jev receives

One request per recording to `POST /v1/systemone`, with model `jev-1.14.0` pinned so thresholds stay valid. `state` holds the feedback (the first 500 characters of the transcript, the page title, the URL host only and the app name) and the targets (name, kind, bio, project, workspace and a recency bucket). It never sends ids, handles, full URLs, paths, screenshots or audio. The questions are one Choice over all candidates, one Noul per candidate and one any-fits Noul. Run `--sample-request FILE` to write the exact body for the first case.

## Run

```bash
swift build -c release --product scout-rank-eval
.build/release/scout-rank-eval --check
.build/release/scout-rank-eval
export TYPESAFE_API_KEY="$(hem get global/typesafe-api-key key)"
.build/release/scout-rank-eval --jev --repeat 3 --record /tmp/jev.json --report /tmp/jev.md
.build/release/scout-rank-eval --replay Eval/Results/jev-1.14.0.json
```

- `--check` validates the fixtures and the payload privacy rules, then runs the baseline.
- With no flags, the harness prints the baseline report.
- `--jev` calls TypeSafe sequentially and needs `TYPESAFE_API_KEY` in the environment. `--repeat N` runs N passes, which gives more latency samples and a stability measure. `TYPESAFE_ENDPOINT` overrides the URL for a local mock.
- `--replay` rebuilds the full report from a recorded run without a key.
- Accuracy uses the first pass. Latency uses every pass except one warm-up request.

The harness builds on macOS and on Linux with Swift 6.2 or later.
