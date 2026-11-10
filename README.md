# Scout

Use your app, say what's wrong, point at it. Scout splits what you say into small tasks, attaches what you saw and pointed at, and sends them to coding agents in hive and Apiary.

Scout replaces Syn. It is a native macOS app first (Swift 6, SwiftUI, macOS 26); a native Linux app comes later.

## Status

What works today:

- **Onboarding.** Live permission checks for Screen Recording, Microphone and Accessibility, a guide card that follows System Settings, relaunch-and-resume, an on-device voice check, pointing practice, and hive/Apiary detection.
- **Scouting.** Press `⌃⌥S` and talk. Recording starts at once with no picker; capture follows the pane or window under the pointer across displays, E widens it (both recent areas, window, screen) and ⇧E follows again. Discard in the recording bar, or `⌃⌥X` twice, throws the recording away without sending anything. `⌥`-drag draws. On-device transcription with word timings, app/window/URL context, pointer dwell targets, and `⌥`-click pins feed the breakpoint engine, which cuts the stream into tasks while you talk.
- **Walkthroughs.** A hotkey recording ends as one walkthrough.v1 bundle (transcript with word timings, key frames, pointed-at elements, drawings, how the captured area changed, a short list of asks and the clip) under `~/Library/Application Support/Scout/walkthroughs`, with its path on the clipboard for ⌘V into Apiary. Press `⌃⌥B` (Caps+B) to start a new ask: what you say next begins it, the bundle records a `break` event, and the bar shows "New ask"; elsewhere Scout splits asks on its own. "Split into tasks" in the menu bar keeps the task flow below.
- **Tasks.** Each task gets a title, transcript, the elements you pointed at, runtime errors from the page, a video clip (cut in about 30 ms, no re-encode) and pin screenshots.
- **Review.** After a session, a review window shows the whole recording on a filmstrip timeline. Trim, split, join or delete tasks, pick up speech that isn't in a task, edit titles and transcripts, and send tasks one by one or all at once. Earlier sessions reopen from the menu bar.
- **Manual tasks.** Switch "New task on" to ⌃⌥B in the menu bar, and only ⌃⌥B (or saying "new task") starts the next task. In automatic mode ⌃⌥B forces a cut. Either way the bar shows "New task".
- **Delivery.** Tasks go to the hive session already working in the app's repo (or a new one), with idempotent sends; the clipboard is the fallback.
- **Web SDK.** `@scout/vite` + `@scout/react` add component names and `file:line` source locations for pins, plus errors and failed requests.

Next up: first-contact approval for SDK clients, Next/Svelte adapters, and native iOS/Android SDKs. See the [roadmap](docs/roadmap.md).

## Run

Requirements: macOS 26, Xcode 26, XcodeGen (`brew install xcodegen`).

```bash
./script/build_and_run.sh                       # build, sign, stage at ~/Applications/Scout.app, launch
./script/build_and_run.sh --reset-onboarding    # start onboarding from the first step
./script/build_and_run.sh --onboarding-step=voice
./script/build_and_run.sh --build-only
```

Scout is staged at a fixed path and signed with the team's Apple Development identity, so macOS permission grants survive rebuilds.

Snapshots of every onboarding step (for visual checks, no screen-recording permission needed):

```bash
open -n ~/Applications/Scout.app --args --reset-onboarding --snapshot-dir=/tmp/scout-shots
```

End-to-end checks without a human at the machine:

