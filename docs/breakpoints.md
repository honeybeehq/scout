# Breakpoints: splitting a session into snippets

Scout records one continuous session: speech, pointer, pins, app context and
screen changes. The segmenter (`Sources/ScoutSegmenter`) cuts that stream into
**snippets**, one piece of feedback each, so every snippet can become one agent
task. It runs online and incrementally, gives the same output for the same
input, and uses only Swift and Foundation, so it also builds on Linux.

```swift
var segmenter = Segmenter(configuration: .default, similarity: LexicalSimilarity(), recordsEvaluations: true)
for signal in stream { handle(segmenter.ingest(signal)) }   // [SegmenterEvent]
handle(segmenter.finish(at: sessionEnd))
let why = segmenter.takeEvaluations()                         // [BoundaryEvaluation]
```

`Segmenter` is a `Sendable` value type; keep it as a `var` inside an actor.
Events follow a fixed lifecycle per snippet: `.opened`, zero or more
`.updated` (at most one per `ingest`), then `.closed` or `.discarded(id:)`.

## Signals and how they are used

| Signal | Used for | Attribution time |
|---|---|---|
| `utterance` | Candidate boundaries, transcript, cues, similarity | its range (word timings when present) |
| filler utterance (`Um.`, `Uh, wait.`, `Okay, so.`) or a lone closing remark (`That's it.`, `Okay, that's all.`) | Lead text for the next utterance only; never opens or splits | start |
| `context` | App, location and window changes; `openingContext` | `at` |
| `focus` | Target dwell (who the user is pointing at) | midpoint of its range |
| `mark` | Pinned target (counts as 3 s of dwell); can open a snippet on its own | `at` |
| `visualChange` | Screen change inside a gap | `at` |
| `command` | `.split` closes now, `.discardCurrent` drops the snippet | `at` |
| `clock` | Advances time so silence timeouts and commands fire | `at` |

A filler utterance consists only of filler words (see
`SegmenterConfiguration.fillerWords`), or of one closing phrase with at most
filler words around it, so "That's it." after a pause never becomes a task of
its own.

## Candidate boundaries

A cut only happens **between utterances**, never inside one. When utterance B
arrives (it arrives when finalized, at `B.end`), the segmenter scores the gap
between the open snippet's last utterance A (ends at `a`) and B (starts at
`b`). The gap is `g = b − a`, using word timings when available.

## Evidence (defaults in `SegmenterConfiguration`)

| Evidence | Weight | Notes |
|---|---|---|
| Pause | 0 → 0.8 | Piecewise linear through (0 s, 0), (0.4, 0.05), (1.2, 0.30), (2.5, 0.55), (≥5, 0.80) |
| Task phrase at B's start | **hard** | "new task", "next issue", "next thing", "new note", … |
| Cue phrase at B's start | +0.35 | "next", "also", "another thing", "okay so", "moving on", "one more", "on this page", "over here", "back to", … |
| Weak cue at B's start | +0.20 | "then", "now", "oh and" |
| Continuation at B's start | −0.30 | "it", "it also", "and the same", "same for", "which", "especially", "this one also", and self-corrections: "wait", "sorry", "I mean" |
| Closing phrase in A's last 6 tokens | +0.25 | "that's it", "that's all", "fix that", "done with that", … |
| App change | +0.45 | Compares the context at `a` with the context at `min(b + 1.5 s, B.end)`. Only the strongest context change counts. |
| Location (URL/route) change | +0.35 | |
| Window title change | +0.25 | |
| Pinned target change | +0.35 | B's dominant target is a fresh mark on a different element |
| Dwell target change | +0.25 | Dominant dwell target differs |
| Same target | −0.30 | Same id, or one is an ancestor of the other |
| Topic shift / continuity | +0.20 … −0.20 | Similarity of B to the snippet's last 4 utterances; ≤ 0.05 → +0.20, ≥ 0.25 → −0.20, linear in between |
| Visual change in the gap | +0.20 × magnitude | Largest change in `(a, b]` |
| Short snippet | −0.35 × (1 − speech / 4 s) | Fades out as the snippet's speech approaches 4 s |
| Long snippet | +0.20 | Snippet already longer than 90 s |

