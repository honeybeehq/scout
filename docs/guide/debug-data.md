# Debug data

Scout has no built-in way to collect or send debug data yet. Everything it records stays in files on your Mac, which you can look at yourself.

## Where to find it

- **Sessions** (recordings made with *Record as tasks*): Settings → General → *Sessions folder* → *Show*.
- **The last walkthrough**: *Show in Finder* in the menu bar panel.

Both live under `~/Library/Application Support/Scout`:

```
~/Library/Application Support/Scout/
  Sessions/<date>/<session-id>/
    session.json      start time, displays, app version, settings
    signals.jsonl     everything Scout noticed during the session, in order
    audio.wav         the microphone recording
    transcript.json   the final transcript
    session.mp4       the whole recording
    review.json       tasks, titles, edits and delivery state
    snippets/<id>/    one folder per task: task.md, clip.mp4, pin screenshots
  walkthroughs/<id>/
    walkthrough.json  transcript, frames, pointers, drawings, asks
    walkthrough.md    the text an agent receives
    frames/           key frames
    clip.mp4          the recording
```

With *Keep debug data* on (Settings → App), each recording also gets a `debug/` folder in its session folder. Its `suggestions.jsonl` has one line for every time the destination sheet opened. Each line records how long the TypeSafe suggestion took, both from the request and from the sheet opening, and what happened to it: `preselected`, `highlighted-late`, `silent-not-confident`, `silent-error` or `off`. Rare cases are `silent-no-answer` (the sheet closed first), `silent-not-requested` (no transcript, or fewer than two chats) and `silent-filtered` (a confident pick hidden by your search). A line also holds Jev's top probability, its any-fits value, and the kind and list position of its top pick. It never holds the transcript, a URL, a page title, a chat name or the key. With the setting off, nothing is written.

These files hold your recording: what was on your screen and what you said. Look through them before you share any of them.

The release app moves old recordings to the Trash on its own: a session's video and audio after 7 days, whole sessions after 14 days.

For the full layout, see [Architecture: storage](../architecture.md#storage).
