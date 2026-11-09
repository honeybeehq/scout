# Scout: experience

This is how Scout looks and behaves from the user's side. Visual rules are in [design-language.md](design-language.md).

## Surfaces

| Surface | What it is | When it shows |
|---|---|---|
| Onboarding window | One 940×640 window, light or dark, full-bleed | First launch, or from the menu bar via "Setup guide" |
| Menu bar item | The Signal beam as a template glyph. Coral while scouting | Always |
| Menu bar panel | Start/stop, recent tasks, integration status | Click on the menu bar item |
| Recording bar (pill) | Solid bar hanging from the top centre of the captured display like a notch | While scouting |
| Capture frame | Accent outline around the captured area, with the rest of the screen dimmed, plus pins and ink | While scouting |
| Snippet stack | Column of task cards on the right edge | While scouting, from the first closed task |
| Review window | Full editor for a finished session: video, timeline, tasks, hand-off | After stopping (by default when a task is waiting), from the menu bar, or for any earlier session |
| Aim overlay | Transparent full-screen layer that highlights the element under the pointer | While the aim key is held during scouting |
| Settings guide | Small floating card beside System Settings | While the user is granting a permission |

Scout is a menu bar app (`LSUIElement`). It becomes a regular app with a Dock icon only while the onboarding window is open, so the window can be found with `⌘Tab` during setup.

## Onboarding

Onboarding is six steps. Every step can be revisited, and progress is saved, so a relaunch (which Screen Recording requires) returns to the same step.

1. **Welcome.** The Scout beam lights up in three steps. One sentence explains the product, with one button: *Set up Scout*. A privacy line under it: "Nothing leaves this Mac until you send it."
2. **Access.** Three permission rows: Screen Recording, Microphone, Accessibility. Each row shows its live state and one action:
   - *Allow* triggers the system request.
   - Once requested, the row shows *Waiting* and a *Open Settings* button. Scout opens the exact pane in System Settings.
   - A **settings guide** card attaches to the side of the System Settings window and follows it as it moves. It shows the Scout icon (which can be dragged into the list) and an animated switch. When macOS reports the grant, the card turns into a check and Scout comes back to the front by itself.
   - Screen Recording only takes effect after a relaunch. When the user returns from Settings without the grant showing, the row offers *Relaunch*. Scout quits, reopens, and resumes on this step.
   - The Scout beam on the left brightens one step per granted permission. With all three granted, the mark pulses and *Continue* turns on. *Skip for now* is always available so nobody gets stuck.
3. **Voice.** Scout starts listening immediately. If needed it first downloads the on-device speech model, showing progress. The user's words appear large as they speak: finalized words in white, words still being decided in grey. After four words: "Scout hears you."
4. **Point.** A practice page (a fake checkout form) teaches aiming. Holding `⌥` highlights the element under the pointer with its role and label. Clicking pins it; an accent marker drops with a ripple, and the pin appears in a list with its (sample) source location. The same step shows the global shortcut and lets the user change it.
5. **Agents.** Scout checks for hive and Apiary live and shows the most recently active sessions. The user picks where tasks go:
   - **Match project** (default): send to the session already working in the app's repo, or start one.
   - **New session**: start a fresh session for every task.
   - **Ask me**: choose a session per task.

   Without hive, tasks go to the clipboard and a folder.
6. **Ready.** The complete mark with expanding rings, the shortcut as large keycaps, an *Open at login* switch, and *Start using Scout*. Closing the window switches Scout back to a menu bar app.

## Scouting

**Start.** Press `⌃⌥S` from any app, or click *Start scouting* in the menu bar panel. Recording starts at once: the recording bar appears at the top of the display and the capture frame outlines what is under it. There is no mode picker and no window or screen to choose.

**The recording bar** (36 pt high, solid, top corners flush with the menu bar):

```
 ● 0:42  ▂▅▇▃▁  …and the total should be bold too   ⤢ Following · Safari — Checkout  ⌃⌥E   Discard   Finish ⌃⌥S
```

From left to right: recording dot and elapsed time, voice level, the last words heard (unfinished words in grey), what is being captured, Discard, and Finish. In manual mode a `Task 3 · Next ⌃⌥B` chip sits before the capture button.

The bar hangs from the top centre of the display being captured, directly under the menu bar. On a MacBook with a notch it sits under the notch and is centred on it, so it is never hidden. It stays put while the capture moves within a display and jumps to another display only when the capture does. Every control has a fixed slot, so nothing shifts when you hover, the transcript grows, the capture scope changes or the Discard question shows; long text truncates inside its slot. The bar never takes focus, is excluded from the recording, and can't be dragged.

