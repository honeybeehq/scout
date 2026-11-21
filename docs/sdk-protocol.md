# Scout bridge protocol v1 (draft)

SDKs make Scout app-aware beyond what macOS accessibility can see: component names, source locations, routes, test IDs, recent errors. The same protocol serves web pages, native macOS apps, iOS and Android apps (simulator and device), and desktop frameworks.

Status: draft for M4. Nothing here is implemented yet.

## Design goals

1. **Zero cost when idle.** SDKs do nothing until Scout says a session is active. No hover streams or DOM walks otherwise.
2. **SDK-side hit testing.** An SDK knows its own pointer position in its own coordinates, so Scout never has to guess browser chrome offsets or zoom (the fragile part of Syn's `coords.ts`).
3. **Safe by default.** Loopback only, origin checks, pairing, no props or input values unless the developer opts in.
4. **Dev only.** Framework adapters inject the SDK only in development builds.

## Transport

- **Desktop and simulator:** WebSocket at `ws://127.0.0.1:47811/v1`. Port 47811 is new, chosen so Syn's 47845 stays free and both can run. If 47811 is busy, Scout tries 47812–47819 and writes the chosen port to `<ScoutDataRoot>/bridge.json`. The release root defaults to `~/Library/Application Support/Scout`; a test bundle such as `com.trmdy.scout.test` defaults to `~/Library/Application Support/Scout-com.trmdy.scout.test`. An absolute `--data-root=` or `SCOUT_DATA_ROOT` override also applies to the bridge file.
- **Loopback only:** The bridge binds explicitly to both `127.0.0.1` and `::1` on the selected port. If one address family is unavailable, it uses the remaining loopback address and logs that fallback. Web SDK clients on `http://localhost` and `http://127.0.0.1` can connect; other hosts cannot reach it over LAN or tailnet. Physical-device LAN pairing is planned and is not served by this listener.
- **Android emulator:** `adb reverse tcp:47811 tcp:47811`, which Scout sets up when an emulator is detected.

Frames are JSON text. Every message is `{"v":1,"type":"<type>", …}`. Requests carry a string `id`; responses repeat it.

Connecting (web SDK): when the dev-server adapter injected a port from `bridge.json`, the SDK connects to that port only; otherwise it tries 47811–47819 in order. It sends `hello` on open, reconnects with a short localhost backoff (1 s rising to 1.5 s, with ±20% jitter, scheduled delay at most 1.8 s), retries immediately on window focus or becoming visible while disconnected, and stops for the rest of the page load after `error {code:"unauthorized"}`.

## Trust

1. **Browsers.** The `Origin` must be loopback: `localhost`, `127.0.0.1`, `[::1]` or `*.localhost`. Other origins, including `null` (sandboxed iframes, `file:` pages), are rejected before the WebSocket upgrade. Clients without an `Origin` header (native SDKs) are allowed to connect.
2. **Tokens.** `bridge.json` holds a random `token`. Dev-server adapters (Vite, Next, …) read it and inject it into the page, and native SDKs read it from the environment (`SCOUT_BRIDGE_TOKEN`, set by an Xcode scheme or Gradle task that Scout's installer adds). **`hello` must carry the token.** A wrong or missing token gets `error {code:"unauthorized"}` and the connection is closed; every other message before a successful `hello` gets `unauthorized` too. Without this, any page that can reach the loopback port could inject text into agent tasks.
3. **First contact (planned).** Tokenless clients will be able to ask for approval ("Acme Web (localhost:3000) wants to connect", Allow or Deny, remembered per origin or bundle id). Until then they are rejected.

## Lifecycle

```
SDK                                   Scout
 │── hello ──────────────────────────▶│
 │◀───────────────────────── welcome ─│  session state, capabilities
 │                                    │
 │◀──────────────── session {active} ─│  user started scouting
 │── context (route, title) ─────────▶│  when the session starts and on every navigation
 │── hover (element) ────────────────▶│  on element change, at most 4 Hz while active
 │◀──────────────────── aim {active} ─│  user holds ⌥
 │── hover (element) ────────────────▶│  at most 20 Hz while aiming; SDK draws an in-page outline
 │◀─────────────────── pin {id, at} ──│  user clicked while aiming
 │── pinned {id, element, crop?} ────▶│
 │── signal (error, log, network) ───▶│  ring buffer, attached to the open snippet
 │◀──────────── session {active:false}│
```

## Messages

### SDK → Scout

**hello**
```json
{
  "v": 1, "type": "hello",
  "token": "…optional…",
  "app": {
    "name": "Acme Web",
    "kind": "web" ,
    "url": "http://localhost:3000/checkout",
    "bundleId": null,
    "pid": 12345,
    "framework": { "name": "react", "version": "19.1.0", "meta": "next@16" }
  },
  "project": { "root": "/Users/me/Projects/acme/web", "gitBranch": "main" },
  "sdk": { "name": "@scout/web", "version": "0.1.0" },
  "capabilities": ["hover", "pin", "highlight", "source", "errors", "console", "network"]
}
```
`kind` is one of `web`, `ios`, `android`, `macos`, `electron`, `flutter`, `react-native`. `project.root` comes from the dev server (web) or the build (native), and is how Scout routes tasks to the right repo. On the web it is the git toplevel of the dev server's root, or the root itself outside git. Unknown values are `null` (`token`, `pid` and `bundleId` on the web). `url` has no query or fragment. `framework.name` is `dom` when no framework was detected. `capabilities` lists `source` only when a framework resolver is loaded.

Until it receives `session {active:true}`, an SDK sends only `hello` and replies to Scout's requests, and those replies carry no page data (`pinned` has `element: null`).

**context**: `{type:"context", route, url?, title?, screen?}`. `route` is the framework route pattern when known (`/orders/[id]`), else the path (or the `#/…` path for hash routers). `url` has no query or fragment. Sent only while a session is active: when it starts (including a `welcome` whose session is already active), after `pushState`, `replaceState`, `popstate` and `hashchange`, and when the title changes. Identical consecutive contexts are not repeated.

**hover** and **pinned**:
```json
{ "v": 1, "type": "hover", "at": 1727370000123, "element": { … }, "viewport": { "x": 0, "y": 87, "scale": 1 } }
{ "v": 1, "type": "pinned", "id": "pin-3", "element": { … }, "viewport": { … }, "crop": "data:image/png;base64,…" }
```
`at` is Unix time in milliseconds. Scout maps it to `SessionTime`. For `hover` it is when the pointer reached the element. `crop` is optional and is only used when Scout has no Screen Recording permission.

- `hover` is sent when the element under the pointer changes: at most 4 per second while a session is active, at most 20 per second while aiming. While aiming, the SDK also sends the current element right away and repeats it about once a second while the pointer rests, so Scout always knows which page is under the pointer.
- `pinned.element` is `null` when nothing of the page was under the pointer at `at` (pointer outside the page, or no active session).
- `viewport` (optional, `null` until the SDK has seen a pointer event) is where the page's viewport sits on screen: `x`, `y` are global screen points (top-left origin) of the viewport's top-left corner, and `scale` is screen points per CSS pixel (browser zoom). Web SDKs derive it from pointer events (`screenX − clientX × scale`). A `viewport`-space rect maps to screen as `(viewport.x + x × scale, viewport.y + y × scale, width × scale, height × scale)`.

**Element descriptor.** Shared by all SDKs:
```json
{
  "id": "stable id within this page load",
  "role": "button",
  "label": "Pay now",
  "text": "Pay now",
  "testId": "pay-now",
  "selector": "[data-testid=pay-now]",
  "component": "PayButton",
  "ownerStack": ["CheckoutPage", "PaymentForm", "PayButton"],
  "source": { "file": "src/checkout/PayButton.tsx", "line": 14, "column": 7 },
  "bounds": { "x": 812, "y": 604, "width": 64, "height": 24, "space": "screen" },
  "state": { "disabled": false, "focused": false },
  "props": null
}
```
- `id` is stable for the element within one page load and is what `highlight {elementId}` refers to.
- `role` is the explicit ARIA role, else the implicit one (`button`, `link`, `textbox`, `heading`, …), else `null`. `label` is the accessible name (`aria-label`, `aria-labelledby`, `<label>`, `alt`, `title`, `placeholder`, or text for roles named by their content). `text` is the visible text, trimmed to 80 characters; it is `null` for inputs, text areas, selects and editable content.
- `component` is the component that wrote the element's markup, and `source` points at that markup. `ownerStack` lists the owning components outermost first and ends with `component`; it is `[]` without a framework resolver.
- `source.file` is relative to `project.root` when possible. `source.line` and `source.column` are 1-based and may be `null` when only the file is known.
- `bounds.space` is `screen` (global points, top-left origin) when the SDK knows its window position (native, Electron), or `viewport` (web: CSS pixels relative to the top-level page's viewport, including same-origin iframe offsets). With `viewport`, Scout places the outline using the message's `viewport` origin.
- `props` stays `null` unless the developer turns on `props: "safe"`. Safe mode sends primitives only, sends at most 20 props, and cuts strings to 64 characters. Keys matching `/pass|secret|token|key|auth|card|ssn/i`, and `value` and `defaultValue` (input values), are sent as `"[redacted]"`. `children`, `key` and `ref` are skipped.

**signal**: runtime evidence that is useful to an agent:
```json
{ "v": 1, "type": "signal", "at": 1727370001000, "kind": "error",
  "message": "TypeError: cannot read 'total' of undefined",
  "stack": "at OrderSummary (src/checkout/OrderSummary.tsx:22:15)…" }
```
`kind` is `error`, `console` (warn and error levels only), or `network` (failed requests). Fields by kind:

| kind | fields |
|---|---|
| `error` | `message` (`Name: message`), `stack` |
| `console` | `level` (`warn` or `error`), `message`, `stack` when an `Error` was logged |
| `network` | `method`, `url` (path for same-origin requests, else origin and path; never a query), `status` (`0` when the request failed without a response), `message` (`POST /api/promo 404`) |

`at` is when it happened. Stacks are frames only, with paths relative to `project.root`, source-mapped where the page serves source maps, and library frames below the first app frame dropped (at most 12 frames, 4000 characters). Messages are cut to 1000 characters. Logged objects are reduced to their keys. SDKs keep the last 50 signals, send them only while a session is active, and send the ones from the last 30 seconds when a session starts. At most 20 signals per second are recorded, and a signal repeating the previous message within a second is dropped.

### Scout → SDK

- **welcome**: `{type:"welcome", scout:{version}, session:{active}, capabilities:[…]}`
- **session**: `{type:"session", active:true|false}`
- **aim**: `{type:"aim", active:true|false}`. While active the SDK draws an accent outline (`#FF6A3D`) with a dark label chip around the hovered element, in a shadow-DOM overlay that doesn't affect layout.
- **pin**: `{type:"pin", id, at}`. The user clicked while aiming. The SDK answers `pinned` with the element that was under its pointer at `at`.
- **resolve**: `{type:"resolve", id, point:{x,y,space:"screen"}}`. Hit-test a point, for native SDKs and Electron. Web SDKs answer `error {id, code:"unsupported"}`.
- **highlight**: `{type:"highlight", elementId|selector, style:"beam"|"flare", durationMs}` (`beam` draws a neutral white outline, `flare` the accent). Used when reviewing a snippet. Works with or without an active session. `durationMs` defaults to 1500 and is clamped to 100–10000. Unknown elements are ignored.
- **error**: `{type:"error", id?, code, message}`. Codes: `unauthorized`, `invalidRequest`, `unsupported`, `tooLarge`. SDKs send the same shape back, with the request's `id`, for a request they cannot serve.

## SDK packages (planned)

| Package | Integration |
|---|---|
| `@scout/web` | Core DOM SDK: hit testing, selectors, safe attributes, in-page overlay, error/console/network ring |
| `@scout/react`, `@scout/svelte`, `@scout/vue` | Component names, owner stacks, source locations (React fiber `_debugSource` / React 19 `_debugStack`, Svelte `__svelte_meta`, Vue `__file`) |
| `@scout/vite`, `@scout/next`, `@scout/tanstack-start` | Dev-only injection, token and project root |
| `ScoutKit` (Swift) | SwiftUI and UIKit: view names, accessibility identifiers, `#fileID:#line` via a `.scout()` modifier; macOS and iOS |
| `scout-android` | View hierarchy, Compose semantics, source via debug metadata |

## What an SDK must never send

Input values, passwords, `href` query strings and fragments, cookies, storage contents, request or response bodies, or anything from a page that has not received `session {active:true}`.

## Dev-only canvas games

A dev entry point, after the Vite SDK injection, can register a canvas:

```ts
import { scout } from "@scout/web"

const unregister = scout.game({
  canvas,
  name: "My game",
  build: "git-sha",
  describe: ({ x, y }) => hitTest(x, y),
  snapshot: () => ({ scene, seed, frame, clock, position, save, extra }),
})
```

Keep the import and registration behind `import.meta.env.DEV` (use a dynamic import to exclude it from production). `scout.game` does not start the SDK without a dev-injected configuration or an explicitly started SDK. `startScout().game(...)` registers on a manually started SDK. Registration returns a cleanup function; stopping Scout clears registrations.

`canvas` is explicit. `describe` receives CSS pixels from its top-left corner, before backing-store scaling or camera transforms. Map them into world coordinates in the adapter. It returns `{entity:{id,kind,label}, layer?, scene?, extra?}` or `null`. Entity IDs must be stable within a game session. Hover, aim and pin hit tests report normal element descriptors with `kind:"game"`, `game` containing that description, the entity kind as `role`, the entity label as `label`, and canvas bounds. Null falls back to the DOM canvas. Historical pin coordinates come from the pointer samples; state is sampled when the pin request arrives.

`snapshot` may return a value or promise: `{scene, seed?, frame, clock, position, save?, extra?}`. `clock` is game seconds; position and extra are adapter-defined JSON. Saves must be JSON serializable. The SDK calls it at each pin and on Scout's `snapshot {id}` request at task close, only while the session is active. It sends:

```json
{"v":1,"type":"gameState","id":"pin-1","reason":"pin","at":1794490000000,"game":{"name":"My game","build":"git-sha","scene":"ring","seed":42,"frame":120,"clock":2,"position":{"x":12,"y":4},"save":{"version":1},"saveStatus":"included"}}
```

`reason` is `pin` or `taskClose`. The currently pointed game replies; over game HUD DOM, the last pointed game is used (or the sole registered game). `gameStateDone {id}` completes the request, including when no game or save is available. Scout accepts at most one state per solicited request, from the client it requested. Task-close requests carry a native task binding, so delayed replies cannot drift into the next task. Saves are capped at **256 KiB of UTF-8 JSON**; larger saves are omitted with `saveStatus:"omitted: exceeds 256 KiB"`. No save gives `absent`. The full game payload is capped at 512 KiB. Nonserializable snapshots or oversized full payloads are skipped; a broken adapter must not stop recording. Snapshot requests complete on `gameStateDone`, with a 750 ms native timeout; adapters should return promptly.

`perf` joins the signal kinds and capabilities. It reports visible-page animation-frame gaps over 50 ms as `Frame hitch: N ms`, and browser long-task entries as `Long task: N ms` where supported. It uses the same 50-entry ring, 30-second replay, 20-per-second burst limit and consecutive-message deduplication as other signals, with an additional one-per-second perf limit so hitches leave room for errors. Hidden-page frame gaps are ignored. No signal, entity description or snapshot is transmitted before the session is active.

Game adapters explicitly opt in to sending saves. They must construct the repro save themselves; Scout never reads storage, cookies or input values. Do not include credentials or unrelated player data in save or extra.

Task-close collection belongs to the native scouting session and precedes routing or delivery. Stop captures the open task's state before deactivating the SDK, rather than waiting for speech and video finalization while the game advances. If final transcription creates the task only after Stop, the scoped state captured at Stop is bound to that task. A responsive matching game supplies `game-snapshots/<task-id>.json`, and delivery waits for capture. A reconnect can change the native client ID; Scout remembers its project and falls back only within that project, without requiring a new hover for an explicitly selected or project-scoped client.

If a reconnected client has no reported project root, Scout cannot safely associate it with the previous connection's task and skips that close capture instead of selecting an arbitrary game client.
