# Scout: experience

This is how Scout looks and behaves from the user's side. Visual rules are in [design-language.md](design-language.md).

## Surfaces

| Surface | What it is | When it shows |
|---|---|---|
| Onboarding window | One 940×640 window, dark, full-bleed | First launch, or from the menu bar via "Setup guide" |
| Menu bar item | Pointer-and-signal glyph. Tinted flare while scouting | Always |
| Menu bar panel | Start/stop, recent tasks, integration status | Click on the menu bar item |
| Scouting pill | Floating glass capsule at the top of the active screen | While scouting |
| Snippet stack | Column of task cards on the right edge | Once the first snippet closes, until everything is sent or dismissed |
| Aim overlay | Transparent full-screen layer that highlights the element under the pointer | While the aim key is held during scouting |
| Settings guide | Small floating card beside System Settings | While the user is granting a permission |

Scout is a menu bar app (`LSUIElement`). It becomes a regular app with a Dock icon only while the onboarding window is open, so the window can be found with `⌘Tab` during setup.

## Onboarding

Onboarding is six steps. Every step can be revisited, and progress is saved, so a relaunch (which Screen Recording requires) returns to the same step.

1. **Welcome.** The Scout mark draws in: pointer first, then the three signal arcs one by one. One sentence explains the product, with one button: *Set up Scout*. A privacy line under it: "Nothing leaves this Mac until you send it."
2. **Access.** Three permission rows: Screen Recording, Microphone, Accessibility. Each row shows its live state and one action:
   - *Allow* triggers the system request.
   - Once requested, the row shows *Waiting* and a *Open Settings* button. Scout opens the exact pane in System Settings.
   - A **settings guide** card attaches to the side of the System Settings window and follows it as it moves. It shows the Scout icon (which can be dragged into the list) and an animated switch. When macOS reports the grant, the card turns into a check and Scout comes back to the front by itself.
   - Screen Recording only takes effect after a relaunch. When the user returns from Settings without the grant showing, the row offers *Relaunch*. Scout quits, reopens, and resumes on this step.
   - The Scout mark on the left lights one arc per granted permission. With all three granted, the mark pulses and *Continue* turns on. *Skip for now* is always available so nobody gets stuck.
3. **Voice.** Scout starts listening immediately. If needed it first downloads the on-device speech model, showing progress. The user's words appear large as they speak: finalized words in white, words still being decided in grey. After four words: "Scout hears you."
4. **Point.** A practice page (a fake checkout form) teaches aiming. Holding `⌥` highlights the element under the pointer with its role and label. Clicking pins it; a flare marker drops with a ripple, and the pin appears in a list with its (sample) source location. The same step shows the global shortcut and lets the user change it.
5. **Agents.** Scout checks for hive and Apiary live and shows the most recently active sessions. The user picks where tasks go:
   - **Match project** (default): send to the session already working in the app's repo, or start one.
   - **New session**: start a fresh session for every task.
   - **Ask me**: choose a session per task.

   Without hive, tasks go to the clipboard and a folder.
6. **Ready.** The complete mark with expanding rings, the shortcut as large keycaps, an *Open at login* switch, and *Start using Scout*. Closing the window switches Scout back to a menu bar app.

## Scouting

**Start.** Press `⌃⌥S` from any app, or click *Start scouting* in the menu bar panel. The pill slides down from the top of the screen under the pointer. Nothing else changes: no mode picker, no region to draw.

**The pill** (about 420×44 pt, glass capsule):

```
 ● 0:42  ▂▅▇▃▁  …and the total should be bold too            3   ■
```

From left to right: recording dot and elapsed time, voice level, the last words heard (unfinished words in grey), the number of snippets so far, and a stop button. The pill never takes focus and is excluded from the recording. It can be dragged anywhere.

**Talking.** The user talks about whatever they are looking at. Scout splits the stream into snippets in the background (see [breakpoints.md](breakpoints.md)). When a snippet closes, its card slides into the snippet stack.

**Pointing.** There are three levels:

- **Hover.** Scout samples the element under the pointer about four times a second. An element the pointer rests on for 600 ms or more is attached to the current snippet, weighted by how long the pointer stayed there.
- **Aim and pin.** Hold `⌥` for 200 ms and a beam-colored outline follows the element under the pointer, with a label chip (`Button "Pay now"`, plus `Checkout.tsx:88` when an SDK is present). Clicking pins the element. The click goes to Scout, not to the app. Releasing `⌥` ends aiming. A key pressed while `⌥` is held cancels aiming, so typing `⌥`-characters on non-US layouts keeps working.
- **Region.** Holding `⌥` and dragging pins a rectangle instead of an element.

**Voice commands.** Spoken phrases act as controls and are removed from the task text:
- "new task" or "next task": split now.
- "scratch that": discard the current snippet.
- "send it": close and send the current snippet right away.

**Stop.** Press the shortcut again or click ■. The open snippet closes, the pill retracts, and the stack stays until every card is sent or dismissed.

## The snippet stack

Each card holds one task:

```
┌──────────────────────────────────────┐
│ ◉ Safari · /checkout          0:12   │
│ Pay now button is too small          │
│ "The pay now button is way too small │
│  and it's grey, it looks disabled…"  │
│ [Button "Pay now"] [Checkout.tsx:88] │
│ → web-shop · claude         Sending… │
└──────────────────────────────────────┘
```

- **Title.** The first clause of the transcript right away, replaced by a short generated title when it is ready (on-device FoundationModels).
- **Destination chip.** Where the task will go. Click to change: a list of hive sessions filtered to the project, plus *New session* and *Clipboard*.
- **Send.** With auto-send on, a 3-second ring counts down before sending and a click cancels it. With auto-send off, `⌘↩` sends the focused card and `⌥⌘↩` sends all.
- **Fix the split.** Hovering a card shows *Merge with previous*, *Split at…* (a transcript view with a cut cursor), and *Delete*. These corrections are logged and used to tune the splitter.
- After sending, the card shrinks to one line with a check and a link that opens the session in Apiary (or its hive transcript).

## What a task contains

Every sent task has a Markdown body, attachments on disk, and a structured JSON manifest. The body looks like this:

```markdown
## Pay now button is too small

> The pay now button is way too small and it's grey, it looks disabled. Make it the primary color and full width on mobile.

**Where:** Safari · http://localhost:3000/checkout · repo `~/Projects/acme/web` (branch `main`)
**Pointed at:** Button "Pay now" · `src/checkout/Checkout.tsx:88` · selector `[data-testid=pay-now]`

[Attached video: /…/snippet-0003/clip.mp4]
[Attached image: /…/snippet-0003/pin-1.png]
[Attached file: /…/snippet-0003/snippet.json]
```

The attachment lines follow Apiary's convention, so the task renders the same in hive and in Apiary.

## Settings

- **General:** shortcut, aim key (`⌥` by default, or `fn`), open at login, pill position.
- **Voice:** language (defaults to the system language, falls back to English), input device, voice commands on/off.
- **Agents:** routing mode, default agent for new sessions (claude, codex, …), auto-send and its delay, project overrides (app or URL pattern → repo).
- **Privacy:** which attachments to include (clip, pin screenshots, full frames), apps never to capture (password managers are excluded by default), redaction of on-screen text in screenshots.
- **SDKs:** bridge status, connected apps, pairing token, SDK install snippets.

## Menu bar panel

A 320 pt panel with: status line, a large *Start scouting* button with the shortcut, the last five tasks with their delivery state, hive and Apiary status badges, *Setup guide*, and *Quit*.
