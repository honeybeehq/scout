# Apiary bridge protocol

This optional local protocol lets Scout point into an Apiary window, list destinations and deliver walkthroughs. It is separate from the [SDK protocol](sdk-protocol.md), which lets an app report elements and runtime signals to Scout. The Scout client is [ApiaryBridge.swift](../mac/Scout/Integrations/ApiaryBridge.swift); delivery parameters are defined in [WalkthroughDelivery.swift](../mac/Scout/Delivery/WalkthroughDelivery.swift).

## Discovery and transport

Scout reads the discovery file at `--apiary-bridge=<file>`, `SCOUT_APIARY_BRIDGE`, `$APIARY_HOME_DIR/scout-bridge.json`, or `~/.apiary/scout-bridge.json`, in that order. Its JSON fields are:

| Field | Type | Meaning |
|---|---|---|
| `protocol` | string | `apiary-scout/1`; Scout accepts the `apiary-scout` protocol family |
| `socketPath` | string | Local Unix socket path |
| `token` | string | Authentication token; never log or commit its value |
| `pid` | integer | Running Apiary process ID |
| `instanceId` | string | Identifies this running instance |

The socket carries newline-delimited JSON. Scout sends `{"id":1,"verb":"<verb>","params":{}}`. The reply echoes `id` and has either `{"ok":true,"result":{}}` or `{"ok":false,"error":{"code":"<code>","message":"<message>"}}`. IDs increase per client; replies resolve the matching pending request.

## Requests and responses

The table describes fields consumed or sent by the current client. A target reference is `{kind,id}`. Target rows require string `kind` and `id`; optional strings include `sessionId`, `title`, `handle`, `subtitle`, `name`, `displayName`, `sessionTitle`, `championName`, `championId`, `workspaceId` and `workspaceName`, with optional boolean `focused` and `open`, and an optional `look` object. When `hello` lists `listTargets.context`, rows may also carry `bio` (a one-line purpose, at most 200 characters) and `lastActiveAt` (ISO 8601), and `listTargets` with `context:false` leaves both out. Scout reads them only when the capability is advertised and uses them only for the opt-in TypeSafe suggestion. Without them it falls back to the name, project, workspace and session title, and to hive's `lastOutputAt` for recency.

Kinds Scout groups are `champion` (or any row with `championName`), `project` and everything else as a session. A `project` row has `id` = the Project ID, `sessionId` = its orchestrator bee and `title` = the Project name. Scout delivers it with the reference `{kind:"project", id}`, which Apiary sends to the orchestrator; hive fallback sends to `sessionId`. Any other row with the same `sessionId`, from the bridge or hive, folds into the project row, so the orchestrator is listed once, under Project orchestrators.

`look` tells Scout how Apiary draws the row. Apiary is its only source; Scout never derives an avatar or a Project colour itself.

| Field | Type | Meaning |
|---|---|---|
| `key` | string, required | Cache key. It must change when the look changes |
| `image` | string | `data:image/png;base64,…` Champion avatar, 32 pt @2x (96 px), the full canvas with the overhang (ears, wings, ring, antennae) and the body centred |
| `tint` | string | `#rrggbb` for the light appearance |
| `tintDark` | string | `#rrggbb` for the dark appearance; `tint` is used when it is missing |
| `glyph` | string | Fallback initial, drawn in the tint when there is no image or icon |
| `iconSvg` | string | Project icon SVG drawn with `stroke="currentColor"` |
| `recipe` | object | Ignored by Scout |

Scout keeps decoded looks in memory by `key` and writes `image` and `iconSvg` to `<data root>/Looks/<hash of key>.png|.svg`, so a later row may send the `key` alone. Avatars are drawn 24 pt without a mask: Scout measures the opaque pixels, centres the canvas on the body and scales it so the body fills about 80 % of the frame unless the overhang would cross the frame edge. Icons are tinted per appearance by replacing `currentColor`, drawn 16 pt in a 24 pt tile with a stroke of at least 1.5 pt, and the tint is darkened (light) or lightened (dark) in small steps until it has 3:1 contrast with its tile. A row without a look gets a neutral monogram tile.

`hello` lists `listTargets.look` in `capabilities` when Apiary sends looks. The protocol stays `apiary-scout/1`; rows without `look` keep working.

| Verb | Parameters | Result used by Scout |
|---|---|---|
| `hello` | `protocol:"apiary-scout/1"`, discovery `token`, `client:{name:"Scout",version,bundleId,pid}` | `apiary:{instanceId}`, `capabilities:[string]`, `windows:[{bounds}]`; bounds are numeric `{x,y,w,h}` rectangles |
| `pointAt` | numeric `x`, `y`; string `reason`; `dom:true` | boolean `hit`, array `stack`, boolean `staleWindows` |
| `focusedChat` | `{}` | `target` row, or no target |
| `listTargets` | `limit:500` | `targets` array of rows |
| `deliver` | `deliveryId`, absolute `bundlePath`, `target:{kind,id}`, `mode:"paste"` or `"send"`, `urgency:"next"` | optional `target:{title}` and `messageId` |

`pointAt` coordinates come from the screen pointer. Scout preserves the returned stack on the recording. [ApiaryStack.swift](../Sources/ScoutCore/ApiaryStack.swift) defines how Scout reads identities and bounds from it.

For delivery, `bundlePath` is the walkthrough directory. The delivery ID is `scout:<walkthrough>:<kind>:<id>:<mode>`. Scout derives the message ID using UUID v5 with namespace `e0aaba76-1ff7-5558-a034-b585db29a50a`; if Apiary returns a different message ID, Scout rejects it. This keeps retries and hive fallback from creating duplicate messages.

Scout uses a 2-second initial handshake timeout, 30 ms for pointing (one 100 ms retry for a pin), 500 ms for focused-chat lookup, 1.5 seconds for target listing (Apiary answers within 1 second, or with `notReady` or `timeout`; Scout then lists hive sessions alone) and 3 seconds for delivery. The connection closes after 30 seconds idle. A missing or dead discovery process leaves the clipboard path available. For `noRenderer`, `notReady`, timeout or an unreachable bridge, send mode falls back to hive when a session ID is available; paste mode keeps the bundle on the clipboard. Other delivery refusals are shown to the user.
