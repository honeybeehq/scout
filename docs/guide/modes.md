# Walkthroughs and tasks

A recording can end in two ways.

| | Walkthrough | Tasks |
|---|---|---|
| Start it with | `⌃⌥S`, or *Start scouting* in the menu bar panel | *Record as tasks* in the menu bar panel |
| What you get | One bundle with the whole recording, split into a short list of asks | Separate tasks, each with its own clip, transcript and pins |
| Where it goes | You pick a destination when you finish, or it stays on the clipboard | Each task goes to its own destination; the review window helps you fix splits |

## Walkthroughs

A recording started with the shortcut ends as one walkthrough. It holds the transcript with word timings, key frames, the elements you pointed at, your drawings, how the captured area changed, a short list of asks and the video clip. Scout saves it under `~/Library/Application Support/Scout/walkthroughs` and puts its path on the clipboard, so you can paste it into Apiary with `⌘V`.

Scout splits what you said into asks by itself: requests, problems and pauses start a new one. Press `⌃⌥B` to start a new ask yourself. The bar shows "New ask", and what you say next begins the new ask.

When you finish, a sheet opens near the pointer with chats and agent sessions you can send to. Search it by name. Press `Enter` to paste into the chosen chat, `⌘↩` to send, or `Esc` to leave the walkthrough on the clipboard only. The menu bar panel keeps the last walkthrough with *Send…*, *Copy* and *Show in Finder*.

## Tasks

Click *Record as tasks* in the menu bar panel. Scout cuts what you say into tasks while you talk. Each task gets a title, the transcript, the elements you pointed at, runtime errors from the page when an SDK is present, a video clip and pin screenshots. As each task closes, its card slides into a stack on the right edge of the screen.

### Automatic or manual

Choose how a new task starts with *New task* in the menu bar panel, or in Settings → General → Tasks. The choice is fixed for each recording.

- **Automatic** (default). Scout starts a new task when you pause, move on, switch apps or point somewhere else. `⌃⌥B` forces a new task.
- **Manual.** Scout only starts a new task when you press `⌃⌥B`, click *Next* in the bar, or say "new task". Pauses and app switches never cut, so one task can span apps and minutes. The bar shows the task number and *Next*.

### When you finish

If any task is still waiting, or some of your speech isn't in any task, the [review window](review.md) opens. Change this in Settings → General → *Open the review after scouting*: *Always*, *When tasks are waiting* (default) or *Never*.