**Lead phrases.** A phrase counts as "at B's start" if at most 4 opener words
come before it ("um", "and", "so", "okay", "actually", …). Filler utterances in the gap are put in front of B's text, so
"Okay, so." followed by "the pricing table…" still reads as the cue "okay so".
When a cue and a continuation overlap, the longer phrase wins: "and then it"
counts as a continuation, not the weak cue "then". A task phrase suppresses any
cue it overlaps.

**Targets.** A's dominant target comes from the open snippet's focus dwell and
marks, with a 20 s half-life, so recent pointing counts more. B's dominant
target comes from dwell and marks in `[max(a, b − 1.5 s), B.end]`. A target
needs at least 0.5 s of weight to count. A mark is an explicit gesture, which
is why a new pin outweighs pointer drift.

**Similarity.** `SemanticSimilarity` is a protocol:
`similarity(of: candidate, to: context) -> Double?`. The default,
`LexicalSimilarity`, computes a term-frequency cosine over content words:
stopwords are removed, camelCase identifiers are split, and a light suffix
stemmer is applied. It returns `nil` (no evidence) when B has fewer than 2
content terms or the context has fewer than 3.

## Decision rule

```
split  ⇔  hard  ∨  Σ weights ≥ threshold (0.6)
```

Breaks that don't need scoring:

- **Silence timeout.** No speech for ≥ 8 s closes the open snippet with reason
  `silenceTimeout`.
- **`.command(.split)`** always closes the open snippet. A split with nothing
  open does nothing.
- **`.command(.discardCurrent)`** drops the open snippet and emits
  `.discarded`. If nothing is open, it drops the most recently closed snippet,
  as long as that snippet closed within the last 10 s. So a consumer can
  receive `.discarded` for a snippet it already saw as `.closed`.
- **`finish(at:)`** closes whatever is open with reason `sessionEnd`.

## Cut time and attribution

- **Speech cuts.** `Breakpoint.at` is the midpoint of the gap. Signals with
  attribution time ≥ `min(at, b − 1.5 s)` go to the new snippet; earlier ones
  stay with the old one. So a route change or pin shortly before B speaks
  belongs to B.
- **Silence cuts.** The cut is at `a + timeout/2`, which is where a speech cut
  would land if B had started exactly at the timeout. Signals after the cut wait
  for whatever comes next.
- **Command cuts.** The cut is at the command's `at`.
- **When no snippet is open,** a new snippet claims signals from
  `B.start − 1.5 s` onward. Older ones are dropped; their context changes stay
  in the context timeline.
- **`openingContext`** is the context active at the snippet's range start.
  `primaryContext` is the last context change in the snippet.
- **`Snippet.range`** spans its utterances, marks and context changes. Focus
  dwell does not extend it.
- **Marks-only snippets.** A mark with no open snippet opens a snippet. Speech
  within 8 s joins it (pin, then talk). If 8 s pass with no speech or new
  marks, the snippet closes as a pins-only snippet. A snippet never exists
  without at least one utterance or mark. Filler-only speech never creates one.
- **Late signals** are ones older than the open snippet's start. Pins are kept
  and folded into the open snippet. Focus is kept if it overlaps the open
  snippet. Everything else only updates the context timeline.

## Streaming and latency: when is a snippet closed?

| Trigger | `.closed` is emitted | Latency after the cut |
|---|---|---|
| Speech boundary | When B is finalized | B's duration plus recognizer lag |
| Silence | When time reaches `a + 8 s + 4 s grace`, or when the next utterance arrives showing the gap was ≥ 8 s | 8–12 s |
| Split / discard | When time reaches `at + 1.5 s`, or when an utterance whose midpoint is after the command arrives | ≤ 1.5 s with a 1 s clock |
| Session end | On `finish(at:)` | immediate |

The grace and tolerance windows exist because an utterance only arrives once
it is finalized. Without them, a focus signal or clock tick could close a
snippet while the user is still mid-sentence. An utterance whose midpoint
falls before a split command lands before the cut. Time moves forward with
the latest timestamp seen on any signal, so the app should send `.clock`
heartbeats (≈1 s) during silence.

