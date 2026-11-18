# Troubleshooting

## Scout doesn't record the screen

Screen Recording only takes effect after Scout reopens. Open *Setup guide* from the menu bar panel. If the Screen Recording row offers *Relaunch*, click it; Scout quits, reopens and returns to the same step.

## A permission is missing

Open *Setup guide* from the menu bar panel (it reads *Finish setup* until setup is done). Each permission row shows its live state and a button to fix it. See [Install and permissions](install.md).

## The browser address is missing from tasks

Scout reads the page address through macOS automation. If you declined when macOS asked, allow Scout to control that browser in System Settings → Privacy & Security → Automation.

## Pinning doesn't work

Pinning needs the Accessibility permission. Hold `⌥` while recording, wait for the outline, then click.

## `⌃⌥S` does nothing

Another app may use the same shortcut. Change Scout's shortcut in the *Point* step of the setup guide.

## A task says "Copied instead"

Scout couldn't reach hive or the session, so it put the task on the clipboard. Hover the task to see the reason. Make sure hive is running, then send the task again. It won't be delivered twice.

## A task says "Needs a destination"

With *Match project*, Scout couldn't tell which repo the app belongs to. This happens for native apps today. Pick a destination on the task, or choose *New session* or *Ask me* in Settings → Agents.

## Discard doesn't work and `⌃⌥X` beeps

A task from this recording has already been sent. Sent tasks can't be discarded; *Finish* keeps the rest.

## Whisper won't install

Settings → Voice shows the reason and *Try again*. A cancelled download keeps its progress and offers *Resume*. Scout uses Apple until Whisper is ready. See [Choosing a transcriber](transcriber.md).

## The transcript has wrong words

Edit the transcript in the [review window](review.md) before sending. You can also try the other transcriber.

## *Check for Updates…* is unavailable

It is off while you record and comes back when the recording ends. See [Updates](updates.md).
