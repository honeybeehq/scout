# Scout glossary

Terms used in code, docs and UI. UI copy may use the plainer word in parentheses.

- **Session.** One continuous stretch of scouting, from pressing the shortcut to stopping. Has one clock.
- **SessionTime.** Seconds since the session started. Every timed value uses it.
- **Signal.** One timestamped observation fed to the segmenter: an utterance, a context change, a focus, a mark, a visual change, a command, or a clock tick. Sessions are stored as signal logs (`signals.jsonl`) and can be replayed.
- **Utterance.** A finalized piece of transcribed speech with its time range and optional word timings.
- **Context.** Where the user is: app, window title, location (URL or route), and project.
- **Project.** The source tree behind an app, identified by its root path and git branch.
- **Target.** An element or region the user referred to. Carries role, label, identifiers, frame, ancestry and, with an SDK, the component and source location.
- **Focus.** The pointer resting on a target for a while (passive pointing).
- **Mark (pin).** An explicit pin: the user held the aim key and clicked a target.
- **Aim.** The state while the aim key is held: Scout outlines the element under the pointer.
- **Breakpoint (cut).** A boundary between two snippets, with a score and the reasons for it.
- **Snippet (task).** The part of a session between two breakpoints. One piece of feedback, and one agent task.
- **Clip.** The video for a snippet, cut from the session's media segments.
- **Destination.** Where a snippet is delivered: an existing hive session, a new session, or the clipboard.
- **Route (routing).** The rule for choosing a destination: match project, new session, or ask.
- **Bridge.** Scout's local server that SDKs connect to.
- **SDK.** A library inside the user's app that reports elements, routes and source locations over the bridge.
- **Settings guide.** The floating card Scout shows beside System Settings while a permission is being granted.
