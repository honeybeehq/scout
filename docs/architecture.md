# Scout: architecture

## Layout

```
Package.swift            ScoutKit: platform-independent core (builds on macOS and Linux)
Sources/ScoutCore        Domain model: signals, targets, contexts, snippets, breakpoints
Sources/ScoutSegmenter   Online breakpoint engine (see breakpoints.md)
Sources/scout-segment    CLI: replay a signal log, explain every cut, check fixtures
Fixtures/sessions        Recorded or hand-written signal logs with expected cuts
mac/project.yml          XcodeGen spec for Scout.app (macOS 26, Swift 6, MainActor by default)
mac/Scout/               The macOS app
script/                  Build, run, icon rendering, verification helpers
docs/                    Product, experience, design, architecture, protocols
```

`ScoutCore` and `ScoutSegmenter` use only Foundation. The Linux app will reuse them unchanged. The macOS app adds capture, context, UI and delivery around them.

## The pipeline

```
 ┌──────────── capture (realtime, off the main actor) ──────────────┐
 │ VoiceStream    AVAudioEngine → SpeechAnalyzer                    │──┐
 │                (SpeechTranscriber + SpeechDetector)               │  │
 │ ScreenStream   SCStream → segmented fMP4 writer + frame taps      │──┤  Signals
 │ PointerStream  pointer @ 10 Hz, AX / SDK hit-test @ 4 Hz → Focus  │──┤  (ScoutCore.Signal)
 │ ContextStream  frontmost app, focused window, URL / route         │──┤
 │ Bridge         SDK connections: elements, routes, source locations│──┘
 └───────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
 Session (MainActor)       SessionClock → SessionTime (seconds since start)
                           signals.jsonl  ← every signal, append-only
                           Segmenter      → opened / updated / closed / discarded
                                   │ closed(snippet)
                                   ▼
 Assembler                 clip = media segments overlapping the range, trimmed
                           pin screenshots, project resolution, task markdown
                                   │
                                   ▼
 Delivery                  Router → HiveClient.send / spawn, or clipboard + folder
```

Rules:

1. **Everything is a signal on one clock.** Capture sources don't talk to each other. Each one turns its input into `Signal`s timestamped in `SessionTime`. The segmenter, the assembler and the UI read only signals. So a session can be replayed exactly (`scout-segment signals.jsonl --explain`), and every real session can become a fixture.
2. **High-frequency data stays in capture.** Audio buffers and video frames never reach the main actor. Capture classes are `nonisolated` and own their queues. Only low-rate results (utterances, focuses, context changes, about 1–10 per second) cross into the session.
3. **Tasks are ranges over one ledger.** `SessionLedger` (ScoutCore) keeps every utterance, focus, pin and context change of a session. A task is just a time range; `ledger.snippet(id:range:)` rebuilds its transcript, targets and context from the ledger (utterances and focuses by midpoint, pins by time, context at the time of speech). That is what lets the review split, join, trim and re-attach speech without losing anything, and it is how old sessions are reopened from `signals.jsonl` + `review.json`.
4. **Snippets close while the user is still talking.** The segmenter emits `closed` as soon as the next utterance arrives, a hard cue is heard, or the silence timeout passes. The assembler and delivery start right away.
5. **Media is segmented on disk from the start.** The screen writer produces 2-second fragmented-MP4 segments (`AVAssetWriter` with `.mpeg4AppleHLS` output). A clip is the init segment plus the media segments overlapping the snippet's range (with 1 s of padding), then trimmed with a passthrough export. Nothing is ever re-encoded, and cutting a clip takes tens of milliseconds, not a full render.

## macOS app modules (`mac/Scout`)

| Folder | Responsibility | Status |
|---|---|---|
| `App/` | `ScoutApp` scenes, `AppModel` root state, preferences, settings, snapshot and simulation modes | M0–M1 |
| `Design/` | Palette, type, motion, mark, aurora backdrop, shared components | M0 |
| `Onboarding/` | Six-step onboarding and its persisted progress | M0 |
| `Permissions/` | Live permission states, requests, the System Settings guide, relaunch | M0 |
| `Voice/` | Microphone (or audio file) capture and live on-device transcription with word timings | M1 |
| `Integrations/` | hive socket client, Apiary detection and bridge client (`ApiaryBridge`), routing preference | M1, M7 |
| `Shortcuts/` | Carbon global hotkeys (need no permission) | M0 |
| `MenuBar/` | Menu bar icon and panel | M0 |
| `Session/` | Scouting session: clock, signal log, segmenter, voice commands, capture timeline, interaction timings | M1 |
| `Context/` | Frontmost app, window title, browser URL (AX `AXWebArea`/`AXURL`), pointer dwell, `TargetResolver` | M1 |
| `Delivery/` | Project resolution, task composition, titles, routing and sending (`Dispatcher`); the walkthrough target picker and delivery (`TargetPicker`, `WalkthroughDelivery`) | M1, M7 |
| `HUD/` | Scouting pill, capture frame and ink overlay, snippet stack, aim overlay and pin event tap (pins, strokes, E/⇧E) | M1–M3 |
| `Review/` | Session review: `SessionReview` (re-cutting, undo, persistence), player, timeline, task list and detail | M1.5 |
| `Capture/` | ScreenCaptureKit segmented recorder (moves to the display under the captured area), region follower, clip cutting, visual change, frame snapshots | M2 |
| `Bridge/` | SDK bridge server (see sdk-protocol.md) | M4 |

Concurrency: the app target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and strict concurrency. UI and coordination code is on the main actor by default. Realtime code opts out explicitly with `nonisolated` types (`MicrophoneCapture`, `HiveClient`, the future capture writers).

