# Scout: design language

Scout's look is called **Signal**: a recording instrument built for keyboard use. Surfaces are solid, tight and high-contrast, in light and dark. One ember-coral color means "live" or "do it now". Everything else is ink and neutrals.

Code: `mac/Scout/Design/` (`Palette`, `Typography`, `Components`, `UIScale`, `Motion`, `ScoutMark`).

## Icon and mark

The app icon is a telescope seen end-on: you look into the barrel, and its lens glows ember-coral inside a dark glass slab. It shares an icon style with Apiary, an agent workspace app, and Honeybee, an agent-session tool. Apiary uses an amber hexagon and Honeybee uses stacked glass plates. All three use a dark rounded square, a beveled edge, a bottom band and light from within; Scout uses a coral lens.

- Rendered with the family's WebGL2 shader, `script/logo-signal/` (concept `C==16`, end-on variant `TV 3`; parameters in `final-takes.json`). See its README to re-render. Grid: an 824×824 body on a 1024 canvas, continuous-corner squircle, shadow inside the margin.
- The telescope reads as light, not as a drawing: the barrel rim is a soft glowing ring that is brightest on the side the lens leans toward, a fainter inner ring sits between rim and lens, and the lens is the one hot point. The rings and the lens sit slightly off centre, so the barrel seems to run back into the glass.
- 16 and 32 px are tuned by hand: the rim and lens are snapped to whole pixels, with a dark gap between them, no bevel and stronger contrast.
- The menu bar glyph is the same end-on telescope as a template image: a soft halo, a rim ring and a solid lens dot (black, adapts to the menu bar). It turns coral while recording. When an update is ready it gets a small dot at the top right, cut out of the rim and in the glyph's own ink, never a second color; the panel then shows a green status dot with "Update available" or "Restart to update" in place of Check for Updates….
- In the app, `ScoutMark` draws the same end-on telescope in SwiftUI: a soft glow, a rim ring lit toward the lens (`RimLight`), a faint inner ring and a warm lens (`LensFill`) set slightly off centre. Below 40 pt it drops the inner ring, as the 16 and 32 px icons do. Its `level` (0–3) dims or brightens it, for example one step per granted permission during onboarding, and it pulses while Scout is ready or recording.

Draw the telescope as light inside the glass: a filled glowing lens and soft rings. A thin luminous outline of a telescope reads as a neon sign or line art and breaks the family.

## Color

Every token is dynamic: it resolves per appearance. The Appearance setting (System, Light, Dark) picks the appearance; `--appearance=` overrides it for a run.

| Token | Light | Dark | Use |
|---|---|---|---|
| `canvas` | `#F6F6F4` | `#0A0A0C` | Window background |
| `surface` | `#FFFFFF` | `#141417` | Cards, panels, bars |
| `raised` | `#EEEEEB` | `#1E1E22` | Segmented track, chips, idle timer |
| `sunken` | `#E9E9E6` | `#060608` | Timeline well, code |
| `hud` | `#FFFFFF` | `#111113` | Recording bar, snippet stack, settings guide |
| `text` | `#0B0B0D` | `#F6F6F8` | Primary text |
| `textSecondary` | `#45454D` | `#B4B4BD` | Secondary text |
| `textTertiary` | `#63636C` | `#8C8C96` | Meta |
| `textQuaternary` | `#9C9CA3` | `#55555D` | Disabled only |
| `hairline` | `#E0E0DC` | `#26262B` | Dividers |
| `stroke` | `#C9C9C4` | `#3A3A41` | Borders |
| `accent` (`recording`) | `#F0482A` | `#FF5A3C` | Live, and the one primary action |
| `accentText` | `#C23113` | `#FF7A5E` | Coral as text or icon |
| `onAccent` | `#0B0B0D` | `#0B0B0D` | Labels on coral |
| `ink` / `onInk` | `#1C1C1E` / `#FFFFFF` | `#F2F2F4` / `#0B0B0D` | Selection, Finish, play |
| `positive` | `#0E7D3A` | `#3DDC84` | Sent, switches on |
| `caution` / `cautionFill` / `onCaution` | `#8A5300` / `#F5A524` / `#1A1300` | `#FFB224` / `#FFB224` / `#0B0B0D` | Needs a destination |
| `negative` / `negativeFill` | `#C81E44` / `#C8102E` | `#FF4F6E` / `#C8102E` | Discard, failures |
| `fill` / `fillRaised` / `fillStrong` | ink at 4 / 7 / 12 % | white at 5 / 9 / 15 % | Overlays, hover, pressed |

Contrast (WCAG 2.x): every text pair passes AA (4.5:1); disabled text is exempt. Body text on canvas or surface is 17–20:1, `textTertiary` is at least 5.5:1, `onAccent` on `accent` is 5.3 (light) and 6.4 (dark), `accentText` on surface is 5.6 and 7.2, `onCaution` on `cautionFill` is 9.1 and 10.9, white on `negativeFill` is 5.9. The token values above and `mac/Scout/Design/Palette.swift` define the color pairs.

Rules:

