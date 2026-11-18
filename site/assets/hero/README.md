# Hero video

| File | What it is |
| --- | --- |
| `hero.mp4` | H.264 High, 1920×1080, 30 fps, AAC mono, faststart. About 26 s. |
| `hero.webm` | VP9 (two-pass, constant quality), Opus mono. The same edit. |
| `hero-poster.webp`, `hero-poster.jpg` | 1920×1080 frame at 3.0 s: the recording bar, and the aim outline with the chip `Link "Choose Household"` just before the pin. |

## What it shows

A real screen recording of a Mac mini test rig (macOS 26.4, 1920×1080 points at 2×). Safari shows Larder, a fictional demo site from `Fixtures/landing-demo-site/`, served on `127.0.0.1:8411`. Scout runs from this repo's Debug build with a separate bundle id (`com.trmdy.scout.dev.hero`) and a scratch data root, in dark appearance.

1. Scout starts recording as tasks. The recording bar hangs from the top of the screen.
2. The pointer moves to the Household plan's "Choose Household" link and pins it. Spoken: "Make this button the primary color, and make it full width."
3. The pointer pins the headline. Spoken: "This headline is far too long. Make it say: Plan dinner together."
4. Recording stops. The review window shows two tasks, each with its pin, clip and transcript.
5. *Copy all* puts both tasks on the clipboard.
6. A coding agent changed the site; Safari comes back to the front and the page live-reloads with both changes.

Everything on screen is real Scout UI and a real result. The speech is `say` output fed to Scout as its microphone input (`--hero-audio`), and Scout transcribed it with Apple's on-device transcriber. Captions are burned in afterwards; quoted captions are the spoken words.

What is driven by code instead of a person: the pointer moves with `CGWarpMouseCursorPosition`, pins go through Scout's own aim handler (`AimController.simulate`, as in `--capture-ux-demo`), recording starts and stops through the same calls as *Record as tasks* and Finish, and *Copy all* calls the same action as the button. No keyboard or mouse events are posted. Destinations are set to Clipboard because the rig has no agent installed for hive to start. Before recording, the demo dismisses Safari's "Make Safari your default browser?" banner with an Accessibility press.

The edit leaves out the minute while the agent worked and trims the ends of both recordings, joined with short crossfades. The review part plays at 1.3× speed.

## How the change was applied

After *Copy all*, Scout wrote the clipboard text to `tasks.txt` and waited. That text went to a fresh Claude agent (Claude Opus 5.5, a new session with no other context) together with a copy of the site repo. The agent's prompt was the task text verbatim plus where the repo is checked out. It edited `index.html` and `styles.css`. Those two files were copied into the recording's `patch/files/`; Scout then started the second recording, raised Safari and wrote the files into the served site, and the page's `livereload.js` reloaded it.

The tasks as delivered (the clip and image paths point into the scratch data root):

```
## Make this button the primary color, and make it full width
> Make this button the primary color, and make it full width.
**Where:** Safari · http://127.0.0.1:8411/ · repo `/private/tmp/scout-hero/site` (branch `main`)
**Pointed at:** Link “Choose Household” · in Article “Household”

## This headline is far too long
> This headline is far too long. Make it say, Plan dinner together.
**Where:** Safari · http://127.0.0.1:8411/ · repo `/private/tmp/scout-hero/site` (branch `main`)
**Pointed at:** Text “Plan every meal of the week with everyone who eats them, in one shared list that never gets lost” · in Heading “Plan every meal of the week …”
```

The agent's change, as recorded in the run (`site.diff`):

```diff
-        <h1>Plan every meal of the week with everyone who eats them, in one shared list that never gets lost</h1>
+        <h1>Plan dinner together</h1>
-        <a class="button ghost" href="#">Choose Household</a>
+        <a class="button primary full" href="#">Choose Household</a>
+.button.full { align-self: stretch; width: 100%; }
```

## Provenance

- Recorded from commit `f14e515` (branch `hero-video`), Debug build, ad-hoc signed, on 2026-11-18.
- Recording: `script/record-hero.sh`, which runs Scout with `--hero-demo` (`mac/Scout/App/HeroDemo.swift`). Scout records the screen itself with `screencapture -v -C` in two fixed-length parts.
- Edit and encode: `script/render-hero.py` with ffmpeg 7.1 (libx264, libvpx-vp9, libass, libwebp), on Linux. Captions use Liberation Sans.
- A Screen Sharing client was connected to the rig for the whole recording window (polled for an hour), so its menu bar icon is covered in the edit: `--mask 1584:0:46:28:1490` copies a 46×28 patch of empty menu bar from x=1490 over the icon. Nothing else is masked. The menu bar still shows the clock and the macOS screen-recording indicator.
- The video starts 0.35 s after recording began, so the recording bar is already on screen in the first frame.

## Re-record

On a Mac with Xcode, Screen Recording and Accessibility granted to the shell you run from (the binary is exec'd directly, so it inherits them), and not a Mac with a Scout install you care about:

1. Build Scout with a non-release bundle id, for example `xcodebuild … PRODUCT_BUNDLE_IDENTIFIER=com.trmdy.scout.dev.hero build`.
2. `script/record-hero.sh <path to Scout.app>`. It copies the fixture to `/tmp/scout-hero/site`, serves it, opens Safari, runs the demo, and restores the clipboard and the bundle's defaults at the end. Safari is quit only if the script started it.
3. When `/tmp/scout-hero/out/waiting-for-patch` appears, give `/tmp/scout-hero/out/tasks.txt` to a coding agent along with a copy of the site, put the files it changed in `/tmp/scout-hero/out/patch/files/`, and `touch /tmp/scout-hero/out/patch/ready`. Scout waits up to 45 minutes. (`--patch <dir>` stages a directory automatically, for rehearsals.)
4. Copy `/tmp/scout-hero/out` to a machine with ffmpeg and run `script/render-hero.py <out dir>` (add `--mask x:y:w:h:source_x` only if something on screen needs covering). It writes the four files here. `--draft` writes a quick preview only; `--font` and `--fontsdir` choose the caption font.
