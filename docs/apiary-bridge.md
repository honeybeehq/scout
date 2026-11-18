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

The table describes fields consumed or sent by the current client. A target reference is `{kind,id}`. Target rows require string `kind` and `id`; optional strings include `sessionId`, `title`, `handle`, `subtitle`, `name`, `displayName`, `sessionTitle`, `championName`, `championId`, `workspaceId` and `workspaceName`, with optional boolean `focused` and `open`.

| Verb | Parameters | Result used by Scout |
|---|---|---|
| `hello` | `protocol:"apiary-scout/1"`, discovery `token`, `client:{name:"Scout",version,bundleId,pid}` | `apiary:{instanceId}`, `capabilities:[string]`, `windows:[{bounds}]`; bounds are numeric `{x,y,w,h}` rectangles |
| `pointAt` | numeric `x`, `y`; string `reason`; `dom:true` | boolean `hit`, array `stack`, boolean `staleWindows` |
| `focusedChat` | `{}` | `target` row, or no target |
| `listTargets` | `limit:500` | `targets` array of rows |
| `deliver` | `deliveryId`, absolute `bundlePath`, `target:{kind,id}`, `mode:"paste"` or `"send"`, `urgency:"next"` | optional `target:{title}` and `messageId` |

`pointAt` coordinates come from the screen pointer. Scout preserves the returned stack on the recording. [ApiaryStack.swift](../Sources/ScoutCore/ApiaryStack.swift) defines how Scout reads identities and bounds from it.

For delivery, `bundlePath` is the walkthrough directory. The delivery ID is `scout:<walkthrough>:<kind>:<id>:<mode>`. Scout derives the message ID using UUID v5 with namespace `e0aaba76-1ff7-5558-a034-b585db29a50a`; if Apiary returns a different message ID, Scout rejects it. This keeps retries and hive fallback from creating duplicate messages.

Scout uses a 2-second initial handshake timeout, 30 ms for pointing (one 100 ms retry for a pin), 500 ms for focused-chat lookup, 800 ms for target listing and 3 seconds for delivery. The connection closes after 30 seconds idle. A missing or dead discovery process leaves the clipboard path available. For `noRenderer`, `notReady`, timeout or an unreachable bridge, send mode falls back to hive when a session ID is available; paste mode keeps the bundle on the clipboard. Other delivery refusals are shown to the user.
