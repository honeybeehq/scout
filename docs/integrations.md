# Scout: integrations

Scout delivers recordings and tasks to coding agents. You can use the clipboard with any agent or chat; no other app is required.

## Clipboard

Without hive, Scout copies `task.md` to the clipboard as text, adds the snippet folder as a file URL, and keeps the folder on disk. Sending several tasks at once (*Copy all* in the review) puts them on the pasteboard together, separated by `---`, with one folder URL per task.

A walkthrough recording leaves its bundle path on the clipboard so you can paste it into a compatible app. The recording stays on disk.

## Linear

Linear is a destination like a hive session. The personal API key lives only in the Keychain (see experience.md, Settings → Linear). Filing happens only from the review window.

- **Issue content.** `IssueComposer` turns a task into a title and markdown: the summary (when there is one), the verbatim transcript (capped at 6,000 characters), pin images, and context (app and window, URL without its query string, repo name and branch, targets with repo-relative `file:line`, runtime errors). The home folder never leaves the Mac as a path; it is written as `~`. The footer carries the task's key, `scout:<session>:<task>`.
- **Summary.** `TaskSummariser` runs on this Mac only (`OnDeviceSummariser`, FoundationModels guided generation). Without Apple Intelligence `TemplateSummariser` returns no summary fields and the issue leads with the transcript. The result is a `TaskBrief` (ScoutCore) stored in `review.json`, so it is generated once and shared with any other consumer.
- **Labels and priority.** The brief's kind maps to an existing team label by name (Bug; Improvement or Polish; Feature; Question); urgency maps to Linear's priority. Both are editable, and Scout never creates labels.
- **Images.** Pin images are stored through `StorageProvider`; `LinearStorage` asks `fileUpload` for a signed URL, PUTs the bytes without the Linear key, and uses the returned `uploads.linear.app` asset URL. Uploads already done for a task are skipped by content hash on retry.
- **Video.** The clip uploads only when the task's *Include video* switch is on (its starting value is Settings → Linear → Include video, off by default). `LinearFiler` is the gate: a video `LocalAsset` can only be made from a `RenderedMedia` and only when `includeVideo` is true, and `RenderedMedia` can only be made by `ClipRedactor`. With no edits the passthrough cut (`clip.mp4`) uploads as it is; with a `ClipRedaction` (ScoutCore: cut time ranges and opaque rectangles, each for the whole clip or a time range, stored in `review.json`) `ClipRedactor` re-encodes with `AVAssetExportPresetHEVC1920x1080` to `clip-redacted-<key>.mp4`, and only that file can upload. Pin images get the same blocks, and pins inside a cut part are left out. After the issue exists, the clip is added as an `attachmentCreate` card ("Scout clip · 0:09") with an id derived from the task key and the clip's hash, so a retry never adds a second card. A size refusal reads "The video is too big for Linear." and offers *File without video*. `CredentialDetectors.installed` is the hook for on-screen secret detection; it is empty, and nothing shows in the UI while it is.
- **Idempotency.** The issue id is derived: a UUID v4 from SHA-256 of the workspace id and the task key. Before creating, `LinearFiler` reads `issue(id:)`; an existing issue is adopted, a trashed or archived one marks the task *deleted in Linear*, and only *File as new issue* (which bumps the key's generation) makes a second issue. A failed create is followed by the same read, so a lost reply converges on the same issue. If a workspace refuses client-chosen ids, Scout remembers that and falls back to searching for the footer key before creating. A pending receipt is saved to `review.json` before the create call.
- **Queue and limits.** Filing is serial. Offline errors retry after 2, 8 and 30 s; `RATELIMITED` waits until the reset time and shows when filing continues.
- **Untrusted replies.** Every reply is decoded into narrow types; issue URLs must be `https://linear.app/…`, asset URLs `https://uploads.linear.app/…`. Remote text is shown as plain text and never fed to the summariser. Debug builds refuse mutations outside `SCOUT_LINEAR_TEST_TEAM`.

## Optional hive and Apiary integration

hive manages coding-agent sessions. Apiary is a desktop workspace for those sessions. Apiary panes are hive sessions (tagged `apiary:workspace=<id>`), so one hive client reaches both. The following sections describe their developer protocols. A Champion is Apiary’s named agent for a workspace.

### hive

Scout talks to the hive daemon directly over its socket, not through the CLI. The CLI is not on a GUI app's `PATH` (it lives in a mise shim), and each run costs a Node start-up.

**Socket.** `$HIVE_V2_SOCKET_PATH`, else `$HIVE_V2_DATA_DIR/hived.sock`, else `~/.hive/v2/hived.sock`. JSON, one object per line. No auth; only the same user can open the socket.

**Handshake.** The server speaks first: `{"protocol":"v2/2","capabilities":[…],"identity":{…}}`. The client answers `{"protocol":"v2/2"}`.

**Requests.** `{"id":<n>,"verb":"<verb>","params":{…}}` → `{"id":<n>,"ok":true,"result":…}` or `{"id":<n>,"ok":false,"error":{"code","message"}}`.

| Need | Verb | Params | Result |
|---|---|---|---|
| Active sessions | `list` | `{lifecycle:"active"}` (always pass it: unfiltered returns every archived bee, many MB) | `{views:[{bee, runtime, view, …}]}` |
| Send a task | `send` | `{beeId, body, urgency:"next", idempotencyKey}` | `{messageId (number), commandId, unarchived, deduped?}` |
| New session | `spawn` | `{name, agent, cwd, title, prompt, tags?, idempotencyKey}` | `{beeId, handle, …}` |
| Live updates | `watch` | – | `delta` / `gap` pushes |

Useful fields on `bee`: `id`, `name`, `handle`, `agent`, `cwd`, `title`, `tags`, `lastOutputAt` (ms), `lifecycle`. Useful fields on `view`: `working`, `waitingForYou`, `runtimeState`. **`bee.env` contains secrets such as `APIARY_AGENT_TOKEN`; Scout must never log, store or display it.**

Implementation: `mac/Scout/Integrations/HiveClient.swift`, a `nonisolated` `Network.framework` Unix-socket client. Measured: `list {lifecycle:"active"}` takes about 60 ms on a store with 2,000+ bees. Verified: a `send` from `HiveClient` arrived in a live session, and repeating it with the same idempotency key returned the same `messageId` with `deduped: true` and no second message.

**Attachments.** hive messages are text. Files are referenced by absolute path, one per line, using Apiary's convention so they render in Apiary too:

```
[Attached video: /abs/clip.mp4]
[Attached image: /abs/pin-1.png]
[Attached file: /abs/snippet.json]
```

**Idempotency.** Every delivery uses `idempotencyKey = "scout:<session-id>:<snippet-id>"`, so retries after a crash or timeout never deliver twice.

### Routing

`DeliveryRoute` (chosen in onboarding, changeable in Settings):

1. **Match project** (default). Resolve the snippet's project root (see below). Among active sessions whose `cwd` is inside that root, pick one that is `waitingForYou` first, then one that is `working`, then any other; within each group the latest `lastOutputAt` wins. Waiting sessions come first so a task doesn't interrupt a turn in progress; `urgency: "next"` queues it anyway. With no match, `spawn` a session in the project root with the default agent, titled after the snippet.
2. **New session.** Always `spawn`.
3. **Ask me.** The card's destination chip opens a picker; nothing is sent until the user chooses.

When a `send` or `spawn` fails (hive stopped, the session is gone, a timeout), Scout copies the task to the pasteboard the same way and marks it "Not sent, copied instead" with hive's reason. The task stays unsent, so Retry or Send still delivers it later.

A chosen destination is kept with the task in `review.json`, together with the resolved project and the runtime notes from the page, so a held task reopens with the same destination and the same outgoing message. A destination Scout picked itself is picked again if that session is no longer active; one you picked always stays.

### Project resolution

To send to the right repo, Scout maps what is on screen to a source tree. It tries these in order and stops at the first answer:

1. **SDK hello.** SDKs report `project.root` (dev servers know their cwd) and the git branch.
2. **nectar.** A page whose origin matches an env's `urls.local`, `urls.mesh` or `urls.public` resolves to that env's source repo (or its borrowed worktree) and branch. `nectar ls --json` lists only name, status and `mesh_url`, and the CLI isn't on a GUI app's `PATH`, so Scout reads the env records `ls` reads: `$NECTAR_HOME/envs/*.json`, default `~/.nectar/envs`. Stopped and expired envs are skipped.
3. **Dev server port.** For `localhost:<port>` URLs: listening pid (`lsof -iTCP:<port> -sTCP:LISTEN`) → process cwd (`proc_pidinfo PROC_PIDVNODEPATHINFO`) → the nearest folder with `.git`. For portless names (`*.localhost`), the host goes through portless's route table (`routes.json` in `$PORTLESS_STATE_DIR`, `~/.portless` or `/tmp/portless`; exact name first, then the most specific parent) to the app's port, then the same chain. If nothing listens on that port, the route's own pid gives the cwd.

The resolved `ProjectReference` is stored on the task and shown in the review, so a wrong guess is visible before sending.

Not implemented yet: native apps (iOS Simulator and macOS debug builds through DerivedData), an optional local project index (names and repo paths, matched against window titles and URL hosts) and user overrides in Settings. Tasks from those sources have no project until the SDK reports one; with "Match project" they wait for a destination.

### Apiary

**Detect.** `~/.hive/gateways/apiary.json` exists and its `pid` is alive → running. Otherwise the bundle id `com.trmd.apiary` resolves → installed.

**Today.** Delivery to Apiary panes works through hive (above). Apiary's attachment convention makes clips and images show up in the conversation.

**Bridge client (walkthroughs).** A hotkey recording talks to Apiary's Scout bridge (see the [Apiary bridge protocol](apiary-bridge.md)). `ApiaryBridge` (`mac/Scout/Integrations/ApiaryBridge.swift`) reads the discovery file, connects to its Unix socket, sends `hello` with the token and Scout's pid, and keeps one NDJSON connection that closes 30 s after the last request. A missing or dead Apiary costs one file read and a 1 s quiet period; nothing else changes.

- **Discovery:** `--apiary-bridge=<file>`, else `SCOUT_APIARY_BRIDGE`, else `$APIARY_HOME_DIR/scout-bridge.json`, else `~/.apiary/scout-bridge.json`. A dev Apiary writes `<userData>/scout/scout-bridge.json`.
- **Pointing:** each pin and each dwell (the pointer still for 0.6 s, sampled every 100 ms off the main thread) calls `pointAt` from a detached task, never on the capture or main thread. Scout asks only when the topmost on-screen window at the point belongs to Apiary's pid (`CGWindowList`, no permission needed). A dwell inside the bounds of the last answer, or one with the same innermost identity, is skipped. Budget 30 ms; a pin retries once with 100 ms. The answer's `stack` is stored verbatim on the pointer (`source: "apiary"`), and finishing waits for answers still in flight.
- **Target picker:** finishing opens a sheet near the cursor at once; the bundle finishes behind it and the asks appear when ready. Rows combine `focusedChat`, `listTargets(limit: 500)` and all active local hive sessions (prefetched when recording starts and refreshed on open). Matching session IDs enrich bridge rows instead of duplicating them. Search matches display names, session titles, Champion names and IDs, handles, session IDs and workspace names/IDs, case-insensitively by substring; multiple words must all match. Search text is indexed when rows change and results are cached until the query changes. The lazy list renders every result. Bridge rows support paste and send; hive-only rows support send. Workspace labels use the bridge's `workspaceName`, falling back to `workspaceId` or hive's workspace tag. Enter pastes into the chosen chat, ⌘↩ sends, Esc leaves the walkthrough on the clipboard only. A choice made before the bundle is ready waits for it ("Sends when ready"). The menu bar's **Send…** reopens the sheet for the last walkthrough.
- **Bridge discovery limit:** Apiary 0.2.40 reads its unfiltered session mirror, places unfocused Champions after ordinary sessions, then truncates to at most 500 rows. It supplies no cursor or workspace names. Scout supplements this with active local hive sessions, whose Champion names come from `bee.name`; hive has no canonical Champion roster/ID or workspace-name lookup. This recovers active local Champions across workspaces, but cannot enumerate inactive or remote Champions missing from the bridge. Complete discovery needs a paginated `listTargets` across all accessible workspaces (including Champions independently of session recency), returning canonical `championId`, `sessionId`, `workspaceId` and `workspaceName`, plus session display names and titles. Scout retains those optional fields when provided. Apiary is not modified here.
- **Delivery:** `deliver` with `deliveryId = scout:<walkthrough>:<kind>:<id>:<mode>`. When Apiary is absent, times out or answers `noRenderer`/`notReady`, a send goes through the hive socket with the same `messageId = uuidv5(deliveryId)` as the idempotency key, so a retry or a bridge send followed by the fallback reaches the session once. A paste with no renderer stays on the clipboard. The sheet shrinks to a one-line confirmation and fades.
- **Record feedback on a proof:** Scout registers the `scout://` URL scheme. Apiary's Record feedback opens `scout://record?target=proof:<proofId>`, which starts a recording exactly like ⌃⌥S with the proof bound to it (`RecordRequest`, `ScoutAppDelegate`). Finishing skips the picker and delivers with `target:{kind:"proof", id}` and mode `paste`, so the walkthrough lands in that proof's pending review. A one-line panel says "In the review: <claim>". When Apiary refuses (`targetGone`, `badRequest`, an outside bundle) or isn't reachable, the walkthrough stays on the clipboard and the line says why. The URL during a recording binds the proof to that recording. Proofs aren't in the picker: `listTargets` doesn't list them yet.

**Next (M7):**

- **Scout gateway for bees.** Write `~/.hive/gateways/scout.json` (`protocol:"mcp"`, `gatewayRev:1`, `socketPath`, `pid`, `shim.command`). hive then adds Scout's MCP tools to every bee:
  - `scout_recent_snippets`: list recent snippets.
  - `scout_snippet(id)`: fetch one snippet with its clip, pins and transcript.
  - `scout_request_feedback(prompt)`: ask the human to scout something and return the result to this bee.
- **Recording host.** Apiary already has a record button that speaks Syn's WebSocket protocol (`hello`, `startRecording{mode, token, windowId, rect}`, `stopRecording`, `packetReady{path, token}`). Scout will offer the same flow under a new versioned endpoint and ask Apiary to add a `scout` host next to `synHost`, keeping Syn's port (47845) free so both can run during the transition.
- **Quick compose.** `apiary://compose?text=…` (≤ 32 KB, text only) is a zero-integration fallback for "Ask me" routing.

### Pollinate and nectar

- **nectar** is a project-resolution source (above). Scout can also attach the nectar preview URL to a task so the agent can check its fix against the same environment.
- **Pollinate** (`pol`) can batch or debounce delivery, for example "collect all snippets from this session and send one summary task when I stop". Not planned before M7.

### Optimise tasks through Claude

Optimise is an explicit review-window action. `OptimiseReview.start()` prepares the full transcript, ledger, current task ranges and at most 60 key-frame JPEG thumbnails, each at most 320 pixels on its longest side. Walkthrough context includes pointer metadata, drawings and explicit break events. The fixed prompt treats recording content as data, requests proposals only, forbids reading/uploading video or audio, and requests the optimise.v1 JSON as the final assistant reply without any file write. The transcript stays inline; the ledger, review and walkthrough JSON are referenced by attached-file paths instead of repeated inside the prompt. The copied inputs live in a private per-bundle `<ScoutDataRoot>/OptimiseRuns/<uuid>` directory, which is always the spawn cwd; Scout has no model API key or HTTP model client.

The transcript, ledger and selected stills go to Claude through the user's hive account after the button press. The video stays on disk and is never attached to the optimiser message. Claude reads only the copied input files inside its cwd. Scout polls the spawned bee through hive view/commands, extracts its final assistant reply from the local session log and validates it with the same decoder as file import before atomically saving optimise.v1.json and exposing proposals for acceptance; it never applies the agent output automatically. A three-minute watchdog covers preparation and the agent run. Failure, invalid output, cancellation and timeout leave the task review unchanged. Success, failure, cancel and timeout use hive's `stop` verb for the spawned bee; cancellation sends one stop per observed generation and polls for a stopped runtime with no pending commands, including after a late spawn receipt or send_wake. Stale undelivered mailbox entries do not invalidate that confirmation. Cleanup errors are logged and retained separately in the review and replay report. Boot failures surface their reason promptly; a failed stop RPC after valid output leaves the proposals available. Each rerun archives an old output under a unique name so a stale file cannot be mistaken for the new result.

Artifacts in a session or bundle: `optimise-ledger.json`, `optimise-transcript.txt`, `optimise-thumbs/`, `optimise.v1.json`, and append-only `corrections.jsonl`. Walkthrough acceptance additionally writes `asks.agent.json`; the original AskExtractor asks remain intact. Workspaces are deleted after confirmed agent shutdown; leftovers older than a day are swept at launch. No optimisation runs automatically and no task is delivered just because a proposal is accepted.

Optimise artifacts follow `ScoutDataRoot`: for `com.trmdy.scout.test`, the default root is `~/Library/Application Support/Scout-com.trmdy.scout.test/`, with sessions under `Sessions/` and walkthroughs under `walkthroughs/`. An absolute `--data-root=` or `SCOUT_DATA_ROOT` overrides it. For a test run, choose a separate bundle ID and pass an absolute `--data-root=` pointing to a fresh temporary directory. Keep recordings and generated output there, away from the release data. See [Contributor checks](contributing.md).
