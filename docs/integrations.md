# Scout: integrations

Scout delivers tasks to coding agents. hive is the delivery channel. Apiary panes are hive sessions (bees tagged `apiary:workspace=<id>`), so one hive client reaches both.

## hive

Scout talks to the hive daemon directly over its socket, not through the CLI. The CLI is not on a GUI app's `PATH` (it lives in a mise shim), and each run costs a Node start-up.

**Socket.** `$HIVE_V2_SOCKET_PATH`, else `$HIVE_V2_DATA_DIR/hived.sock`, else `~/.hive/v2/hived.sock`. JSON, one object per line. No auth; only the same user can open the socket.

**Handshake.** The server speaks first: `{"protocol":"v2/1","capabilities":[…],"identity":{…}}`. The client answers `{"protocol":"v2/1"}`.

**Requests.** `{"id":<n>,"verb":"<verb>","params":{…}}` → `{"id":<n>,"ok":true,"result":…}` or `{"id":<n>,"ok":false,"error":{"code","message"}}`.

| Need | Verb | Params | Result |
|---|---|---|---|
| Active sessions | `list` | `{lifecycle:"active"}` (always pass it: unfiltered returns every archived bee, many MB) | `{views:[{bee, runtime, view, …}]}` |
| Send a task | `send` | `{beeId, body, urgency:"next", idempotencyKey}` | `{messageId, commandId, unarchived}` |
| New session | `spawn` | `{name, agent, cwd, title, prompt, tags?, idempotencyKey}` | `{beeId, handle, …}` |
| Live updates | `watch` | – | `delta` / `gap` pushes |

Useful fields on `bee`: `id`, `name`, `handle`, `agent`, `cwd`, `title`, `tags`, `lastOutputAt` (ms), `lifecycle`. Useful fields on `view`: `working`, `waitingForYou`, `runtimeState`. **`bee.env` contains secrets such as `APIARY_AGENT_TOKEN`; Scout must never log, store or display it.**

Implementation: `mac/Scout/Integrations/HiveClient.swift`, a `nonisolated` `Network.framework` Unix-socket client. Measured: `list {lifecycle:"active"}` takes about 60 ms on a store with 2,000+ bees.

**Attachments.** hive messages are text. Files are referenced by absolute path, one per line, using Apiary's convention so they render in Apiary too:

```
[Attached video: /abs/clip.mp4]
[Attached image: /abs/pin-1.png]
[Attached file: /abs/snippet.json]
```

**Idempotency.** Every delivery uses `idempotencyKey = "scout:<session-id>:<snippet-id>"`, so retries after a crash or timeout never deliver twice.

## Routing

`DeliveryRoute` (chosen in onboarding, changeable in Settings):

1. **Match project** (default). Resolve the snippet's project root (see below). Pick the active session whose `cwd` is inside that root and has the latest `lastOutputAt`. Prefer sessions that are `waitingForYou` over `working`, so a task doesn't interrupt a turn in progress; `urgency: "next"` queues it anyway. With no match, `spawn` a session in the project root with the default agent, titled after the snippet.
2. **New session.** Always `spawn`.
3. **Ask me.** The card's destination chip opens a picker; nothing is sent until the user chooses.

Without hive: copy `task.md` to the pasteboard (text plus the snippet folder as a file URL) and keep the snippet folder.

## Project resolution

To send to the right repo, Scout maps what is on screen to a source tree. It tries these in order and stops at the first answer:

1. **SDK hello.** SDKs report `project.root` (dev servers know their cwd) and the git branch.
2. **nectar.** `nectar ls --json` maps preview URLs (`urls.local`, `urls.mesh`, `urls.public`) to `{repo, worktree, branch}` and even the hive bee that published them.
3. **Dev server port.** For `localhost:<port>` or `*.localhost` URLs: listening pid (`proc_listallpids` + `proc_pidfdinfo`, or `lsof -iTCP:<port> -sTCP:LISTEN` as a fallback) → process cwd (`proc_pidinfo PROC_PIDVNODEPATHINFO`) → `git rev-parse --show-toplevel`. portless (`*.localhost` names) resolves through its route table.
4. **Native apps.** For iOS Simulator and macOS debug builds, the app's bundle path goes through DerivedData to the `.xcodeproj` / `Package.swift` path in `info.plist` of the DerivedData folder.
5. **pro index.** `~/Projects/_system/index.jsonl` lists every project and repo path. A window title or URL host that matches a project name or alias is a weak match.
6. **User overrides** in Settings (app or URL pattern → repo). These always win when present.

The resolved `ProjectReference` is stored on the snippet's context and shown on the card, so a wrong guess is visible before sending.

## Apiary

**Detect.** `~/.hive/gateways/apiary.json` exists and its `pid` is alive → running. Otherwise the bundle id `com.trmd.apiary` resolves → installed.

**Today.** Delivery to Apiary panes works through hive (above). Apiary's attachment convention makes clips and images show up in the conversation.

**Next (M7):**

- **Scout gateway for bees.** Write `~/.hive/gateways/scout.json` (`protocol:"mcp"`, `gatewayRev:1`, `socketPath`, `pid`, `shim.command`). hive then adds Scout's MCP tools to every bee:
  - `scout_recent_snippets`: list recent snippets.
  - `scout_snippet(id)`: fetch one snippet with its clip, pins and transcript.
  - `scout_request_feedback(prompt)`: ask the human to scout something and return the result to this bee.
- **Recording bridge.** Apiary already has a record button that speaks Syn's WebSocket protocol (`hello`, `startRecording{mode, token, windowId, rect}`, `stopRecording`, `packetReady{path, token}`). Scout will offer the same flow under a new versioned endpoint and ask Apiary to add a `scout` host next to `synHost`, keeping Syn's port (47845) free so both can run during the transition.
- **Quick compose.** `apiary://compose?text=…` (≤ 32 KB, text only) is a zero-integration fallback for "Ask me" routing.

## Pollinate and nectar

- **nectar** is a project-resolution source (above). Scout can also attach the nectar preview URL to a task so the agent can check its fix against the same environment.
- **Pollinate** (`pol`) can batch or debounce delivery, for example "collect all snippets from this session and send one summary task when I stop". Not planned before M7.
