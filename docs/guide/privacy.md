# Privacy

Nothing leaves your Mac until you send it.

## On your Mac

- **Speech.** Both transcribers, Apple and Whisper, run on your Mac. Your audio never leaves it.
- **Titles.** When Apple Intelligence is on, short task titles are written on your Mac.
- **Recordings.** Video, audio, transcripts and screenshots are saved under `~/Library/Application Support/Scout`. See [Debug data](debug-data.md) for what is in there.
- **Scout's own windows** are kept out of the recording.
- **Browser address.** When you scout in a browser, macOS may ask whether Scout can control it. Scout uses this only to read the address of the page you're on.
- **SDK bridge.** The bridge web SDKs talk to listens on `127.0.0.1` only, on your Mac.

## Deleting recordings

- *Discard* while recording (or `⌃⌥X` twice) deletes everything the recording wrote. Nothing is sent, pasted or copied, and the clipboard stays as it was.
- The trash button in the [review window](review.md) deletes a session that has no sent tasks.
- The release app moves old recordings to the Trash on its own: a session's video and audio after 7 days, and whole sessions after 14 days.

## What leaves your Mac, and when

- **When you send a task**, its text goes to the destination you chose: the clipboard, or an agent session through hive or Apiary. The text names the files of its clip and screenshots on your Mac, so the agent can open them. What the agent does with them depends on that agent. Turn off *Attach video clips* in Settings → Agents to leave clips out.
- **Update checks.** Scout asks GitHub once a day whether a new version exists. You can turn this off. See [Updates](updates.md).
- **Speech models.** During setup, macOS may download Apple's on-device speech model. The Whisper model downloads from Hugging Face only after you click *Download and install* or *Download*.
- **Linear.** If you connect Linear in Settings, Scout checks your API key with Linear and keeps it in your Mac's Keychain.

Scout's code makes no other network requests and contains no analytics.