```bash
say -o /tmp/narration.aiff "The pay button is too small. [[slnc 2500]] Next thing, the footer overlaps."
open -n ~/Applications/Scout.app --args --simulate-session=/tmp/narration.aiff --dry-run-delivery --simulate-pin --simulate-output=/tmp/scout-simulation
cat /tmp/scout-simulation/report.json

# manual mode with a ⌃⌥B at 11 s, plus scripted review edits and review screenshots (each ⌃⌥B adds a pill-break-<s>.png and an entry under "breaks" in report.json; with --simulate-result=walkthrough it records a break in the walkthrough)
open -g -n ~/Applications/Scout.app --args --simulate-session=/tmp/narration.aiff --dry-run-delivery --segmentation=manual --simulate-break=11 --simulate-review --simulate-output=/tmp/scout-manual

# any run above at another interface size, without saving it; --simulate-ui-size=<size>@<seconds> switches size mid-session as the Settings picker does (and saves it), and records pill and stack frames in report.json
open -g -n ~/Applications/Scout.app --args --ui-size=extraLarge --simulate-session=/tmp/narration.aiff --dry-run-delivery --simulate-ui-size=small@6 --simulate-output=/tmp/scout-size

# press Discard and confirm it at 6 s, then write discard.json: files left, deliveries, clipboard (--simulate-result=walkthrough records a walkthrough, as ⌃⌥S does)
# --simulate-discard-hotkey presses ⌃⌥X, Esc, then ⌃⌥X twice through the registered hotkeys; --simulate-discard-after-send sends the first task before pressing, which must refuse the discard
open -g -n ~/Applications/Scout.app --args --simulate-session=/tmp/narration.aiff --dry-run-delivery --simulate-result=walkthrough --simulate-discard=6 --simulate-discard-hotkey --simulate-output=/tmp/scout-discard

# design review without a screen: renders every surface in light and dark at all four sizes, plus a recording-bar frame sequence and bar-frames.json (add --appearance=light|dark to force one appearance for the app itself)
open -g -n ~/Applications/Scout.app --args --simulate-session=/tmp/narration.aiff --dry-run-delivery --simulate-review --simulate-output=/tmp/scout-gallery-sim --design-gallery=/tmp/scout-gallery

# capture UX: hotkey, follow, keep-both, ⌃⌥E/⌃⌥⇧E, pin, draw, finish, with timings (add --capture-ux-video for flow.mp4)
~/Applications/Scout.app/Contents/MacOS/Scout --capture-ux-demo=$HOME/.cache/scout-capture-ux --capture-ux-audio=/tmp/narration.aiff --dry-run-delivery
```

A walkthrough from a fixture (audio, a test recording and timed pins, dwells and strokes, as JSON), through the same recorder and writer. `Fixtures/walkthrough/make_fixture.py <dir>` builds one with `say`, headless Chrome and ffmpeg:

```bash
open -g -n ~/Applications/Scout.app --args --simulate-walkthrough=<dir>/session.json --simulate-output=/tmp/scout-walkthrough
cat /tmp/scout-walkthrough/walkthrough-report.json
```

Web SDK:

```bash
cd sdk/web && pnpm install && pnpm e2e
```

Breakpoint engine:

```bash
swift build
swift run scout-segment Fixtures/sessions/<fixture>.jsonl --explain
swift run scout-segment --check Fixtures/sessions
```

## Layout

| Path | What |
|---|---|
| `Sources/ScoutCore` | Domain model (Foundation only, Linux-ready) |
| `Sources/ScoutSegmenter` | Online breakpoint engine |
| `Sources/scout-segment` | Replay, explain and check CLI |
| `Fixtures/sessions` | Signal logs with expected cuts |
| `mac/` | Scout.app (`project.yml` → XcodeGen) |
| `sdk/web` | `@scout/web`, `@scout/react`, `@scout/vite`, fixture app and e2e check |
| `script/` | Build, run, icon rendering |
| `docs/` | Product and engineering docs |

## Docs

- [Product](docs/product.md): what Scout is, principles, what changes from Syn
- [Experience](docs/experience.md): onboarding, scouting, pointing, the snippet stack
- [Design language](docs/design-language.md): mark, color, type, motion
- [Architecture](docs/architecture.md): pipeline, modules, storage, permissions
- [Breakpoints](docs/breakpoints.md): how Scout splits a session into tasks
- [Integrations](docs/integrations.md): hive socket, routing, project resolution, Apiary
- [SDK protocol](docs/sdk-protocol.md): the bridge SDKs talk to (draft)
- [Roadmap](docs/roadmap.md)
- [Glossary](CONTEXT.md)
