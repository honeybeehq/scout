# Scout: roadmap

Each milestone ends with something the user can run and judge.

## M0: Foundation ✅

- Product, experience, design, architecture, integration and SDK protocol docs.
- `ScoutCore` domain model and `ScoutSegmenter` breakpoint engine, with the `scout-segment` replay CLI and fixture checks.
- Scout.app shell: menu bar item and panel, Carbon global shortcut, design system, app icon.
- Six-step onboarding: live permission states, the System Settings guide, relaunch-and-resume, on-device voice check, pointing practice, hive/Apiary detection, routing choice, open at login.
- hive socket client (`list`, `send`, `spawn`).

## M1: Scouting slice ✅

Talk in any app, get split tasks, send them to hive. Verified end to end with `--simulate-session` (a synthesized narration becomes the three intended tasks, with cut reasons).

- `Session`: clock, append-only `signals.jsonl`, segmenter bridge, snippet store.
- Voice stream: time-indexed `SpeechTranscriber` with word timings; the last words are flushed on stop. (`SpeechDetector` voice activity is still open; it would let the segmenter drop its 4 s silence grace.)
- Context stream: frontmost app, focused window title (AX), browser URL from the page's accessibility tree (`AXURL`, with Chromium and Electron trees switched on through `AXManualAccessibility`). An Automation fallback is still open.
- Hover focus: AX element under the pointer, with dwell detection.
- The pill and the snippet stack. Task markdown. Delivery through the router (hive `send`/`spawn`, clipboard fallback) with idempotency keys.
- Voice commands: "new task", "scratch that", "send it".

## M2: Clips ✅

Done: segmented recording, clip cutting (~30 ms while recording, ~5 ms after stop, no re-encode), visual-change signal, pin screenshots. Open: following the pointer to another display mid-session, password-manager exclusion.

- ScreenCaptureKit stream of the display under the pointer, following it across displays, into 2 s fMP4 segments.
- Clip cutting per snippet (segment concatenation plus passthrough trim).
- Visual-change signal from frame differences.
- Pin screenshots with the element outlined.
- Exclude Scout's own windows and password managers from capture.

## M3: Aim and pin (mostly done)

Done: `⌥` aim overlay, click-to-pin through a session event tap, accessibility element resolution with ancestry, SDK pin enrichment. Open:

- Region pins by dragging.
- iOS Simulator elements through the macOS accessibility bridge (verify and tune).

## M4: Web SDK and bridge v1 (in progress)

- Bridge server ✅ (loopback WebSocket, Origin checks, `bridge.json` token, session/aim/pin, hover dwell, runtime signals, project root from hello). First-contact approval UI is still open.
- `@scout/web`, `@scout/react`, `@scout/vite` ✅ (e2e 20/20, and verified live against Scout: an `⌥`-click pin arrives as `PayButton "Pay now" · PayButton.tsx:3:5`). Still to do: `@scout/svelte`, `@scout/vue`, `@scout/next`, `@scout/tanstack-start`.
- Error, console and network signals attached to snippets ✅.
- Project resolution: SDK hello → nectar → dev-server port → cwd → git root → pro index → user overrides.

## M5: Smarter splitting

- Sentence-embedding similarity (`NLEmbedding`) behind the segmenter's `SemanticSimilarity` protocol.
- On-device FoundationModels: snippet titles ✅ (used when Apple Intelligence is on), merge and split refinement within a short window after each close.
- Split corrections logged to `corrections.jsonl` and turned into fixtures. Weights tuned against them.

## M6: Native SDKs

- `ScoutKit` for SwiftUI and UIKit on iOS and macOS, simulator and device (Bonjour and TLS pairing).
- Android: emulator through `adb` and uiautomator first, then `scout-android` for Compose and Views.

## M7: Deep hive and Apiary integration

- `~/.hive/gateways/scout.json` MCP gateway: `scout_recent_snippets`, `scout_snippet`, `scout_request_feedback`.
- Apiary recording host for Scout (the record button in Apiary starts scouting and routes results to that pane).
- Session picker with live `watch` updates, and delivery status from hive back into the stack.

## M8: Release

- Developer ID signing, notarization and stapling (team `4QK8JBAU4V`), DMG, Sparkle updates.
- Privacy review: capture exclusions, redaction, retention.

## Linux

The Linux app comes after M4 and is also native. `ScoutCore` and `ScoutSegmenter` already build with plain Foundation. The Linux shell will need:

- **Capture:** PipeWire through the xdg-desktop-portal ScreenCast API.
- **Voice:** a local streaming model such as whisper.cpp or Moonshine, because `SpeechAnalyzer` is Apple-only. It goes behind the same utterance signal.
- **Context:** AT-SPI for accessibility, plus the compositor's foreign-toplevel protocol where available.
- **UI:** GTK 4 / libadwaita.

Language choice for the shell (Swift with GTK bindings, or Rust calling the Swift core over C ABI) is an open decision for that milestone.
