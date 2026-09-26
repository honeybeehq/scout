# Scout bridge protocol v1 (draft)

SDKs make Scout app-aware beyond what macOS accessibility can see: component names, source locations, routes, test IDs, recent errors. The same protocol serves web pages, native macOS apps, iOS and Android apps (simulator and device), and desktop frameworks.

Status: draft for M4. Nothing here is implemented yet.

## Design goals

1. **Zero cost when idle.** SDKs do nothing until Scout says a session is active. No hover streams or DOM walks otherwise.
2. **SDK-side hit testing.** An SDK knows its own pointer position in its own coordinates, so Scout never has to guess browser chrome offsets or zoom (the fragile part of Syn's `coords.ts`).
3. **Safe by default.** Loopback only, origin checks, pairing, no props or input values unless the developer opts in.
4. **Dev only.** Framework adapters inject the SDK only in development builds.

## Transport

- **Desktop and simulator:** WebSocket at `ws://127.0.0.1:47811/v1`. Port 47811 is new, chosen so Syn's 47845 stays free and both can run. If 47811 is busy, Scout tries 47812–47819 and writes the chosen port to `~/Library/Application Support/Scout/bridge.json`.
- **Physical devices (LAN):** Scout advertises Bonjour `_scout._tcp`. Devices connect over TLS using a certificate pinned during pairing. Pairing is a QR code in Scout's SDK settings.
- **Android emulator:** `adb reverse tcp:47811 tcp:47811`, which Scout sets up when an emulator is detected.

Frames are JSON text. Every message is `{"v":1,"type":"<type>", …}`. Requests carry a string `id`; responses repeat it.

## Trust

1. **Browsers.** The `Origin` must be loopback: `localhost`, `127.0.0.1`, `[::1]`, `*.localhost`, or a nectar/portless dev host. Other origins are rejected before the WebSocket upgrade.
2. **Tokens.** `bridge.json` holds a random `token`. Dev-server adapters (Vite, Next, …) read it at dev-server start and inject it into the page, and native SDKs read it from the environment (`SCOUT_BRIDGE_TOKEN`, set by an Xcode scheme or Gradle task that Scout's installer adds). A matching token is trusted without asking.
3. **First contact.** A client without a token appears in Scout as "Acme Web (localhost:3000) wants to connect", with Allow and Deny. The answer is remembered per origin or bundle id.

## Lifecycle

```
SDK                                   Scout
 │── hello ──────────────────────────▶│
 │◀───────────────────────── welcome ─│  session state, capabilities
 │                                    │
 │◀──────────────── session {active} ─│  user started scouting
 │── context (route, title) ─────────▶│  on connect and on every navigation
 │── hover (element) ────────────────▶│  throttled to 4 Hz while active
 │◀──────────────────── aim {active} ─│  user holds ⌥
 │── hover (element) ────────────────▶│  20 Hz while aiming; SDK draws an in-page outline
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
`kind` is one of `web`, `ios`, `android`, `macos`, `electron`, `flutter`, `react-native`. `project.root` comes from the dev server (web) or the build (native), and is how Scout routes tasks to the right repo.

**context**: `{type:"context", route, url?, title?, screen?}`. `route` is the framework route pattern when known (`/orders/[id]`), else the path.

**hover** and **pinned**:
```json
{ "v": 1, "type": "hover", "at": 1727370000123, "element": { … } }
{ "v": 1, "type": "pinned", "id": "pin-3", "element": { … }, "crop": "data:image/png;base64,…" }
```
`at` is Unix time in milliseconds. Scout maps it to `SessionTime`. `crop` is optional and is only used when Scout has no Screen Recording permission.

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
- `source.file` is relative to `project.root` when possible.
- `bounds.space` is `screen` (global points, top-left origin) when the SDK knows its window position (native, Electron), or `viewport` (web). With `viewport`, Scout places the outline using the page's own reported viewport origin.
- `props` stays `null` unless the developer turns on `props: "safe"`. Safe mode sends primitives only, redacts keys matching `/pass|secret|token|key|auth|card|ssn/i`, sends at most 20 props, and cuts strings to 64 characters.

**signal**: runtime evidence that is useful to an agent:
```json
{ "v": 1, "type": "signal", "at": 1727370001000, "kind": "error",
  "message": "TypeError: cannot read 'total' of undefined",
  "stack": "at OrderSummary (src/checkout/OrderSummary.tsx:22:15)…" }
```
`kind` is `error`, `console` (warn and error levels only), or `network` (failed requests: method, url without query, status). SDKs keep the last 50 and send them only while a session is active.

### Scout → SDK

- **welcome**: `{type:"welcome", scout:{version}, session:{active}, capabilities:[…]}`
- **session**: `{type:"session", active:true|false}`
- **aim**: `{type:"aim", active:true|false}`. While active the SDK draws a beam-colored outline (`#8B96FF`) and label chip around the hovered element, in a shadow-DOM overlay that doesn't affect layout.
- **pin**: `{type:"pin", id, at}`. The user clicked while aiming. The SDK answers `pinned` with the element that was under its pointer at `at`.
- **resolve**: `{type:"resolve", id, point:{x,y,space:"screen"}}`. Hit-test a point, for native SDKs and Electron.
- **highlight**: `{type:"highlight", elementId|selector, style:"beam"|"flare", durationMs}`. Used when reviewing a snippet.
- **error**: `{type:"error", id?, code, message}`. Codes: `unauthorized`, `invalidRequest`, `unsupported`, `tooLarge`.

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