Per-signal cost doesn't grow with session length. The buffers only hold the
current gap, and the context timeline keeps 2 minutes of history. Each
`.updated` copies the open snippet. A synthetic 4-hour session (20k signals)
runs in about 0.3 s.

## Explainability

Every scored gap produces a `BoundaryEvaluation` with `at`, `score`,
`threshold`, `isHard`, `decision` (`split` or `keep`), the two utterance ids,
and `reasons: [BreakpointReason]`. Each reason has a kind, a signed weight and
a human-readable detail. Silence, command and session-end closes are recorded
too. Every closed snippet also carries `closedBy: Breakpoint` with the same
reasons. Evaluations are only kept when `recordsEvaluations` is true; collect
them with `takeEvaluations()`.

```
  @ 0:42.0  SPLIT  score +1.55 ≥ 0.60  [u8 → u9]
      +0.65  pause             3.5 s pause
      +0.35  cuePhrase         cue “also”
      +0.35  targetChange      BillingForm “Save” → pinned InvoiceTable “Invoices”
      +0.14  topicShift        similarity 0.08 to recent speech
      +0.06  visualChange      screen changed 30%
```

ScoutCore has no dedicated reason kinds for task phrases or continuations.
They appear as `cuePhrase` and `topicContinuity`, told apart by their detail
text.

## Tuning with fixtures

Fixtures live in `Fixtures/sessions/*.jsonl`: one `Signal` per line, in
arrival order. `#` lines are comments; blank lines are ignored. Headers:

```
# expect: 5                          number of closed, non-discarded snippets
# expect-breaks: 15.3, 25.4, 42.0    cut times between snippets, ±1.5 s
# expect-discarded: 1
```

```
swift run scout-segment Fixtures/sessions/a-web-app-routes.jsonl --explain
swift run scout-segment <fixture> --json | --events
swift run scout-segment --check Fixtures/sessions      # exits non-zero on any FAIL
```

Workflow:

1. Record or write a session.
2. Set the headers to what a thoughtful human would want.
3. Run `--explain` and look at scores near the 0.6 threshold.
4. Change one weight at a time and re-run `--check`.

Prefer changing evidence over special cases. A fixture that only passes with a
new phrase or rule usually means a signal is missing.

Current fixtures: (a) route changes and cues in one web app; (b) browser →
Simulator → Figma with continuous talk; (c) a 108 s single-topic ramble with
4 s pauses that must stay whole; (d) rapid-fire pins; (e) "New task.", split,
and discard; (f) a 20 s silence plus filler false starts. The closest calls
today are the keep of "Oh, and the same … on the expiry field" in (c) at 0.55
(a sibling field) and the rapid-fire splits in (d) at 0.74–0.83. The short-snippet
prior pulls those down.

## Known limits

- Focus is delivered when a dwell ends. Pointing that continues past the end
  of B is not visible when B is scored. The capture layer should flush
  in-progress dwells when an utterance finalizes.
- Sibling elements (two fields in one form) count as different targets. Text
  and continuation cues have to hold them together.
- Lexical similarity is weak on 1–2 sentence utterances, which is why its
  weight is small.
- The segmenter can't merge back across a cut that has already been emitted.

## Next steps

1. **Sentence embeddings.** On macOS, add a `NaturalLanguage`
   `NLContextualEmbedding` (or `NLEmbedding.sentenceEmbedding`)
   implementation of `SemanticSimilarity`. Cache the context vector per
   snippet and re-fit the low/high bands against the fixtures.
2. **LLM refinement pass.** After a snippet closes (or a few of them), run a
   `FoundationModels` pass on-device. It would propose merges of adjacent
   snippets or splits at utterance boundaries, and write a title and a
   one-line task. It would emit `.discarded` + `.closed` pairs, so the online
   segmenter stays fast and the app stays responsive.
3. **Learn weights from corrections.** Log each evaluation with the user's
   later merge/split/discard as a label, then fit the weights (logistic
   regression on the reason vector) per user or team. `SegmenterConfiguration`
   is `Codable`, so tuned weights can ship as JSON.
4. **Speech-activity signal.** A voice-activity start/stop signal from the
   recognizer would replace the 4 s silence grace and cut latency.
