# Scout: design language

Scout looks like a night-time instrument: deep ink and indigo, one warm signal color, glass on top. It is built on macOS 26 Liquid Glass and does not borrow from Syn.

Code: `mac/Scout/Design/`.

## Mark

A pointer with three signal arcs coming from its tip: *point* and *talk* in one glyph (`ScoutMark.swift`).

- The arcs double as a progress display, and they are the one place the accent appears as brand rather than as state. During onboarding, one arc lights per granted permission, and a pulse runs through lit arcs while Scout is ready or scouting.
- The menu bar icon is the same mark rendered as a template image. It takes the accent color while scouting.
- The app icon (`script/render-app-icon.sh`) renders the mark on an ink-to-indigo squircle with an accent glow in the lower-right corner.

## Color

Scout is a dark, neutral interface with one accent. Color is rare on purpose, so when it appears it means something.

| Token | Hex | Use |
|---|---|---|
| `ink` | `#07080D` | Deepest background |
| `night` | `#0E1020` | Panels, glass tint |
| `indigo` | `#1C2156` | Aurora field |
| `plum` | `#3B1650` | Aurora field |
| `accent` | `#FF6A3D` | The only accent (see rules) |
| `accentGradient` | `#FF8152 → #FF6A3D` | Primary button fill only |
| `positive` | `#5CCF9E` | Status dot only |
| `caution` | `#E9AE57` | Status dot only |
| `negative` | `#EE6078` | Status dot or small warning glyph only |

Neutrals do everything else: text in white at 100 / 64 / 40 / 24 %, fills in white at 5 / 9 / 14 %, hairlines at 8 %, strokes at 14 %.

Rules:

1. **One accent, three jobs.** The accent marks the primary action (one per view), live capture (the recording dot, the aim outline, pins on screen) and the current selection (the selected task in the review). Nothing else is accent-colored: no eyebrows, links, icons, chips or counters.
2. **Status is a dot, not a color scheme.** Positive, caution and negative appear only as a 5–6 pt dot or a small glyph next to neutral text. Never as text color, fill or border.
3. **No colored glows.** Depth comes from glass and a 1 pt hairline, not from colored shadows.
4. **Secondary actions are neutral.** Glass capsules with white text (`SecondaryButtonStyle`); quiet actions are text only (`QuietButtonStyle`). When several rows each have an action, only the one that matters next is primary.
5. **The brand lives in two places.** The mark's signal arcs and the aurora. The aurora keeps one hue on every screen; only its intensity changes.

## Backdrop

`Aurora` is a 3×3 `MeshGradient` whose inner points drift slowly (periods of 25–50 s). The lower-left control point carries the accent as a soft glow; onboarding steps change only its intensity, animated with a spring. `Grain` adds a fixed noise layer at 1.5–5% opacity so gradients don't band. Both stop moving when Reduce Motion is on.

## Type

System fonts only.

| Style | Spec |
|---|---|
| Hero | SF Pro Bold, expanded width, 52 pt, tracking −1.5 |
| Title | SF Pro Semibold, 30 pt, tracking −0.4 |
| Headline | Semibold, 15 pt |
| Body | Regular, 14 pt, line spacing +3 |
| Eyebrow | Semibold, expanded width, 11 pt, uppercase, tracking 1.4, 40% white |
| Mono | SF Mono Medium, 12 pt, used for paths, URLs and source locations |
| Transcript | Medium, 26 pt, used for live speech |

## Surfaces and shape

- Cards are `glassEffect(.regular.tint(night @ 10–30%))` in continuous rounded rectangles with a 20–24 pt radius. The item that needs attention gets a lighter glass and a 1 pt neutral stroke, not a color.
- Primary buttons are accent-gradient capsules with a top highlight and no shadow. Secondary buttons are interactive glass capsules. Tertiary buttons are text only.
- Keycaps are rounded squares with a 1.5 pt drop edge. Pressed keycaps sink and turn white.
- Status badges are a status dot plus a secondary-text label on a 5% fill with a hairline.

## Motion

| Token | Spring | Use |
|---|---|---|
| `snappy` | response 0.32, damping 0.86 | Presses, toggles, hover |
| `smooth` | 0.55, 0.9 | Layout and color changes |
| `bouncy` | 0.45, 0.62 | Success moments: checks, pins, arcs lighting |
| `step` | 0.6, 0.88 | Onboarding step transitions: slide 36 pt, fade, scale 0.98 |

Moments of delight are kept for real events: a permission granted, a pin dropped, a snippet closed, a task delivered. Everything else stays quiet. Reduce Motion replaces movement with fades.

## Copy

Short, direct, second person. Say what happens, not what the feature is called. Examples: "Scout hears you", "Switch on Scout", "Scout resumes right here". Avoid "packet", "capture mode" and other internal terms in the UI.
