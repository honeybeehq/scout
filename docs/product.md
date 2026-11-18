# Scout: product

## One line

Use your app, say what's wrong, point at it. Scout turns that into small, precise tasks and hands them to coding agents that fix them.

## Who it is for

- **Developers** who iterate on web, native, and mobile apps together with coding agents (hive, Apiary, Claude, Codex).
- **Designers** who review builds and want to leave precise feedback without writing tickets.

Both want the same thing: stay inside the app they are judging, and have the fixes happen somewhere else.

## The core loop

1. **Scout.** Press the shortcut (`⌃⌥S` by default) in any app. Scout starts listening, watching the screen, and tracking what the pointer is on.
2. **Talk and point.** Say what is off. Hover over the thing, or hold `⌥` and click to pin it. Keep going: one session can hold many pieces of feedback.
3. **Scout splits.** As you talk, Scout cuts the stream into **snippets**, one per task. It cuts on pauses, cue phrases ("next", "also"), app, window, and route changes, a change of target, and a shift in topic. Each snippet carries its clip, transcript, pinned elements, and app context.
4. **Send.** Each snippet goes to the right agent session. By default that is the session already working in the app's repo; if there is none, Scout starts one. Sending can happen while you are still talking.
5. **Fix.** The agent gets a task that says what you said, shows what you saw, and names the element and source file you pointed at.

Apple transcription supplies live words. After you stop, Scout transcribes the recording again with Apple or, when selected and installed, Whisper large-v3-turbo through WhisperKit. Both engines run on your Mac. Whisper needs a one-time model download; Apple remains the fallback until it is installed.

The target is under 10 seconds from finishing a sentence to the task arriving in an agent session, and ideally 2–3 seconds.

## Principles

1. **Voice is the task.** What the user says is the primary signal. Video and screenshots support it.
2. **Stream, don't batch.** Transcription, splitting, clip cutting, and context capture all run while the user talks. Keep the final transcription pass after stopping as short as possible.
3. **Know the app.** Scout resolves what is on screen to a real element (accessibility tree, SDK, DOM, component) and, when possible, to a source file and repo. "This button" should arrive as `Button "Pay now" · Checkout.tsx:88`.
4. **Zero-ceremony capture.** No capture-mode picker. No region selection before recording. One shortcut, then talk.
5. **Local first.** Transcription and splitting run on the Mac. Nothing leaves it until a task is sent, and the user can see exactly what is sent.
6. **Agents are the destination.** hive and Apiary are first-class. The clipboard and a folder are fallbacks, not the main path.
7. **Setup must be effortless.** Permissions are the biggest source of friction on macOS. Scout's onboarding checks each one live, guides the user in System Settings, and brings them back automatically.

## What Scout is not

- Not a general screen recorder or a Loom replacement. Clips exist to give agents context.
- Not a bug tracker. Tasks go to agents, not into a backlog. Other integrations can come later.
- Not a design tool. Annotations are for pointing, not for making mockups.

## Platforms

- **macOS first**, native: Swift 6, SwiftUI with AppKit where needed, macOS 26 or later.
- **Linux later**, native. The core model and the breakpoint engine (`ScoutCore`, `ScoutSegmenter`) are pure Swift and build on Linux.
- **SDKs** give Scout deeper app awareness: web (React, Svelte, Vue, Next, Vite), iOS (SwiftUI/UIKit, simulator and device), Android, and desktop frameworks. See [sdk-protocol.md](sdk-protocol.md).

## Measures of success

- Time from end of a spoken sentence to a task in an agent session: p50 under 3 s, p95 under 10 s.
- Split accuracy: at least 85% of automatic cuts accepted without a merge or split by the user.
- Target resolution: at least 90% of pins resolve to a named element; at least 60% resolve to a source file when an SDK is present.
- Onboarding: at least 90% of new users finish all permissions in under two minutes without reading documentation.

## Relationship to Syn

Syn is Scout's predecessor, a narrated screen-capture tool for agent feedback. Scout replaces it. It keeps what worked: narrated screen capture, element flagging, the web element SDK idea, agent handoff. It changes the rest:

| Syn | Scout |
|---|---|
| Record, then process a packet | Stream and split live into snippets |
| One packet per recording | One task per snippet, many per session |
| Seven capture modes and a picker | One shortcut; Scout follows what you look at |
| Bundled whisper.cpp, offline passes | Apple live transcription; optional WhisperKit large-v3-turbo second pass, on device after a model download |
| Double-Shift chord, needs an event tap | Carbon hotkey, needs no permission |
| Unauthenticated WebSocket on :47845 | Authenticated local bridge with app identity |
| Clipboard and folder handoff | Direct delivery to hive sessions and Apiary panes |