## Storage

```
~/Library/Application Support/Scout/
  Sessions/<yyyy-mm-dd>/<session-id>/
    session.json               start time, displays, app version, settings snapshot
    signals.jsonl              every Signal, append-only; replayable with scout-segment
    capture.jsonl              scope changes and strokes (CaptureTimeline), append-only
    timings.jsonl              interaction timings: input → handled, committed, on screen
    session.mp4                the whole recording, joined from the segments on stop (passthrough)
    review.json                task ranges, titles, edits and delivery state; reopens the session later
    media/init.mp4             fMP4 init segment (while recording)
    media/seg-00001.m4s …      2 s media segments (deleted once session.mp4 exists)
    snippets/<snippet-id>/
      snippet.json             Snippet (ScoutCore) + delivery state
      task.md                  the text sent to the agent
      clip.mp4                 trimmed clip
      pin-<n>.png              screenshot at each pin, element outlined
  corrections.jsonl            user merges and splits, for tuning the segmenter
  walkthroughs/<wt_ULID>/      one walkthrough.v1 bundle per hotkey recording (written as <id>.partial/, renamed when complete)
    walkthrough.json           transcript with word timings, frames, pointers, drawings, asks, clip
    walkthrough.md             the text an agent receives
    frames/<ms>.png            key frames at start, pins, dwells, strokes, scope and scene changes, end (≤ 1600 px)
    frames/thumbs/<ms>.jpg     ≤ 320 px previews
    clip.mp4                   the session's segments joined without re-encoding
```

A recording started with the hotkey or Start scouting ends as a walkthrough. `WalkthroughRecorder` (Session/) feeds every signal to `WalkthroughBuilder` (ScoutCore) while the session runs and writes key frames into the `.partial` folder as they happen, so finishing only adds the end frame, the clip, the JSON and the text. Strokes and scope changes enter through `WalkthroughRecorder.add(_:)`; until the capture overlay calls it, a bundle has one `screen` scope and no drawings. Leftover `.partial` folders older than a day are removed at launch. The bundle path goes on the clipboard as `com.trmd.scout.walkthrough`, a file URL to `walkthrough.json` and plain text. "Split into tasks" in the menu bar starts a session that ends in tasks and review, as before.

Retention: when a session ends, its segments are joined into `session.mp4` (passthrough) and `media/` is deleted two minutes later, so a session keeps one copy of its video. `session.mp4` is pruned after 7 days and whole sessions after 14; `review.json` and the snippet folders of sent tasks go with the session.

## Permissions model

| Permission | Why | Check | Request |
|---|---|---|---|
| Screen Recording | Clips, pin screenshots, window titles | `CGPreflightScreenCaptureAccess` | `CGRequestScreenCaptureAccess` once, then the Settings pane. Needs a relaunch |
| Microphone | Voice | `AVCaptureDevice.authorizationStatus(.audio)` | `AVCaptureDevice.requestAccess` (not `AVAudioApplication`, which never returns in menu bar apps) |
| Accessibility | Element under the pointer, focused window, `⌥`-aim key filtering | `AXIsProcessTrusted` | `AXIsProcessTrustedWithOptions(prompt)` once, then the Settings pane |
| Automation (optional, per browser) | Read the active tab URL when no SDK is present | `AEDeterminePermissionToAutomateTarget` | Same call with `askUserIfNeeded` |

Speech recognition permission is not needed: `SpeechAnalyzer` runs on the device without it (verified on macOS 26.6). Global shortcuts use Carbon `RegisterEventHotKey` and need no permission. Input Monitoring is never requested.

Signing matters for TCC. Development builds are signed with the Apple Development identity of team `4QK8JBAU4V` and staged at `~/Applications/Scout.app` (`script/build_and_run.sh`), so grants survive rebuilds. `ENABLE_DEBUG_DYLIB=NO` avoids hardened-runtime library validation failures.

## Verification

- `swift build && swift run scout-segment --check Fixtures/sessions` checks the breakpoint engine against its fixtures.
- `script/build_and_run.sh` builds, signs, stages and launches the app. Flags: `--build-only`, and app arguments such as `--reset-onboarding` and `--onboarding-step=<name>`.
- `open -n ~/Applications/Scout.app --args --reset-onboarding --snapshot-dir=<dir>` walks every onboarding step and writes a PNG of each, then quits. Add `--settings-pane=general|agents|sdks` to capture a Settings pane instead. Pass values with `=`: a separate path argument is treated as a document to open, and SwiftUI then skips the default window.
- `open -n ~/Applications/Scout.app --args --simulate-session=<audio file> --dry-run-delivery --simulate-output=<dir>` runs a real scouting session with the audio file in place of the microphone (context, pointer and aim still run live), snapshots the pill and stack, and writes `report.json` with every task, its cut reasons and its destination. `--dry-run-delivery` writes `message.txt` into each snippet folder instead of sending. Make narration with pauses using `say -o narration.aiff "First note. [[slnc 2500]] Next thing, …"`.
- `Scout.app/Contents/MacOS/Scout --capture-ux-demo=<dir> --capture-ux-audio=<audio file> --dry-run-delivery` opens two throwaway test windows and drives the capture flow through the same handlers the hotkey and event tap use: start, follow between panes and windows, the keep-both suggestion, E three times, ⇧E, a pin, a stroke, a second pin and finish. It writes `report.json` with every interaction timing, the capture timeline and the pins, then quits. Add `--capture-ux-video` to also write `flow.mp4`, composed from Scout's own windows (no Screen Recording needed). Timings from a video run are slower, because frames are captured while it runs.
