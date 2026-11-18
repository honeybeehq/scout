# Product shots

Rendered at 2x from the app's offscreen galleries at commit `2b824ca` (Debug build, on a Mac mini test rig), then losslessly re-compressed. Each file exists as `-dark@2x.png` and `-light@2x.png`, at the Default interface size.

| File | Gallery argument | State |
| --- | --- | --- |
| `recording-bar-*` | `--simulate-session=<narration> --dry-run-delivery --simulate-review --design-gallery=<dir>` | `bar-standard-*-11-transcript-3.png`, the bar mid-recording with live transcript |
| `review-tasks-*` | `--review-gallery=<dir>` | `review-three-*-standard.png`, three tasks, task 2 selected |
| `review-walkthrough-*` | `--review-gallery=<dir>` | `review-walkthrough-*-standard.png`, five-minute session with six tasks |
| `transcriber-choice-*` | `--engine-gallery=<dir>` | `onboarding-1-offer-*-standard.png`, Apple or Whisper download |
| `transcriber-download-*` | `--engine-gallery=<dir>` | `onboarding-2-downloading-*-standard.png`, Whisper downloading |
| `menu-bar-panel-*` | `--panel-gallery=<dir>` | `panel-content-*-standard.png`, recent tasks and a walkthrough |

All content is gallery fixture data (acme-web, `/Users/dev/...`). The recording-bar narration is spoken with `say`; it needs three sentences so that a task closes during the recording, which triggers the bar capture.

## Re-render

On a Mac with Xcode and XcodeGen (not one with a Scout install you care about):

```bash
script/render-shots.py
```

This builds Scout into `build/ShotsDerivedData`, runs the four galleries into a temp dir and writes the files here. To only collect and compress gallery output that was rendered elsewhere (works on any machine with Python 3):

```bash
script/render-shots.py --from <dir with panel/ review/ engine/ design/>
```