**What is captured.** Scout follows the pointer. The captured area is the pane under the pointer, or the window when Scout can't tell panes apart, or the screen when no window is under it. Panes are split views found through Accessibility; inside Apiary they come from the Apiary bridge. At the shortcut, the frame starts on the window under the pointer and narrows to the pane as soon as it is known. When the pointer rests in another area for 250 ms, the frame glides there (120 ms) and the recording moves to that display if it changed. Outside the frame the screen is dimmed a little, so it is always clear what the recording is about.

**Expanding** is never required:
- When the pointer goes back and forth between two areas within 6 seconds, a dashed outline around both appears with "You keep moving between these. Keep both in view **⌃⌥E**" for 4 seconds. Scout never expands on its own.
- **⌃⌥E** keeps both recent areas in view. **⌃⌥E** again widens to the window, then to the screen, then back to following.
- **⌃⌥⇧E** goes back to following the pointer.
- The capture button in the pill does the same: click to widen, ⇧-click to follow.
- Both are global shortcuts in the same family as ⌃⌥S, registered only while recording, like ⌃⌥B and ⌃⌥X (discard). They need no permission. Scout takes no bare letter keys while recording, so typing in pages, lists and fields is never affected.

**Talking.** The user talks about whatever they are looking at. Scout splits the stream into snippets in the background (see [breakpoints.md](breakpoints.md)). When a snippet closes, its card slides into the snippet stack.

**Pointing.** There are three levels:

- **Hover.** Scout samples the element under the pointer about four times a second. An element the pointer rests on for 600 ms or more is attached to the current snippet, weighted by how long the pointer stayed there.
- **Aim and pin.** Hold `⌥` for 200 ms and an accent outline follows the element under the pointer, with a dark label chip (`Button "Pay now"`, plus `Checkout.tsx:88` when an SDK is present). Clicking pins the element and leaves a numbered badge on screen. The click goes to Scout, not to the app. Releasing `⌥` ends aiming. A key pressed while `⌥` is held cancels aiming, so typing `⌥`-characters on non-US layouts keeps working.
- **Draw.** Hold `⌥` and drag to draw in the accent color. A drag shorter than 6 pt is a pin. Strokes stay on screen until the session ends, and every point is recorded with its time.

**Voice commands.** Spoken phrases act as controls and are removed from the task text:
- "new task" or "next task": split now.
- "scratch that": discard the current snippet.
- "send it": close and send the current snippet right away.

**Discard.** *Discard* in the pill, or **⌃⌥X** (Caps+X with the Caps layer), asks "Discard this recording?" with *Keep* (esc) in place of the transcript, *Next* and the capture button, while *Discard* (⌃⌥X) turns crimson in its own slot; the question goes away by itself after 4 seconds, and recording carries on while it shows. Press ⌃⌥X again or click *Discard* to confirm; Esc or *Keep* cancels. ⌃⌥X is registered only while recording, and Esc only while the question shows. Discarding stops the recording, withdraws its waiting tasks and deletes everything the session wrote (video, signals, frames, the unfinished walkthrough). Nothing is sent, pasted or copied, and the clipboard stays as it was. Once a task from the recording has been sent (split into tasks with auto-send), Discard is off and ⌃⌥X beeps, as in the review: the sent task's files stay, and *Finish* keeps the rest.

**Stop.** Press the shortcut again or click *Finish*. The open snippet closes and the pill and frame disappear within about two frames (≈30 ms at 60 Hz). Nothing long runs on stop: transcription, splitting and segments were already streaming. If any task is still waiting (no destination, held, failed) or some speech isn't in any task, the review window opens. Otherwise the stack stays until its cards are sent or dismissed. Settings → General → "Open the review after scouting" switches between *Always*, *When tasks are waiting* and *Never*.

## Automatic and manual tasks

Two ways to decide where one task ends and the next begins. Pick one in the menu bar panel ("New task on: Auto / ⌃⌥B only") or in Settings → General. The choice is fixed per session.

- **Automatic** (default). The breakpoint engine cuts on pauses, cue phrases ("next thing", "also"), app/window/URL changes, a new target, topic shifts and screen changes. See [breakpoints.md](breakpoints.md).
- **Manual.** Nothing cuts except you: press **⌃⌥B** (Caps+B with the Caps layer), click *Next* in the pill, or say "new task" / "next task" as a sentence of its own. Pauses, app switches and long silences never cut, so one task can span apps and minutes. The pill shows `Task 3 · Next ⌃⌥B`.

