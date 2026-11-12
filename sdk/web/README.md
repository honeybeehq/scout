# Scout web SDK

Lets Scout see inside your web app while you scout it. When you point at something, Scout's task says `Button "Pay now" · src/checkout/PayButton.tsx:3` instead of just "a button".

The SDK connects to the Scout app's local bridge (`ws://127.0.0.1:47811/v1`, see [the protocol](../../docs/sdk-protocol.md)). It stays idle until you start a scouting session. It is meant for development only.

| Package | What it does |
|---|---|
| `@scout/web` | Core SDK: tracks the pointer, describes the element under it, draws the aim outline, reports route changes, errors, console warnings and failed requests. About 10.5 kB min+gz. |
| `@scout/react` | Adds the component name, owner stack and source location (React 16–19). |
| `@scout/vite` | Vite plugin that injects the SDK into the dev server, with the bridge token and the project root. Never runs in `vite build`. |

## Use it

### Vite

```bash
pnpm add -D @scout/vite @scout/react
```

```ts
// vite.config.ts
import react from "@vitejs/plugin-react"
import { scout } from "@scout/vite"

export default defineConfig({
  plugins: [react(), scout()],
})
```

That is all. The plugin adds two scripts to `index.html` while the dev server runs: the config (`window.__SCOUT__`) and the SDK. It loads `@scout/react` when the project has it installed. Your code does not import anything, so production builds contain no Scout code.

Plugin options: `app: { name }` (how Scout labels the app; defaults to the `package.json` name), `props: "safe"` (see below), `bridgeFile`, `enabled`. The environment variables `SCOUT_BRIDGE_FILE` (path to `bridge.json`) and `SCOUT_DISABLED=1` do the same without code changes.

The plugin reads `~/Library/Application Support/Scout/bridge.json` (`{ port, token }`) on every page load, so restarting Scout only needs a page reload. Without the file, the SDK tries ports 47811–47819, but Scout rejects clients without the token until first-contact approval exists, so pass `token` to `startScout` when you load the SDK another way (copy it from Scout's Settings → SDKs or from `bridge.json`).

### Plain script tag

```html
<script>window.__SCOUT__ = { app: { name: "Acme" }, projectRoot: "/Users/me/acme" }</script>
<script src="/node_modules/@scout/web/dist/scout.global.js"></script>
```

The script starts itself when `window.__SCOUT__` exists and exposes `window.Scout`.

### Manual start

```ts
import { startScout } from "@scout/web"
import "@scout/react"

if (import.meta.env.DEV) startScout({ app: { name: "Acme" }, projectRoot: "/Users/me/acme" })
```

`startScout(options)` returns `{ connected, active, stop() }`. Calling it again returns the same instance. Options: `port`, `token`, `projectRoot`, `serverRoot` (the directory the dev server serves, used to turn URLs into file paths), `gitBranch`, `app: { name }`, `framework: { name, version, meta }`, `props: "off" | "safe"`, `route: () => string` (report a route pattern such as `/orders/[id]` instead of the path), `signals: false` (turn off error, console and network capture).

Other frameworks can add component information with `registerResolver({ name, detect, resolve })`.

## What Scout receives

Only while a session is active (after Scout sends `session {active:true}`):

- **Context:** route, URL without query or fragment, page title. Sent when the session starts and on every navigation.
- **Hover and pins:** the element under the pointer, when it changes (4 per second at most, 20 while aiming): role, accessible name, visible text (80 characters), test id, a CSS selector, component, owner stack, source file and line, position, and disabled/focused state.
- **Signals:** uncaught errors and unhandled rejections, `console.warn` and `console.error`, and failed `fetch` and XHR requests (method, path, status). Up to 50 are kept while idle; the ones from the last 30 seconds are sent when a session starts.

Before a session, the SDK only sends `hello`: app name, page URL without query, framework, project root and git branch.

## Privacy

- Never sends input values, passwords, text inside inputs or editable content, query strings or fragments, cookies, storage, or request and response bodies.
- Component props are not sent. With `props: "safe"`, it sends up to 20 primitive props, cuts strings to 64 characters, and redacts `value`, `defaultValue` and keys that look like passwords, secrets, tokens, keys, auth, cards or SSNs.
- Logged objects are reduced to their keys.
- The page listens for pointer events only while a session is active. Error, console and network capture runs from page load so that a recent error can be attached when you start scouting.
- The bridge token is written into the dev page. Anyone who can open your dev server can read it, but the bridge only accepts connections from this Mac.

## Limitations

- Cross-origin iframes are opaque. A cross-origin frame that runs its own SDK connects separately.
- Canvas and WebGL apps report only the canvas element.
- Closed shadow roots report their host element.
- Chrome's Local Network Access rules block the bridge connection from pages that are not served from a loopback address (for example a LAN IP or a tailnet name) unless the user allows it. `localhost`, `127.0.0.1` and `*.localhost` (portless) work.
- Browser zoom is estimated from pointer movement, and pinch zoom is ignored, so `viewport` can be slightly off until the pointer has moved.
- React Server Components are untested (there is no Next adapter yet).
- Only Vite has an adapter so far. Next, Svelte, Vue and TanStack Start adapters are not done.

## Develop

```bash
cd sdk/web
pnpm install
pnpm build        # builds the packages and prints the bundle sizes
pnpm typecheck
pnpm e2e          # builds, then runs the end-to-end check
```

`pnpm e2e` starts a mock bridge on port 47819 (`SCOUT_E2E_PORT` changes it), points the fixture at it with a temporary `bridge.json`, drives `fixtures/react-vite` in headless Chromium with Playwright, prints a PASS/FAIL table and exits non-zero on failure. It never connects to a running Scout. It also runs `vite build` and checks that the output contains no Scout code.

Try the fixture by hand with the mock bridge:

```bash
node scripts/mock-bridge.mjs --port 47819 --token dev --bridge-file /tmp/scout-bridge.json
# in another terminal
cd fixtures/react-vite && SCOUT_BRIDGE_FILE=/tmp/scout-bridge.json pnpm dev
```

Type `session on`, `aim on`, `pin`, `highlight <selector> flare` or a raw JSON message into the mock bridge. It logs every frame as JSON lines.

### Canvas game fixture and task proof

Run `pnpm run e2e` to drive `fixtures/react-vite/game.html` against the mock bridge. It verifies the named entity pin, pin/task-close snapshots, oversized-save omission, perf signals and idle privacy, and writes `.audit/game` at the repo root (including a screenshot and the received bridge messages).

To run the actual Swift task composer against that captured game state, without launching Scout:

```sh
swift build
swiftc -I .build/debug/Modules sdk/web/scripts/game-task-proof.swift mac/Scout/Bridge/BridgeMessages.swift mac/Scout/Delivery/TaskComposer.swift .build/debug/ScoutCore.build/*.swift.o -o .audit/game-proof
.audit/game-proof "$PWD/.audit/game"
```

This produces `.audit/game/session/snippets/game-pin/{game-state.json,save.json,task.md,message.txt,snippet.json}`. It exercises the native game-state parser and task serialization only; it does not replace native recording and delivery verification on a test Mac.
