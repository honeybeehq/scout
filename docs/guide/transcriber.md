# Choosing a transcriber

Scout always uses Apple's built-in transcriber to show your words live while you talk. After you stop, it transcribes the whole recording again with the transcriber you chose. Both run on your Mac.

| | Apple | Whisper |
|---|---|---|
| Name | Built-in Apple transcriber | Whisper large-v3-turbo, on device |
| Download | Nothing to download | About 650 MB, once |
| Live words | Yes | Apple still shows the live words |
| After you stop | Apple writes the transcript | Whisper writes the whole transcript again |

Scout uses Apple until the Whisper model is installed.

## In setup

The *Transcriber* step shows both side by side. *Use Apple* keeps Apple. *Download and install* selects Whisper and starts the download; nothing downloads without that click. You can continue setup while the download and preparation carry on in the background.

## In Settings

Settings → Voice → *Transcribe with* switches between Apple and Whisper. The *Whisper model* row shows the model's state:

- *Not installed* with *Download*.
- Download progress with *Cancel*. A cancelled download keeps its progress and offers *Resume*.
- A file check, then *Preparing model…* with a timer while Scout loads the model onto your Mac's Neural Engine. This takes longer the first time. You can close Settings meanwhile.
- *Installed*, with how much disk space it uses, and *Remove*. Scout asks before removing it. Removing the model switches back to Apple.
- If setup fails, the reason and *Try again*.

The model is downloaded once from Hugging Face, checked against pinned checksums before use, and kept on your Mac. Your audio never leaves it.