⌃⌥B also works in automatic mode as a forced cut. It is registered only while scouting, so it never steals the chord otherwise.

## The review window

The review is where a finished recording becomes tasks you are happy to hand off.

```
┌───────────────────────────────────────────────────────────────────────────────────┐
│ ◉ Session review · 27 Sep 07:39 · 0:38 · Safari, Simulator   [Sessions] [Send all to…] [Send all ⌥⌘↩] │
├──────────────┬────────────────────────────────────┬───────────────────────────────┤
│ TASKS        │ ┌──────── session video ────────┐  │ TASK                          │
│ ① Pay now …  │ │                               │  │ Make the Pay now button …     │
│ ② Summary …  │ └───────────────────────────────┘  │ WHAT YOU SAID  (editable)     │
│ ③ Email …    │ ▶ 0:02.4 / 0:09.2  Loop  ✂ Split  │ POINTED AT  [PayButton ✕]     │
│ NOT IN A TASK│ PINS  [shot 1] [shot 2]            │ WHERE  Safari · /checkout     │
│ “That's it.” │                                    │                               │
│ [+ New] [Add to 3]                                │ Send to [web-shop · claude ▾] [Send task ⌘↩] │
├──────────────┴────────────────────────────────────┴───────────────────────────────┤
│ TIMELINE  Safari │ Simulator                          [✂ Split ⌘B][Join ⌘J][Delete ⌘⌫][Undo ⌘Z] │
│ [▓▓ 1 ▓▓▓][░░][▓▓ 2 ▓▓][░░░][▓▓▓ 3 ▓▓▓]   ← filmstrip, outlined tasks            │
│  ▂▂▂ ▂▂●   ▂▂▂▂  ┅┅┅    ← speech (dashed amber = not in a task), ● pins          │
│ 0:00      0:05      0:10      0:15 …                                               │
└───────────────────────────────────────────────────────────────────────────────────┘
```

- **One video, many tasks.** On stop, Scout joins the recording into `session.mp4` (a passthrough copy, no re-encode). The player shows the selected task and loops it; Space plays and pauses, ↑/↓ move between tasks.
- **The timeline is the editor.** Each task is an outlined region on a filmstrip of the session. Drag a task's edge to trim it or to move the boundary between two neighbouring tasks; edges snap to pauses in your speech (hold ⌥ to place them freely). ⌘B splits the selected task at the playhead, ⌘J joins it with the next one, ⌘⌫ deletes it, ⌘Z undoes. Sent tasks are locked.
- **Nothing you said gets lost.** Speech that isn't in any task shows as dashed amber on the timeline and under "Not in a task yet" in the list, with *New task* and *Add to task N* (the neighbouring task).
- **Edit before sending.** The title and the transcript are editable (an *Edited* badge and *Use the original* appear). Elements under "Pointed at" can be left out. Pins show the frame at the moment of the pin.
- **Hand-off.** Each task has its own destination and *Send task* (⌘↩). The header has *Send all to…* (one destination for every waiting task) and *Send all* (⌥⌘↩). Clips are cut from the task's current range when it is sent. Any edit puts a task that was counting down on hold.
- **Discard.** *Discard* in the player bar asks "Discard session?" and then deletes the session's video, signals and `review.json`, and its waiting tasks. A session with a sent task, or whose video is still being prepared, can't be discarded.
- **Earlier sessions.** *Sessions* lists recent sessions; the menu bar's *Review* opens the latest. Each session keeps its tasks and edits in `review.json` next to its recording.

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

- **General:** interface size (Small, Default, Large, Extra large; scales every Scout window, the pill and the stack, live), shortcut, aim key (`⌥` by default, or `fn`), open at login, appearance (System, Light, Dark).
- **Voice:** language (defaults to the system language, falls back to English), input device, voice commands on/off.
- **Agents:** routing mode, default agent for new sessions (claude, codex, …), auto-send and its delay, project overrides (app or URL pattern → repo).
- **Privacy:** which attachments to include (clip, pin screenshots, full frames), apps never to capture (password managers are excluded by default), redaction of on-screen text in screenshots.
- **SDKs:** bridge status, connected apps, pairing token, SDK install snippets.

## Menu bar panel

A 320 pt panel with: status line, a large *Start scouting* button with the shortcut, the last five tasks with their delivery state, hive and Apiary status badges, *Setup guide*, and *Quit*.
