# Sending tasks

Scout delivers recordings and tasks to coding agents. You can use the clipboard with any agent or chat; no other app is required.

## Clipboard

Without hive, each task is copied as text: the transcript, the elements you pointed at, and the paths of its clip and screenshots. Its folder is kept on disk. *Copy all* in the review window puts every waiting task on the clipboard at once, separated by `---`.

A walkthrough leaves its bundle path on the clipboard, so you can paste it into a compatible app such as Apiary. The recording stays on disk.

## hive

hive manages coding-agent sessions. When hive is running, Scout sends tasks straight to a session. Choose where tasks go in the *Agents* step of setup or in Settings → Agents:

- **Match project** (default): send to the agent already working in that app's repo. Start one if none is.
- **New session**: start a fresh agent session for every task.
- **Ask me**: pick a session for each task before it's sent.

Settings → Agents also has:

- **Agent for new sessions**: claude (default), codex, grok or kimi.
- **Send automatically**: on by default. Each task waits a moment (5 seconds by default, 1 to 30) so you can hold it or change where it goes. With it off, send a card with `⌘↩`, or all cards with `⌥⌘↩`.
- **Attach video clips**: on by default. The part of the recording each task covers.

Scout finds the repo behind an app from the [web SDK](../sdk-protocol.md), a nectar preview, or the process listening on a `localhost` port. It shows the project it found on the task, so a wrong guess is visible before sending. Native apps aren't matched to a repo yet; with *Match project* their tasks wait for you to pick a destination.

If a send fails, for example because hive stopped or the session is gone, Scout copies the task to the clipboard and marks it *Copied instead* with the reason. The task stays unsent, so you can send it again later. Sending the same task twice never delivers it twice.

## Apiary

Apiary is a desktop workspace for hive sessions, and Apiary panes are hive sessions, so tasks reach them through hive. Clips and images in a task show up in the Apiary conversation.

When you finish a walkthrough, the destination sheet lists Apiary chats and active hive sessions, grouped as the focused chat, Champions, Project orchestrators, sessions and *Clipboard only*. Type to filter every group at once; `Tab` jumps to the next group. `Enter` pastes the walkthrough into the chosen chat and `⌘↩` sends it. If you choose before the walkthrough is ready, the sheet shows "Sends when ready".

With *Suggest a target with TypeSafe* on (Settings → Agents, off by default), Scout asks TypeSafe which chat the recording belongs in as soon as you stop. A confident answer gets a *Suggested* badge and a "via TypeSafe" tag. If it arrives within about 300 ms of the sheet opening, and you haven't typed or moved yet, it is also selected, so `Enter` sends it. A later answer only highlights its row: your selection and the order of the rows stay as they are. When TypeSafe isn't sure, fails or is offline, the sheet is the normal list. The suggestion never sends anything by itself. The first time a recording finishes, the sheet offers *Suggest a target with TypeSafe?* with *Enable* and *Not now*. See [Privacy](privacy.md) for what is sent.

Apiary's *Record feedback* on a proof starts a Scout recording tied to that proof. When you finish, the walkthrough goes into that proof's review, and a line says "In the review: …". If Apiary refuses or isn't reachable, the walkthrough stays on the clipboard and the line says why.

## Linear

Coming. Settings → Linear lets you connect a personal API key and choose teams and projects, but Scout does not file Linear issues yet.