1. **Coral means live or now.** The recording block, the capture outline, the aim outline and chip, pins and the one primary button per view. Never selection, links, eyebrows or decoration.
2. **Selection is ink.** Selected tabs, segments, tasks and the play button are `ink` with `onInk` labels.
3. **State has one color each.** Amber: needs a destination (`cautionFill` for the action that fixes it). Green: sent. Crimson: discard and failures. State appears as a rail, tag, dot or filled action, always with a text label.
4. **Solid, not glass.** Surfaces are opaque tokens with a 1 pt `stroke` or `hairline`. Shadows are small and neutral. No colored glows outside the icon and mark.
5. **Shortcuts are visible.** Actions with a shortcut show it as a keycap (`KeyHint`). Keycaps on coral or ink buttons are dark and emphasized.

## Type

System fonts only (SF Pro, SF Mono). Numbers that change use monospaced digits so they don't jitter.

| Style | Spec | Use |
|---|---|---|
| `display` | SF Pro Heavy 34, condensed; onboarding Welcome 60, Ready 44, tracking −1.2 to −1.8 | Onboarding heroes |
| Step title | Heavy 30, tracking −0.6 | Onboarding steps |
| `title` | Bold 22 | Window titles |
| `headline` | Semibold 13 | Card titles |
| `body` | Regular 13 (onboarding message 15) | Body |
| `callout` | Regular 12 | Secondary body, transcript in the bar |
| `caption` | Medium 11 | Meta |
| `label` | Bold 10, uppercase, tracking 0.9 | Eyebrows, state tags |
| `numeric` | Semibold 12, monospaced digits | Timers, counts, step numbers |
| `key` | Semibold 10.5, monospaced digits, tracking 0.6 (12.5 in Settings) | Keycaps |
| `mono` | SF Mono Medium 11.5 | Paths, URLs, source locations |
| `transcript` | Semibold 22 | Live speech in onboarding |

## Shape and size

- Radii (`Radius`): tag 3, key 4, control 6, card 8, panel 10. The recording bar uses 12 on its bottom corners only.
- Controls are 28 pt high in the bar and 24–28 pt elsewhere.
- Every surface scales with the UI size setting (`scaledToUISize()`): Small 0.86, Default 1, Large 1.15, Extra large 1.25. Small keeps controls at 24 pt or more.

## The recording bar

While recording, the bar hangs from the top centre of the captured display like a notch: it starts at the screen's top edge (`NSScreen.frame`, not `visibleFrame`) and draws over the menu bar, top corners flush with the bezel, bottom corners rounded. Its window level (just above `CGWindowLevelForKey(.overlayWindow)`) is far above the menu bar (`.mainMenu`) and status items (`.statusBar`), and above Scout's capture frame. On a MacBook with a notch it wraps around the hardware notch (`NotchGeometry`, from `safeAreaInsets` and the auxiliary top areas): centred on the notch, taller by the notch's height, with the controls row directly under it, so no control is ever hidden. The band beside the notch is the bar's own fill, so in dark mode the notch and bar read as one shape. It moves only when the capture moves to another display. It is not draggable.

The layout never shifts. Every control has a fixed slot, from left to right: timer (coral while recording), voice level, transcript, `Task N · Next` (manual mode only), capture scope, Discard, Finish. The transcript and scope labels truncate inside their slots; the transcript fades in at its left edge. The Discard question replaces the transcript, task and scope slots in place, and Discard itself turns crimson in its own slot. Hover and press change only color. The bar's width is fixed for a given UI size.

## Motion

| Token | Spring | Use |
|---|---|---|
| `snappy` | response 0.32, damping 0.86 | Presses, toggles, hover |
| `smooth` | 0.55, 0.9 | Layout and color changes |
| `bouncy` | 0.45, 0.62 | Success moments: checks, pins, the mark lighting up |
| `step` | 0.6, 0.88 | Onboarding step transitions |

Delight is kept for real events: a permission granted, a pin dropped, a task delivered. Reduce Motion replaces movement with fades and stops the mark's pulse.

## Copy

Short, direct, second person. Say what happens, not what the feature is called: "Scout hears you", "Discard this recording?", "2 need a destination". Avoid internal terms such as "packet" or "capture mode" in the UI.

## Rendering the UI offscreen

`--design-gallery=<dir>` added to a `--simulate-session` run renders every surface with `ImageRenderer` in light and dark at all four sizes, plus a frame sequence of the recording bar with `bar-frames.json` (window frame and every control's position per frame). Use it to review design changes when the screen can't be captured.

`--panel-gallery=<dir>` renders the menu bar panel alone from fixed states (empty with hive not responding and updates not set up, five long recent tasks with a walkthrough, recording, an update available, an update ready to restart, and an update held during a recording), plus the menu bar glyph with and without the update dot (`menubar-*.png`), in light and dark at all four sizes, then quits. It needs no session and no permissions.

`--engine-gallery=<dir>` renders the onboarding Transcriber step (full window) and the Settings → Voice pane in every Whisper model state (offer, downloading, checking, preparing, installed, ready, paused, failed, remove confirmation) in light and dark at Default and Extra large, then quits. It skips the hotkey, the bridge and pruning, and never downloads.

`--review-gallery=<dir>` renders the review window from fixture sessions (1, 3 and 8 tasks with every delivery state and long titles, a five-minute session, leftover speech only, and no session) in light and dark at all four sizes, at the default and the minimum window size, then hosts the 3-task fixture in a live window and saves frames after split, join, delete, undo and include, with `live-log.txt`. It skips the global hotkey, the bridge and session pruning, so it can run beside an everyday Scout.
