# Scout

Use your app, say what's wrong, point at it. Scout splits what you say into small tasks, attaches what you saw and pointed at, and sends them to coding agents in hive and Apiary.

Scout replaces Syn. It is a native macOS app first (Swift 6, SwiftUI, macOS 26); a native Linux app comes later.

## Status

**M0: Foundation.** Scout.app runs: menu bar item, global shortcut, and the full onboarding (permissions with live status and a System Settings guide, on-device voice check, pointing practice, hive/Apiary detection). The breakpoint engine runs on recorded signal logs. The live scouting session (M1) is next. See the [roadmap](docs/roadmap.md).

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
