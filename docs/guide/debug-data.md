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

These files hold your recording: what was on your screen and what you said. Look through them before you share any of them.

The release app moves old recordings to the Trash on its own: a session's video and audio after 7 days, whole sessions after 14 days.

For the full layout, see [Architecture: storage](../architecture.md#storage).
