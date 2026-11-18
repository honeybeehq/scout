# Install and permissions

Scout needs macOS 26 or later.

## Install

1. Download the latest Scout DMG from [GitHub Releases](https://github.com/honeybeehq/scout/releases/latest).
2. Open the DMG and drag **Scout** into **Applications**.
3. Open Scout from Applications. It lives in the menu bar and opens a setup window the first time.

Scout is a menu bar app. While the setup window is open it also shows in the Dock, so you can find the window with `⌘Tab`.

## Setup

Setup has seven steps: Welcome, Access, Voice, Transcriber, Point, Agents and Ready. Progress is saved, so a relaunch returns you to the same step. You can open setup again at any time from *Setup guide* in the menu bar panel.

- **Access** asks for the three permissions below.
- **Voice** listens to you once to check that speech recognition works on your Mac.
- **Transcriber** lets you choose Apple's built-in transcriber or download Whisper. See [Choosing a transcriber](transcriber.md).
- **Point** is a practice page where you hold `⌥` and click to pin an element. It also shows the global shortcut and lets you change it.
- **Agents** checks for hive and Apiary and lets you choose where tasks go. See [Sending tasks](sending.md).
- **Ready** shows your shortcut and an *Open at login* switch.

## Permissions

Setup asks for three permissions. You can skip them with *Skip for now* and grant them later from *Setup guide* in the menu bar panel.

| Permission | Why Scout needs it |
|---|---|
| **Microphone** | To hear what you say while you scout. Speech is transcribed on your Mac. |
| **Screen Recording** | To record the screen while you scout, so your recording comes with a clip and screenshots of what you were looking at. macOS asks you to reopen Scout after you switch this on; setup offers a *Relaunch* button and picks up where you left off. |
| **Accessibility** | To see which button, field or link is under the pointer, so you can hold `⌥` and click to pin it. |

For each permission, *Allow* asks macOS, and *Open Settings* opens the right pane in System Settings. While you are in System Settings, a small card sits beside the window and shows what to switch on. When macOS reports the permission as granted, Scout comes back to the front by itself.

When you scout in a browser, macOS may also ask whether Scout can control that browser. Scout uses this only to read the address of the page you're on, so your feedback lands in the right project.

Nothing leaves your Mac until you send it. See [Privacy](privacy.md).

## hive and Apiary are optional

Without them, each recording ends on the clipboard, ready to paste into any agent or chat. See [Sending tasks](sending.md).

## Updates

Scout checks for updates once a day and asks before it installs anything. See [Updates](updates.md).
